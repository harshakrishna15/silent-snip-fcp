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
    let analysisRange: TimeRange?
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
                               routingHintStore: DirectAudioRenderHintStore? = nil,
                               workflowOrigin: WorkflowReviewOrigin? = nil,
                               onSession: (FinalCutAXSession) -> Void = { _ in },
                               progress: (String) -> Void = { _ in }) async throws -> CapturedFinalCutProject {
        let timing = timing ?? AnalysisTiming(request: UUID())
        let session = try timing.measure("capture.sessionDiscovery") { try FinalCutAXSession(workflowOrigin: workflowOrigin) }
        defer { timing.recordCounters(session.projectLookupCounters) }
        do {
        try await timing.measure("capture.activation") { try await session.activate() }
        progress("Preparing Final Cut Pro for export…")
        // Capture the exact selection before suspending the effect window.
        // Opening an AU view can leave the Inspector focused, making Final
        // Cut omit the timeline's active selection until the timeline regains
        // focus. Direct AX focus preserves the existing clip/range selection;
        // the menu command is only a compatibility fallback.
        let includingRange = workflowOrigin != nil
        let beforeFocus = try timing.measure("capture.selectionBeforeFocus") {
            try session.readTimelineSelection(includingRange: includingRange)
        }
        let selectionBeforeFocus = try? beforeFocus.clip.get()
        progress("Focusing the project timeline…")
        try await timing.measure("capture.focusBeforeExport") { try await session.focusTimeline() }
        progress("Reading the selected timeline clip…")
        let initial = try timing.measure("capture.selection") { try session.readTimelineSelection(includingRange: includingRange) }
        let selected = try initial.clip.get()
        let selectedRange = initial.range
        guard selectedRange == beforeFocus.range else {
            throw FinalCutCaptureError.invalidSelection("The selected timeline range changed while restoring timeline focus.")
        }
        try session.rememberReviewSelection(selected)
        onSession(session)
        if let selectionBeforeFocus, selectionBeforeFocus != selected {
            throw FinalCutCaptureError.invalidSelection("The selected timeline clip changed while restoring timeline focus.")
        }
        // The Inspector can expose an obvious duplicate before Share displaces
        // the AU window. XML validation remains authoritative if it is hidden.
        if workflowOrigin == nil, controllerEffectUIDs.contains(AudioControllerSettings.effectUID),
           timing.measure("capture.inspector", operation: { session.hasMultipleSilentSnipEffectsInInspector() }) {
            throw AudioControllerSettingsError.ambiguousController
        }
        // A remote AU field commit can raise Controls after activation and
        // interrupt the Share menu. Suspend only the verified original editor;
        // the existing review restoration reopens it after the exchange.
        try await timing.measure("capture.suspendControls") { try await session.suspendReviewWindow() }
        try await session.activate()
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
        // Only the freshly authorized AX selection may consume a hint. Other
        // projects and clips keep their routes for a later manual Analyze.
        let directRenderHint = await timing.measure("capture.routingHintLookup") {
            guard selectedRange == nil else { return nil as DirectAudioRenderHint? }
            return await routingHintStore?.consume(matching: selected, workflowOrigin: workflowOrigin)
        }
        try Task.checkCancellation()
        try session.assertCurrentProject()
        guard try session.selectionSnapshot() == selected else {
            throw FinalCutCaptureError.invalidSelection("The selected timeline clip changed while checking the analysis route.")
        }
        let hintedRead: MediaContentSnapshot.ReadGuard?
        if let hint = directRenderHint {
            // Pin source identities BEFORE any render. Full hashes overlap the
            // same host exchange and must join before its PCM/XML is accepted.
            hintedRead = try timing.measure("capture.sourceValidationBeforeRender") {
                try hint.prepareSourceRead(matching: selected, workflowOrigin: workflowOrigin)
            }
        } else { hintedRead = nil }
        if let hint = directRenderHint, let hintedRead {
            timing.incrementCounter("capture.routingHint.combined")
            progress("Rendering fresh audio and project XML together…")
            let combined = try await timing.measure("capture.combinedExchange") {
                try await DirectAudioRenderCapture.perform(prepared: hintedRead, render: {
                    try await session.shareRenderedAudio(timing: timing, renderSelection: hint.scope == .selectedRange ? selected : nil,
                        sharePurpose: .analyze)
                }, cleanup: { receipt in
                    try? ShareDestinationManager.shared.cleanupRenderedMedia(receipt: receipt)
                })
            }
            let receipt = combined.receipt
            rendered = receipt
            media = combined.media
            timing.recordCounters(["capture.sourceHashOverlapsRender": 1])
            try ShareDestinationManager.shared.validateReceipt(receipt)
            guard receipt.mediaURLs.count == 1 else { throw ProjectAnalysisError.invalidRenderArtifact }
            let source = receipt.xmlURL.pathExtension.lowercased() == "fcpxmld"
                ? receipt.xmlURL.appendingPathComponent("Info.fcpxml") : receipt.xmlURL
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            xml = destination.appendingPathComponent("Info.fcpxml")
            try Data(contentsOf: source).write(to: xml, options: .withoutOverwriting)
        } else {
            timing.incrementCounter(directRenderHint == nil ? "capture.routingHint.miss" : "capture.routingHint.sourceUnavailable")
            xml = try await timing.measure("capture.xmlExchange") { try await session.exportProjectXML(to: destination, timing: timing, sharePurpose: .analyze) }
        }
        // The exporter has confirmed this unique output is complete. Until the
        // caller receives it, capture owns cleanup if validation subsequently fails.
        var delivered = false
        defer { if !delivered { try? FileManager.default.removeItem(at: destination) } }
        let data = try Data(contentsOf: xml)
        try workflowOrigin?.verify(projectData: data)
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
        let final = try timing.measure("capture.selectionAfterExport") { try session.readTimelineSelection(includingRange: includingRange) }
        guard try final.clip.get() == selected else {
            throw FinalCutCaptureError.invalidSelection("The selected timeline clip changed during export.")
        }
        let (selection, target) = try selected.resolve(in: document)
        if final.range != selectedRange {
            throw FinalCutCaptureError.invalidSelection("The selected timeline range changed during export.")
        }
        let scope = try selectedRange?.resolve(in: document, clip: target)
        if let receipt = rendered, let hint = directRenderHint, let sourceMedia = media,
           !(try hint.accepts(projectData: data, selection: selection, media: sourceMedia, workflowOrigin: workflowOrigin)) {
            // The hint was stale. These fresh XML bytes still provide the normal
            // capture, but this full-project audio cannot represent the target.
            try ShareDestinationManager.shared.cleanupRenderedMedia(receipt: receipt)
            rendered = nil; media = nil
            timing.incrementCounter("capture.routingHint.stale")
        }
        delivered = true
        transferred = true
        return CapturedFinalCutProject(xmlURL: xml, document: document, selection: selection,
            target: target, projectName: document.projectName, controllerEffectUIDs: controllerEffectUIDs,
            dropFrame: formats.first == "DF", analysisRange: scope == target.timelineRange ? nil : scope,
            session: session, renderedAudio: rendered, renderedMedia: media)
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
