import AppKit
import ApplicationServices
import CutdownCore
import Foundation

extension FinalCutAXSession {
    /// Read the retained menu tree without opening it. Missing or incomplete
    /// shortcut metadata falls back before sending any input, never after it.
    private func rangeCommand(_ command: FinalCutRangeCommand) async throws {
        try await focusTimeline()
        guard currentSheet() == nil else {
            throw FinalCutCaptureError.unavailable("Close the open Final Cut dialog before selecting a range.")
        }
        let shortcut: FinalCutMenuShortcut? = {
            guard let bar = Self.elementAttribute(root, kAXMenuBarAttribute) else { return nil }
            let owners = children(bar).filter { string($0, kAXTitleAttribute) == "Mark" }
            guard owners.count == 1 else { return nil }
            let menus = children(owners[0]).filter { string($0, kAXRoleAttribute) == kAXMenuRole }
            guard menus.count == 1 else { return nil }
            let items = children(menus[0]).filter {
                string($0, kAXRoleAttribute) == kAXMenuItemRole && string($0, kAXTitleAttribute) == command.rawValue
            }
            guard items.count == 1 else { return nil }
            let item = items[0]
            return FinalCutMenuShortcut(
                virtualKey: (attribute(item, kAXMenuItemCmdVirtualKeyAttribute) as? NSNumber)?.intValue,
                modifiers: (attribute(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue,
                character: attribute(item, kAXMenuItemCmdCharAttribute) as? String,
                glyph: (attribute(item, kAXMenuItemCmdGlyphAttribute) as? NSNumber)?.intValue,
                enabled: (attribute(item, kAXEnabledAttribute) as? NSNumber)?.boolValue)
        }()
        if let shortcut {
            // The command is non-destructive. Callers verify its result; a
            // timeout must stop preparation rather than issue it a second time.
            guard hasTimelineFocus() else {
                throw FinalCutCaptureError.invalidSelection("The timeline lost keyboard focus before selecting a range.")
            }
            try key(code: shortcut.keyCode, flags: shortcut.flags)
        } else {
            try await pressMenu(path: ["Mark", command.rawValue], allowDisabled: command == .clear)
        }
    }

    func clearTimelineRanges() async throws {
        try await focusTimeline()
        try await FinalCutRangePreparation.clearIfNeeded(hasRanges: hasTimelineRanges, clear: {
            try await self.rangeCommand(.clear)
        }, verifyCleared: {
            try await self.waitUntil(timeout: 3, context: "cleared timeline ranges") {
                (try? self.hasTimelineRanges()) == false
            }
        })
    }

    private func hasTimelineRanges() throws -> Bool {
        try assertInputFocus()
        // Unlike children(), a failed AX read must not become an empty list:
        // that could silently export only a selected range of the clip.
        guard string(timeline, kAXRoleAttribute) == kAXLayoutAreaRole,
              string(timeline, kAXDescriptionAttribute) == "Project Timeline",
              let items = attribute(timeline, kAXChildrenAttribute) as? [AXUIElement],
              items.count <= 10_000 else {
            throw FinalCutCaptureError.unavailable("The timeline range selection could not be read before sharing.")
        }
        return items.contains { string($0, kAXDescriptionAttribute) == "Range Selection" }
    }

    private func hasTimelineFocus() -> Bool {
        if (attribute(timeline, kAXFocusedAttribute) as? NSNumber)?.boolValue == true { return true }
        var element = Self.elementAttribute(root, kAXFocusedUIElementAttribute)
        for _ in 0..<12 {
            guard let current = element else { break }
            if CFEqual(current, timeline) { return true }
            element = Self.elementAttribute(current, kAXParentAttribute)
        }
        return false
    }

    func focusTimeline() async throws {
        try assertInputFocus()
        if hasTimelineFocus() { return }
        if AXUIElementSetAttributeValue(timeline, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
            try await waitUntil(timeout: 2, context: "direct timeline focus") { hasTimelineFocus() }
            return
        }
        try await pressMenu(path: ["Window", "Go To", "Timeline"])
        // Verify the fallback too; elapsed time alone does not establish focus.
        try await waitUntil(timeout: 2, context: "timeline focus") { hasTimelineFocus() }
    }

    /// Move only the playhead, using Apple's timecode-entry command. No timeline
    /// range, blade, trim or delete input is involved.
    func movePlayhead(to time: RationalTime, document: TimelineDocument, dropFrame: Bool) async throws {
        guard document.projectName == projectName, time >= .zero, time < document.projectRange.end else {
            throw FinalCutCaptureError.changedProject
        }
        let timecode = try FinalCutTimecode.format(time.adding(document.projectTimecodeStart),
            frameDuration: document.frameDuration, dropFrame: dropFrame)
        try await activate()
        try await focusTimeline()
        let priorFocus = Self.elementAttribute(root, kAXFocusedUIElementAttribute)
        var input: AXUIElement?
        var opened = false
        func focusedTimecodeInput() -> AXUIElement? {
            guard let focused = Self.elementAttribute(root, kAXFocusedUIElementAttribute),
                  string(focused, kAXRoleAttribute) == kAXTextFieldRole else { return nil }
            let labels = [string(focused, kAXDescriptionAttribute), string(focused, kAXIdentifierAttribute),
                          string(focused, kAXTitleAttribute)].compactMap { $0 }.joined(separator: " ").lowercased()
            return labels.contains("timecode") ? focused : nil
        }
        try await FinalCutOwnedInput.perform(operation: {
            // https://support.apple.com/guide/final-cut-pro/ver1632d762/mac
            try key(code: 35, flags: .maskControl)
            opened = true
            try await waitUntil(timeout: 3, context: "the playhead timecode field") {
                guard let focused = focusedTimecodeInput() else { return false }
                input = focused
                return true
            }
            guard let input else { throw FinalCutCaptureError.unavailable("The playhead timecode field is unavailable.") }
            try assertInputFocus()
            guard currentSheet() == nil,
                  let focused = Self.elementAttribute(root, kAXFocusedUIElementAttribute), CFEqual(focused, input) else {
                throw FinalCutCaptureError.unavailable("The playhead timecode field lost focus.")
            }
            guard AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, timecode.filter(\.isNumber) as CFString) == .success else {
                throw FinalCutCaptureError.unavailable("Final Cut did not accept the playhead timecode.")
            }
            guard currentSheet() == nil,
                  let stillFocused = Self.elementAttribute(root, kAXFocusedUIElementAttribute), CFEqual(stillFocused, input) else {
                throw FinalCutCaptureError.unavailable("The playhead timecode field lost focus before confirmation.")
            }
            try key(code: 36)
            try await waitUntil(timeout: 3, context: "the requested playhead time") {
                guard let display = Self.search(self.mainWindow, description: "Timecode", containersOnly: true),
                      let focused = Self.elementAttribute(self.root, kAXFocusedUIElementAttribute), !CFEqual(focused, input),
                      let value = self.string(display, kAXValueAttribute),
                      let actual = try? FinalCutTimecode.time(value, frameDuration: document.frameDuration) else { return false }
                return actual == (try? time.adding(document.projectTimecodeStart))
            }
        }, cleanup: {
            guard opened else { return }
            // A posted key event may not have opened the editor yet when the
            // task is cancelled. Wait briefly while focus stays on the original
            // control; never wait through a move to an unrelated field/window.
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                guard (try? self.assertInputFocus()) != nil, self.currentSheet() == nil,
                      let current = Self.elementAttribute(self.root, kAXFocusedUIElementAttribute) else { return }
                if let focused = focusedTimecodeInput() {
                    if let input {
                        guard CFEqual(focused, input) else { return }
                    } else {
                        guard priorFocus.map({ !CFEqual($0, focused) }) == true else { return }
                    }
                    try self.key(code: 53)
                    try await self.waitUntil(timeout: 2, context: "the timecode editor to close") {
                        guard let next = Self.elementAttribute(self.root, kAXFocusedUIElementAttribute) else { return false }
                        return !CFEqual(next, focused)
                    }
                    return
                }
                guard input == nil, priorFocus.map({ CFEqual($0, current) }) == true else { return }
                try await Task.sleep(for: .milliseconds(150))
            }
        })
    }

}
