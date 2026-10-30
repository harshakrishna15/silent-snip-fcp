import AppKit
import ApplicationServices
import SilentSnipCore
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
    var renderedAudio: ShareDestinationReceipt? = nil
    var renderedMedia: MediaContentSnapshot? = nil

    /// Restore the custom Audio Unit view if a host operation displaced it.
    /// A non-nil result explains how to reconnect manually when safe automatic
    /// restoration could not be established; it never replaces an analysis error.
    public func restoreReviewWindow() async -> String? {
#if DEBUG
        QuietSharePrototype.pluginLease?.reveal(reason: "Restoring Final Cut Controls.")
#endif
        return await session.restoreReviewWindow()
    }

    /// Successful analysis may restore the exact original occurrence after its
    /// own browser cleanup, then activate and raise the host's Controls window.
    func presentReviewWindow() async -> String? {
#if DEBUG
        QuietSharePrototype.pluginLease?.reveal(reason: "Review is ready.")
#endif
        return await session.restoreReviewWindowIfSafe(bringToFront: true, document: document, target: target)
    }
}

@MainActor public enum FinalCutProjectCapture {
    static func capture(to directory: URL, controllerEffectUIDs: Set<String> = [],
                               timing: AnalysisTiming? = nil,
                               directRenderHint: DirectAudioRenderHint? = nil,
                               onSession: (FinalCutAXSession) -> Void = { _ in },
                               progress: (String) -> Void = { _ in }) async throws -> CapturedFinalCutProject {
        let timing = timing ?? AnalysisTiming(request: UUID())
        let session = try timing.measure("capture.sessionDiscovery") { try FinalCutAXSession() }
        defer { timing.recordCounters(session.projectLookupCounters) }
        do {
        try await timing.measure("capture.activation") { try await session.activate() }
        progress("Preparing Final Cut for export…")
        // Keep the effect window open; only move input focus to the project.
        // Opening an AU view can leave the Inspector focused, making Final
        // Cut omit the timeline's active selection until the timeline regains
        // focus. Direct AX focus preserves the existing clip/range selection;
        // the menu command is only a compatibility fallback.
        let selectionBeforeFocus = try? timing.measure("capture.selectionBeforeFocus") { try session.selectionSnapshot() }
        progress("Focusing the project timeline…")
        try await timing.measure("capture.focusBeforeExport") { try await session.focusTimeline() }
        progress("Reading the selected timeline clip…")
        let selected = try timing.measure("capture.selection") { try session.selectionSnapshot() }
        try session.rememberReviewSelection(selected)
        onSession(session)
        if let selectionBeforeFocus, selectionBeforeFocus != selected {
            throw FinalCutCaptureError.invalidSelection("The selected timeline clip changed while restoring timeline focus.")
        }
        // The Inspector can expose an obvious duplicate before Share displaces
        // the AU window. XML validation remains authoritative if it is hidden.
        if controllerEffectUIDs.contains(AudioControllerSettings.effectUID),
           timing.measure("capture.inspector", operation: { session.hasMultipleSilentSnipEffectsInInspector() }) {
            throw AudioControllerSettingsError.ambiguousController
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        progress("Exporting the active project XML…")
        let destination = directory.appendingPathComponent("Project-\(UUID()).fcpxmld")
        var rendered: ShareDestinationReceipt?
        var media: MediaContentSnapshot?
        var transferred = false
        defer {
            if !transferred, let rendered { try? ShareDestinationManager.shared.cleanupRenderedMedia(receipt: rendered) }
        }
        let xml: URL
        if let hint = directRenderHint, hint.matches(selected) {
            // Hash the hinted sources BEFORE rendering. Fresh delivered XML must
            // reference this exact set; changed scope falls back to isolation.
            media = try await timing.measure("capture.sourceValidationBeforeRender") {
                try await MediaContentSnapshot.capture(hint.sourceURLs)
            }
            progress("Rendering fresh audio and project XML together…")
            let receipt = try await timing.measure("capture.combinedExchange") {
                try await session.shareRenderedAudio(timing: timing, renderSelection: hint.scope == .selectedRange ? selected : nil)
            }
            rendered = receipt
            try ShareDestinationManager.shared.validateReceipt(receipt)
            guard receipt.mediaURLs.count == 1 else { throw ProjectAnalysisError.invalidRenderArtifact }
            let source = receipt.xmlURL.pathExtension.lowercased() == "fcpxmld"
                ? receipt.xmlURL.appendingPathComponent("Info.fcpxml") : receipt.xmlURL
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            xml = destination.appendingPathComponent("Info.fcpxml")
            try Data(contentsOf: source).write(to: xml, options: .withoutOverwriting)
        } else {
            xml = try await timing.measure("capture.xmlExchange") { try await session.exportProjectXML(to: destination, timing: timing) }
        }
        // The exporter has confirmed this unique output is complete. Until the
        // caller receives it, capture owns cleanup if validation subsequently fails.
        var delivered = false
        defer { if !delivered { try? FileManager.default.removeItem(at: destination) } }
        let data = try Data(contentsOf: xml)
        let document = try timing.measure("capture.parse") {
            try TimelineParser.parse(data: data, exclusions: .init(controllerEffectUIDs: controllerEffectUIDs))
        }
        let structure = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        let formats = try structure.nodes(forXPath: "//project/sequence/@tcFormat").compactMap(\.stringValue)
        guard formats.count <= 1, formats.allSatisfy({ $0 == "NDF" || $0 == "DF" }) else {
            throw FinalCutCaptureError.unsupportedTimecode("unknown project timecode format")
        }
        try timing.measure("capture.finalProjectCheck") { try session.assertCurrentProject() }
        try await timing.measure("capture.focusAfterExport") { try await session.focusTimeline() }
        guard try timing.measure("capture.selectionAfterExport", operation: { try session.selectionSnapshot() }) == selected else {
            throw FinalCutCaptureError.invalidSelection("The selected timeline clip changed during export.")
        }
        let (selection, target) = try selected.resolve(in: document)
        if let receipt = rendered, let hint = directRenderHint, let sourceMedia = media,
           !(try hint.accepts(projectData: data, selection: selection, media: sourceMedia)) {
            // The hint was stale. These fresh XML bytes still provide the normal
            // capture, but this full-project audio cannot represent the target.
            try ShareDestinationManager.shared.cleanupRenderedMedia(receipt: receipt)
            rendered = nil; media = nil
        }
        delivered = true
        transferred = true
        return CapturedFinalCutProject(xmlURL: xml, document: document, selection: selection,
            target: target, projectName: document.projectName, controllerEffectUIDs: controllerEffectUIDs,
            dropFrame: formats.first == "DF", session: session, renderedAudio: rendered, renderedMedia: media)
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
