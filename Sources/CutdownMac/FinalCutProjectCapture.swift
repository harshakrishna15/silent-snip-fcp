import AppKit
import ApplicationServices
import CutdownCore
import Foundation

@MainActor public struct CapturedFinalCutProject {
    public let xmlURL: URL
    public let document: TimelineDocument
    public let selection: TimelineSelection
    public let target: TimelineClip
    public let projectName: String
    public let controllerEffectUIDs: Set<String>
    public let dropFrame: Bool
    let session: FinalCutAXSession

    /// Restore the custom Audio Unit view if a host operation displaced it.
    /// A non-nil result explains how to reconnect manually when safe automatic
    /// restoration could not be established; it never replaces an analysis error.
    public func restoreReviewWindow() async -> String? {
        await session.restoreReviewWindow()
    }
}

@MainActor public enum FinalCutProjectCapture {
    static func capture(to directory: URL, controllerEffectUIDs: Set<String> = [],
                               onSession: (FinalCutAXSession) -> Void = { _ in },
                               progress: (String) -> Void = { _ in }) async throws -> CapturedFinalCutProject {
        let session = try FinalCutAXSession()
        do {
        try await session.activate()
        progress("Preparing Final Cut for export…")
        // Keep the effect window open; only move input focus to the project.
        // Opening an AU view can leave the Inspector focused, making Final
        // Cut omit the timeline's active selection until the timeline regains
        // focus. Direct AX focus preserves the existing clip/range selection;
        // the menu command is only a compatibility fallback.
        let selectionBeforeFocus = try? session.selectionSnapshot()
        progress("Focusing the project timeline…")
        try await session.focusTimeline()
        progress("Reading the selected audio-only timeline clip…")
        let selected = try session.selectionSnapshot()
        try session.rememberReviewSelection(selected)
        onSession(session)
        if let selectionBeforeFocus, selectionBeforeFocus != selected {
            throw FinalCutCaptureError.invalidSelection("The selected timeline clip changed while restoring timeline focus.")
        }
        // The Inspector can expose an obvious duplicate before Share displaces
        // the AU window. XML validation remains authoritative if it is hidden.
        if controllerEffectUIDs.contains(AudioControllerSettings.effectUID),
           session.hasMultipleCutdownEffectsInInspector() {
            throw AudioControllerSettingsError.ambiguousController
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        progress("Exporting the active project XML…")
        let destination = directory.appendingPathComponent("Project-\(UUID()).fcpxmld")
        let xml = try await session.exportProjectXML(to: destination)
        // The exporter has confirmed this unique output is complete. Until the
        // caller receives it, capture owns cleanup if validation subsequently fails.
        var delivered = false
        defer { if !delivered { try? FileManager.default.removeItem(at: destination) } }
        let data = try Data(contentsOf: xml)
        let document = try TimelineParser.parse(data: data,
            exclusions: .init(controllerEffectUIDs: controllerEffectUIDs))
        let structure = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        let formats = try structure.nodes(forXPath: "//project/sequence/@tcFormat").compactMap(\.stringValue)
        guard formats.count <= 1, formats.allSatisfy({ $0 == "NDF" || $0 == "DF" }) else {
            throw FinalCutCaptureError.unsupportedTimecode("unknown project timecode format")
        }
        try session.assertCurrentProject()
        try await session.focusTimeline()
        guard try session.selectionSnapshot() == selected else {
            throw FinalCutCaptureError.invalidSelection("The selected timeline clip changed during export.")
        }
        let (selection, target) = try selected.resolve(in: document)
        delivered = true
        return CapturedFinalCutProject(xmlURL: xml, document: document, selection: selection,
            target: target, projectName: document.projectName, controllerEffectUIDs: controllerEffectUIDs,
            dropFrame: formats.first == "DF", session: session)
        } catch {
            if let guidance = await session.restoreReviewWindow() {
                throw FinalCutCaptureError.reviewRestoration(original: error.localizedDescription, guidance: guidance)
            }
            throw error
        }
    }
}

/// AU custom views are hosted in a nonmodal AXDialog. A dialog role alone does
/// not mean that a sheet is blocking the project. Only our identifiable review
/// view is exempt; unknown dialogs and every explicitly modal window still block.
