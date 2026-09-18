import CutdownCore
import Foundation

public struct AudioProjectProcessingCut: Codable, Sendable {
    public let range: TimeRange
    public let included: Bool
    public let unavailableReason: String?
}

/// Evidence for an offline transformation. This does not assert that a host
/// effect initiated processing or that Final Cut imported the result.
public struct AudioProjectProcessingReport: Codable, Sendable {
    public let operation: String
    public let analysisScope: String
    public let sourceRange: TimeRange?
    public let detector: String
    public let classifiesBreaths: Bool
    public let sourceXML: URL
    public let dialogueAudio: URL
    public let dialogueAudioSHA256: String
    public let assertedDialogueRoles: [String]
    public let audioDuration: RationalTime
    public let sampleRate: Double
    public let channelCount: Int
    public let measurementWindowCount: Int
    public let settings: AnalysisSettings
    public let analysis: SilenceAnalysisResult
    public let reviewCuts: [AudioProjectProcessingCut]
    public let editedProject: EditedProjectReport
}

public struct AudioProjectArtifacts: Sendable {
    public let directory: URL
    public let editedXML: URL
    public let beforeXML: URL
    public let reportURL: URL
    public let report: AudioProjectProcessingReport
}

public struct AudioProjectProcessingResult: Sendable {
    public let analyzed: AnalyzedAudioProject
    /// Nil means no cuts were selected or eligible. No directory is then created.
    public let artifacts: AudioProjectArtifacts?
}

public enum AudioProjectProcessingError: Error, LocalizedError, Equatable {
    case invalidOutputDirectory
    case outputExists
    case invalidDestinationLibrary
    case invalidSelection
    case changedProject
    case changedSourceMedia(String)

    public var errorDescription: String? {
        switch self {
        case .invalidOutputDirectory:
            return "Choose a new local output directory whose parent already exists."
        case .outputExists:
            return "The output directory already exists. Choose a new directory; existing results are never overwritten."
        case .invalidDestinationLibrary:
            return "The destination must be an existing local Final Cut library (.fcpbundle)."
        case .invalidSelection:
            return "Selected ranges must match distinct eligible cuts from this analysis."
        case .changedProject:
            return "The project XML changed during processing. Analyze the new project state again."
        case .changedSourceMedia(let path):
            return "Source media changed during processing: \(path)"
        }
    }
}

/// Runs PCM decoding, silence analysis, safety review, and editable XML creation
/// without a window, Share interaction, import, or native timeline mutation.
/// Render roles remain explicit caller evidence, not an inference from filenames.
public enum AudioProjectProcessor {
    public static func process(
        projectXML: URL,
        selection: TimelineSelection,
        dialogueAudio: URL,
        renderContext: DialogueRenderContext,
        settings: AnalysisSettings = .defaults,
        outputDirectory: URL,
        outputName: String,
        destinationLibrary: URL? = nil,
        selectedRanges: [TimeRange]? = nil,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> AudioProjectProcessingResult {
        try Task.checkCancellation()
        let outputDirectory = try checkedOutputDirectory(outputDirectory)
        try validateDestinationLibrary(destinationLibrary)
        let xmlURL = projectXML.pathExtension.lowercased() == "fcpxmld"
            ? projectXML.appendingPathComponent("Info.fcpxml") : projectXML
        let originalData = try Data(contentsOf: xmlURL)
        let baseline = try TimelineParser.parse(data: originalData, exclusions: renderContext.fingerprintExclusions)
        _ = try baseline.selectedTarget(selection)
        let sourceIdentities = try sourceMediaIdentities(baseline)
        var analyzed = try await ProjectAudioAnalysis.analyze(projectXML: projectXML, selection: selection,
            dialogueAudio: dialogueAudio, renderContext: renderContext, settings: settings, progress: progress)
        try validateInputs(xmlURL: xmlURL, originalData: originalData, renderContext: renderContext,
                           dialogueAudio: dialogueAudio, sourceIdentities: sourceIdentities)

        if let selectedRanges {
            let requested = Set(selectedRanges)
            let eligible = Set(analyzed.review.cuts.filter(\.isEligible).map(\.range))
            guard requested.count == selectedRanges.count, requested.isSubset(of: eligible) else {
                throw AudioProjectProcessingError.invalidSelection
            }
            for cut in analyzed.review.cuts {
                try analyzed.review.setIncluded(requested.contains(cut.range), cutID: cut.id)
            }
        }
        let cuts = analyzed.review.selectedCuts.map(\.range)
        guard !cuts.isEmpty else { return AudioProjectProcessingResult(analyzed: analyzed, artifacts: nil) }
        let output = try EditedProjectWriter.write(projectData: originalData, selection: selection,
            selectedRanges: cuts, outputName: outputName, destinationLibrary: destinationLibrary)
        let report = AudioProjectProcessingReport(operation: "offline-edited-project",
            analysisScope: renderContext.sourceRange == nil ? "rendered-project-dialogue" : "selected-source-audio",
            sourceRange: renderContext.sourceRange,
            detector: "Loudest-channel RMS threshold in fixed windows", classifiesBreaths: false,
            sourceXML: xmlURL, dialogueAudio: renderContext.audioURL,
            dialogueAudioSHA256: renderContext.audioSHA256,
            assertedDialogueRoles: renderContext.renderedRoles.sorted(), audioDuration: analyzed.audio.duration,
            sampleRate: analyzed.audio.sampleRate, channelCount: analyzed.audio.channelCount,
            measurementWindowCount: analyzed.audio.windows.count, settings: settings, analysis: analyzed.analysis,
            reviewCuts: analyzed.review.cuts.map {
                AudioProjectProcessingCut(range: $0.range, included: $0.included, unavailableReason: $0.unavailableReason)
            }, editedProject: output.report)

        // Publish the completed directory in one move. Cleanup is confined to a
        // newly created, private staging directory, never a caller's existing result.
        let staging = outputDirectory.deletingLastPathComponent()
            .appendingPathComponent(".Cutdown-\(UUID().uuidString).staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let editedName = "Cutdown.fcpxml"
        let beforeName = "Before-Cutdown.fcpxml"
        let reportName = "Edit-Report.json"
        try output.xmlData.write(to: staging.appendingPathComponent(editedName), options: .withoutOverwriting)
        try originalData.write(to: staging.appendingPathComponent(beforeName), options: .withoutOverwriting)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: staging.appendingPathComponent(reportName), options: .withoutOverwriting)
        try validateInputs(xmlURL: xmlURL, originalData: originalData, renderContext: renderContext,
                           dialogueAudio: dialogueAudio, sourceIdentities: sourceIdentities)
        try validateDestinationLibrary(destinationLibrary)
        try Task.checkCancellation()
        // moveItem fails if another operation created this destination meanwhile.
        try FileManager.default.moveItem(at: staging, to: outputDirectory)
        let artifacts = AudioProjectArtifacts(directory: outputDirectory,
            editedXML: outputDirectory.appendingPathComponent(editedName),
            beforeXML: outputDirectory.appendingPathComponent(beforeName),
            reportURL: outputDirectory.appendingPathComponent(reportName), report: report)
        return AudioProjectProcessingResult(analyzed: analyzed, artifacts: artifacts)
    }

    private static func checkedOutputDirectory(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw AudioProjectProcessingError.invalidOutputDirectory }
        let output = url.standardizedFileURL.resolvingSymlinksInPath()
        let parent = output.deletingLastPathComponent()
        var isDirectory = ObjCBool(false)
        guard output != parent, FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw AudioProjectProcessingError.invalidOutputDirectory }
        guard !FileManager.default.fileExists(atPath: output.path),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else {
            throw AudioProjectProcessingError.outputExists
        }
        return output
    }

    private static func validateDestinationLibrary(_ url: URL?) throws {
        guard let url else { return }
        var isDirectory = ObjCBool(false)
        guard url.isFileURL, url.pathExtension.lowercased() == "fcpbundle",
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AudioProjectProcessingError.invalidDestinationLibrary
        }
    }

    private struct SourceIdentity: Equatable {
        let url: URL
        let resolvedURL: URL
        let deviceIdentifier: UInt64
        let fileIdentifier: UInt64
        let size: UInt64
        let modified: Date?
        let created: Date?
    }

    private static func identity(_ url: URL) throws -> SourceIdentity {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
            throw TimelineError.missingMedia(url.path)
        }
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: resolvedURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw TimelineError.missingMedia(url.path)
        }
        return SourceIdentity(url: url, resolvedURL: resolvedURL,
            deviceIdentifier: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
            fileIdentifier: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modified: attributes[.modificationDate] as? Date, created: attributes[.creationDate] as? Date)
    }

    private static func sourceMediaIdentities(_ document: TimelineDocument) throws -> [SourceIdentity] {
        let urls = Set(document.clips.filter(\.enabled).compactMap(\.mediaURL))
        return try urls.sorted { $0.path < $1.path }.map(identity)
    }

    private static func validateInputs(xmlURL: URL, originalData: Data, renderContext: DialogueRenderContext,
                                       dialogueAudio: URL, sourceIdentities: [SourceIdentity]) throws {
        try Task.checkCancellation()
        guard try Data(contentsOf: xmlURL) == originalData else { throw AudioProjectProcessingError.changedProject }
        let current = try DialogueRenderContext(projectFingerprint: renderContext.projectFingerprint,
            projectUID: renderContext.projectUID, projectName: renderContext.projectName,
            projectRange: renderContext.projectRange, renderedRoles: renderContext.renderedRoles,
            audioURL: dialogueAudio, controllerEffectUIDs: renderContext.controllerEffectUIDs,
            allowOmittedPrivateSettings: renderContext.allowOmittedPrivateSettings, sourceRange: renderContext.sourceRange)
        guard current.audioURL == renderContext.audioURL, current.audioSHA256 == renderContext.audioSHA256 else {
            throw ProjectAnalysisError.changedRenderArtifact
        }
        for previous in sourceIdentities {
            guard try identity(previous.url) == previous else {
                throw AudioProjectProcessingError.changedSourceMedia(previous.url.path)
            }
        }
    }
}
