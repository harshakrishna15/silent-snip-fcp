import AppKit
import ApplicationServices
import SilentSnipCore
import Foundation

extension FinalCutAXSession {
    func pressMenu(path: [String], allowDisabled: Bool = false, openingProject: String? = nil) async throws {
#if DEBUG
        if quietPrototypeMenu {
            if let lease = QuietSharePrototype.pluginLease, !FinalCutGuardedMenuReturn.supportsCoveredPath(path) {
                lease.reveal(reason: "Visible compatibility step: " + path.joined(separator: " → "))
            } else {
                try await pressMenuUnderPrototypeCover(path: path, allowDisabled: allowDisabled)
                return
            }
        }
#endif
        let previousStage = operationStage
        operationStage = "\(previousStage), menu \(path.joined(separator: " → "))"
        defer { operationStage = previousStage }
        try assertInputFocus()
        guard !path.isEmpty, let bar = Self.elementAttribute(root, kAXMenuBarAttribute) else {
            throw FinalCutCaptureError.unavailable("The Final Cut menu bar is unavailable.")
        }
        var container = bar
        var menuOwner: AXUIElement?
        for (index, title) in path.enumerated() {
            let matches = children(container).filter { string($0, kAXTitleAttribute) == title }
            guard matches.count == 1 else { throw FinalCutCaptureError.unavailable("Menu command \(path.joined(separator: " → ")) was not found.") }
            let item = matches[0]
            if index == path.count - 1 {
                if allowDisabled && (attribute(item, kAXEnabledAttribute) as? NSNumber)?.boolValue == false {
                    try key(code: 53) // Dismiss only the menu just opened by this method.
                    return
                }
                let action = try press(item)
                if let menuOwner {
                    try await activatePickedMenuItem(item, menu: container, owner: menuOwner, action: action,
                                                    openingProject: openingProject)
                }
                return
            }
            try press(item)
            try await Task.sleep(for: .milliseconds(100))
            guard let menu = children(item).first(where: { string($0, kAXRoleAttribute) == kAXMenuRole }) else {
                throw FinalCutCaptureError.unavailable("A Final Cut submenu did not open.")
            }
            menuOwner = item
            container = menu
        }
    }

    private func activatePickedMenuItem(_ item: AXUIElement, menu: AXUIElement, owner: AXUIElement, action: String,
                                        openingProject: String?) async throws {
        func projectOpened() -> Bool {
            guard let openingProject, let current = try? FinalCutAXSession() else { return false }
            return current.projectName == openingProject
                && current.application.processIdentifier == application.processIdentifier
                && CFEqual(current.mainWindow, mainWindow)
        }
        func waitForMenu(timeout: TimeInterval, predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                try Task.checkCancellation()
                // Open Clip can replace the timeline before the menu closes.
                // Ordinary menu actions retain their original-project check.
                if projectOpened() { return }
                try assertCurrentProject()
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(150))
            }
            throw FinalCutCaptureError.unavailable("The selected menu command did not finish.")
        }
        func menuIsOpen() -> Bool {
            // Final Cut keeps closed menus in AXChildren. Hit-testing distinguishes
            // an on-screen item from that retained accessibility representation.
            guard children(owner).contains(where: { CFEqual($0, menu) }),
                  let point = self.controlCenter(item) else { return false }
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(self.root, Float(point.x), Float(point.y), &hit) == .success,
                  let hit else { return false }
            return CFEqual(hit, item) || self.children(item).contains { CFEqual($0, hit) }
        }
        func itemIsSelected() -> Bool {
            (attribute(item, kAXSelectedAttribute) as? NSNumber)?.boolValue == true
                || (attribute(menu, kAXSelectedChildrenAttribute) as? [AXUIElement] ?? []).contains { CFEqual($0, item) }
        }
        // An AX action can select a menu item without executing it. Wait for
        // proof of that exact selection before clicking once. If the menu
        // has already closed, do not send another event to the resulting UI.
        try await Task.sleep(for: .milliseconds(200))
        if projectOpened() { return }
        if currentSheet() != nil { return }
        try await waitForMenu(timeout: 2) {
            !menuIsOpen() || itemIsSelected()
        }
        if projectOpened() { return }
        guard menuIsOpen() else { return }
        let enabled = (attribute(item, kAXEnabledAttribute) as? NSNumber)?.boolValue != false
        guard string(item, kAXRoleAttribute) == kAXMenuItemRole,
              children(menu).contains(where: { CFEqual($0, item) }),
              FinalCutControlAction.confirmsPickedMenuItem(action: action, menuOpen: menuIsOpen(),
                  itemSelected: itemIsSelected(), itemEnabled: enabled) else {
            throw FinalCutCaptureError.unavailable("\(operationStage): The expected menu command is not selected and enabled for activation.")
        }
        guard let point = controlCenter(item), let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw FinalCutCaptureError.unavailable("The selected menu item's screen bounds are unavailable.")
        }
        try assertInputFocus()
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        try await waitForMenu(timeout: 3) {
            !menuIsOpen() || self.currentSheet() != nil
        }
    }

}

#if DEBUG
extension FinalCutAXSession {
    /// Feasibility-only dispatch. There is deliberately no coordinate fallback.
    /// A dispatch or timeout is never followed by a different invocation path.
    private func pressMenuUnderPrototypeCover(path: [String], allowDisabled: Bool) async throws {
        try assertInputFocus()
        guard !path.isEmpty, let bar = Self.elementAttribute(root, kAXMenuBarAttribute) else {
            throw FinalCutCaptureError.unavailable("The prototype cannot identify the menu bar.")
        }
        func resolve() -> (AXUIElement, AXUIElement)? {
            var parent = bar
            for (index, title) in path.enumerated() {
                let matches = children(parent).filter { string($0, kAXTitleAttribute) == title }
                guard matches.count == 1 else { return nil }
                if index == path.count - 1 { return (parent, matches[0]) }
                let menus = children(matches[0]).filter { string($0, kAXRoleAttribute) == kAXMenuRole }
                guard menus.count == 1 else { return nil }
                parent = menus[0]
            }
            return nil
        }
        func advertisedShortcut(_ item: AXUIElement) -> FinalCutMenuShortcut? {
            FinalCutMenuShortcut(
                virtualKey: (attribute(item, kAXMenuItemCmdVirtualKeyAttribute) as? NSNumber)?.intValue,
                modifiers: (attribute(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue,
                character: attribute(item, kAXMenuItemCmdCharAttribute) as? String,
                glyph: (attribute(item, kAXMenuItemCmdGlyphAttribute) as? NSNumber)?.intValue,
                enabled: (attribute(item, kAXEnabledAttribute) as? NSNumber)?.boolValue)
        }
        // Read the exact retained command without opening a menu first.
        if let (_, item) = resolve(), let shortcut = advertisedShortcut(item) {
            try assertInputFocus()
            guard let (_, fresh) = resolve(), CFEqual(item, fresh),
                  let rechecked = advertisedShortcut(fresh), rechecked.keyCode == shortcut.keyCode,
                  rechecked.flags == shortcut.flags else {
                throw FinalCutCaptureError.unavailable("The advertised menu shortcut changed before dispatch.")
            }
            quietPrototypeInvocation?(path.joined(separator: " → ") + ": advertised-shortcut")
            try key(code: shortcut.keyCode, flags: shortcut.flags)
            return
        }
        var container = bar
        var owner: AXUIElement?
        for (index, title) in path.enumerated() {
            let matches = children(container).filter { string($0, kAXTitleAttribute) == title }
            guard matches.count == 1 else { throw FinalCutCaptureError.unavailable("The prototype menu path is ambiguous: \(title)") }
            let item = matches[0]
            guard (attribute(item, kAXEnabledAttribute) as? NSNumber)?.boolValue == true else {
                if allowDisabled { throw FinalCutCaptureError.unavailable("The prototype will not dispatch a disabled menu command.") }
                throw FinalCutCaptureError.unavailable("The prototype menu command is disabled: \(title)")
            }
            let action = try press(item)
            if index != path.count - 1 {
                var submenu: AXUIElement?
                try await waitUntil(timeout: 2, context: "prototype submenu \(title)") {
                    let menus = self.children(item).filter { self.string($0, kAXRoleAttribute) == kAXMenuRole }
                    submenu = menus.count == 1 ? menus[0] : nil
                    return submenu != nil
                }
                guard let submenu else { throw FinalCutCaptureError.unavailable("The prototype submenu disappeared.") }
                owner = item; container = submenu
                continue
            }
            quietPrototypeInvocation?(path.joined(separator: " → ") + ": accessibility-" + action)
            guard let owner else { return }
            // Give the successful AX action a chance to deliver its UI change.
            // Immediate retained-menu reads can otherwise race an opening panel.
            try await Task.sleep(for: .milliseconds(200))
            if ShareDestinationManager.shared.prototypeHostAcceptedShare(projectName: projectName) { return }
            func menuOpen() -> Bool {
                guard self.children(owner).contains(where: { CFEqual($0, container) }),
                      let point = self.controlCenter(item) else { return false }
                var hit: AXUIElement?
                guard AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &hit) == .success,
                      let hit else { return false }
                return CFEqual(hit, item) || self.children(item).contains { CFEqual($0, hit) }
            }
            func selectedExactly() -> Bool {
                let selected = self.attribute(container, kAXSelectedChildrenAttribute) as? [AXUIElement] ?? []
                return selected.count == 1 && CFEqual(selected[0], item)
            }
            try await waitUntil(timeout: 2, context: "exact prototype menu selection") {
                ShareDestinationManager.shared.prototypeHostAcceptedShare(projectName: self.projectName)
                    || self.currentSheet() != nil || !menuOpen() || selectedExactly()
            }
            if ShareDestinationManager.shared.prototypeHostAcceptedShare(projectName: projectName)
                || currentSheet() != nil || !menuOpen() { return }
            try assertInputFocus()
            guard let (freshMenu, freshItem) = resolve(), CFEqual(container, freshMenu), CFEqual(item, freshItem),
                  FinalCutGuardedMenuReturn.permits(action: action, menuOpen: menuOpen(),
                    selectedCount: (attribute(container, kAXSelectedChildrenAttribute) as? [AXUIElement])?.count ?? 0,
                    intendedSelected: selectedExactly(), enabled: (attribute(item, kAXEnabledAttribute) as? NSNumber)?.boolValue == true) else {
                throw FinalCutCaptureError.unavailable("The prototype could not prove the intended enabled menu selection. No Return was sent.")
            }
            quietPrototypeInvocation?(path.joined(separator: " → ") + ": guarded-return-once")
            try key(code: 36)
            try await waitUntil(timeout: 3, context: "prototype menu activation") { self.currentSheet() != nil || !menuOpen() }
        }
    }
}

enum FinalCutGuardedMenuReturn {
    static func supportsCoveredPath(_ path: [String]) -> Bool {
        [["File", "Share", "Silent Snip…"], ["Window", "Go To", "Timeline"],
         ["Mark", "Clear Selected Ranges"]].contains(path)
    }
    static func permits(action: String, menuOpen: Bool, selectedCount: Int, intendedSelected: Bool, enabled: Bool) -> Bool {
        [kAXPickAction, kAXPressAction].contains(action) && menuOpen && selectedCount == 1 && intendedSelected && enabled
    }
}
#endif
