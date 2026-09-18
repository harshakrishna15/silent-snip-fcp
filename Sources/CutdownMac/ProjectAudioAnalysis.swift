import CutdownCore
import Foundation

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
    /// Non-nil means selected source audio, not a rendered Dialogue mix.
    public let sourceRange: TimeRange?
    let isolatedTargetID: String?

    /// Use the same exact controller allowlist for export, analysis, and subsequent
    /// baseline checks. Callers must obtain these UIDs from a verified effect export.
    public var fingerprintExclusions: TimelineFingerprintExclusions {
        .init(controllerEffectUIDs: controllerEffectUIDs)
    }

    public init(projectFingerprint: String, projectUID: String?, projectName: String,
                projectRange: TimeRange, renderedRoles: Set<String>, audioURL: URL,
                controllerEffectUIDs: Set<String> = [], allowOmittedPrivateSettings: Bool = false, sourceRange: TimeRange? = nil) throws {
        let canonicalURL = try MediaContentSnapshot.canonical(audioURL)
        try self.init(projectFingerprint: projectFingerprint, projectUID: projectUID, projectName: projectName,
            projectRange: projectRange, renderedRoles: renderedRoles, audioURL: canonicalURL,
            controllerEffectUIDs: controllerEffectUIDs, allowOmittedPrivateSettings: allowOmittedPrivateSettings,
            sourceRange: sourceRange, audioSHA256: MediaContentSnapshot.contentHash(at: canonicalURL))
    }

    /// Only the interactive capture path can reuse its freshly read media evidence.
    static func capturedSource(document: TimelineDocument, target: TimelineClip,
                               media: MediaContentSnapshot) throws -> Self {
        guard let url = target.mediaURL else { throw SourceAudioError.invalidAudio }
        let canonicalURL = try MediaContentSnapshot.canonical(url)
        guard let digest = media.hashes[canonicalURL] else { throw ProjectAnalysisError.invalidRenderArtifact }
        return Self(projectFingerprint: document.fingerprint, projectUID: document.projectUID,
            projectName: document.projectName, projectRange: document.projectRange, renderedRoles: [],
            audioURL: canonicalURL, controllerEffectUIDs: [AudioControllerSettings.effectUID],
            allowOmittedPrivateSettings: true,
            sourceRange: TimeRange(start: target.sourceFileStart,
                end: try target.sourceFileStart.adding(target.timelineRange.checkedDuration())), audioSHA256: digest)
    }

    private init(projectFingerprint: String, projectUID: String?, projectName: String,
                 projectRange: TimeRange, renderedRoles: Set<String>, audioURL: URL,
                 controllerEffectUIDs: Set<String>, allowOmittedPrivateSettings: Bool,
                 sourceRange: TimeRange?, audioSHA256: String, isolatedTargetID: String? = nil) {
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
    }

    static func capturedIsolated(document: TimelineDocument, target: TimelineClip, audioURL: URL) throws -> Self {
        let canonical = try MediaContentSnapshot.canonical(audioURL)
        return Self(projectFingerprint: document.fingerprint, projectUID: document.projectUID,
            projectName: document.projectName, projectRange: document.projectRange, renderedRoles: [],
            audioURL: canonical, controllerEffectUIDs: [AudioControllerSettings.effectUID],
            allowOmittedPrivateSettings: true, sourceRange: nil,
            audioSHA256: try MediaContentSnapshot.contentHash(at: canonical), isolatedTargetID: target.id)
    }

    fileprivate func validateArtifact(at url: URL) async throws {
        guard url.isFileURL else { throw ProjectAnalysisError.invalidRenderArtifact }
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard canonicalURL == audioURL, try await MediaContentSnapshot.capture([canonicalURL]).hashes[canonicalURL] == audioSHA256 else {
            throw ProjectAnalysisError.changedRenderArtifact
        }
    }

    fileprivate func retainingAudio(at url: URL) -> Self {
        Self(projectFingerprint: projectFingerprint, projectUID: projectUID, projectName: projectName,
            projectRange: projectRange, renderedRoles: renderedRoles, audioURL: url,
            controllerEffectUIDs: controllerEffectUIDs, allowOmittedPrivateSettings: allowOmittedPrivateSettings,
            sourceRange: sourceRange, audioSHA256: audioSHA256, isolatedTargetID: isolatedTargetID)
    }


}

public struct AnalyzedAudioProject: Sendable {
    public let document: TimelineDocument
    public let target: TimelineClip
    public let dialogueContext: DialogueRenderContext
    public let audio: DialogueAudio
    public private(set) var settings: AnalysisSettings
    public private(set) var analysis: SilenceAnalysisResult
    public var review: ReviewPlan

    public var isAudioOnlyTarget: Bool { !target.hasVideo }

    func retainingAudio(at url: URL) -> Self {
        Self(document: document, target: target, dialogueContext: dialogueContext.retainingAudio(at: url),
            audio: audio, settings: settings, analysis: analysis, review: review)
    }

    /// Reuse the same analyzed render when Inspector settings change. Apply still
    /// requires a fresh project export and baseline verification by the editor.
    @discardableResult public mutating func recalculate(settings: AnalysisSettings) throws -> Bool {
        guard settings.windowDuration == self.settings.windowDuration else {
            throw ProjectAnalysisError.changedWindowDuration
        }
        let updated = try SilenceDetector.analyze(windows: audio.windows, target: target.timelineRange,
            frameDuration: document.frameDuration, settings: settings)
        let resetChoices = try review.recalculate(updated, document: document)
        self.settings = settings
        self.analysis = updated
        return resetChoices
    }

    init(document: TimelineDocument, target: TimelineClip, dialogueContext: DialogueRenderContext,
         audio: DialogueAudio, settings: AnalysisSettings, analysis: SilenceAnalysisResult, review: ReviewPlan) {
        self.document = document
        self.target = target
        self.dialogueContext = dialogueContext
        self.audio = audio
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
        // no controller, but must validate any Cutdown AU that is present.
        if renderContext.allowOmittedPrivateSettings {
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
            try await renderContext.validateArtifact(at: dialogueAudio)
        }
        let audio: DialogueAudio
        if let isolatedID = renderContext.isolatedTargetID {
            guard isolatedID == target.id else { throw ProjectAnalysisError.staleRender }
            let decoded = try await DialogueAudioReader.read(url: dialogueAudio,
                expectedDuration: target.timelineRange.checkedDuration(), frameDuration: document.frameDuration,
                windowDuration: settings.windowDuration, progress: progress)
            guard abs(decoded.duration.seconds - target.timelineRange.duration.seconds) <= 1.1 / decoded.sampleRate else {
                throw ProjectAnalysisError.incompleteRender
            }
            let windows = try decoded.windows.map { window in
                AudioLevelWindow(range: TimeRange(start: try window.range.start.adding(target.timelineRange.start),
                    end: try window.range.end.adding(target.timelineRange.start)), channelRMS: window.channelRMS)
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
        let analysis = try SilenceDetector.analyze(windows: audio.windows, target: target.timelineRange,
            frameDuration: document.frameDuration, settings: settings)
        let review = try ReviewPlan(jobID: jobID, document: document, target: target, analysis: analysis, requireDialogue: renderContext.sourceRange == nil && renderContext.isolatedTargetID == nil)
        return AnalyzedAudioProject(document: document, target: target, dialogueContext: renderContext,
            audio: audio, settings: settings, analysis: analysis, review: review)
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
