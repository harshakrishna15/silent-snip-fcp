import AppKit
import CutdownCore
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A complete, verified result exists on disk before Final Cut receives it.
/// Sending the document confirms delivery, not a successful host round trip.
struct PreparedXMLProject {
    let outputURL: URL
    let recoveryURL: URL
    let recoveryData: Data
    let libraryURL: URL
    let output: EditedProjectOutput

    @MainActor func send(using importer: (URL) async throws -> Void) async throws {
        try Task.checkCancellation()
        guard try Data(contentsOf: outputURL) == output.xmlData,
              try Data(contentsOf: recoveryURL) == recoveryData else {
            throw EditedProjectWriterError.verificationFailed("the saved result or recovery XML changed before import")
        }
        try XMLProjectApply.validateLibrary(libraryURL)
        try Task.checkCancellation()
        // Exactly one delivery attempt. An uncertain result must not cause a
        // second import or delete the artifact that the host may be reading.
        try await importer(outputURL)
    }
}

enum XMLProjectApply {
    /// This runs before generation and compares two captures of the original
    /// project, not a generated result against a natively edited timeline.
    static func verifyBaseline(_ current: TimelineDocument, analyzed: TimelineDocument) throws {
        var changes: [String] = []
        if current.projectUID != analyzed.projectUID { changes.append("project identity") }
        if current.projectName != analyzed.projectName { changes.append("project name") }
        if current.projectRange != analyzed.projectRange { changes.append("project duration") }
        if current.frameDuration != analyzed.frameDuration { changes.append("frame rate") }
        if current.fingerprint != analyzed.fingerprint { changes.append("timeline content, media references, or effects") }
        guard changes.isEmpty else { throw XMLProjectBaselineError(changes: changes) }
    }

    static func validateLibrary(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard url.isFileURL, url.pathExtension.lowercased() == "fcpbundle",
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EditedProjectWriterError.unsupported("the source library is unavailable; no edited project was sent")
        }
    }

    static func prepare(projectData: Data, selection: TimelineSelection, cuts: [TimeRange],
                        settings: AnalysisSettings, mode: CutdownOutputMode,
                        outputName: String, directory: URL, replaceOriginal: Bool = false) throws -> PreparedXMLProject {
        let document = try TimelineParser.parse(data: projectData)
        let xml = try XMLDocument(data: projectData, options: [.nodeLoadExternalEntitiesNever])
        let libraries = try xml.nodes(forXPath: "/fcpxml/library").compactMap { $0 as? XMLElement }
        guard libraries.count == 1, let location = libraries[0].attribute(forName: "location")?.stringValue,
              let library = URL(string: location) else {
            throw EditedProjectWriterError.unsupported("the exported XML does not identify its source library")
        }
        try validateLibrary(library)
        let gap = try mode.gapDuration(frame: document.frameDuration)
        var gaps: [TimeRange: RationalTime] = [:]
        if let gap { for cut in cuts { gaps[cut] = gap } }
        let withSettings = try AudioControllerSettings.embedding(settings, in: projectData, selection: selection)
        let output = try EditedProjectWriter.write(projectData: withSettings, selection: selection,
            selectedRanges: cuts, outputName: outputName, destinationLibrary: library, replacementGaps: gaps, replaceOriginal: replaceOriginal)
        let recovery = try ProjectRecoverySnapshot.recovery(data: projectData, name: document.projectName + " — Before Cuts")
        guard directory.isFileURL, !FileManager.default.fileExists(atPath: directory.path) else {
            throw EditedProjectWriterError.unsupported("the result folder already exists or is not local")
        }
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let outputURL = directory.appendingPathComponent("Cutdown.fcpxml")
        let recoveryURL = directory.appendingPathComponent("Before-Cuts.fcpxml")
        try recovery.write(to: recoveryURL, options: .withoutOverwriting)
        try output.xmlData.write(to: outputURL, options: .withoutOverwriting)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(output.report).write(to: directory.appendingPathComponent("Edit-Report.json"), options: .withoutOverwriting)
        // Final Cut may omit/reset AU state on XML import. Preserve the exact
        // analysis settings separately; do not pretend this restores the effect.
        try encoder.encode(settings).write(to: directory.appendingPathComponent("Analysis-Settings.json"), options: .withoutOverwriting)
        guard try Data(contentsOf: recoveryURL) == recovery,
              try Data(contentsOf: outputURL) == output.xmlData else {
            throw EditedProjectWriterError.verificationFailed("the saved result or recovery snapshot changed")
        }
        return PreparedXMLProject(outputURL: outputURL, recoveryURL: recoveryURL, recoveryData: recovery, libraryURL: library, output: output)
    }

    @MainActor static func importIntoFinalCut(_ url: URL) async throws {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: FinalCutAccessibility.bundleIdentifier) else {
            throw FinalCutAccessibility.AccessibilityError.notRunning
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration)
    }
}

struct XMLProjectBaselineError: LocalizedError {
    let changes: [String]
    var errorDescription: String? {
        "The project changed after Analyze (\(changes.joined(separator: "; "))). Analyze again before applying cuts. No edited project was generated."
    }
}
