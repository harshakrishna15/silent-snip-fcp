import AppKit
import ApplicationServices
import SilentSnipCore
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

extension FinalCutAXSession {
    func exportProjectXML(to destination: URL, timing: AnalysisTiming? = nil) async throws -> URL {
        let timing = timing ?? AnalysisTiming(request: UUID())
        try assertCurrentProject()
        guard currentSheet() == nil, destination.isFileURL,
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw FinalCutCaptureError.unavailable("Close the current dialog before requesting project XML.")
        }
        let delivered = try await timing.measure("share.xml.exchange") {
            try await ShareDestinationManager.shared.captureXML(projectName: projectName) {
                try await timing.measure("share.xml.setup") { try await self.beginShare(renderAudio: false, timing: timing) }
            }
        }
        lastXMLShareDirectory = delivered.deletingLastPathComponent().standardizedFileURL
        try assertCurrentProject()
        _ = try TimelineParser.parse(url: delivered)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep the caller's capture format stable without a Save dialog.
        let input = delivered.pathExtension.lowercased() == "fcpxmld"
            ? delivered.appendingPathComponent("Info.fcpxml") : delivered
        let output: URL
        if destination.pathExtension.lowercased() == "fcpxmld" {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            output = destination.appendingPathComponent("Info.fcpxml")
        } else { output = destination }
        try Data(contentsOf: input).write(to: output, options: .withoutOverwriting)
        try await waitUntil(timeout: 5, context: "the completed XML exchange") { self.currentSheet() == nil }
        // The host's Open Document message may activate this accessory helper.
        // Return input to the pinned project before checking the same selection.
        try await activate()
        return output
    }

    func shareRenderedAudio(timing: AnalysisTiming? = nil) async throws -> ShareDestinationReceipt {
        let timing = timing ?? AnalysisTiming(request: UUID())
        try await timing.measure("share.render.clearRanges") { try await clearTimelineRanges() }
        return try await timing.measure("share.render.exchange") {
            try await ShareDestinationManager.shared.captureMedia(projectName: projectName) {
                try await timing.measure("share.render.setup") { try await self.beginShare(renderAudio: true, timing: timing) }
            }
        }
    }

    private func beginShare(renderAudio: Bool, timing: AnalysisTiming) async throws {
        let prefix = renderAudio ? "share.render" : "share.xml"
        try assertCurrentProject()
        guard currentSheet() == nil else { throw FinalCutCaptureError.unavailable("Close the current dialog before sharing.") }
        try await timing.measure(prefix + ".focus") { try await focusTimeline() }
        var ownsPanel = false
        do {
            try await timing.measure(prefix + ".openPanel") {
                try await pressMenu(path: ["File", "Share", "Silent Snip…"])
                try await waitUntil(timeout: 10, context: "Silent Snip Share confirmation") {
                    guard let panel = self.currentSheet() else { return false }
                    return self.string(panel, kAXTitleAttribute) == "Silent Snip"
                        && self.find(in: panel, role: kAXButtonRole, title: "Next…") != nil
                }
            }
            ownsPanel = true
            guard let panel = currentSheet() else { throw FinalCutCaptureError.unavailable("Share panel disappeared.") }
            if renderAudio { try await FinalCutDialogueExport.configureShare(panel, session: self, timing: timing) }
            guard let next = find(in: panel, role: kAXButtonRole, title: "Next…") else {
                throw FinalCutCaptureError.unavailable("The Share confirmation is unavailable.")
            }
            _ = try timing.measure(prefix + ".confirm") { try press(next) }
            ownsPanel = false
        } catch {
            if ownsPanel {
                await Task { @MainActor in
                    if let panel = self.currentSheet(), self.string(panel, kAXTitleAttribute) == "Silent Snip",
                       let cancel = self.find(in: panel, role: kAXButtonRole, title: "Cancel") { _ = try? self.press(cancel) }
                }.value
            }
            throw error
        }
    }

    /// Open only an exact, uniquely named generated project. XML verification
    /// after opening establishes its UID and contents; a name alone never does.
}
