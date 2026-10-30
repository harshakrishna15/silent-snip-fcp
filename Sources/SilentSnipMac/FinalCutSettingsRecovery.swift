import AppKit
import ApplicationServices
import SilentSnipCore
import Foundation

extension FinalCutAXSession {
    /// Bind the native selection to a unique occurrence, including its timeline
    /// edges and source mapping, before touching the imported controller.
    func selectTimelineClip(_ clip: TimelineClip, document: TimelineDocument,
                            restoring expected: FinalCutSelectionSnapshot? = nil, scrollToVisible: Bool = true) async throws {
        if expected == nil {
            try await activate()
            try await focusTimeline()
        } else {
            // Restoring a cleared selection is a targeted AX operation, not
            // keyboard input. A floating editor need not relinquish focus.
            requestActivation()
            try await waitUntil(timeout: 3, context: "Final Cut activation for review selection") {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == self.application.processIdentifier
            }
            try refreshTimeline()
        }
        func assertRestorableSelection() throws {
            guard let expected else { return }
            if (try? selectionSnapshot()) == expected { return }
            // Browser cleanup can clear the selection. Never replace another
            // selection, a range, or an unreadable native selection state.
            guard let items = attribute(timeline, kAXChildrenAttribute) as? [AXUIElement], items.count <= 10_000,
                  !items.contains(where: { string($0, kAXDescriptionAttribute) == "Range Selection" }),
                  items.filter({ string($0, kAXRoleAttribute) == kAXLayoutItemRole }).allSatisfy({
                      (attribute($0, kAXSelectedAttribute) as? NSNumber)?.boolValue == false
                  }) else { throw AudioControllerSettingsError.targetChanged }
        }
        try assertRestorableSelection()
        let items = children(timeline)
        guard items.count <= 10_000 else { throw FinalCutCaptureError.invalidSelection("The timeline is too large to select safely.") }
        let deadline = Date().addingTimeInterval(5)
        var matches: [AXUIElement] = []
        for item in items where string(item, kAXRoleAttribute) == kAXLayoutItemRole {
            try Task.checkCancellation()
            guard Date() < deadline else { throw FinalCutCaptureError.unavailable("Locating the imported segment took too long.") }
            let nodes = children(item).prefix(100).map {
                AccessibilityNode(role: string($0, kAXRoleAttribute), identifier: nil, title: nil,
                    description: string($0, kAXDescriptionAttribute), value: string($0, kAXValueAttribute),
                    selected: nil, enabled: nil, children: [])
            }
            let node = AccessibilityNode(role: kAXLayoutItemRole, identifier: nil, title: nil, description: nil,
                value: string(item, kAXValueAttribute), selected: true, enabled: nil, children: nodes)
            let layout = AccessibilityNode(role: kAXLayoutAreaRole, identifier: nil, title: nil,
                description: "Project Timeline", value: nil, selected: nil, enabled: nil, children: [node])
            if let snapshot = try? FinalCutSelectionSnapshot(projectName: projectName, timeline: layout),
               expected == nil || snapshot == expected,
               let (_, resolved) = try? snapshot.resolve(in: document), resolved == clip { matches.append(item) }
        }
        guard matches.count == 1 else { throw AudioControllerSettingsError.targetChanged }
        if expected == nil { try assertInputFocus() }
        else {
            try assertCurrentProject()
            guard currentSheet() == nil,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
                throw AudioControllerSettingsError.targetChanged
            }
        }
        try assertRestorableSelection()
        guard AXUIElementSetAttributeValue(timeline, kAXSelectedChildrenAttribute as CFString, matches as CFArray) == .success else {
            throw FinalCutCaptureError.unavailable("Final Cut could not select the exact imported segment for settings recovery.")
        }
        if scrollToVisible { _ = AXUIElementPerformAction(matches[0], "AXScrollToVisible" as CFString) }
        try await waitUntil(timeout: 3, context: "the imported segment selection") {
            guard let snapshot = try? self.selectionSnapshot(), let (_, selected) = try? snapshot.resolve(in: document) else { return false }
            return selected == clip
        }
    }

    func restoreControllerSettings(_ settings: AnalysisSettings, clip: TimelineClip, document: TimelineDocument) async throws {
        try await activate()
        try await suspendReviewWindow()
        try await selectTimelineClip(clip, document: document)
        let expected = try selectionSnapshot()
        if try await restoreNativeControllerSettings(settings, expected: expected) { return }
        // selectTimelineClip has verified this exact imported occurrence. A prior
        // segment's suspended review must not veto this deliberate selection.
        reviewOwnership.bindVerifiedRecovery(expected)
        if let reason = await restoreReviewWindowIfSafe() { throw FinalCutCaptureError.unavailable(reason) }
        guard let window = recoveryReviewWindow(clipName: clip.name) else { throw AudioControllerSettingsError.targetChanged }
        func assertController() throws {
            try assertCurrentProject()
            guard try selectionSnapshot() == expected,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
                  self.recoveryReviewWindow(clipName: clip.name).map({ CFEqual($0, window) }) == true,
                  self.currentSheet() == nil else { throw AudioControllerSettingsError.targetChanged }
        }
        let values = [settings.thresholdDBFS, settings.minimumSilenceDuration,
                      settings.beforeSpeechPadding, settings.afterSpeechPadding]
        for (index, value) in values.enumerated() {
            try assertController()
            guard let field = find(in: window, role: kAXTextFieldRole, identifier: "silentsnip.setting.\(index)", maxDepth: 16),
                  let text = SilentSnipSettingText.string(Float(value)) else {
                throw FinalCutCaptureError.unavailable("The imported Silent Snip setting \(index + 1) is not available.")
            }
            let result = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString)
            guard result == .success else {
                throw FinalCutCaptureError.unavailable("Could not restore the imported Silent Snip setting \(index + 1) (AX error \(result.rawValue)).")
            }
            // An AX acknowledgment can precede the remote AppKit update. Write
            // once, then yield while checking ownership and the observed value.
            let deadline = Date().addingTimeInterval(2)
            while true {
                try assertController()
                if string(field, kAXValueAttribute) == text { break }
                guard Date() < deadline else {
                    throw FinalCutCaptureError.unavailable("The imported Silent Snip setting \(index + 1) did not update in time.")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        try assertController()
        guard let commit = find(in: window, role: kAXButtonRole, identifier: "silentsnip.saveSettings", maxDepth: 16),
              (attribute(commit, kAXEnabledAttribute) as? NSNumber)?.boolValue == true,
              AXUIElementPerformAction(commit, kAXPressAction as CFString) == .success else {
            throw FinalCutCaptureError.unavailable("The imported controller could not save its settings. Install the matching Silent Snip Audio build before retrying verification.")
        }
        try await waitUntil(timeout: 3, context: "the controller settings to save") {
            guard let label = self.find(in: window, identifier: "silentsnip.status", maxDepth: 16) else { return false }
            return self.string(label, kAXValueAttribute) == "Settings saved."
        }
        try assertController()
        // Close before the next segment or Share. The final host export checks
        // actual persisted AU values; field text is never treated as proof.
        try await activate()
        try await suspendReviewWindow()
    }

    /// Host parameters remain editable while the initiating Controls view is
    /// waiting for Apply/verification. Scope every write to the one verified
    /// segment and the exact Silent Snip Inspector block. The caller verifies
    /// all persisted values in a new host export; field text is never proof.
    private func restoreNativeControllerSettings(_ settings: AnalysisSettings,
                                                expected: FinalCutSelectionSnapshot) async throws -> Bool {
        func snapshot() throws -> (elements: [AXUIElement], nodes: [AccessibilityNode]) {
            try assertCurrentProject()
            try assertInputFocus()
            guard try selectionSnapshot() == expected, currentSheet() == nil,
                  let inspector = Self.search(mainWindow, role: kAXScrollAreaRole, description: "inspector", containersOnly: true) else {
                throw AudioControllerSettingsError.targetChanged
            }
            let elements = children(inspector)
            guard elements.count <= 500 else { throw AudioControllerSettingsError.targetChanged }
            let nodes = elements.map {
                let role = string($0, kAXRoleAttribute)
                let binary = [kAXCheckBoxRole, kAXDisclosureTriangleRole].contains(role ?? "")
                let value = binary ? FinalCutNativeSettings.binaryValue(attribute($0, kAXValueAttribute)) : string($0, kAXValueAttribute)
                return AccessibilityNode(role: role, identifier: nil, title: string($0, kAXTitleAttribute),
                    description: string($0, kAXDescriptionAttribute), value: value, selected: nil,
                    enabled: (attribute($0, kAXEnabledAttribute) as? NSNumber)?.boolValue, children: [])
            }
            guard FinalCutReviewInspector.controllerRange(in: nodes) != nil else { throw AudioControllerSettingsError.targetChanged }
            return (elements, nodes)
        }
        func record(_ stage: String, nodes: [AccessibilityNode]) {
#if DEBUG
            guard let lease = QuietSharePrototype.pluginLease,
                  let directory = try? FinalCutDialogueExport.makeJobDirectory(jobID: lease.request) else { return }
            let group = FinalCutReviewInspector.controllerRange(in: nodes)
            let selected = group.map { Array(nodes[($0.lowerBound - 1)..<$0.upperBound]) } ?? nodes
            struct Trace: Encodable { let stage: String; let controls: [AccessibilityNode] }
            if let data = try? JSONEncoder().encode(Trace(stage: stage, controls: selected)) {
                try? data.write(to: directory.appendingPathComponent("Native-Settings-Recovery.json"), options: .atomic)
            }
#endif
        }
        var observed = try snapshot()
        record("initial", nodes: observed.nodes)
        if FinalCutNativeSettings.sliderIndices(in: observed.nodes) == nil {
            guard let disclosure = FinalCutNativeSettings.disclosureIndex(in: observed.nodes) else {
                record("native-disclosure-unavailable", nodes: observed.nodes); return false
            }
            guard observed.nodes[disclosure].value == "0" else {
                record("native-sliders-missing-in-expanded-block", nodes: observed.nodes); return false
            }
            try press(observed.elements[disclosure])
            let deadline = Date().addingTimeInterval(2)
            repeat {
                try await Task.sleep(for: .milliseconds(50))
                observed = try snapshot()
                if FinalCutNativeSettings.sliderIndices(in: observed.nodes) != nil { break }
            } while Date() < deadline
        }
        guard FinalCutNativeSettings.fieldIndices(in: observed.nodes) != nil else {
            record("native-numeric-fields-unavailable-after-expansion", nodes: observed.nodes); return false
        }
        let values = [settings.thresholdDBFS, settings.minimumSilenceDuration,
                      settings.beforeSpeechPadding, settings.afterSpeechPadding]
        for (parameter, value) in values.enumerated() {
            observed = try snapshot()
            guard let text = SilentSnipSettingText.string(Float(value)),
                  let indices = FinalCutNativeSettings.fieldIndices(in: observed.nodes) else { throw AudioControllerSettingsError.targetChanged }
            let field = observed.elements[indices[parameter]]
            guard AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
                throw FinalCutCaptureError.unavailable("Final Cut could not focus the native Silent Snip parameter \(parameter + 1).")
            }
            let focusDeadline = Date().addingTimeInterval(2)
            while true {
                _ = try snapshot()
                if Self.elementAttribute(root, kAXFocusedUIElementAttribute).map({ CFEqual($0, field) }) == true { break }
                guard Date() < focusDeadline else {
                    throw FinalCutCaptureError.unavailable("Final Cut did not focus the native Silent Snip parameter \(parameter + 1).")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            // Native sliders quantize -42.5 dBFS and 0.125 seconds on 12.4.
            // Its numeric editor accepts the exact Float32 decimal. Write once,
            // confirm only while this exact field owns input, then move focus
            // to commit the editor before another parameter or host export.
            let result = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString)
            guard result == .success else {
                throw FinalCutCaptureError.unavailable("Final Cut could not restore the native Silent Snip parameter \(parameter + 1) (AX error \(result.rawValue)).")
            }
            _ = try snapshot()
            guard Self.elementAttribute(root, kAXFocusedUIElementAttribute).map({ CFEqual($0, field) }) == true else {
                throw AudioControllerSettingsError.targetChanged
            }
            try key(code: 36)
            let commitDeadline = Date().addingTimeInterval(2)
            while true {
                _ = try snapshot()
                guard Self.elementAttribute(root, kAXFocusedUIElementAttribute).map({ CFEqual($0, field) }) == true else {
                    throw AudioControllerSettingsError.targetChanged
                }
                if string(field, kAXValueAttribute) == text { break }
                guard Date() < commitDeadline else {
                    throw FinalCutCaptureError.unavailable("Final Cut did not accept the exact native Silent Snip parameter \(parameter + 1).")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        try await focusTimeline()
        observed = try snapshot()
        record("native-writes-complete-awaiting-XML-verification", nodes: observed.nodes)
        return true
    }

}
