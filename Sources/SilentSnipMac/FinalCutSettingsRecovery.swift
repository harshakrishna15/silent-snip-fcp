import AppKit
import ApplicationServices
import SilentSnipCore
import Foundation

extension FinalCutAXSession {
    /// Bind the native selection to a unique occurrence, including its timeline
    /// edges and source mapping, before touching the imported controller.
    func selectTimelineClip(_ clip: TimelineClip, document: TimelineDocument,
                            restoring expected: FinalCutSelectionSnapshot? = nil) async throws {
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
        _ = AXUIElementPerformAction(matches[0], "AXScrollToVisible" as CFString)
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
        let formatter = SilentSnipSettingText.formatter()
        for (index, value) in values.enumerated() {
            try assertController()
            guard let field = find(in: window, role: kAXTextFieldRole, identifier: "silentsnip.setting.\(index)", maxDepth: 16),
                  let text = formatter.string(from: NSNumber(value: Float(value))),
                  AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString) == .success,
                  string(field, kAXValueAttribute) == text else {
                throw FinalCutCaptureError.unavailable("Could not restore the imported Silent Snip settings.")
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

}
