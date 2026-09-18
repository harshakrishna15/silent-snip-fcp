import AppKit
import ApplicationServices
import CutdownCore
import Foundation

extension FinalCutAXSession {
    func pressMenu(path: [String], allowDisabled: Bool = false, openingProject: String? = nil) async throws {
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
