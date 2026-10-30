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
#if DEBUG
        if QuietSharePrototype.pluginLease != nil { try QuietSharePrototype.verifyLibrary(delivered) }
#endif
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

    func shareRenderedAudio(timing: AnalysisTiming? = nil,
                            renderSelection: FinalCutSelectionSnapshot? = nil) async throws -> ShareDestinationReceipt {
        let timing = timing ?? AnalysisTiming(request: UUID())
        // Hashing can yield after capture focused the timeline. A delayed AU
        // field commit or our own URL delivery may then raise Controls again.
        // Restore only this pinned project, before any range command is sent.
        if (try? assertInputFocus()) == nil {
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard foreground == application.processIdentifier || foreground == NSRunningApplication.current.processIdentifier else {
                throw FinalCutCaptureError.unavailable("The audio export lost focus to another application. Return to Final Cut and Analyze again.")
            }
            try assertCurrentProject()
            if let expected = reviewOwnership.active, try selectionSnapshot() != expected {
                throw AudioControllerSettingsError.targetChanged
            }
            try await timing.measure("share.render.restoreProjectFocus") { try await activate() }
        }
        var receipt: ShareDestinationReceipt?
        var preparedRange = false
        do {
            if let renderSelection {
                try await timing.measure("share.render.selectClipRange") { try await prepareRenderedClipRange(selection: renderSelection) }
                preparedRange = true
            } else {
                try await timing.measure("share.render.clearRanges") { try await clearTimelineRanges() }
            }
            let delivered = try await timing.measure("share.render.exchange") {
                try await ShareDestinationManager.shared.captureMedia(projectName: projectName) {
                    try await timing.measure("share.render.setup") {
                        try await self.beginShare(renderAudio: true, timing: timing, renderSelection: renderSelection)
                    }
                }
            }
            receipt = delivered
#if DEBUG
            if QuietSharePrototype.pluginLease != nil { try QuietSharePrototype.verifyLibrary(delivered.xmlURL) }
#endif
            // The real Open Document delivery can activate the accessory helper.
            // Direct rendering stays in this project, so there is no return-project
            // navigation to restore focus on its behalf.
            try await activate()
            if let renderSelection {
                preparedRange = false // Never retry an uncertain Clear command.
                try await timing.measure("share.render.restoreClipSelection") { try await clearRenderedClipRange(selection: renderSelection) }
            }
            return delivered
        } catch {
            if preparedRange, let renderSelection {
                await Task { @MainActor in
                    guard self.currentSheet() == nil else { return }
                    try? await self.clearRenderedClipRange(selection: renderSelection)
                }.value
            }
            // A post-delivery focus/range failure must not orphan its WAV just
            // because the receipt never reached the caller's cleanup scope.
            if let receipt { try? ShareDestinationManager.shared.cleanupRenderedMedia(receipt: receipt) }
            throw error
        }
    }

    private func beginShare(renderAudio: Bool, timing: AnalysisTiming,
                            renderSelection: FinalCutSelectionSnapshot? = nil) async throws {
#if DEBUG
        let previousPrototypeMenu = quietPrototypeMenu
        if renderAudio, let lease = QuietSharePrototype.pluginLease {
            // The 12.4 Return probe delivered WAV/XML without exposing the
            // settings panel. That cannot prove the required Dialogue mix.
            // Choose visible legacy input before a NEW render dispatch; never
            // retry the already delivered probe or accept its unverified audio.
            lease.reveal(reason: "Processed-audio Share requires visible settings verification.")
            quietPrototypeInvocation?("Processed-audio Share: visible legacy path selected before dispatch")
            quietPrototypeMenu = false
        }
        defer { quietPrototypeMenu = previousPrototypeMenu }
#endif
        let prefix = renderAudio ? "share.render" : "share.xml"
        try assertCurrentProject()
        guard currentSheet() == nil else { throw FinalCutCaptureError.unavailable("Close the current dialog before sharing.") }
        try await timing.measure(prefix + ".focus") { try await focusTimeline() }
        var ownsPanel = false
        do {
            try await timing.measure(prefix + ".openPanel") {
                try await pressMenu(path: ["File", "Share", "Silent Snip…"])
                try await waitUntil(timeout: 10, context: "Silent Snip Share confirmation") {
#if DEBUG
                    if self.quietPrototypeStage != nil,
                       ShareDestinationManager.shared.prototypeShareHasResponse(projectName: self.projectName) { return true }
#endif
                    guard let panel = self.currentSheet() else { return false }
                    return self.string(panel, kAXTitleAttribute) == "Silent Snip"
                        && self.find(in: panel, role: kAXButtonRole, title: "Next…") != nil
                }
            }
#if DEBUG
            if quietPrototypeStage != nil, ShareDestinationManager.shared.prototypeShareHasResponse(projectName: projectName) {
                // Some hosts complete XML without showing a confirmation. A
                // rendered response cannot stand in for verified live settings.
                guard !renderAudio else { throw FinalCutDialogueExport.ExportError.unverifiedDialogueOutput }
                quietPrototypeStage?("xmlDeliveredWithoutPanel")
                return
            }
#endif
            ownsPanel = true
            guard let panel = currentSheet() else { throw FinalCutCaptureError.unavailable("Share panel disappeared.") }
            try await restoreOwnShareActivation(panel: panel)
            if renderAudio { try await FinalCutDialogueExport.configureShare(panel, session: self, timing: timing) }
            if let renderSelection,
               try renderedClipRange() != FinalCutRenderedClipRange(selection: renderSelection) {
                throw FinalCutCaptureError.invalidSelection("The selected clip export range changed before rendering.")
            }
#if DEBUG
            quietPrototypeStage?("beforeConfirmation")
            try Task.checkCancellation()
#endif
            guard let next = find(in: panel, role: kAXButtonRole, title: "Next…") else {
                throw FinalCutCaptureError.unavailable("The Share confirmation is unavailable.")
            }
            try await restoreOwnShareActivation(panel: panel)
            _ = try timing.measure(prefix + ".confirm") { try press(next) }
            ownsPanel = false
#if DEBUG
            quietPrototypeStage?("delivery")
#endif
        } catch {
            if ownsPanel {
                await Task { @MainActor in
                    if let panel = self.currentSheet(), self.string(panel, kAXTitleAttribute) == "Silent Snip",
                       let cancel = self.find(in: panel, role: kAXButtonRole, title: "Cancel") {
                        try? await self.restoreOwnShareActivation(panel: panel)
                        _ = try? self.press(cancel)
                    }
                }.value
            }
            throw error
        }
    }

    /// A late XML Open Document can activate our own helper during the next
    /// Share panel. Return only that activation, without raising the project
    /// over its sheet or reclaiming focus from another application.
    func restoreOwnShareActivation(panel: AXUIElement) async throws {
        try assertCurrentProject()
        guard let current = currentSheet(), CFEqual(current, panel),
              string(panel, kAXTitleAttribute) == "Silent Snip" else {
            throw FinalCutCaptureError.unavailable("The owned Silent Snip Share panel changed.")
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == NSRunningApplication.current.processIdentifier {
            requestActivation()
            try await waitUntil(timeout: 2, context: "returning our Share activation to Final Cut") {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == self.application.processIdentifier
            }
        }
        // Final Cut may keep AXFocusedWindow on its remote AU editor even
        // though its Share sheet is already visible. Raise only the exact
        // request-owned sheet, and only while Final Cut itself is foreground.
        if (try? assertInputFocus()) == nil,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
            _ = AXUIElementPerformAction(panel, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(panel, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            try await waitUntil(timeout: 2, context: "focus on the owned Silent Snip Share panel") {
                guard let current = self.currentSheet(), CFEqual(current, panel) else { return false }
                return (try? self.assertInputFocus()) != nil
            }
        }
        do { try assertInputFocus() }
        catch {
            let owner = NSWorkspace.shared.frontmostApplication?.localizedName ?? "an unavailable application"
            throw FinalCutCaptureError.unavailable("The Silent Snip Share panel lost input focus to \(owner). Bring Final Cut’s Share panel forward and Analyze again.")
        }
    }

    /// Open only an exact, uniquely named generated project. XML verification
    /// after opening establishes its UID and contents; a name alone never does.
}
