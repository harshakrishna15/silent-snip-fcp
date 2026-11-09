import AppKit
import SilentSnipCore
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
    /// Binds a staged source-only edit to the original export. The final
    /// read-only Share can use a new bookmark for the same original file.
    struct SourceOnlyEvidence: Sendable {
        let destination: XMLReplacementTarget
        fileprivate let comparableXML: Data

        func verifyCurrent(projectData: Data) throws {
            // The identity reader runs the bounded parser before FoundationXML.
            guard try XMLReplacementTarget(projectData: projectData) == destination,
                  try XMLProjectApply.sourceOnlyComparableXML(XMLProjectApply.sourceOnlyXML(projectData)) == comparableXML else {
                throw XMLProjectBaselineError(changes: ["the source project or its event"])
            }
        }
    }

    /// Only a plain whole-project audio asset may omit Apply's native render.
    /// Keep the ordinary path for unrecognized structures and processing flags.
    static func sourceOnlyEvidence(projectData: Data, document: TimelineDocument,
                                   target: TimelineClip) throws -> SourceOnlyEvidence? {
        let parsed = try TimelineParser.parse(data: projectData)
        guard parsed.projectUID == document.projectUID, parsed.projectName == document.projectName,
              parsed.fingerprint == document.fingerprint, parsed.clips == [target], document.clips == [target],
              parsed.warnings.isEmpty, target.kind == "asset-clip", target.isPrimaryStoryline, target.parentID == nil,
              target.lane == 0, target.enabled, target.hasAudio, !target.hasVideo, target.unsupportedReasons.isEmpty,
              !target.hasUnresolvedTiming, target.timelineRange == parsed.projectRange else { return nil }
        let xml = try sourceOnlyXML(projectData)
        func shape(_ element: XMLElement, attributes: Set<String>, children: Set<String> = []) -> Bool {
            (element.namespaces ?? []).isEmpty
                && (element.attributes ?? []).allSatisfy { attributes.contains($0.name ?? "") }
                && (element.children ?? []).allSatisfy { node in
                    if let child = node as? XMLElement { return children.contains(child.name ?? "") }
                    return node.kind == .comment || (node.kind == .text
                        && node.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
                }
        }
        func only(_ name: String, in parent: XMLElement) -> XMLElement? {
            let elements = parent.elements(forName: name)
            return elements.count == 1 ? elements.first : nil
        }
        func attr(_ name: String, in element: XMLElement) -> String? {
            element.attribute(forName: name)?.stringValue
        }
        func inertMetadata(_ node: XMLElement) -> Bool {
            shape(node, attributes: [], children: ["md"])
                && node.elements(forName: "md").allSatisfy { shape($0, attributes: ["key", "value"]) }
        }
        guard let root = xml.rootElement(), shape(root, attributes: ["version"], children: ["resources", "library"]),
              let resources = only("resources", in: root), shape(resources, attributes: [], children: ["format", "asset"]),
              let format = only("format", in: resources), let asset = only("asset", in: resources),
              shape(format, attributes: ["id", "name", "frameDuration", "width", "height", "colorSpace"]),
              let library = only("library", in: root),
              shape(library, attributes: ["location", "colorProcessing"], children: ["event", "smart-collection"]),
              let event = only("event", in: library), shape(event, attributes: ["name", "uid"], children: ["project"]),
              let project = only("project", in: event),
              shape(project, attributes: ["name", "uid", "modDate"], children: ["sequence"]),
              let sequence = only("sequence", in: project),
              shape(sequence, attributes: ["format", "duration", "tcStart", "tcFormat", "audioLayout", "audioRate"], children: ["spine"]),
              attr("format", in: sequence) == attr("id", in: format),
              let spine = only("spine", in: sequence), shape(spine, attributes: [], children: ["asset-clip"]),
              let clip = only("asset-clip", in: spine),
              shape(clip, attributes: ["ref", "name", "offset", "start", "duration", "audioRole", "enabled", "srcEnable"]),
              attr("ref", in: clip) == attr("id", in: asset),
              attr("enabled", in: clip) == nil || attr("enabled", in: clip) == "1",
              ["all", "audio"].contains(attr("srcEnable", in: clip) ?? "all"),
              let role = attr("audioRole", in: clip), role == "dialogue" || role.hasPrefix("dialogue."),
              !role.components(separatedBy: ".").contains(where: \.isEmpty),
              role.trimmingCharacters(in: .whitespacesAndNewlines) == role,
              role.rangeOfCharacter(from: .controlCharacters) == nil,
              shape(asset, attributes: ["id", "name", "uid", "start", "duration", "hasAudio", "hasVideo",
                "audioSources", "audioChannels", "audioRate"], children: ["media-rep", "metadata"]),
              asset.elements(forName: "metadata").allSatisfy(inertMetadata),
              attr("hasAudio", in: asset) == "1", (attr("hasVideo", in: asset) ?? "0") == "0",
              attr("audioSources", in: asset) == "1",
              let channels = attr("audioChannels", in: asset).flatMap(Int.init), (1...8).contains(channels),
              let rate = attr("audioRate", in: asset).flatMap(Int.init), (1...768_000).contains(rate),
              let representation = only("media-rep", in: asset),
              shape(representation, attributes: ["kind", "src", "sig"], children: ["bookmark"]),
              attr("kind", in: representation) == "original-media",
              let source = attr("src", in: representation).flatMap(URL.init(string:)), source == target.mediaURL,
              source.isFileURL, source.host == nil || source.host == "", source.path.hasPrefix("/"),
              source.query == nil, source.fragment == nil, source.user == nil, source.password == nil, source.port == nil,
              let destination = try? XMLReplacementTarget(projectData: projectData),
              let comparable = try sourceOnlyComparableXML(xml) else { return nil }
        return .init(destination: destination, comparableXML: comparable)
    }

    private static func sourceOnlyXML(_ data: Data) throws -> XMLDocument {
        try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever, .nodePreserveAll])
    }

    private static func sourceOnlyComparableXML(_ xml: XMLDocument) throws -> Data? {
        let bookmarks = try xml.nodes(forXPath: "/fcpxml/resources/asset/media-rep[@kind='original-media']/bookmark")
        guard bookmarks.count <= 1 else { return nil }
        if let bookmark = bookmarks.first {
            guard (bookmark.children ?? []).allSatisfy({ $0.kind == .text }) else { return nil }
            bookmark.stringValue = ""
        }
        return xml.xmlData(options: [.nodePreserveAll])
    }

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
                        settings: AnalysisSettings, mode: SilentSnipOutputMode,
                        outputName: String, directory: URL, replaceOriginal: Bool = false,
                        selectedClipOnly: Bool = false, useOriginalEvent: Bool = false,
                        omitController: Bool = false,
                        losslessAudio: LosslessRenderedAudio? = nil,
                        workflowOrigin: WorkflowReviewOrigin? = nil) throws -> PreparedXMLProject {
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
        let withSettings: Data
        if let workflowOrigin {
            try workflowOrigin.verify(projectData: projectData)
            try WorkflowReviewOrigin.validate(settings: settings)
            // Workflow controls own these settings. Never insert a controller
            // or overwrite an existing AU's state on this route.
            withSettings = projectData
        } else {
            withSettings = try AudioControllerSettings.embedding(settings, in: projectData, selection: selection)
        }
        let output = try EditedProjectWriter.write(projectData: withSettings, selection: selection,
            selectedRanges: cuts, outputName: outputName, destinationLibrary: library, replacementGaps: gaps,
            replaceOriginal: replaceOriginal, selectedClipOnly: selectedClipOnly, useOriginalEvent: useOriginalEvent,
            omitController: omitController, losslessAudio: losslessAudio)
        let recovery = try ProjectRecoverySnapshot.recovery(data: projectData, name: document.projectName + " — Before Cuts")
        guard directory.isFileURL, !FileManager.default.fileExists(atPath: directory.path) else {
            throw EditedProjectWriterError.unsupported("the result folder already exists or is not local")
        }
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let outputURL = directory.appendingPathComponent("Silent Snip.fcpxml")
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
        "The project changed after analysis (\(changes.joined(separator: "; "))). Click Analyze Again before applying cuts. No cleaned project was created."
    }
}
