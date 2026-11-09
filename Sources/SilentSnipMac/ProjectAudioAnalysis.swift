import SilentSnipCore
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// The exporter supplies the project, range, role, and verified controller metadata.
/// The URL and content hash bind that metadata to one completed local audio file;
/// they detect substitution or changes, but do not prove which mix was exported.
public struct DialogueRenderContext: Sendable {
    public let projectFingerprint: String
    public let projectUID: String?
    public let projectName: String
    public let projectRange: TimeRange
    public let renderedRoles: Set<String>
    public let controllerEffectUIDs: Set<String>
    public let audioURL: URL
    public let audioSHA256: String
    public let allowOmittedPrivateSettings: Bool
    public let workflowOrigin: WorkflowReviewOrigin?
    /// Non-nil means selected source audio, not a rendered Dialogue mix.
    public let sourceRange: TimeRange?
    let isolatedTargetID: String?
    let projectSlice: Bool
    private let nativeRenderGuard: MediaContentSnapshot.ReadGuard?

    /// Use the same exact controller allowlist for export, analysis, and subsequent
    /// baseline checks. Callers must obtain these UIDs from a verified effect export.
    public var fingerprintExclusions: TimelineFingerprintExclusions {
        .init(controllerEffectUIDs: controllerEffectUIDs)
    }

    public init(projectFingerprint: String, projectUID: String?, projectName: String,
                projectRange: TimeRange, renderedRoles: Set<String>, audioURL: URL,
                controllerEffectUIDs: Set<String> = [], allowOmittedPrivateSettings: Bool = false, sourceRange: TimeRange? = nil,
                workflowOrigin: WorkflowReviewOrigin? = nil) throws {
        let canonicalURL = try MediaContentSnapshot.canonical(audioURL)
        try self.init(projectFingerprint: projectFingerprint, projectUID: projectUID, projectName: projectName,
            projectRange: projectRange, renderedRoles: renderedRoles, audioURL: canonicalURL,
            controllerEffectUIDs: controllerEffectUIDs, allowOmittedPrivateSettings: allowOmittedPrivateSettings,
            sourceRange: sourceRange, audioSHA256: MediaContentSnapshot.contentHash(at: canonicalURL), workflowOrigin: workflowOrigin)
    }

    /// Only the interactive capture path can reuse its freshly read media evidence.
    static func capturedSource(document: TimelineDocument, target: TimelineClip,
                               media: MediaContentSnapshot, workflowOrigin: WorkflowReviewOrigin? = nil) throws -> Self {
        guard let url = target.mediaURL else { throw SourceAudioError.invalidAudio }
        let canonicalURL = try MediaContentSnapshot.canonical(url)
        guard let digest = media.hashes[canonicalURL] else { throw ProjectAnalysisError.invalidRenderArtifact }
        return Self(projectFingerprint: document.fingerprint, projectUID: document.projectUID,
            projectName: document.projectName, projectRange: document.projectRange, renderedRoles: [],
            audioURL: canonicalURL, controllerEffectUIDs: [AudioControllerSettings.effectUID],
            allowOmittedPrivateSettings: true,
            sourceRange: TimeRange(start: target.sourceFileStart,
                end: try target.sourceFileStart.adding(target.timelineRange.checkedDuration())), audioSHA256: digest,
            workflowOrigin: workflowOrigin)
    }

    private init(projectFingerprint: String, projectUID: String?, projectName: String,
                 projectRange: TimeRange, renderedRoles: Set<String>, audioURL: URL,
                 controllerEffectUIDs: Set<String>, allowOmittedPrivateSettings: Bool,
                 sourceRange: TimeRange?, audioSHA256: String, isolatedTargetID: String? = nil, projectSlice: Bool = false,
                 workflowOrigin: WorkflowReviewOrigin? = nil, nativeRenderGuard: MediaContentSnapshot.ReadGuard? = nil) {
        self.workflowOrigin = workflowOrigin
        self.projectSlice = projectSlice
        self.isolatedTargetID = isolatedTargetID
        self.sourceRange = sourceRange
        self.allowOmittedPrivateSettings = allowOmittedPrivateSettings
        self.projectFingerprint = projectFingerprint
        self.projectUID = projectUID
        self.projectName = projectName
        self.projectRange = projectRange
        self.renderedRoles = renderedRoles
        self.controllerEffectUIDs = controllerEffectUIDs
        self.audioURL = audioURL
        self.audioSHA256 = audioSHA256
        self.nativeRenderGuard = nativeRenderGuard
    }

    static func capturedIsolated(document: TimelineDocument, target: TimelineClip, audioURL: URL,
                                 workflowOrigin: WorkflowReviewOrigin? = nil) throws -> Self {
        let canonical = try MediaContentSnapshot.canonical(audioURL)
        return capturedRender(document: document, target: target, canonical: canonical,
            digest: try MediaContentSnapshot.contentHash(at: canonical), projectSlice: false, workflowOrigin: workflowOrigin)
    }

    /// Call only after the fresh XML passes DirectAudioRender's scope proof.
    static func capturedProjectSlice(document: TimelineDocument, target: TimelineClip, audioURL: URL,
                                     workflowOrigin: WorkflowReviewOrigin? = nil) throws -> Self {
        let canonical = try MediaContentSnapshot.canonical(audioURL)
        return capturedRender(document: document, target: target, canonical: canonical,
            digest: try MediaContentSnapshot.contentHash(at: canonical), projectSlice: true, workflowOrigin: workflowOrigin)
    }

    /// Call after verifying a fresh native Share receipt and its render scope.
    /// Pin the artifact before hashing so this full read is also the pre-decode
    /// evidence. Keep the same guard through the full post-decode comparison.
    static func capturedNativeRender(document: TimelineDocument, target: TimelineClip, audioURL: URL,
                                     projectSlice: Bool = false, workflowOrigin: WorkflowReviewOrigin? = nil) async throws -> Self {
        let prepared = try MediaContentSnapshot.prepareRead([audioURL])
        let snapshot = try await MediaContentSnapshot.capture(prepared: prepared)
        guard let canonical = prepared.canonicalURLs.first, let digest = snapshot.hashes[canonical] else {
            throw ProjectAnalysisError.invalidRenderArtifact
        }
        return capturedRender(document: document, target: target, canonical: canonical, digest: digest,
            projectSlice: projectSlice, workflowOrigin: workflowOrigin, nativeRenderGuard: prepared)
    }

    private static func capturedRender(document: TimelineDocument, target: TimelineClip, canonical: URL, digest: String,
                                       projectSlice: Bool, workflowOrigin: WorkflowReviewOrigin?,
                                       nativeRenderGuard: MediaContentSnapshot.ReadGuard? = nil) -> Self {
        return Self(projectFingerprint: document.fingerprint, projectUID: document.projectUID,
            projectName: document.projectName, projectRange: document.projectRange, renderedRoles: [],
            audioURL: canonical, controllerEffectUIDs: [AudioControllerSettings.effectUID],
            allowOmittedPrivateSettings: true, sourceRange: nil,
            audioSHA256: digest, isolatedTargetID: target.id, projectSlice: projectSlice,
            workflowOrigin: workflowOrigin, nativeRenderGuard: nativeRenderGuard)
    }

    fileprivate func validateArtifact(at url: URL, beforeMeasurement: Bool = false) async throws {
        let canonicalURL = try MediaContentSnapshot.canonical(url)
        guard canonicalURL == audioURL else { throw ProjectAnalysisError.changedRenderArtifact }
        let snapshot: MediaContentSnapshot
        if let nativeRenderGuard {
            if beforeMeasurement {
                try nativeRenderGuard.validate()
                return
            }
            snapshot = try await MediaContentSnapshot.capture(prepared: nativeRenderGuard)
        } else {
            snapshot = try await MediaContentSnapshot.capture([canonicalURL])
        }
        guard snapshot.hashes[canonicalURL] == audioSHA256 else {
            throw ProjectAnalysisError.changedRenderArtifact
        }
    }

    fileprivate func retainingAudio(at url: URL) -> Self {
        Self(projectFingerprint: projectFingerprint, projectUID: projectUID, projectName: projectName,
            projectRange: projectRange, renderedRoles: renderedRoles, audioURL: url,
            controllerEffectUIDs: controllerEffectUIDs, allowOmittedPrivateSettings: allowOmittedPrivateSettings,
            sourceRange: sourceRange, audioSHA256: audioSHA256, isolatedTargetID: isolatedTargetID, projectSlice: projectSlice,
            workflowOrigin: workflowOrigin)
    }


}

public struct AnalyzedAudioProject: Sendable {
    public let document: TimelineDocument
    public let target: TimelineClip
    public let dialogueContext: DialogueRenderContext
    public let audio: DialogueAudio
    /// Captured analysis grid survives cache reuse and local settings updates.
    /// Nil is retained only for older internal fixture/API construction.
    public let cutFrameDuration: RationalTime?
    public private(set) var settings: AnalysisSettings
    public private(set) var analysis: SilenceAnalysisResult
    public var review: ReviewPlan

    public var isAudioOnlyTarget: Bool { !target.hasVideo }

    func retainingAudio(at url: URL) -> Self {
        Self(document: document, target: target, dialogueContext: dialogueContext.retainingAudio(at: url),
            audio: audio, settings: settings, analysis: analysis, review: review, cutFrameDuration: cutFrameDuration)
    }

    /// Reuse the same analyzed render when Inspector settings change. Apply still
    /// requires a fresh project export and baseline verification by the editor.
    @discardableResult public mutating func recalculate(settings: AnalysisSettings) throws -> Bool {
        guard settings.windowDuration == self.settings.windowDuration else {
            throw ProjectAnalysisError.changedWindowDuration
        }
        let updated = try SilenceDetector.analyze(windows: audio.windows, target: target.timelineRange,
            frameDuration: cutFrameDuration ?? ProjectAudioAnalysis.cutGrid(videoFrameDuration: document.frameDuration,
                sampleRate: audio.sampleRate), settings: settings)
        let resetChoices = try review.recalculate(updated, document: document)
        self.settings = settings
        self.analysis = updated
        return resetChoices
    }

    init(document: TimelineDocument, target: TimelineClip, dialogueContext: DialogueRenderContext,
         audio: DialogueAudio, settings: AnalysisSettings, analysis: SilenceAnalysisResult, review: ReviewPlan,
         cutFrameDuration: RationalTime? = nil) {
        self.document = document
        self.target = target
        self.dialogueContext = dialogueContext
        self.audio = audio
        self.cutFrameDuration = cutFrameDuration
        self.settings = settings
        self.analysis = analysis
        self.review = review
    }
}

/// Read-only analysis of an audio-only timeline target using the full project's
/// Dialogue render. Other timeline media remains part of the captured context.
public enum ProjectAudioAnalysis {
    public static func analyze(
        projectXML: URL,
        selection: TimelineSelection,
        dialogueAudio: URL,
        renderContext: DialogueRenderContext,
        settings: AnalysisSettings = .defaults,
        jobID: UUID = UUID(),
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> AnalyzedAudioProject {
        try await analyze(projectXML: projectXML, selection: selection, dialogueAudio: dialogueAudio,
            renderContext: renderContext, settings: settings, jobID: jobID, capturedMedia: nil, progress: progress)
    }

    static func analyze(projectXML: URL, selection: TimelineSelection, dialogueAudio: URL,
                        renderContext: DialogueRenderContext, settings: AnalysisSettings, jobID: UUID,
                        capturedMedia: MediaContentSnapshot?,
                        progress: @Sendable (Double) -> Void = { _ in },
                        validating: @Sendable () async -> Void = {}) async throws -> AnalyzedAudioProject {
        let xmlURL = projectXML.pathExtension.lowercased() == "fcpxmld"
            ? projectXML.appendingPathComponent("Info.fcpxml") : projectXML
        let projectData = try Data(contentsOf: xmlURL)
        return try await analyze(projectData: projectData, selection: selection, dialogueAudio: dialogueAudio,
            renderContext: renderContext, settings: settings, jobID: jobID, capturedMedia: capturedMedia,
            progress: progress, validating: validating)
    }

    /// Interactive analysis already owns immutable capture bytes. Reuse them;
    /// retain the same semantic, controller, audio, and source-content checks.
    static func analyze(projectData: Data, selection: TimelineSelection, dialogueAudio: URL,
                        renderContext: DialogueRenderContext, settings: AnalysisSettings, jobID: UUID,
                        capturedMedia: MediaContentSnapshot?,
                        progress: @Sendable (Double) -> Void = { _ in },
                        validating: @Sendable () async -> Void = {},
                        detecting: @Sendable () async -> Void = {}) async throws -> AnalyzedAudioProject {
        let document = try TimelineParser.parse(data: projectData, exclusions: renderContext.fingerprintExclusions)
        guard document.projectName == renderContext.projectName,
              document.projectUID == renderContext.projectUID,
              document.fingerprint == renderContext.projectFingerprint,
              document.projectRange == renderContext.projectRange else {
            throw ProjectAnalysisError.staleRender
        }
        guard renderContext.isolatedTargetID != nil || renderContext.sourceRange != nil || (!document.dialogueRoles.isEmpty &&
              renderContext.renderedRoles == Set(document.dialogueRoles)) else {
            throw ProjectAnalysisError.incorrectRoles
        }
        let target = try document.selectedTarget(selection)
        // The app verifies a required controller before driving Final Cut's
        // export. The read-only verifier also accepts audio-only fixtures with
        // no controller, but must validate any Silent Snip AU that is present.
        if let origin = renderContext.workflowOrigin {
            try origin.verify(projectData: projectData)
            try WorkflowReviewOrigin.validate(settings: settings)
        } else if renderContext.allowOmittedPrivateSettings {
            try AudioControllerSettings.validateInteractive(projectData: projectData, target: target, requested: settings)
        } else {
            try AudioControllerSettings.validate(projectData: projectData, target: target, requested: settings, requireController: false)
        }
        if let capturedMedia {
            guard renderContext.sourceRange != nil,
                  try MediaContentSnapshot.canonical(dialogueAudio) == renderContext.audioURL,
                  capturedMedia.hashes[renderContext.audioURL] == renderContext.audioSHA256 else {
                throw ProjectAnalysisError.changedRenderArtifact
            }
        } else {
            try await renderContext.validateArtifact(at: dialogueAudio, beforeMeasurement: true)
        }
        let audio: DialogueAudio
        if renderContext.projectSlice {
            guard renderContext.isolatedTargetID == target.id,
                  try DirectAudioRender.isEligible(projectData: projectData, selection: selection) else {
                throw ProjectAnalysisError.staleRender
            }
            audio = try await SourceAudioReader.read(url: dialogueAudio, range: target.timelineRange,
                timelineStart: target.timelineRange.start, windowDuration: settings.windowDuration,
                expectedMediaDuration: document.projectRange.checkedDuration(), progress: progress)
        } else if let isolatedID = renderContext.isolatedTargetID {
            guard isolatedID == target.id else { throw ProjectAnalysisError.staleRender }
            let decoded = try await DialogueAudioReader.read(url: dialogueAudio,
                expectedDuration: target.timelineRange.checkedDuration(), frameDuration: document.frameDuration,
                windowDuration: settings.windowDuration, progress: progress)
            guard abs(decoded.duration.seconds - target.timelineRange.duration.seconds) <= 1.1 / decoded.sampleRate else {
                throw ProjectAnalysisError.incompleteRender
            }
            let logicalDuration = try target.timelineRange.checkedDuration()
            let nativeTail = try logicalDuration.subtracting(decoded.duration)
            let normalizeLastClock: Bool
            if nativeTail > .zero {
                // A native floor-ended WAV can leave less than one logical
                // sample at the video-project end. Match SourceAudioReader's
                // final measurement clock without adding or changing PCM/RMS.
                guard decoded.sampleRate >= 1, decoded.sampleRate <= 768_000,
                      decoded.sampleRate.rounded() == decoded.sampleRate,
                      nativeTail < RationalTime(1, Int64(decoded.sampleRate)),
                      decoded.windows.last?.range.end == decoded.duration else {
                    throw ProjectAnalysisError.incompleteRender
                }
                normalizeLastClock = true
            } else {
                normalizeLastClock = false
            }
            let windows = try decoded.windows.enumerated().map { index, window in
                let end = normalizeLastClock && index == decoded.windows.count - 1
                    ? logicalDuration : window.range.end
                return AudioLevelWindow(range: TimeRange(start: try window.range.start.adding(target.timelineRange.start),
                    end: try end.adding(target.timelineRange.start)), channelRMS: window.channelRMS)
            }
            audio = DialogueAudio(windows: windows, duration: decoded.duration,
                sampleRate: decoded.sampleRate, channelCount: decoded.channelCount)
        } else if let sourceRange = renderContext.sourceRange {
            let expectedRange = TimeRange(start: target.sourceFileStart,
                end: try target.sourceFileStart.adding(target.timelineRange.checkedDuration()))
            guard sourceRange == expectedRange,
                  target.mediaURL?.standardizedFileURL.resolvingSymlinksInPath() == renderContext.audioURL,
                  renderContext.renderedRoles.isEmpty else { throw ProjectAnalysisError.staleRender }
            audio = try await SourceAudioReader.read(url: dialogueAudio, range: sourceRange,
                timelineStart: target.timelineRange.start, windowDuration: settings.windowDuration, progress: progress)
        } else {
            audio = try await DialogueAudioReader.read(url: dialogueAudio,
                expectedDuration: document.projectRange.checkedDuration(), frameDuration: document.frameDuration,
                windowDuration: settings.windowDuration, progress: progress)
            guard abs(audio.duration.seconds - document.projectRange.duration.seconds) <= 1.1 / audio.sampleRate else {
                throw ProjectAnalysisError.incompleteRender
            }
        }
        await validating()
        if let capturedMedia { try await capturedMedia.validate() }
        else { try await renderContext.validateArtifact(at: dialogueAudio) }
        await detecting()
        let grid = try analysisCutGrid(projectData: projectData, frameDuration: document.frameDuration,
            decodedSampleRate: audio.sampleRate, sourceAudio: renderContext.sourceRange != nil)
        let analysis = try SilenceDetector.analyze(windows: audio.windows, target: target.timelineRange,
            frameDuration: grid, settings: settings)
        let review = try ReviewPlan(jobID: jobID, document: document, target: target, analysis: analysis, requireDialogue: renderContext.sourceRange == nil && renderContext.isolatedTargetID == nil)
        return AnalyzedAudioProject(document: document, target: target, dialogueContext: renderContext,
            audio: audio, settings: settings, analysis: analysis, review: review, cutFrameDuration: grid)
    }

    static func analysisCutGrid(projectData: Data, frameDuration: RationalTime,
                                decodedSampleRate: Double, sourceAudio: Bool) throws -> RationalTime {
        var rate = decodedSampleRate
        if sourceAudio {
            // Source decoding may have a different rate from the project's
            // future native mix. Prefer its declared output clock for cuts.
            let xml = try XMLDocument(data: projectData, options: [.nodeLoadExternalEntitiesNever])
            let sequences = try xml.nodes(forXPath: "//project/sequence").compactMap { $0 as? XMLElement }
            guard sequences.count == 1 else { throw ProjectAnalysisError.staleRender }
            if let declared = sequences[0].attribute(forName: "audioRate")?.stringValue {
                let rates: [String: Double] = ["32k": 32_000, "44.1k": 44_100, "48k": 48_000,
                    "88.2k": 88_200, "96k": 96_000, "176.4k": 176_400, "192k": 192_000]
                guard let projectRate = rates[declared] else { throw SourceAudioError.invalidAudio }
                rate = projectRate
            }
        }
        // A verified native render is authoritative even when its WAV export
        // rate differs from the sequence setting. Never resample it here.
        return try cutGrid(videoFrameDuration: frameDuration, sampleRate: rate)
    }

    static func cutGrid(videoFrameDuration: RationalTime, sampleRate: Double) throws -> RationalTime {
        guard sampleRate.isFinite, sampleRate >= 1, sampleRate <= 768_000,
              sampleRate.rounded() == sampleRate else { throw SourceAudioError.invalidAudio }
        return try AudioVideoCutGrid.frameDuration(videoFrameDuration: videoFrameDuration,
            sampleRate: Int64(sampleRate))
    }
}

public enum ProjectAnalysisError: LocalizedError {
    case staleRender, incorrectRoles, incompleteRender
    case invalidRenderArtifact, changedRenderArtifact, changedWindowDuration
    public var errorDescription: String? {
        switch self {
        case .staleRender:
            return "The dialogue render does not match this project state and full project range. Export and analyze again."
        case .incorrectRoles:
            return "The render must contain every enabled Dialogue role and subrole, with other roles excluded."
        case .incompleteRender:
            return "The dialogue render does not cover the entire project to audio-sample precision. Export the full project again."
        case .invalidRenderArtifact:
            return "The dialogue render must be a completed local audio file."
        case .changedRenderArtifact:
            return "The dialogue audio file changed or was replaced after its export context was captured. Export and analyze again."
        case .changedWindowDuration:
            return "Changing the analysis window duration requires reading the dialogue render again."
        }
    }
}
