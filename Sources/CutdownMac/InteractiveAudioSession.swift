import AppKit
import CutdownCore
import Foundation

/// Connects explicit effect-window actions to capture, PCM analysis and XML
/// project replacement. Recovery XML is saved before replacing the project; source media is unchanged.
@MainActor public final class InteractiveAudioSession {
    private struct Context {
        let capture: CapturedFinalCutProject
        let directory: URL
        let mediaSnapshot: MediaContentSnapshot
    }
    private let preview = TimelineCutPreview()
    private let analysisCache = AnalysisCache()
    public var onPreviewReady: ((UUID, ReviewAnalysisResult) -> Void)?
    private var reviewSession: FinalCutAXSession?
    private var restoringControllerSettings = false

    public func canReconnectReview(view: UUID) -> Bool {
        !restoringControllerSettings && reviewSession?.canReconnectReview(view: view) == true
    }

    public func updatePreview(_ id: UUID, review: ReviewPlan?) {
        guard let review, let context = contexts[id] else { preview.hide(); return }
        preview.show(review: review, session: context.capture.session)
    }

    private var verifications = PendingVerificationRegistry()

    public func canRetryVerification(_ id: UUID) -> Bool {
        verifications[id] != nil
    }

    private var contexts: [UUID: Context] = [:]
    public init() {}

    public func discard(_ requestID: UUID) {
        contexts.removeValue(forKey: requestID)
    }

    public func stop() {
        preview.hide()
        contexts.removeAll()
        reviewSession = nil
        verifications.removeAll()
        analysisCache.clear()
    }

    public func analyze(_ request: AnalyzeRequest,
                        progress: @escaping AnalysisReviewCoordinator.Progress) async throws -> ReviewAnalysisResult {
        // Only one coordinator job may run. Release earlier review contexts.
        preview.hide()
        contexts.removeAll()
        reviewSession = nil
        let directory = try FinalCutDialogueExport.makeJobDirectory(jobID: request.id)
        let timing = AnalysisTiming(request: request.id)
        var outcome = "failed"
        defer { timing.save(to: directory.appendingPathComponent("Analysis-Timing.json"),
            outcome: Task.isCancelled ? "cancelled" : outcome) }
        timing.begin("capture")
        let capture = try await FinalCutProjectCapture.capture(to: directory,
            controllerEffectUIDs: [AudioControllerSettings.effectUID],
            onSession: { self.reviewSession = $0 }) { progress($0, nil) }
        reviewSession = capture.session
        var renderedReceipt: ShareDestinationReceipt?
        var cleanup: (IsolatedAudioProject, Data)?
        var importedAnalysisName: String?
        var cleanupNotice: String?
        defer { if let receipt = renderedReceipt { try? ShareDestinationManager.shared.cleanupRenderedMedia(receipt: receipt) } }
        do {
            // One immutable input for routing, isolation, analysis, and preflight.
            let projectData = try Data(contentsOf: capture.xmlURL)
            try AudioControllerSettings.validateInteractive(projectData: projectData, target: capture.target,
                requested: request.settings)
            timing.begin("sourceValidation")
            progress("Checking source media before analysis…", nil)
            let media = try await Self.mediaSnapshot(capture.document)
            guard let sourceURL = capture.target.mediaURL else { throw SourceAudioError.invalidAudio }
            let route = try ClipAudioAnalysisRoute.resolve(projectData: projectData,
                selection: capture.selection)
            timing.begin("cacheValidationAndRecalculation")
            let key = try AnalysisCacheKey.make(data: projectData, document: capture.document, target: capture.target,
                media: media, windowDuration: request.settings.windowDuration,
                hostSession: "\(capture.session.application.processIdentifier):\(capture.session.application.launchDate?.timeIntervalSince1970 ?? 0)")
            let cached = try await analysisCache.reuse(key: key, document: capture.document, target: capture.target,
                settings: request.settings, jobID: request.id)
            timing.cache = key == nil ? "ineligible: processing state cannot be verified" : (cached == nil ? "miss" : "hit")
            let analyzed: AnalyzedAudioProject
            let scopeNotice: String
            if let cached {
                progress("Reusing verified audio measurements with the current detection settings…", nil)
                timing.begin("sourceValidationAfterReuse")
                try await media.validate()
                analyzed = cached
                scopeNotice = "Reused verified audio measurements after checking the current project and source contents."
            } else {
                let boundContext: DialogueRenderContext
                let audioURL: URL
                switch route {
                case .source:
                    boundContext = try DialogueRenderContext.capturedSource(document: capture.document,
                        target: capture.target, media: media)
                    audioURL = sourceURL
                    scopeNotice = "Analyzed original audio; this clip has no audio adjustments or processing effects."
                case .finalCutRender:
                    timing.begin("renderPreparation")
                    let isolated = try IsolatedAudioProject.make(projectData: projectData, selection: capture.selection)
                    let isolatedURL = directory.appendingPathComponent("Isolated.fcpxml")
                    try isolated.data.write(to: isolatedURL, options: .withoutOverwriting)
                    progress("Opening an isolated copy of the selected clip…", nil)
                    importedAnalysisName = isolated.name
                    try await XMLProjectApply.importIntoFinalCut(isolatedURL)
                    let isolatedSession = try await capture.session.openImportedProject(named: isolated.name, importedXML: isolatedURL)
                    do {
                        timing.begin("render")
                        progress("Rendering the isolated clip with its effects…", nil)
                        let receipt = try await isolatedSession.shareRenderedAudio()
                        renderedReceipt = receipt
                        guard receipt.mediaURLs.count == 1 else { throw ProjectAnalysisError.invalidRenderArtifact }
                        try ShareDestinationManager.shared.validateReceipt(receipt)
                        let deliveredXML = receipt.xmlURL.pathExtension.lowercased() == "fcpxmld"
                            ? receipt.xmlURL.appendingPathComponent("Info.fcpxml") : receipt.xmlURL
                        // The render delivers its own project XML. Compare that
                        // directly with the intended isolation before using any PCM,
                        // binding the host-assigned UUID here. A preceding XML-only
                        // Share would duplicate this same semantic verification.
                        timing.begin("renderVerification")
                        progress("Verifying the rendered clip and its effects…", nil)
                        let deliveredData = try Data(contentsOf: deliveredXML)
                        try ProjectRoundTripVerification.verify(expected: isolated.data, actual: deliveredData,
                            reportURL: directory.appendingPathComponent("Render-Verification.json"), allowHostAssignedIdentity: true)
                        cleanup = (isolated, deliveredData)
                        audioURL = receipt.mediaURLs[0]
                        boundContext = try DialogueRenderContext.capturedIsolated(document: capture.document, target: capture.target, audioURL: audioURL)
                        timing.begin("returnToOriginal")
                        _ = try await isolatedSession.returnToPreviousProject(named: capture.projectName)
                    } catch {
                        _ = try? await Task { @MainActor in
                            try await isolatedSession.returnToPreviousProject(named: capture.projectName)
                        }.value
                        throw error
                    }
                    scopeNotice = "Analyzed Final Cut’s rendered audio, including clip volume and enabled effects."
                }
                timing.begin("measurement")
                analyzed = try await ProjectAudioAnalysis.analyze(projectData: projectData,
                    selection: capture.selection, dialogueAudio: audioURL,
                    renderContext: boundContext, settings: request.settings, jobID: request.id,
                    capturedMedia: route == .source ? media : nil,
                    progress: { fraction in
                        Task { @MainActor in progress(route == .source
                            ? "Measuring selected source audio…" : "Measuring audio rendered by Final Cut…", fraction) }
                    }, validating: {
                        await MainActor.run {
                            timing.begin("audioValidationAfterMeasurement")
                            progress("Verifying source media after analysis…", nil)
                        }
                    }, detecting: { await MainActor.run { timing.begin("detection") } })
            }
            if route == .finalCutRender && cached == nil {
                timing.begin("sourceValidationAfterRender")
                try await media.validate()
                timing.begin("originalProjectVerification")
                progress("Checking the original project after rendering…", nil)
                let restored = try FinalCutAXSession()
                guard restored.projectName == capture.projectName else { throw FinalCutCaptureError.changedProject }
                let restoredURL = try await restored.exportProjectXML(to: directory.appendingPathComponent("After-Isolation.fcpxmld"))
                let restoredDocument = try TimelineParser.parse(url: restoredURL, exclusions: analyzed.dialogueContext.fingerprintExclusions)
                try XMLProjectApply.verifyBaseline(restoredDocument, analyzed: capture.document)
            }
            timing.begin("previewPreparation")
            // Prove that the selected cuts can be represented before enabling Apply.
            if !analyzed.review.selectedCuts.isEmpty {
                _ = try EditedProjectWriter.write(projectData: projectData,
                    selection: capture.selection, selectedRanges: analyzed.review.selectedCuts.map(\.range),
                    outputName: capture.projectName + " — Cutdown")
            }
            contexts[request.id] = Context(capture: capture,
                directory: directory, mediaSnapshot: media)
            if cached == nil {
                timing.begin("cacheStorage")
                do { try await analysisCache.store(key: key, analysis: analyzed, directory: directory) }
                catch is CancellationError { throw CancellationError() }
                catch { timing.cache += "; storage unavailable" }
            }
            try Task.checkCancellation()
            let early = ReviewAnalysisResult(analyzed: analyzed, dropFrame: capture.dropFrame,
                presentationNotice: scopeNotice)
            timing.markPreviewReady()
            onPreviewReady?(request.id, early)
            // The coordinator retains operation ownership and disables Apply
            // while this housekeeping runs. The verified preview is already visible.
            if let (isolated, delivered) = cleanup {
                timing.begin("cleanup")
                progress("Preview ready. Removing the temporary analysis project…", nil)
                do {
                    let restored = try FinalCutAXSession()
                    guard restored.projectName == capture.projectName else { throw FinalCutCaptureError.changedProject }
                    try await restored.removeAnalysisProject(isolated, verifiedData: delivered)
                    cleanup = nil; importedAnalysisName = nil
                } catch {
                    cleanupNotice = "Temporary project ‘\(isolated.name)’ remains in Cutdown Analysis: \(error.localizedDescription)"
                }
                try Data((cleanupNotice ?? "Temporary analysis project removed.").utf8)
                    .write(to: directory.appendingPathComponent("Cleanup-Status.txt"), options: .atomic)
            }
            timing.begin("restoreControls")
            let notice = await capture.restoreReviewWindow()
            try Task.checkCancellation()
            outcome = "review"
            return ReviewAnalysisResult(analyzed: analyzed, dropFrame: capture.dropFrame,
                presentationNotice: [scopeNotice + " Threshold uses 10 ms average loudness (RMS), not peak meters. Apply replaces this project in its current event and saves recovery XML before import. Import verification automatically recovers saved Cutdown settings if Final Cut resets them. Quiet breaths may qualify; this detector does not classify breaths.", cleanupNotice, notice].compactMap { $0 }.joined(separator: " "))
        } catch {
            // A cancellation must not prevent bounded cleanup of a verified,
            // request-owned project after returning to the original timeline.
            if let (isolated, delivered) = cleanup {
                let cleaned = await Task { @MainActor in
                    do {
                        let restored = try FinalCutAXSession()
                        guard restored.projectName == capture.projectName else { return false }
                        try await restored.removeAnalysisProject(isolated, verifiedData: delivered)
                        return true
                    } catch { return false }
                }.value
                if cleaned { importedAnalysisName = nil }
            }
            if let name = importedAnalysisName {
                try? Data("Analysis interrupted; ‘\(name)’ may remain in Cutdown Analysis. Ownership/content verification or cleanup did not complete; no unverified project was deleted.\n".utf8)
                    .write(to: directory.appendingPathComponent("Cleanup-Status.txt"), options: .atomic)
            }
            _ = await capture.restoreReviewWindow()
            throw error
        }
    }

    public func apply(_ request: AnalyzeRequest, result: ReviewAnalysisResult,
                      progress: @escaping AnalysisReviewCoordinator.Progress) async throws {
        guard let context = contexts.removeValue(forKey: request.id) else {
            throw AudioProjectProcessingError.changedProject
        }
        let capture = context.capture
        let session = capture.session
        let parent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cutdown/Results", isDirectory: true)
            .appendingPathComponent(request.id.uuidString, isDirectory: true)
        var prepared: PreparedXMLProject?
        var importAttempted = false
        do {
            let removals = result.analyzed.review.selectedCuts.map(\.range)
            guard !removals.isEmpty else { throw EditedProjectWriterError.noSelectedCuts }
            let exclusions = result.analyzed.dialogueContext.fingerprintExclusions
            try await session.activate()
            progress("Checking the current project before replacing it…", 0)
            let finalURL = try await session.exportProjectXML(to: context.directory.appendingPathComponent("Before-XML-Apply.fcpxmld"))
            let finalData = try Data(contentsOf: finalURL)
            let final = try TimelineParser.parse(data: finalData, exclusions: exclusions)
            try XMLProjectApply.verifyBaseline(final, analyzed: capture.document)
            guard try await Self.mediaSnapshot(final) == context.mediaSnapshot else { throw AudioProjectProcessingError.changedProject }
            try AudioControllerSettings.validateInteractive(projectData: finalData, target: final.selectedTarget(capture.selection),
                requested: result.analyzed.settings)
            try Task.checkCancellation()
            progress("Creating all selected cuts in the edited project…", 0.4)
            let outputName = capture.projectName
            let artifact = try XMLProjectApply.prepare(projectData: finalData, selection: capture.selection,
                cuts: removals, settings: result.analyzed.settings, mode: request.outputMode,
                outputName: outputName, directory: parent, replaceOriginal: true)
            prepared = artifact
            if let target = artifact.output.report.replacementTarget {
                try await session.prepareReplacementBrowser(target)
            }
            try session.assertCurrentProject()
            progress("Sending ‘\(outputName)’ to Final Cut Pro…", 0.8)
            try Data("Import requested; verification pending. Do not import again until checking Final Cut.\n".utf8)
                .write(to: parent.appendingPathComponent("Import-Status.txt"), options: .atomic)
            let verification = try ImportedResultVerification(expected: artifact.output.xmlData, outputURL: artifact.outputURL,
                originalProjectName: capture.projectName, request: request, replacementTarget: artifact.output.report.replacementTarget)
            try await artifact.send { url in
                try verification.savePending()
                importAttempted = true
                self.verifications.remember(request.id, at: verification.outputURL)
                try await XMLProjectApply.importIntoFinalCut(url)
            }
            try await retryVerification(request.id, progress: progress, acceptReplacement: true)
        } catch {
            _ = await capture.restoreReviewWindow()
            if error is XMLProjectApplyFailure { throw error }
            if let prepared {
                let failure = XMLProjectApplyFailure(cause: error, outputURL: prepared.outputURL, importAttempted: importAttempted, replacingOriginal: prepared.output.report.replacementTarget != nil)
                try? failure.saveStatus()
                throw failure
            }
            throw error
        }
    }

    public func loadVerification(_ outputURL: URL, view: UUID) throws -> AnalyzeRequest {
        let session = try FinalCutAXSession()
        try session.rememberReviewSelection(session.selectionSnapshot())
        guard session.canReconnectReview(view: view) else {
            throw FinalCutCaptureError.unavailable("Select the clip belonging to this Controls window before verifying a result.")
        }
        let request = try loadVerification(outputURL)
        reviewSession = session
        return request
    }

    public func loadVerification(_ outputURL: URL) throws -> AnalyzeRequest {
        let result = try ImportedResultVerification.load(outputURL: outputURL)
        verifications.remember(result.request.id, at: outputURL)
        return result.request
    }

    public func retryVerification(_ id: UUID, progress: @escaping AnalysisReviewCoordinator.Progress, acceptReplacement: Bool = false) async throws {
        guard let outputURL = verifications[id] else {
            throw FinalCutCaptureError.unavailable("There is no pending imported result to verify.")
        }
        let result = try ImportedResultVerification.load(outputURL: outputURL)
        let parent = result.outputURL.deletingLastPathComponent()
        do {
            let current = try FinalCutAXSession(allowImportDialog: true, allowEmptyTimeline: result.replacementTarget != nil)
            guard result.replacementTarget != nil || current.projectName == result.originalProjectName || current.projectName == result.projectName else {
                throw FinalCutCaptureError.unavailable("Open the original project or ‘\(result.projectName)’ before retrying verification.")
            }
            progress("Checking the existing imported project…", 0.9)
            let imported = try await current.openImportedProject(named: result.projectName, importedXML: result.outputURL, replacement: result.replacementTarget, acceptReplacement: acceptReplacement)
            _ = try await result.verify(capture: {
                let url = try await imported.exportProjectXML(to: parent.appendingPathComponent("Verification-\(UUID().uuidString).fcpxmld"))
                return try Data(contentsOf: url)
            }, restore: { correction, document in
                progress("Restoring Cutdown settings on ‘\(correction.clip.name)’…", nil)
                // These temporary Controls views are being written by recovery,
                // not offered for review. A reconnect could disable their fields.
                self.restoringControllerSettings = true
                defer { self.restoringControllerSettings = false }
                try await imported.restoreControllerSettings(correction.settings, clip: correction.clip, document: document)
            })
            let disposition = result.replacementTarget == nil ? "Original project unchanged." : "Project replaced in its original event. Recovery XML saved in the result folder."
            let message = "Verified ‘\(result.projectName)’: timeline, source media, rendering effects, and Cutdown settings match. \(disposition)"
            try Data((message + "\n").utf8).write(to: parent.appendingPathComponent("Import-Status.txt"), options: .atomic)
            result.markComplete()
            verifications.remove(id)
            progress(message, 1)
        } catch {
            let failure = XMLProjectApplyFailure(cause: error, outputURL: result.outputURL, importAttempted: true, replacingOriginal: result.replacementTarget != nil)
            try? failure.saveStatus()
            throw failure
        }
    }

    public func highlight(_ request: AnalyzeRequest, result: ReviewAnalysisResult, cutID: String) async throws {
        guard let context = contexts[request.id],
              let cut = result.analyzed.review.cuts.first(where: { $0.id == cutID }) else { throw ReviewError.unknownCut }
        let session = context.capture.session
        try await session.activate()
        let url = try await session.exportProjectXML(to: context.directory.appendingPathComponent("Before-Jump-\(UUID().uuidString).fcpxmld"))
        let document = try TimelineParser.parse(url: url, exclusions: result.analyzed.dialogueContext.fingerprintExclusions)
        try XMLProjectApply.verifyBaseline(document, analyzed: context.capture.document)
        try await session.movePlayhead(to: cut.range.start, document: document, dropFrame: result.dropFrame)
    }

    private nonisolated static func mediaSnapshot(_ document: TimelineDocument) async throws -> MediaContentSnapshot {
        try await MediaContentSnapshot.capture(document.clips.filter(\.enabled).compactMap(\.mediaURL))
    }
}
