import AppKit
import CryptoKit
import SilentSnipCore
import Foundation

/// Connects explicit effect-window actions to capture, PCM analysis and XML
/// creation of a separate, editable project copy. The original project and source media stay unchanged.
@MainActor public final class InteractiveAudioSession {
    private struct Context {
        let capture: CapturedFinalCutProject
        let directory: URL
        let mediaSnapshot: MediaContentSnapshot
        let sourceOnlyProjectDigest: SHA256.Digest?
    }
    private let preview = TimelineCutPreview()
    private let analysisCache = AnalysisCache()
    private let routingHintStore = DirectAudioRenderHintStore()
    private var routingHintMaintenance: Task<Void, Never>?
    public var onPreviewReady: ((UUID, ReviewAnalysisResult) -> Void)?
    private var reviewSession: FinalCutAXSession?
    public private(set) var reviewRequestID: UUID?
    private var restoringControllerSettings = false
    private var lastReviewAuthorizationFailure: String?

    public func canReconnectReview(view: UUID) -> Bool {
        guard !restoringControllerSettings, let session = reviewSession else { return false }
        let reason = session.reviewReconnectFailure(view: view)
        if let reason, reason != lastReviewAuthorizationFailure,
           let context = contexts.values.first(where: { $0.capture.session === session }) {
            let report = ["reason": reason, "view": view.uuidString]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: context.directory.appendingPathComponent("Review-Authorization.json"), options: .atomic)
            }
        }
        lastReviewAuthorizationFailure = reason
        return reason == nil
    }

    public func restoreReviewAfterLateCompletion(_ directory: URL, request: UUID) async {
        await contexts[request]?.capture.session.raiseReviewAfterLateCompletion(directory: directory)
    }

    public func canAuthorizeApply(view: UUID, gesture: UUID) -> Bool {
        !restoringControllerSettings && reviewSession?.canAuthorizeApply(view: view, gesture: gesture) == true
    }

    public func canAuthorizePreview(view: UUID, edit: UUID) -> Bool {
        !restoringControllerSettings && reviewSession?.canAuthorizePreview(view: view, edit: edit) == true
    }

    public func canAuthorizeNativeNavigation(_ command: ReviewCommand) -> Bool {
        guard !restoringControllerSettings, let view = command.view, let gesture = command.navigationGesture,
              reviewRequestID == command.request, let context = contexts[command.request],
              let session = reviewSession, session === context.capture.session,
              let selected = session.reviewOwnership.active,
              (try? selected.resolve(in: context.capture.document).1) == context.capture.target else { return false }
        return session.canAuthorizeWorkflowNavigation(view: view, gesture: gesture)
    }

    public func canAuthorizeRecalculation(_ command: ReviewCommand) -> Bool {
        guard command.localPreview == true, let view = command.view, let edit = command.settingsEdit else { return false }
        guard command.automaticPreview == true else { return canAuthorizePreview(view: view, edit: edit) }
        guard !restoringControllerSettings, command.verifySettings == true,
              reviewRequestID == command.request, let context = contexts[command.request],
              let session = reviewSession, session === context.capture.session,
              session.workflowOrigin?.view == view, let settings = command.settings,
              let rawOutput = command.output, let output = SilentSnipOutputMode(rawValue: rawOutput) else { return false }
        return session.canAuthorizeWorkflowAutomaticPreview(view: view, edit: edit, settings: settings, output: output)
    }

    public func recordLocalPreview(_ id: UUID, seconds: Double, succeeded: Bool) {
        guard let context = contexts[id] else { return }
        let report: [String: Any] = ["request": id.uuidString, "elapsedSeconds": seconds,
            "shareExchanges": 0, "audioSnapshot": true, "outcome": succeeded ? "preview" : "failed"]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: context.directory.appendingPathComponent("Local-Preview-Timing.json"), options: .atomic)
        }
    }

    public func updateCutsPreview(_ request: AnalyzeRequest, result: ReviewAnalysisResult,
                                  progress: @escaping AnalysisReviewCoordinator.Progress) async throws {
        guard let context = contexts[request.id], result.usesAudioSnapshot,
              result.analyzed.settings == request.settings else { throw ReviewError.staleProject }
        try validateReviewSelection(context.capture)
        try Task.checkCancellation()
    }

    private func validateReviewSelection(_ capture: CapturedFinalCutProject) throws {
        let session = capture.session
        try session.assertCurrentProject()
        guard let expected = session.reviewOwnership.active,
              (try? session.selectionSnapshot()) == expected,
              (try? expected.resolve(in: capture.document).1) == capture.target else {
            throw ReviewError.staleProject
        }
    }

    public func updatePreview(_ id: UUID, review: ReviewPlan?) {
        guard let review, let context = contexts[id] else { preview.hide(); return }
        preview.show(review: review, session: context.capture.session)
    }

    private var verifications = PendingVerificationRegistry()
    // A new Workflow recovery gesture first proves the SDK's currently open
    // project with fresh XML, before navigating to the already imported result.
    private var recoveryOrigins: [UUID: WorkflowReviewOrigin] = [:]

    public func canRetryVerification(_ id: UUID) -> Bool {
        verifications[id] != nil
    }

    private var contexts: [UUID: Context] = [:]
    public init() {}

    public var storageProtectedURLs: Set<URL> {
        Set(analysisCache.protectedAudio.map { [$0] } ?? [])
    }

    /// Cached analysis is optional; existing review/recovery state stays intact.
    public func clearAnalysisCache() {
        analysisCache.discardForCleanup()
        let previous = routingHintMaintenance, store = routingHintStore
        routingHintMaintenance = Task {
            await previous?.value
            await store.clear()
        }
    }

    public func discard(_ requestID: UUID) {
        contexts.removeValue(forKey: requestID)
        if reviewRequestID == requestID, verifications[requestID] == nil {
            reviewSession = nil; reviewRequestID = nil
        }
    }

    public func stop() {
        preview.hide()
        contexts.removeAll()
        reviewSession = nil
        reviewRequestID = nil
        verifications.removeAll()
        recoveryOrigins.removeAll()
        analysisCache.clear()
    }

    public func analyze(_ request: AnalyzeRequest,
                        progress: @escaping AnalysisReviewCoordinator.Progress) async throws -> ReviewAnalysisResult {
        if request.workflowOrigin != nil { try WorkflowReviewOrigin.validate(settings: request.settings) }
        // Only one coordinator job may run. Release earlier review contexts.
        preview.hide()
        contexts.removeAll()
        reviewSession = nil
        reviewRequestID = request.id
        let directory = try FinalCutDialogueExport.makeJobDirectory(jobID: request.id)
        let timing = AnalysisTiming(request: request.id)
        var outcome = "failed"
        defer { timing.save(to: directory.appendingPathComponent("Analysis-Timing.json"),
            outcome: Task.isCancelled ? "cancelled" : outcome) }
        timing.begin("capture")
        await routingHintMaintenance?.value
        try Task.checkCancellation()
        let capture: CapturedFinalCutProject
        do {
            capture = try await FinalCutProjectCapture.capture(to: directory,
                controllerEffectUIDs: [AudioControllerSettings.effectUID],
                timing: timing, routingHintStore: routingHintStore,
                workflowOrigin: request.workflowOrigin,
                onSession: { if !Task.isCancelled { self.reviewSession = $0 } }) { progress($0, nil) }
        } catch {
            try? Data(error.localizedDescription.utf8).write(
                to: directory.appendingPathComponent("Analysis-Failure.txt"), options: .atomic)
            throw error
        }
        reviewSession = capture.session
        var renderedReceipt: ShareDestinationReceipt? = capture.renderedAudio
        var cleanup: (IsolatedAudioProject, Data)?
        var importedAnalysisName: String?
        var cleanupNotice: String?
        var renderedInOriginal = false
        defer { if let receipt = renderedReceipt { try? ShareDestinationManager.shared.cleanupRenderedMedia(receipt: receipt) } }
        do {
            // Capture transfers request-owned audio even if cancellation arrives
            // during Share. Install cleanup before observing that cancellation.
            try Task.checkCancellation()
            // One immutable input for routing, isolation, analysis, and preflight.
            let projectData = try Data(contentsOf: capture.xmlURL)
            if let origin = request.workflowOrigin { try origin.verify(projectData: projectData) }
            else {
                try AudioControllerSettings.validateInteractive(projectData: projectData, target: capture.target,
                    requested: request.settings)
            }
            timing.begin("sourceValidation")
            progress("Checking source media before analysis…", nil)
            let mediaReadGuard = try MediaContentSnapshot.prepareRead(capture.document.clips.filter(\.enabled).compactMap(\.mediaURL))
            async let pendingMedia = Self.mediaSnapshot(capture.document, renderedMedia: capture.renderedMedia, prepared: mediaReadGuard)
            let cacheEligible = try AnalysisCacheKey.isEligible(data: projectData, target: capture.target)
            // Ineligible effects must render on every manual Analyze. Overlap
            // their host exchange with hashing, then join before accepting PCM.
            let earlyMedia: MediaContentSnapshot?
            if cacheEligible { earlyMedia = try await pendingMedia } else { earlyMedia = nil }
            guard let sourceURL = capture.target.mediaURL else { throw SourceAudioError.invalidAudio }
            let route = try ClipAudioAnalysisRoute.resolve(projectData: projectData,
                selection: capture.selection)
            timing.begin("cacheValidationAndRecalculation")
            let key = try earlyMedia.flatMap { media in try AnalysisCacheKey.make(data: projectData, document: capture.document, target: capture.target,
                media: media, windowDuration: request.settings.windowDuration,
                hostSession: "\(capture.session.application.processIdentifier):\(capture.session.application.launchDate?.timeIntervalSince1970 ?? 0)") }
            let cached = try await analysisCache.reuse(key: key, document: capture.document, target: capture.target,
                settings: request.settings, jobID: request.id)
            timing.cache = key == nil ? "ineligible: processing state cannot be verified" : (cached == nil ? "miss" : "hit")
            let analyzed: AnalyzedAudioProject
            let scopeNotice: String
            if let cached {
                progress("Reusing verified audio measurements with the current detection settings…", nil)
                timing.begin("sourceValidationAfterReuse")
                try await pendingMedia.validate()
                analyzed = cached
                scopeNotice = "Reused verified audio measurements after checking the current project and source contents."
            } else {
                let boundContext: DialogueRenderContext
                let audioURL: URL
                switch route {
                case .source:
                    boundContext = try DialogueRenderContext.capturedSource(document: capture.document,
                        target: capture.target, media: try await pendingMedia, workflowOrigin: request.workflowOrigin)
                    audioURL = sourceURL
                    scopeNotice = "Analyzed original audio; this clip has no audio adjustments or processing effects."
                case .finalCutRender:
                    if let renderScope = try DirectAudioRender.scope(projectData: projectData, selection: capture.selection) {
                        timing.recordCounters(["directRender.scope." + renderScope.rawValue: 1])
                        timing.begin("directRender")
                        progress("Rendering the selected clip with its effects…", nil)
                        let receipt: ShareDestinationReceipt
                        if let combined = capture.renderedAudio {
                            receipt = combined
                        } else {
                            let renderSelection: FinalCutSelectionSnapshot?
                            if renderScope != .selectedRange { renderSelection = nil }
                            else {
                                guard let active = capture.session.reviewOwnership.active else { throw AudioControllerSettingsError.targetChanged }
                                renderSelection = active
                            }
                            receipt = try await capture.session.shareRenderedAudio(timing: timing, renderSelection: renderSelection, sharePurpose: .analyze)
                            renderedReceipt = receipt
                        }
                        guard receipt.mediaURLs.count == 1 else { throw ProjectAnalysisError.invalidRenderArtifact }
                        try ShareDestinationManager.shared.validateReceipt(receipt)
                        let deliveredXML = receipt.xmlURL.pathExtension.lowercased() == "fcpxmld"
                            ? receipt.xmlURL.appendingPathComponent("Info.fcpxml") : receipt.xmlURL
                        let deliveredData = try Data(contentsOf: deliveredXML)
                        try request.workflowOrigin?.verify(projectData: deliveredData)
                        timing.begin("directRenderVerification")
                        // The same exchange delivers PCM and fresh XML. Identity,
                        // source trim, effects and scope all remain authoritative.
                        try ProjectRoundTripVerification.verify(expected: projectData, actual: deliveredData,
                            reportURL: directory.appendingPathComponent("Render-Verification.json"))
                        guard try DirectAudioRender.scope(projectData: deliveredData, selection: capture.selection) == renderScope else {
                            throw ProjectAnalysisError.staleRender
                        }
                        try await capture.session.focusTimeline()
                        guard try capture.session.selectionSnapshot() == capture.session.reviewOwnership.active else {
                            throw AudioControllerSettingsError.targetChanged
                        }
                        audioURL = receipt.mediaURLs[0]
                        boundContext = try await DialogueRenderContext.capturedNativeRender(document: capture.document,
                            target: capture.target, audioURL: audioURL, receipt: receipt, projectSlice: renderScope == .projectSlice,
                            workflowOrigin: request.workflowOrigin)
                        try ShareDestinationManager.shared.validateReceipt(receipt)
                        renderedInOriginal = true
                    } else {
                        timing.begin("renderPreparation")
                        let isolated = try IsolatedAudioProject.make(projectData: projectData, selection: capture.selection)
                        try EditableEffectReconstruction.validate(projectData: isolated.data)
                        let isolatedURL = directory.appendingPathComponent("Isolated.fcpxml")
                        try isolated.data.write(to: isolatedURL, options: .withoutOverwriting)
                        progress("Opening an isolated copy of the selected clip…", nil)
                        importedAnalysisName = isolated.name
                        try await XMLProjectApply.importIntoFinalCut(isolatedURL)
                        let isolatedSession = try await capture.session.openImportedProject(named: isolated.name, importedXML: isolatedURL)
                        do {
                            timing.begin("render")
                            progress("Rendering the isolated clip with its effects…", nil)
                            let receipt = try await isolatedSession.shareRenderedAudio(timing: timing)
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
                            try isolated.destination.verifyDestination(deliveredData)
                            cleanup = (isolated, deliveredData)
                            audioURL = receipt.mediaURLs[0]
                            boundContext = try await DialogueRenderContext.capturedNativeRender(document: capture.document,
                                target: capture.target, audioURL: audioURL, receipt: receipt, workflowOrigin: request.workflowOrigin)
                            try ShareDestinationManager.shared.validateReceipt(receipt)
                            timing.begin("returnToOriginal")
                            _ = try await isolatedSession.returnToPreviousProject(named: capture.projectName)
                        } catch {
                            _ = try? await Task { @MainActor in
                                try await isolatedSession.returnToPreviousProject(named: capture.projectName)
                            }.value
                            throw error
                        }
                    }
                    scopeNotice = "Analyzed Final Cut Pro’s rendered audio, including clip volume and enabled audio effects."
                }
                timing.begin("measurement")
                analyzed = try await ProjectAudioAnalysis.analyze(projectData: projectData,
                    selection: capture.selection, dialogueAudio: audioURL,
                    renderContext: boundContext, settings: request.settings, jobID: request.id,
                    capturedMedia: route == .source ? try await pendingMedia : nil,
                    progress: { fraction in
                        Task { @MainActor in progress(route == .source
                            ? "Measuring selected source audio…" : "Measuring audio rendered by Final Cut Pro…", fraction) }
                    }, validating: {
                        await MainActor.run {
                            timing.begin("audioValidationAfterMeasurement")
                            progress("Verifying source media after analysis…", nil)
                        }
                    }, detecting: { await MainActor.run { timing.begin("detection") } })
            }
            let media = try await pendingMedia
            try mediaReadGuard.validate()
            if capture.renderedMedia != nil { timing.incrementCounter("capture.reusedCombinedSourceHashes") }
            if route == .finalCutRender && cached == nil {
                timing.begin("sourceValidationAfterRender")
                try await media.validate()
                if !renderedInOriginal {
                    timing.begin("originalProjectVerification")
                    progress("Checking the original project after rendering…", nil)
                    let restored = try FinalCutAXSession(inheritingWorkflowFrom: capture.session)
                    guard restored.projectName == capture.projectName else { throw FinalCutCaptureError.changedProject }
                    let restoredURL = try await restored.exportProjectXML(to: directory.appendingPathComponent("After-Isolation.fcpxmld"), timing: timing)
                    let restoredData = try Data(contentsOf: restoredURL)
                    try request.workflowOrigin?.verify(projectData: restoredData)
                    let restoredDocument = try TimelineParser.parse(data: restoredData, exclusions: analyzed.dialogueContext.fingerprintExclusions)
                    try XMLProjectApply.verifyBaseline(restoredDocument, analyzed: capture.document)
                    capture.session.lastXMLShareDirectory = restored.lastXMLShareDirectory
                }
            }
            timing.begin("previewPreparation")
            // Prove that the selected cuts can be represented before enabling Apply.
            if !analyzed.review.selectedCuts.isEmpty {
                try Self.validateEditableOutput(projectData: projectData, selection: capture.selection,
                    cuts: analyzed.review.selectedCuts.map(\.range), request: request,
                    outputName: Self.outputName(clip: capture.target, request: request.id))
            }
            let mayApplySourceOnly = request.workflowOrigin != nil && route == .source
                && capture.document.clips.count == 1 && !capture.target.hasVideo
            contexts[request.id] = Context(capture: capture, directory: directory, mediaSnapshot: media,
                sourceOnlyProjectDigest: mayApplySourceOnly ? SHA256.hash(data: projectData) : nil)
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
                    let restored = try FinalCutAXSession(inheritingWorkflowFrom: capture.session)
                    guard restored.projectName == capture.projectName else { throw FinalCutCaptureError.changedProject }
                    try await restored.removeAnalysisProject(isolated, verifiedData: delivered)
                    cleanup = nil; importedAnalysisName = nil
                } catch {
                    cleanupNotice = "Temporary project ‘\(isolated.name)’ remains in ‘\(isolated.destination.eventName)’: \(error.localizedDescription)"
                }
                try Data((cleanupNotice ?? "Temporary analysis project removed.").utf8)
                    .write(to: directory.appendingPathComponent("Cleanup-Status.txt"), options: .atomic)
            }
            timing.begin("restoreControls")
            let notice = await capture.presentReviewWindow()
            timing.recordCounters(capture.session.workflowReviewLookupCounters())
            recordPresentation(notice, in: directory)
            try Task.checkCancellation()
            if renderedInOriginal, key == nil, let selection = capture.session.reviewOwnership.active,
               let scope = try DirectAudioRender.scope(projectData: projectData, selection: capture.selection) {
                let hint = DirectAudioRenderHint(selection: selection,
                    sourceURLs: capture.document.clips.filter(\.enabled).compactMap(\.mediaURL),
                    scope: scope, workflowIdentity: request.workflowOrigin.map { .init(origin: $0) })
                _ = await timing.measure("capture.routingHintStorage") { await routingHintStore.save(hint) }
                try Task.checkCancellation()
            }
            outcome = "review"
            return ReviewAnalysisResult(analyzed: analyzed, dropFrame: capture.dropFrame,
                presentationNotice: [scopeNotice + " Threshold uses 10 ms average loudness (RMS), not peak meters. Apply cuts the source clips in a cleaned project copy and keeps their audio effects editable. Quiet breaths may qualify; this detector does not classify breaths.", cleanupNotice, notice].compactMap { $0 }.joined(separator: " "),
                canUpdateCuts: route == .source || renderedInOriginal)
        } catch {
            // A cancellation must not prevent bounded cleanup of a verified,
            // request-owned project after returning to the original timeline.
            if let (isolated, delivered) = cleanup {
                let cleaned = await Task { @MainActor in
                    do {
                        let restored = try FinalCutAXSession(inheritingWorkflowFrom: capture.session)
                        guard restored.projectName == capture.projectName else { return false }
                        try await restored.removeAnalysisProject(isolated, verifiedData: delivered)
                        return true
                    } catch { return false }
                }.value
                if cleaned { importedAnalysisName = nil }
            }
            if let name = importedAnalysisName {
                try? Data("Analysis interrupted; ‘\(name)’ may remain in the original event. Ownership/content verification or cleanup did not complete; no unverified project was deleted.\n".utf8)
                    .write(to: directory.appendingPathComponent("Cleanup-Status.txt"), options: .atomic)
            }
            let guidance = await capture.restoreReviewWindow()
            var failure: Error = error
            if let guidance, !Task.isCancelled, !(error is CancellationError) {
                failure = FinalCutCaptureError.reviewRestoration(
                    original: error.localizedDescription, guidance: guidance)
            }
            try? Data(failure.localizedDescription.utf8).write(
                to: directory.appendingPathComponent("Analysis-Failure.txt"), options: .atomic)
            throw failure
        }
    }

    /// Recalculate only the currently retained review. A fresh XML/media and
    /// selection check gates Apply; this is not a cross-analysis effects cache.
    public func verifySettingsPreview(_ request: AnalyzeRequest, result: ReviewAnalysisResult,
                                      progress: @escaping AnalysisReviewCoordinator.Progress) async throws {
        guard let context = contexts[request.id], let selection = context.capture.session.reviewOwnership.active,
              result.analyzed.settings == request.settings else { throw AudioProjectProcessingError.changedProject }
        let session = context.capture.session
        let timing = AnalysisTiming(request: request.id)
        var outcome = "failed"
        let attempt = UUID()
        defer { timing.save(to: context.directory.appendingPathComponent("Settings-Timing-\(attempt).json"),
            outcome: Task.isCancelled ? "cancelled" : outcome) }
        do {
            timing.begin("projectVerification")
            progress("Preview updated. Verifying the current project…", nil)
            try await session.activate()
            let url = try await session.exportProjectXML(to: context.directory.appendingPathComponent("Settings-Check-\(attempt).fcpxmld"), timing: timing)
            let data = try Data(contentsOf: url)
            let current = try TimelineParser.parse(data: data, exclusions: result.analyzed.dialogueContext.fingerprintExclusions)
            try XMLProjectApply.verifyBaseline(current, analyzed: context.capture.document)
            guard try session.selectionSnapshot() == selection else { throw AudioControllerSettingsError.targetChanged }
            if let origin = request.workflowOrigin { try origin.verify(projectData: data) }
            else {
                try AudioControllerSettings.validateForApply(projectData: data, target: current.selectedTarget(context.capture.selection),
                    requested: request.settings)
            }
            timing.begin("mediaVerification")
            guard try await Self.mediaSnapshot(current) == context.mediaSnapshot else { throw AudioProjectProcessingError.changedProject }
            try Task.checkCancellation()
            timing.begin("editValidation")
            if !result.analyzed.review.selectedCuts.isEmpty {
                try Self.validateEditableOutput(projectData: data, selection: context.capture.selection,
                    cuts: result.analyzed.review.selectedCuts.map(\.range), request: request,
                    outputName: Self.outputName(clip: context.capture.target, request: request.id))
            }
            try Task.checkCancellation()
            timing.begin("restoreControls")
            let notice = await context.capture.presentReviewWindow()
            recordPresentation(notice, in: context.directory)
            try Task.checkCancellation()
            outcome = "verified"
        } catch {
            _ = await context.capture.restoreReviewWindow()
            throw error
        }
    }

    private func recordPresentation(_ guidance: String?, in directory: URL) {
        let report = ["state": guidance == nil ? "focused" : "manual-reopen-required",
                      "guidance": guidance ?? "Controls is the focused Final Cut window."]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("Review-Presentation.json"), options: .atomic)
        }
    }

    public func apply(_ request: AnalyzeRequest, result: ReviewAnalysisResult,
                      progress: @escaping AnalysisReviewCoordinator.Progress) async throws {
        guard let context = contexts.removeValue(forKey: request.id) else {
            throw AudioProjectProcessingError.changedProject
        }
        let capture = context.capture
        let session = capture.session
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Silent Snip", isDirectory: true)
        let parent = support.appendingPathComponent("Results", isDirectory: true)
            .appendingPathComponent(request.id.uuidString, isDirectory: true)
        var prepared: PreparedXMLProject?
        var importAttempted = false
        var bulkTransferStarted = false
        var fullMixReceipt: ShareDestinationReceipt?
        let timing = AnalysisTiming(request: request.id)
        var outcome = "failed"
        defer {
            if let fullMixReceipt { try? ShareDestinationManager.shared.cleanupRenderedMedia(receipt: fullMixReceipt) }
            timing.save(to: context.directory.appendingPathComponent("Apply-Timing.json"),
                outcome: Task.isCancelled ? "cancelled" : outcome)
        }
        do {
            let removals = result.analyzed.review.selectedCuts.map(\.range)
            guard !removals.isEmpty else { throw EditedProjectWriterError.noSelectedCuts }
            let exclusions = result.analyzed.dialogueContext.fingerprintExclusions
            try await session.activate()
            try validateReviewSelection(capture)
            try await session.suspendReviewWindow()
            try await session.activate()
            let baselineData = try Data(contentsOf: capture.xmlURL)
            if let digest = context.sourceOnlyProjectDigest, SHA256.hash(data: baselineData) != digest {
                throw AudioProjectProcessingError.changedProject
            }
            let applyRoute = try ClipAudioAnalysisRoute.resolve(projectData: baselineData, selection: capture.selection)
            let nativePlan = try Self.nativeEditPlanIfNeeded(projectData: baselineData,
                selection: capture.selection, cuts: removals, request: request)
            let finalData: Data
            let final: TimelineDocument
            let outputMedia: MediaContentSnapshot
            let readGuard: MediaContentSnapshot.ReadGuard
            let renderGuard: MediaContentSnapshot.ReadGuard?
            let sourceOnly: XMLProjectApply.SourceOnlyEvidence?
            if context.sourceOnlyProjectDigest != nil, request.workflowOrigin != nil, applyRoute == .source, nativePlan == nil,
               result.analyzed.dialogueContext.sourceRange != nil,
               let evidence = try XMLProjectApply.sourceOnlyEvidence(projectData: baselineData,
                   document: capture.document, target: capture.target),
               let guardValue = try context.mediaSnapshot.prepareValidationRead() {
                // Stage from the immutable Analyze baseline. The final Share
                // after the full source scan must prove these same XML inputs.
                guard context.mediaSnapshot.covers(capture.document.clips.filter(\.enabled).compactMap(\.mediaURL)) else {
                    throw ProjectAnalysisError.changedRenderArtifact
                }
                sourceOnly = evidence
                finalData = baselineData
                final = capture.document
                outputMedia = context.mediaSnapshot
                readGuard = guardValue
                renderGuard = nil
                timing.incrementCounter("apply.sourceOnlyXML")
            } else {
                sourceOnly = nil
                timing.begin("projectAndAudioVerification")
                progress("Rendering project audio before applying cuts…", 0.05)
                let roles = try FinalCutAudioMixScope.expectedRoles(projectData: baselineData)
                // Recheck the current native processing before editing source clips.
                // Detection remains Dialogue-only; the complete mix is never
                // substituted for a mixed target's review or for result media.
                let sourceCapture = try await ApplyAudioRenderCapture.perform(sourceMedia: context.mediaSnapshot,
                    render: {
                        try await session.shareRenderedAudio(timing: timing,
                            mixScope: .fullProjectMix(expectedRoles: roles), sharePurpose: .apply)
                    }, cleanup: { try? ShareDestinationManager.shared.cleanupRenderedMedia(receipt: $0) })
                let receipt = sourceCapture.receipt
                fullMixReceipt = receipt
                readGuard = sourceCapture.readGuard
                if sourceCapture.overlappedSourceValidation {
                    timing.recordCounters(["apply.sourceHashOverlapsRender": 1])
                }
                try ShareDestinationManager.shared.validateReceipt(receipt)
                guard receipt.mediaURLs.count == 1 else { throw ProjectAnalysisError.invalidRenderArtifact }
                let finalURL = receipt.xmlURL.pathExtension.lowercased() == "fcpxmld"
                    ? receipt.xmlURL.appendingPathComponent("Info.fcpxml") : receipt.xmlURL
                finalData = try Data(contentsOf: finalURL)
                final = try TimelineParser.parse(data: finalData, exclusions: exclusions)
                try XMLProjectApply.verifyBaseline(final, analyzed: capture.document)
                guard try FinalCutAudioMixScope.expectedRoles(projectData: finalData) == roles else {
                    throw AudioProjectProcessingError.changedProject
                }
                try sourceCapture.validateSourceReferences(final.clips.filter(\.enabled).compactMap(\.mediaURL))
                if !sourceCapture.overlappedSourceValidation {
                    // Legacy evidence keeps the preceding full-content route.
                    // Exact delivered references were checked above; validate()
                    // retains legacy canonical-reference/hash compatibility.
                    try await context.mediaSnapshot.validate()
                }
                try readGuard.validate()
                let target = try final.selectedTarget(capture.selection)
                if let origin = request.workflowOrigin { try origin.verify(projectData: finalData) }
                else {
                    try AudioControllerSettings.validateForApply(projectData: finalData,
                        target: target, requested: result.analyzed.settings)
                }
                let fullMix = receipt.mediaURLs[0]
                let nativeRenderGuard = try MediaContentSnapshot.prepareRead([fullMix, finalURL])
                renderGuard = nativeRenderGuard
                if applyRoute == .finalCutRender {
                    timing.begin("freshAudioMeasurement")
                    progress("Checking current audio against the reviewed cuts…", 0.2)
                    let audible = final.clips.filter { $0.enabled && $0.hasAudio }
                    let fresh: AnalyzedAudioProject
                    if audible.count == 1, audible[0].id == target.id,
                       try DirectAudioRender.isEligible(projectData: finalData, selection: capture.selection) {
                        // With exactly one audible source, the full mix is also the
                        // selected Dialogue render. Its file zero is project zero.
                        let bound = try await DialogueRenderContext.capturedNativeRender(document: final,
                            target: target, audioURL: fullMix, receipt: receipt, projectSlice: true, workflowOrigin: request.workflowOrigin)
                        fresh = try await ProjectAudioAnalysis.analyze(projectData: finalData,
                            selection: capture.selection, dialogueAudio: fullMix, renderContext: bound,
                            settings: request.settings, jobID: request.id, capturedMedia: nil)
                    } else {
                        fresh = try await freshTargetForApply(projectData: finalData, document: final,
                            capture: capture, directory: context.directory, request: request,
                            timing: timing, progress: progress)
                    }
                    let evidence: [String: Any] = ["reviewedCandidates": result.analyzed.review.cuts.map(\.id),
                        "freshCandidates": fresh.review.cuts.map(\.id), "selectedCuts": result.analyzed.review.selectedCuts.map(\.id),
                        "reviewedAudioSHA256": result.analyzed.dialogueContext.audioSHA256,
                        "freshAudioSHA256": fresh.dialogueContext.audioSHA256,
                        "verificationAudio": "continuous full-project native mix",
                        "outputAudio": "original source clips with editable audio effects"]
                    try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                        .write(to: context.directory.appendingPathComponent("Apply-Audio-Verification.json"), options: .atomic)
                    try ReviewedCutValidation.verify(reviewed: result.analyzed, fresh: fresh)
                }
                if !sourceCapture.overlappedSourceValidation { try await context.mediaSnapshot.validate() }
                // The original phase guard spans both the joined hash/render and
                // later target measurement, including any extra native isolation.
                try readGuard.validate()
                try validateReviewSelection(capture)
                try Task.checkCancellation()
                timing.begin("preserveSourceAudio")
                progress("Preserving source clips and audio effects…", 0.3)
                try ShareDestinationManager.shared.validateReceipt(receipt)
                try nativeRenderGuard.validate()
                // The native mix is analysis evidence only. The cleaned timeline
                // references the original media and copies each kept clip's DSP
                // chain, volume and source-time animation, like manual blade cuts.
                outputMedia = try await timing.measure("apply.outputMediaEvidence") {
                    try await sourceCapture.captureOutputMedia(adding: [])
                }
                timing.recordCounters(["apply.outputSourceHashReuse": sourceCapture.reusesSourceHashesForOutput ? 1 : 0])
                guard outputMedia == context.mediaSnapshot else {
                    throw AudioProjectProcessingError.changedProject
                }
                try readGuard.validate()
            }
            if nativePlan != nil {
                guard let receipt = fullMixReceipt, let renderGuard else {
                    throw ProjectAnalysisError.invalidRenderArtifact
                }
                let outputName = Self.outputName(clip: capture.target, request: request.id)
                let plan = try BulkEffectTransferPlan.make(projectData: finalData,
                    selection: capture.selection, cuts: removals, outputName: outputName)
                timing.recordCounters(["apply.bulkXMLCuts": removals.count, "apply.nativeRangeRemovals": 0])
                guard !FileManager.default.fileExists(atPath: parent.path) else {
                    throw EditedProjectWriterError.unsupported("the result folder already exists")
                }
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                let outputURL = parent.appendingPathComponent("Silent Snip.fcpxml")
                let importURL = parent.appendingPathComponent("Import-Cuts.fcpxml")
                try plan.expectedXML.write(to: outputURL, options: .withoutOverwriting)
                try Data("Created by one bulk XML import and one native audio-effects transfer. The existing native result and unchanged original project retain advanced settings omitted from XML. Silent Snip.fcpxml is verification evidence; reimporting it cannot restore omitted settings. Import-Cuts.fcpxml intentionally contains no audio effects.\n".utf8)
                    .write(to: parent.appendingPathComponent("Native-Result.txt"), options: .withoutOverwriting)
                try plan.effectFreeOutput.xmlData.write(to: importURL, options: .withoutOverwriting)
                try finalData.write(to: parent.appendingPathComponent("Before-Cuts.fcpxml"), options: .withoutOverwriting)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(plan.effectFreeOutput.report).write(to: parent.appendingPathComponent("Edit-Report.json"), options: .withoutOverwriting)
                try encoder.encode(request.settings).write(to: parent.appendingPathComponent("Analysis-Settings.json"), options: .withoutOverwriting)
                progress("Preparing all cuts in XML and preserving the original effects…", 0.4)
                // Copy the current native source only after a fresh final baseline
                // check. No source attributes, native duplicates or range edits are made.
                let importGuard = try MediaContentSnapshot.prepareRead(outputMedia.sourceURLs + [outputURL, importURL])
                try await outputMedia.validate()
                try await session.activate()
                try self.validateReviewSelection(capture)
                let check = try await session.exportProjectXML(to: context.directory
                    .appendingPathComponent("Before-Bulk-Import-\(UUID().uuidString).fcpxmld"), timing: timing, sharePurpose: .apply)
                let checkData = try Data(contentsOf: check)
                try XMLProjectApply.verifyBaseline(TimelineParser.parse(data: checkData, exclusions: exclusions), analyzed: final)
                try request.workflowOrigin?.verify(projectData: checkData)
                try self.validateReviewSelection(capture)
                try readGuard.validate(); try renderGuard.validate(); try importGuard.validate()
                let token = try await session.captureNativeEffectTransfer(plan: plan.sourcePlan,
                    originalData: finalData, outputName: outputName, timing: timing)
                try token.prepareJournal(directory: parent, expectedResultData: plan.expectedXML,
                    effectFreeData: plan.effectFreeOutput.xmlData)
                let verification = try ImportedResultVerification(expected: plan.expectedXML, outputURL: outputURL,
                    originalProjectName: capture.projectName, request: request, sourceMedia: outputMedia,
                    bulkEffectTransfer: true)
                try verification.savePending()
                self.verifications.remember(request.id, at: outputURL)
                bulkTransferStarted = true
                try importGuard.validate(); try readGuard.validate(); try renderGuard.validate()
                try ShareDestinationManager.shared.validateReceipt(receipt)
                try XMLProjectApply.validateLibrary(try XMLReplacementTarget(projectData: finalData).libraryURL)
                try session.assertCurrentProject()
                try Task.checkCancellation()
                importAttempted = true
                try await timing.measure("bulkXML.import") { try await XMLProjectApply.importIntoFinalCut(importURL) }
                let imported = try await session.openImportedProject(named: outputName, importedXML: importURL)
                progress("Restoring the original audio effects to all retained clips…", 0.8)
                let importedUID = try await imported.applyBulkEffects(token: token, plan: plan.sourcePlan,
                    originalData: finalData, expectedEffectFreeData: plan.effectFreeOutput.xmlData,
                    expectedResultData: plan.expectedXML, directory: parent, timing: timing)
                timing.recordCounters(["apply.bulkEffectTransfers": 1])
                try await verifyImportedResult(request.id, progress: progress, timing: timing,
                    completedBulkTransfer: (imported.projectName, importedUID))
                outcome = "verified"
                return
            }
            timing.begin("projectCreationAndImport")
            progress("Creating the cleaned project…", 0.4)
            let outputName = Self.outputName(clip: capture.target, request: request.id)
            let artifact = try XMLProjectApply.prepare(projectData: finalData, selection: capture.selection,
                cuts: removals, settings: result.analyzed.settings, mode: request.outputMode,
                outputName: outputName, directory: parent, selectedClipOnly: false, useOriginalEvent: true,
                omitController: true, workflowOrigin: request.workflowOrigin)
            prepared = artifact
            try session.assertCurrentProject()
            try Data("Import requested; verification pending. Do not import again until checking Final Cut Pro.\n".utf8)
                .write(to: parent.appendingPathComponent("Import-Status.txt"), options: .atomic)
            let verification = try ImportedResultVerification(expected: artifact.output.xmlData, outputURL: artifact.outputURL,
                originalProjectName: capture.projectName, request: request, replacementTarget: artifact.output.report.replacementTarget,
                sourceMedia: outputMedia)
            try await artifact.send { url in
                timing.begin("finalProjectVerification")
                // Source verification yields while Final Cut remains
                // editable. The final exchange must therefore follow the full
                // content check and prove the same timeline/effects/settings
                // immediately before this single import attempt.
                let importReadGuard = try MediaContentSnapshot.prepareRead(outputMedia.sourceURLs +
                    [artifact.outputURL, artifact.recoveryURL])
                progress("Checking the source media and current project before import…", 0.7)
                try await timing.measure("apply.finalFullMediaValidation") {
                    if sourceOnly != nil { _ = try await outputMedia.validatedSnapshot(prepared: readGuard) }
                    else { try await outputMedia.validate() }
                }
                try await session.activate()
                try self.validateReviewSelection(capture)
                let importCheck = try await session.exportProjectXML(to: context.directory
                    .appendingPathComponent("Before-Import-\(UUID().uuidString).fcpxmld"), timing: timing, sharePurpose: .apply)
                let importData = try Data(contentsOf: importCheck)
                let current = try TimelineParser.parse(data: importData, exclusions: exclusions)
                try XMLProjectApply.verifyBaseline(current, analyzed: final)
                try sourceOnly?.verifyCurrent(projectData: importData)
                if let origin = request.workflowOrigin { try origin.verify(projectData: importData) }
                else {
                    try AudioControllerSettings.validateForApply(projectData: importData,
                        target: current.selectedTarget(capture.selection), requested: result.analyzed.settings)
                }
                try self.validateReviewSelection(capture)
                try importReadGuard.validate()
                try readGuard.validate()
                try renderGuard?.validate()
                if let fullMixReceipt { try ShareDestinationManager.shared.validateReceipt(fullMixReceipt) }
                try verification.savePending()
                // The phase guard covers both the full scan and XML exchange.
                // No second full media scan is needed after these synchronous
                // checks, and an uncertain delivery is never retried.
                try importReadGuard.validate()
                try readGuard.validate()
                try renderGuard?.validate()
                progress("Sending ‘\(outputName)’ to Final Cut Pro…", 0.8)
                try session.assertCurrentProject()
                try Task.checkCancellation()
                importAttempted = true
                self.verifications.remember(request.id, at: verification.outputURL)
                timing.begin("importAndVerification")
                try await timing.measure("import.delivery") { try await XMLProjectApply.importIntoFinalCut(url) }
            }
            try await verifyImportedResult(request.id, progress: progress, timing: timing, freshImportOrigin: session)
            outcome = "verified"
        } catch {
            _ = await capture.restoreReviewWindow()
            if bulkTransferStarted {
                let message = "Bulk XML Apply did not finish verification. A partial cleaned project may remain. No import or effect transfer was repeated. The original project was not edited. Check the bulk transfer journal and use Verify Existing Result only after a completed transfer. \(error.localizedDescription)"
                try? Data((message + "\n").utf8).write(to: parent.appendingPathComponent("Import-Status.txt"), options: .atomic)
                throw FinalCutCaptureError.unavailable(message)
            }
            if error is XMLProjectApplyFailure { throw error }
            if let prepared {
                let failure = XMLProjectApplyFailure(cause: error, outputURL: prepared.outputURL, importAttempted: importAttempted, replacingOriginal: prepared.output.report.replacementTarget != nil)
                try? failure.saveStatus()
                throw failure
            }
            throw error
        }
    }

    private static func nativeEditPlanIfNeeded(projectData: Data, selection: TimelineSelection,
                                               cuts: [TimeRange], request: AnalyzeRequest) throws -> NativeSourceEditPlan? {
        do { try EditableEffectReconstruction.validate(projectData: projectData); return nil }
        catch {
            guard request.workflowOrigin != nil, request.outputMode == .remove else { throw error }
            // Bulk XML owns every cut. A single native effects transfer retains
            // omitted settings; unsupported animation/layouts never fall back to cuts.
            return try BulkEffectTransferPlan.make(projectData: projectData, selection: selection,
                cuts: cuts, outputName: "Silent Snip Validation").sourcePlan
        }
    }

    private static func validateEditableOutput(projectData: Data, selection: TimelineSelection,
                                               cuts: [TimeRange], request: AnalyzeRequest, outputName: String) throws {
        if try nativeEditPlanIfNeeded(projectData: projectData, selection: selection, cuts: cuts, request: request) != nil {
            _ = try EditedProjectWriter.nativeEditExpectation(projectData: projectData, selection: selection,
                selectedRanges: cuts, outputName: outputName, projectUID: UUID())
        } else {
            _ = try EditedProjectWriter.write(projectData: projectData, selection: selection,
                selectedRanges: cuts, outputName: outputName, selectedClipOnly: false,
                useOriginalEvent: true, omitController: true)
        }
    }

    /// Freshly verify a processed target independently of the full project mix.
    /// The latter can contain Music or overlapping Dialogue and must not change
    /// which cuts the user reviewed. Every temporary render is request-owned.
    private func freshTargetForApply(projectData: Data, document: TimelineDocument,
                                     capture: CapturedFinalCutProject, directory: URL,
                                     request: AnalyzeRequest, timing: AnalysisTiming,
                                     progress: @escaping AnalysisReviewCoordinator.Progress) async throws -> AnalyzedAudioProject {
        let target = try document.selectedTarget(capture.selection)
        var owned: ShareDestinationReceipt?
        defer { if let owned { try? ShareDestinationManager.shared.cleanupRenderedMedia(receipt: owned) } }
        let receipt: ShareDestinationReceipt
        let scope = try DirectAudioRender.scope(projectData: projectData, selection: capture.selection)
        if let scope {
            receipt = try await capture.session.shareRenderedAudio(timing: timing,
                renderSelection: scope == .selectedRange ? capture.session.reviewOwnership.active : nil)
            owned = receipt
            try ShareDestinationManager.shared.validateReceipt(receipt)
            let xml = receipt.xmlURL.pathExtension.lowercased() == "fcpxmld"
                ? receipt.xmlURL.appendingPathComponent("Info.fcpxml") : receipt.xmlURL
            let targetData = try Data(contentsOf: xml)
            try request.workflowOrigin?.verify(projectData: targetData)
            try ProjectRoundTripVerification.verify(expected: projectData, actual: targetData,
                reportURL: directory.appendingPathComponent("Apply-Target-Render-Verification.json"))
        } else {
            let isolated = try IsolatedAudioProject.make(projectData: projectData, selection: capture.selection)
            try EditableEffectReconstruction.validate(projectData: isolated.data)
            let url = directory.appendingPathComponent("Apply-Isolated-\(UUID().uuidString).fcpxml")
            try isolated.data.write(to: url, options: .withoutOverwriting)
            progress("Checking the selected clip independently of the other audio…", nil)
            var isolatedSession: FinalCutAXSession?
            var delivered: Data?
            do {
                // Import/open can fail after Final Cut has accepted the file.
                // Keep its exact generated name even before a verified session
                // exists; unknown delivery never authorizes project deletion.
                try await XMLProjectApply.importIntoFinalCut(url)
                let opened = try await capture.session.openImportedProject(named: isolated.name, importedXML: url)
                isolatedSession = opened
                receipt = try await opened.shareRenderedAudio(timing: timing)
                owned = receipt
                try ShareDestinationManager.shared.validateReceipt(receipt)
                let xml = receipt.xmlURL.pathExtension.lowercased() == "fcpxmld"
                    ? receipt.xmlURL.appendingPathComponent("Info.fcpxml") : receipt.xmlURL
                let data = try Data(contentsOf: xml)
                try ProjectRoundTripVerification.verify(expected: isolated.data, actual: data,
                    reportURL: directory.appendingPathComponent("Apply-Target-Render-Verification.json"),
                    allowHostAssignedIdentity: true)
                try isolated.destination.verifyDestination(data)
                delivered = data
                _ = try await opened.returnToPreviousProject(named: capture.projectName)
            } catch {
                if let isolatedSession {
                    _ = try? await Task { @MainActor in
                        try await isolatedSession.returnToPreviousProject(named: capture.projectName)
                    }.value
                }
                try? Data("Apply interrupted; temporary project ‘\(isolated.name)’ may remain in its original event. Ownership/content verification or cleanup did not complete; no unverified project was deleted. \(error.localizedDescription)\n".utf8)
                    .write(to: directory.appendingPathComponent("Apply-Cleanup-Status.txt"), options: .atomic)
                throw error
            }
            if let delivered {
                do {
                    let original = try FinalCutAXSession(inheritingWorkflowFrom: capture.session)
                    guard original.projectName == capture.projectName else { throw FinalCutCaptureError.changedProject }
                    try await original.removeAnalysisProject(isolated, verifiedData: delivered)
                } catch {
                    try? Data("Verified temporary Apply project ‘\(isolated.name)’ remains in its original event: \(error.localizedDescription)\n".utf8)
                        .write(to: directory.appendingPathComponent("Apply-Cleanup-Status.txt"), options: .atomic)
                }
            }
            let original = try FinalCutAXSession(inheritingWorkflowFrom: capture.session)
            guard original.projectName == capture.projectName else { throw FinalCutCaptureError.changedProject }
            let after = try await original.exportProjectXML(
                to: directory.appendingPathComponent("Apply-After-Isolation-\(UUID().uuidString).fcpxmld"), timing: timing)
            let afterData = try Data(contentsOf: after)
            try request.workflowOrigin?.verify(projectData: afterData)
            let current = try TimelineParser.parse(data: afterData,
                exclusions: .init(controllerEffectUIDs: [AudioControllerSettings.effectUID]))
            try XMLProjectApply.verifyBaseline(current, analyzed: document)
        }
        guard receipt.mediaURLs.count == 1 else { throw ProjectAnalysisError.invalidRenderArtifact }
        let audio = receipt.mediaURLs[0]
        let bound = try await DialogueRenderContext.capturedNativeRender(document: document, target: target, audioURL: audio,
            receipt: receipt, projectSlice: scope == .projectSlice, workflowOrigin: request.workflowOrigin)
        try ShareDestinationManager.shared.validateReceipt(receipt)
        return try await ProjectAudioAnalysis.analyze(projectData: projectData, selection: capture.selection,
            dialogueAudio: audio, renderContext: bound, settings: request.settings,
            jobID: request.id, capturedMedia: nil)
    }

    public func loadVerification(_ verification: ReviewVerificationRequest) throws -> AnalyzeRequest {
        guard let origin = verification.workflowOrigin else {
            return try loadVerification(verification.result, view: verification.view)
        }
        let session = try FinalCutAXSession()
        try session.bindWorkflow(origin, action: "verify")
        let result = try ImportedResultVerification.load(outputURL: verification.result)
        try result.validateWorkflowRecovery(origin)
        // Adopt only presentation and the explicit recovery capability. This
        // creates no analysis context and cannot make the saved plan applicable.
        let request = AnalyzeRequest(id: result.request.id, settings: result.request.settings,
            outputMode: result.request.outputMode, workflowOrigin: origin)
        verifications.remember(request.id, at: verification.result)
        recoveryOrigins[request.id] = origin
        reviewSession = session
        reviewRequestID = request.id
        return request
    }

    public func loadVerification(_ outputURL: URL, view: UUID) throws -> AnalyzeRequest {
        let session = try FinalCutAXSession()
        try session.rememberReviewSelection(session.selectionSnapshot())
        guard session.canReconnectReview(view: view) else {
            throw FinalCutCaptureError.unavailable("Select the clip belonging to this Controls window before verifying a result.")
        }
        let request = try loadVerification(outputURL)
        reviewSession = session
        reviewRequestID = request.id
        return request
    }

    public func loadVerification(_ outputURL: URL) throws -> AnalyzeRequest {
        let result = try ImportedResultVerification.load(outputURL: outputURL)
        verifications.remember(result.request.id, at: outputURL)
        return result.request
    }

    public func retryVerification(_ id: UUID, progress: @escaping AnalysisReviewCoordinator.Progress, acceptReplacement: Bool = false,
                                  originalTimelineSignature: [String]? = nil) async throws {
        try await verifyImportedResult(id, progress: progress, acceptReplacement: acceptReplacement,
            originalTimelineSignature: originalTimelineSignature)
    }

    private func verifyImportedResult(_ id: UUID, progress: @escaping AnalysisReviewCoordinator.Progress,
                                     acceptReplacement: Bool = false, originalTimelineSignature: [String]? = nil,
                                     timing: AnalysisTiming? = nil,
                                     freshImportOrigin: FinalCutAXSession? = nil,
                                     completedBulkTransfer: (name: String, uid: String)? = nil) async throws {
        guard let outputURL = verifications[id] else {
            throw FinalCutCaptureError.unavailable("There is no pending imported result to verify.")
        }
        let parent = outputURL.deletingLastPathComponent()
        let attemptTiming = timing ?? AnalysisTiming(request: id)
        let attempt = UUID().uuidString
        var verificationOutcome = "failed"
        defer {
            // Standalone Retry has its own report. Apply shares its parent
            // timer so result verification is no longer an opaque stage.
            if timing == nil {
                attemptTiming.save(to: parent.appendingPathComponent("Result-Verification-Timing-\(attempt).json"),
                    outcome: Task.isCancelled ? "cancelled" : verificationOutcome)
            }
        }
        let result = try attemptTiming.measure("verification.loadReceipt") {
            try ImportedResultVerification.load(outputURL: outputURL)
        }
        do {
            if let completedBulkTransfer {
                // Bind the completed Paste to the saved result, then discover
                // and settle the workspace afresh before verification Share.
                guard result.request.id == id, result.bulkEffectTransfer,
                      result.replacementTarget == nil, !acceptReplacement, originalTimelineSignature == nil,
                      result.hostProjectUID == completedBulkTransfer.uid,
                      result.projectName == completedBulkTransfer.name else { throw FinalCutCaptureError.changedProject }
            }
            let origin = freshImportOrigin.flatMap { session -> FinalCutAXSession? in
                guard result.request.id == id, !result.bulkEffectTransfer, result.replacementTarget == nil,
                      !acceptReplacement, originalTimelineSignature == nil, recoveryOrigins[id] == nil,
                      session.projectName == result.originalProjectName,
                      session.canObserveFreshImport() else { return nil }
                return session
            }
            let current: FinalCutAXSession
            if let origin {
                attemptTiming.incrementCounter("verification.freshImportOriginReuses")
                current = origin
            } else {
                current = try await attemptTiming.measure("verification.sessionDiscovery") {
                    try await FinalCutAXSession.forImport(allowEmptyTimeline: result.replacementTarget != nil,
                        inheritingWorkflowFrom: reviewSession)
                }
            }
            if let origin = recoveryOrigins[id] {
                progress("Verifying the selected project…", nil)
                try await current.activate()
                let url = try await current.exportProjectXML(to: parent.appendingPathComponent("Recovery-Origin-\(UUID().uuidString).fcpxmld"))
                try origin.verify(projectData: Data(contentsOf: url))
                recoveryOrigins.removeValue(forKey: id)
            }
            guard result.replacementTarget != nil || current.projectName == result.originalProjectName || current.projectName == result.projectName else {
                throw FinalCutCaptureError.unavailable("Open the original project or ‘\(result.projectName)’ before retrying verification.")
            }
            progress("Verifying the existing cleaned project…", 0.9)
            let imported = try await attemptTiming.measure("verification.openImportedProject") {
                try await current.openImportedProject(named: result.projectName, importedXML: result.outputURL,
                    replacement: result.replacementTarget, acceptReplacement: acceptReplacement,
                    originalTimelineSignature: originalTimelineSignature, usingFreshImportOrigin: origin != nil)
            }
            let report = try await result.verify(capture: {
                // Verification can start from an already-open result's remote
                // Controls window. Pin keyboard focus to the project before
                // Share reads its selection or dispatches any host input.
                try await attemptTiming.measure("verification.activate") { try await imported.activate() }
                let shareID = UUID().uuidString
                let shareTiming = AnalysisTiming(request: id)
                var shareOutcome = "failed"
                defer {
                    shareTiming.save(to: parent.appendingPathComponent("Verification-Share-Timing-\(shareID).json"),
                        outcome: Task.isCancelled ? "cancelled" : shareOutcome)
                }
                let url = try await attemptTiming.measure("verification.share") {
                    // A result has a different host identity from the original
                    // Workflow pin. It deliberately retains ordinary Share.
                    try await imported.exportProjectXML(to: parent.appendingPathComponent("Verification-\(shareID).fcpxmld"),
                        timing: shareTiming, sharePurpose: .verification)
                }
                shareOutcome = "delivered"
                return try attemptTiming.measure("verification.readCapturedXML") { try Data(contentsOf: url) }
            }, restore: { correction, document in
                progress("Restoring Silent Snip settings on ‘\(correction.clip.name)’…", nil)
                // These temporary Controls views are being written by recovery,
                // not offered for review. A reconnect could disable their fields.
                self.restoringControllerSettings = true
                defer { self.restoringControllerSettings = false }
                try await imported.restoreControllerSettings(correction.settings, clip: correction.clip, document: document)
            }, timing: attemptTiming)
            let disposition = result.replacementTarget == nil ? "Original project unchanged." : "Project replaced in its original event. Recovery XML saved in the result folder."
            let settingsNotice = report.controllerSettingsPreserved == nil
                ? "Analysis settings are saved with the result."
                : "Silent Snip settings match."
            let nativeNotice = result.bulkEffectTransfer ? " Original audio effects were transferred in one operation."
                : result.nativeProjectUID == nil ? "" : " Native edits retained the existing effect instances."
            let message = "Verified ‘\(result.projectName)’: timeline, exported effect data and media references match.\(nativeNotice) \(settingsNotice) \(result.sourceMediaNotice) \(disposition)"
            // Initial Apply and Verify Existing Result share this boundary.
            // Complete durable native bookkeeping before publishing success or
            // releasing the pending verification, so a failed write can retry.
            if let nativeUID = result.nativeProjectUID {
                guard let uid = UUID(uuidString: nativeUID) else { throw FinalCutCaptureError.changedProject }
                try NativeResultFinalization.complete(directory: parent, projectUID: uid,
                    projectName: result.projectName)
            }
            if result.bulkEffectTransfer {
                guard let uid = result.hostProjectUID else { throw FinalCutCaptureError.changedProject }
                try NativeBulkEffectTransferJournal.markVerified(directory: parent, hostUID: uid)
            }
            try Data((message + "\n").utf8).write(to: parent.appendingPathComponent("Import-Status.txt"), options: .atomic)
            result.markComplete()
            verifications.remove(id)
            progress(message, 1)
            verificationOutcome = "verified"
        } catch {
            if result.nativeProjectUID != nil {
                let message = "The existing native result ‘\(result.projectName)’ could not be verified. No cut or import was repeated. Keep the original and this native copy; XML reimport cannot restore omitted effect settings. Use Verify Existing Result after checking the project. \(error.localizedDescription)"
                try? Data((message + "\n").utf8).write(to: parent.appendingPathComponent("Import-Status.txt"), options: .atomic)
                throw FinalCutCaptureError.unavailable(message)
            }
            let failure = XMLProjectApplyFailure(cause: error, outputURL: result.outputURL, importAttempted: true, replacingOriginal: result.replacementTarget != nil)
            try? failure.saveStatus()
            throw failure
        }
    }

    public func verifyNativeNavigation(_ request: AnalyzeRequest, result: ReviewAnalysisResult, cutID: String) async throws {
        guard let context = contexts[request.id], let origin = request.workflowOrigin,
              context.capture.session.workflowOrigin?.view == origin.view,
              let cut = result.analyzed.review.cuts.first(where: { $0.id == cutID }) else { throw ReviewError.staleProject }
        let document = context.capture.document
        let absolute = try document.projectTimecodeStart.adding(cut.range.start)
        let session = context.capture.session
        let timing = AnalysisTiming(request: request.id)
        timing.recordCounters(["share.exchanges": 0, "navigation.sdkAcknowledgments": 1])
        timing.begin("verifySDKPlayhead")
        var outcome = "failed"
        defer { timing.save(to: context.directory.appendingPathComponent("Navigation-Timing.json"),
            outcome: Task.isCancelled ? "cancelled" : outcome) }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        repeat {
            try validateReviewSelection(context.capture)
            guard session.currentSheet() == nil else {
                throw FinalCutCaptureError.unavailable("A Final Cut Pro dialog is blocking playhead verification.")
            }
            if session.timelinePlayheadMatches(absolute, frameDuration: document.frameDuration) {
                try validateReviewSelection(context.capture)
                outcome = "navigated"
                return
            }
            try await Task.sleep(for: .milliseconds(40))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw FinalCutCaptureError.unavailable("Final Cut Pro did not confirm the playhead at the selected cut.")
    }

    public func highlight(_ request: AnalyzeRequest, result: ReviewAnalysisResult, cutID: String) async throws {
        guard let context = contexts[request.id],
              let cut = result.analyzed.review.cuts.first(where: { $0.id == cutID }) else { throw ReviewError.unknownCut }
        let session = context.capture.session
        let timing = AnalysisTiming(request: request.id)
        var outcome = "failed"
        defer {
            timing.recordCounters(["share.exchanges": 0])
            timing.save(to: context.directory.appendingPathComponent("Navigation-Timing.json"), outcome: outcome)
        }
        timing.begin("selectionValidation")
        try validateReviewSelection(context.capture)
        try await session.activate()
        try validateReviewSelection(context.capture)
        timing.begin("movePlayhead")
        do {
            try await session.movePlayhead(to: cut.range.start, document: context.capture.document, dropFrame: result.dropFrame)
        } catch {
            _ = await context.capture.restoreReviewWindow()
            throw error
        }
        timing.begin("restoreControls")
        _ = await context.capture.presentReviewWindow()
        outcome = "navigated"
    }

    private nonisolated static func mediaSnapshot(_ document: TimelineDocument,
                                                 renderedMedia: MediaContentSnapshot? = nil,
                                                 prepared: MediaContentSnapshot.ReadGuard? = nil) async throws -> MediaContentSnapshot {
        if let renderedMedia {
            guard let prepared, renderedMedia.covers(document.clips.filter(\.enabled).compactMap(\.mediaURL)) else {
                throw ProjectAnalysisError.changedRenderArtifact
            }
            // The combined exchange already hashed these sources while rendering.
            // Bind that snapshot to the current guard and keep the final full
            // content check after measurement or cache reuse.
            try renderedMedia.requireExactGuard(prepared)
            return renderedMedia
        }
        if let prepared { return try await MediaContentSnapshot.capture(prepared: prepared) }
        return try await MediaContentSnapshot.capture(document.clips.filter(\.enabled).compactMap(\.mediaURL))
    }

    /// A request keeps its name across delivery and verification retries. A new
    /// Analyze gets another name, so Apply never needs a Replace decision.
    static func outputName(clip: TimelineClip, request: UUID) -> String {
        let name = clip.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? "Clip" : name) + " — Cleaned — " + String(request.uuidString.prefix(8))
    }
}
