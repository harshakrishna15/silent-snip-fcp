import CutdownCore
import CutdownMac
import Darwin
import Foundation

private let usage = """
Usage: CutdownVerify --xml PATH --audio PATH --target-start TIME --target-end TIME
                     --role ROLE [--role ROLE ...] [--controller-uid UID ...]
                     [--threshold DBFS] [--minimum SECONDS]
                     [--before SECONDS] [--after SECONDS]
                     [--output-directory PATH --output-name NAME]
                     [--destination-library PATH]

Verify one exported project and its completed Dialogue render.
TIME uses FCPXML rational seconds, for example 0s, 10s, or 1001/30000s.
Repeat --role for every Dialogue role/subrole in the exported render. Roles are
explicit caller assertions; a filename cannot establish what audio was exported.
Only pass --controller-uid for an exact Cutdown UID verified in an actual export.
Defaults: threshold -40 dBFS, minimum 0.5s, before 0.1s, after 0.1s.
By default this is read-only. --output-directory creates a NEW directory with an
editable cut-up FCPXML project, the input XML, and a processing report. Its parent
must exist. --destination-library embeds the import destination; it does not open
Final Cut or import anything. Source files and existing timelines stay unchanged.
Results are JSON on stdout; progress and errors are on stderr.
"""

private struct CommandError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct Options {
    let xml: URL
    let audio: URL
    let selection: TimelineSelection
    let roles: Set<String>
    let controllerUIDs: Set<String>
    let settings: AnalysisSettings
    let outputDirectory: URL?
    let outputName: String?
    let destinationLibrary: URL?

    init(arguments: [String]) throws {
        let singleFlags: Set<String> = ["--xml", "--audio", "--target-start", "--target-end", "--threshold", "--minimum", "--before", "--after", "--output-directory", "--output-name", "--destination-library"]
        let repeatedFlags: Set<String> = ["--role", "--controller-uid"]
        var values: [String: String] = [:]
        var repeated: [String: Set<String>] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard singleFlags.contains(flag) || repeatedFlags.contains(flag) else {
                throw CommandError(message: "Unknown option: \(flag).\n\(usage)")
            }
            guard index + 1 < arguments.count, !arguments[index + 1].isEmpty,
                  !arguments[index + 1].hasPrefix("--") else {
                throw CommandError(message: "Missing value for \(flag).")
            }
            let value = arguments[index + 1]
            if repeatedFlags.contains(flag) {
                repeated[flag, default: []].insert(value)
            } else {
                guard values[flag] == nil else { throw CommandError(message: "Duplicate option: \(flag).") }
                values[flag] = value
            }
            index += 2
        }
        func required(_ flag: String) throws -> String {
            guard let value = values[flag] else { throw CommandError(message: "Required option: \(flag).\n\(usage)") }
            return value
        }
        func number(_ flag: String, default fallback: Double) throws -> Double {
            guard let text = values[flag] else { return fallback }
            guard let value = Double(text) else { throw CommandError(message: "Invalid number for \(flag): \(text).") }
            return value
        }
        let start = try RationalTime.parse(required("--target-start"))
        let end = try RationalTime.parse(required("--target-end"))
        guard start >= .zero, end > start else { throw CommandError(message: "The target must have a nonnegative start and an end after its start.") }
        _ = try end.subtracting(start)
        guard let explicitRoles = repeated["--role"], !explicitRoles.isEmpty else {
            throw CommandError(message: "Provide at least one explicit --role from the Dialogue export.")
        }
        xml = URL(fileURLWithPath: try required("--xml")).standardizedFileURL
        audio = URL(fileURLWithPath: try required("--audio")).standardizedFileURL
        selection = TimelineSelection(timelineRange: TimeRange(start: start, end: end))
        roles = explicitRoles
        controllerUIDs = repeated["--controller-uid"] ?? []
        outputDirectory = values["--output-directory"].map { URL(fileURLWithPath: $0).standardizedFileURL }
        outputName = values["--output-name"]
        destinationLibrary = values["--destination-library"].map { URL(fileURLWithPath: $0).standardizedFileURL }
        guard outputDirectory != nil || (outputName == nil && destinationLibrary == nil) else {
            throw CommandError(message: "--output-name and --destination-library require --output-directory.")
        }
        settings = try AnalysisSettings(
            thresholdDBFS: number("--threshold", default: -40),
            minimumSilenceDuration: number("--minimum", default: 0.5),
            beforeSpeechPadding: number("--before", default: 0.1),
            afterSpeechPadding: number("--after", default: 0.1)
        )
    }
}

private struct AudioIdentity: Encodable {
    let url: URL
    let sha256: String
    let duration: RationalTime
    let sampleRate: Double
    let channelCount: Int
    let windowCount: Int
    let assertedRoles: [String]
}

private struct VerificationReport: Encodable {
    let operation: String
    let editedXML: URL?
    let processingReport: URL?
    let projectName: String
    let projectUID: String?
    let projectFingerprint: String
    let projectRange: TimeRange
    let frameDuration: RationalTime
    let controllerEffectUIDs: [String]
    let audio: AudioIdentity
    let target: TimelineClip
    let isAudioOnlyTarget: Bool
    let settings: AnalysisSettings
    let disposition: SilenceAnalysisDisposition
    let proposedCuts: [TimeRange]
    let reviewCuts: [ReviewCut]
    let proposedRemovalDuration: RationalTime
    let selectedRemovalDuration: RationalTime
    let roleMetadataSource = "Explicit caller assertion; file identity verifies the artifact, not the exported mix."
}

@main
private enum CutdownVerify {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--help"] || arguments == ["-h"] { print(usage); return }
            let options = try Options(arguments: arguments)
            let exclusions = TimelineFingerprintExclusions(controllerEffectUIDs: options.controllerUIDs)
            let baseline = try TimelineParser.parse(url: options.xml, exclusions: exclusions)
            let context = try DialogueRenderContext(
                projectFingerprint: baseline.fingerprint, projectUID: baseline.projectUID,
                projectName: baseline.projectName, projectRange: baseline.projectRange,
                renderedRoles: options.roles, audioURL: options.audio,
                controllerEffectUIDs: options.controllerUIDs
            )
            let result: AnalyzedAudioProject
            var editedXML: URL?
            var processingReport: URL?
            if let directory = options.outputDirectory {
                FileHandle.standardError.write(Data("CutdownVerify: decoding audio and preparing editable cuts…\n".utf8))
                let processed = try await AudioProjectProcessor.process(
                    projectXML: options.xml, selection: options.selection, dialogueAudio: options.audio,
                    renderContext: context, settings: options.settings, outputDirectory: directory,
                    outputName: options.outputName ?? "\(baseline.projectName) — Cutdown",
                    destinationLibrary: options.destinationLibrary
                )
                result = processed.analyzed
                editedXML = processed.artifacts?.editedXML
                processingReport = processed.artifacts?.reportURL
                let message = editedXML == nil ? "No eligible cuts; no output project created." : "Created and verified the edited FCPXML project."
                FileHandle.standardError.write(Data("CutdownVerify: \(message)\n".utf8))
            } else {
                result = try await ProjectAudioAnalysis.analyze(
                    projectXML: options.xml, selection: options.selection, dialogueAudio: options.audio,
                    renderContext: context, settings: options.settings
                )
            }
            let report = VerificationReport(
                operation: options.outputDirectory == nil ? "read-only-analysis" : "process-to-edited-project",
                editedXML: editedXML, processingReport: processingReport,
                projectName: result.document.projectName, projectUID: result.document.projectUID,
                projectFingerprint: result.document.fingerprint, projectRange: result.document.projectRange,
                frameDuration: result.document.frameDuration, controllerEffectUIDs: options.controllerUIDs.sorted(),
                audio: AudioIdentity(url: context.audioURL, sha256: context.audioSHA256,
                    duration: result.audio.duration, sampleRate: result.audio.sampleRate,
                    channelCount: result.audio.channelCount, windowCount: result.audio.windows.count,
                    assertedRoles: options.roles.sorted()),
                target: result.target, isAudioOnlyTarget: result.isAudioOnlyTarget, settings: result.settings,
                disposition: result.analysis.disposition, proposedCuts: result.analysis.candidates,
                reviewCuts: result.review.cuts, proposedRemovalDuration: result.analysis.removedDuration,
                selectedRemovalDuration: try result.review.selectedDuration
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(report))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("CutdownVerify: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
