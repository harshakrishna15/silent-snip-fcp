import AppKit
import ApplicationServices
import SilentSnipCore
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
            guard try hasTimelineFocus() else {
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

    func selectClipRangeCommand() async throws { try await rangeCommand(.clip) }

    private func hasTimelineRanges() throws -> Bool {
        try assertInputFocus()
        try refreshTimeline()
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

    private func hasTimelineFocus() throws -> Bool {
        try refreshTimeline()
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
        if try hasTimelineFocus() { return }
        if AXUIElementSetAttributeValue(timeline, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
            try await waitUntil(timeout: 2, context: "direct timeline focus") { (try? hasTimelineFocus()) == true }
            return
        }
        try await pressMenu(path: ["Window", "Go To", "Timeline"])
        // Verify the fallback too; elapsed time alone does not establish focus.
        try await waitUntil(timeout: 2, context: "timeline focus") { (try? hasTimelineFocus()) == true }
    }

    /// Final Cut's numeric timecode editor is not an AXTextField on current
    /// hosts. Clear the exact clip selection first so duration entry cannot
    /// trim it, then require the native numeric controls and pending LCD value
    /// before confirming. The timeline Playhead, not the LCD, proves success.
    func movePlayhead(to time: RationalTime, document: TimelineDocument, dropFrame: Bool) async throws {
        guard document.projectName == projectName, time >= .zero, time < document.projectRange.end else {
            throw FinalCutCaptureError.changedProject
        }
        let absolute = try time.adding(document.projectTimecodeStart)
        let timecode = try FinalCutTimecode.format(absolute,
            frameDuration: document.frameDuration, dropFrame: dropFrame)
        let expected = try selectionSnapshot()
        let (_, target) = try expected.resolve(in: document)
        try await suspendReviewWindow()
        try await activate()
        try await focusTimeline()
        guard let lcd = Self.search(mainWindow, role: kAXStaticTextRole,
                description: "Timecode LCD", containersOnly: true),
              let controls = Self.elementAttribute(lcd, kAXParentAttribute) else {
            throw FinalCutCaptureError.unavailable("The native playhead timecode display is unavailable.")
        }
        func hasLabel(_ element: AXUIElement, _ label: String) -> Bool {
            string(element, kAXDescriptionAttribute) == label || string(element, kAXTitleAttribute) == label
        }
        func numericEntryOpen() -> Bool {
            let items = children(controls)
            guard items.count <= 100, items.contains(where: { CFEqual($0, lcd) }) else { return false }
            return items.filter { string($0, kAXRoleAttribute) == kAXButtonRole && hasLabel($0, "Numeric Entry Type") }.count == 1
                && items.filter { string($0, kAXRoleAttribute) == kAXImageRole && hasLabel($0, "Numeric Entry Direction") }.count == 1
        }
        func emptySelection() -> Bool {
            guard (try? refreshTimeline()) != nil,
                  let items = attribute(timeline, kAXChildrenAttribute) as? [AXUIElement], items.count <= 10_000,
                  !items.contains(where: { string($0, kAXDescriptionAttribute) == "Range Selection" }) else { return false }
            return items.filter { string($0, kAXRoleAttribute) == kAXLayoutItemRole }.allSatisfy {
                (attribute($0, kAXSelectedAttribute) as? NSNumber)?.boolValue == false
            }
        }
        func assertOwnedEntry() throws {
            try assertInputFocus()
            guard currentSheet() == nil, try hasTimelineFocus(), emptySelection(), numericEntryOpen() else {
                throw FinalCutCaptureError.unavailable("Final Cut's playhead entry lost ownership. No timecode was confirmed.")
            }
        }
        guard !numericEntryOpen(), try selectionSnapshot() == expected else {
            throw FinalCutCaptureError.invalidSelection("Finish the current timecode entry before navigating to a cut.")
        }
        var clearedSelection = false
        var opened = false
        var observedEntry = false
        try await FinalCutOwnedInput.perform(operation: {
            try assertInputFocus()
            guard try selectionSnapshot() == expected else { throw AudioControllerSettingsError.targetChanged }
            // Some hosts acknowledge AXSelectedChildren=[] without clearing a
            // clip. Use the native non-editing command, then verify every item.
            clearedSelection = true
            try await pressMenu(path: ["Edit", "Deselect All"])
            try await waitUntil(timeout: 2, context: "an empty timeline selection for playhead entry") { emptySelection() }
            guard try hasTimelineFocus(), currentSheet() == nil else {
                throw FinalCutCaptureError.unavailable("The timeline lost focus before playhead entry.")
            }
            // Apple's documented absolute timecode command. No selected clip or
            // range exists, so the numeric editor cannot change clip duration.
            // https://support.apple.com/guide/final-cut-pro/ver1632d762/mac
            try key(code: 35, flags: .maskControl)
            opened = true
            try await waitUntil(timeout: 2, context: "native playhead numeric entry") { numericEntryOpen() }
            observedEntry = true
            // Keypad digits are independent of the user's alphabetic layout.
            let codes: [Character: CGKeyCode] = ["0": 82, "1": 83, "2": 84, "3": 85, "4": 86,
                "5": 87, "6": 88, "7": 89, "8": 91, "9": 92]
            for digit in timecode.filter(\.isNumber) {
                try assertOwnedEntry()
                guard let code = codes[digit] else { throw FinalCutCaptureError.unsupportedTimecode(timecode) }
                try key(code: code, flags: .maskNumericPad)
            }
            try await waitUntil(timeout: 2, context: "the pending playhead timecode") {
                numericEntryOpen() && string(lcd, kAXValueAttribute) == timecode
            }
            try assertOwnedEntry()
            guard string(lcd, kAXValueAttribute) == timecode else {
                throw FinalCutCaptureError.unavailable("Final Cut's pending timecode did not match the selected cut. No timecode was confirmed.")
            }
            try key(code: 36)
            try await waitUntil(timeout: 2, context: "the requested timeline playhead time") {
                guard !numericEntryOpen(), emptySelection() else { return false }
                let playheads = children(timeline).filter {
                    string($0, kAXRoleAttribute) == kAXValueIndicatorRole && string($0, kAXDescriptionAttribute) == "Playhead"
                }
                guard playheads.count == 1, let value = string(playheads[0], kAXValueAttribute),
                      let actual = try? FinalCutTimecode.time(value, frameDuration: document.frameDuration) else { return false }
                return actual == absolute
            }
            try await selectTimelineClip(target, document: document, restoring: expected, scrollToVisible: false)
        }, cleanup: {
            // Only dismiss our own numeric editor while the original project,
            // timeline focus and empty selection remain provable. Never send
            // Escape/Return to a field, dialog, or new user selection.
            if opened, !observedEntry {
                // A cancelled task can outrun the posted Control-P. Allow its
                // editor to arrive only while the exact original input context
                // remains ours; cleanup runs in an independent cancellation scope.
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline {
                    guard (try? self.assertInputFocus()) != nil, self.currentSheet() == nil,
                          (try? self.hasTimelineFocus()) == true, emptySelection() else { return }
                    if numericEntryOpen() { break }
                    try await Task.sleep(for: .milliseconds(150))
                }
            }
            if opened, (try? self.assertInputFocus()) != nil, self.currentSheet() == nil,
               (try? self.hasTimelineFocus()) == true, emptySelection(), numericEntryOpen() {
                try self.key(code: 53)
                try await self.waitUntil(timeout: 2, context: "playhead numeric entry to close") { !numericEntryOpen() }
            }
            if clearedSelection, !numericEntryOpen(), emptySelection() {
                try await self.selectTimelineClip(target, document: document, restoring: expected, scrollToVisible: false)
            }
        })
    }

}
