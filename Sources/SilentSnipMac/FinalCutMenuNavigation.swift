import AppKit
import ApplicationServices
import SilentSnipCore
import Foundation

extension FinalCutAXSession {
    /// One action on the retained CLOSED Share hierarchy. This
    /// function sends no menu-opening, keyboard, Return, or coordinate input.
    /// A native result (including an error) consumes its one permitted attempt.
    func invokeClosedShareAX(probe: DirectShareAXProbe, timing: AnalysisTiming, prefix: String) throws -> [AXUIElement] {
        try probe.configuration.verify(workflowOrigin)
        guard projectName == probe.configuration.projectName else { throw DirectShareAXError.preflight("The pinned project changed.") }
        try assertClosedProjectInputForShareProbe(probe)
        guard let expected = reviewOwnership.active, try selectionSnapshot() == expected else {
            throw DirectShareAXError.preflight("The analyzed clip selection could not be reverified.")
        }
        guard let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement], windows.count <= 32,
              let bar = Self.elementAttribute(root, kAXMenuBarAttribute) else {
            throw DirectShareAXError.preflight("The host windows or retained menu bar could not be bounded.")
        }
        typealias Command = ClosedShareAXCommand<AXUIElement>
        func resolve(_ bar: AXUIElement) throws -> Command {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            return try Command.resolve(menuBar: bar, read: { element in
                var owner: pid_t = 0
                guard AXUIElementGetPid(element, &owner) == .success, owner == self.application.processIdentifier else {
                    throw DirectShareAXError.preflight("A retained menu object is not owned by the pinned Final Cut process.")
                }
                let values = FinalCutAXAttributes.read(element, names: [kAXRoleAttribute, kAXTitleAttribute,
                    kAXEnabledAttribute, kAXChildrenAttribute])
                if probe.mode == .production {
                    guard let role = values[kAXRoleAttribute] as? String,
                          ![kAXMenuBarRole, kAXMenuRole, kAXMenuBarItemRole].contains(role)
                            || values[kAXChildrenAttribute] is [AXUIElement] else {
                        throw DirectShareAXError.preflight("The retained menu hierarchy could not be read completely.")
                    }
                }
                return Command.Node(role: values[kAXRoleAttribute] as? String,
                    title: values[kAXTitleAttribute] as? String,
                    enabled: (values[kAXEnabledAttribute] as? NSNumber)?.boolValue,
                    children: values[kAXChildrenAttribute] as? [AXUIElement] ?? [])
            }, actions: { element in
                var actions: CFArray?
                guard AXUIElementCopyActionNames(element, &actions) == .success,
                      let available = actions as? [String] else { throw DirectShareAXError.preflight("The command's advertised actions could not be read.") }
                return available
            }, pressOnly: probe.mode == .production,
                shouldContinue: { !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline })
        }
        let retained = try resolve(bar)
        probe.update {
            $0.advertisedActions = retained.actions
            $0.selectedAction = retained.action
            $0.foregroundBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
            $0.projectBefore = String(self.projectName.prefix(512))
        }
        try assertClosedProjectInputForShareProbe(probe)
        try probe.configuration.verify(workflowOrigin)
        guard try selectionSnapshot() == expected,
              let currentBar = Self.elementAttribute(root, kAXMenuBarAttribute), CFEqual(currentBar, bar) else {
            throw DirectShareAXError.preflight("The project selection or menu bar changed before dispatch.")
        }
        let fresh = try resolve(currentBar)
        guard retained.isSame(as: fresh, equals: { CFEqual($0, $1) }) else {
            throw DirectShareAXError.preflight("The retained menu hierarchy or advertised action changed before dispatch.")
        }
        try assertClosedProjectInputForShareProbe(probe)
        guard try selectionSnapshot() == expected else { throw DirectShareAXError.preflight("The clip changed immediately before dispatch.") }
        probe.update { $0.uniqueMatchedPath = true }
        try timing.measure(prefix + ".directAX.dispatch") {
            try probe.dispatch(action: fresh.action) {
                AXUIElementPerformAction(fresh.item, fresh.action as CFString).rawValue
            }
        }
        return windows
    }

    private func assertClosedProjectInputForShareProbe(_ probe: DirectShareAXProbe) throws {
        try assertCurrentProject()
        guard currentSheet() == nil, application.isActive,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
              let focused = Self.elementAttribute(root, kAXFocusedWindowAttribute), CFEqual(focused, mainWindow),
              let main = Self.elementAttribute(root, kAXMainWindowAttribute), CFEqual(main, mainWindow),
              let bar = Self.elementAttribute(root, kAXMenuBarAttribute) else {
            throw DirectShareAXError.preflight("The unobstructed pinned project does not own input.")
        }
        let selected = attribute(bar, kAXSelectedChildrenAttribute) as? [AXUIElement]
        probe.update { $0.menuBarTrackingStateAvailable = selected != nil }
        if probe.mode == .production, selected == nil {
            throw DirectShareAXError.preflight("The menu bar's closed state could not be read.")
        }
        guard selected?.isEmpty != false else { throw DirectShareAXError.preflight("A menu is already tracking input.") }
        try refreshTimeline()
        var element = Self.elementAttribute(root, kAXFocusedUIElementAttribute)
        var timelineOwnsInput = false
        for _ in 0..<24 {
            try Task.checkCancellation()
            guard let current = element else { break }
            let role = string(current, kAXRoleAttribute)
            if probe.mode == .production, role == nil {
                throw DirectShareAXError.preflight("The focused input hierarchy could not be read completely.")
            }
            guard ![kAXMenuRole, kAXMenuItemRole, kAXMenuBarRole, kAXMenuBarItemRole].contains(role ?? "") else {
                throw DirectShareAXError.preflight("A menu already owns keyboard focus.")
            }
            if CFEqual(current, timeline) { timelineOwnsInput = true }
            if CFEqual(current, mainWindow) {
                guard timelineOwnsInput else { throw DirectShareAXError.preflight("The pinned timeline does not own input; a browser clip must not be shared.") }
                return
            }
            element = Self.elementAttribute(current, kAXParentAttribute)
        }
        throw DirectShareAXError.preflight("Focused input could not be bound to the closed-menu project workspace.")
    }

    func makeMenuPath(path: [String]) -> FinalCutMenuPath<AXUIElement> {
        let pid = application.processIdentifier
        return FinalCutMenuPath(titles: path,
            read: { FinalCutAXAttributes.read($0, names: $1) },
            owned: { element in
                var owner: pid_t = 0
                return AXUIElementGetPid(element, &owner) == .success && owner == pid
            }, actions: { element in
                var names: CFArray?
                guard AXUIElementCopyActionNames(element, &names) == .success else { return nil }
                return names as? [String]
            }, equals: { CFEqual($0, $1) })
    }

    /// Use only the shortcut advertised by this exact retained menu command.
    /// A missing assignment leaves the request-local identity route available
    /// for ordinary menu navigation. A dispatched or uncertain event never
    /// authorizes a second invocation.
    func pressAdvertisedMenuShortcut(path: [String], menuPath: FinalCutMenuPath<AXUIElement>? = nil) throws -> Bool {
        try assertInputFocus()
        guard currentSheet() == nil else {
            throw FinalCutCaptureError.unavailable("Close the current dialog before sharing.")
        }
        guard !path.isEmpty, let bar = Self.elementAttribute(root, kAXMenuBarAttribute) else { return false }
        let route = menuPath ?? makeMenuPath(path: path)
        guard route.titles == path else { return false }
        func shortcut(_ value: [String: Any]) -> FinalCutMenuShortcut? {
            FinalCutMenuShortcut(
                virtualKey: (value[kAXMenuItemCmdVirtualKeyAttribute] as? NSNumber)?.intValue,
                modifiers: (value[kAXMenuItemCmdModifiersAttribute] as? NSNumber)?.intValue,
                character: value[kAXMenuItemCmdCharAttribute] as? String,
                glyph: (value[kAXMenuItemCmdGlyphAttribute] as? NSNumber)?.intValue,
                enabled: (value[kAXEnabledAttribute] as? NSNumber)?.boolValue)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        let shouldContinue = { !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline }
        guard let item = route.command(in: bar, shouldContinue: shouldContinue),
              let advertised = shortcut(item.values) else { return false }
        try assertInputFocus()
        guard currentSheet() == nil else {
            throw FinalCutCaptureError.unavailable("The Final Cut Pro dialog changed before sharing.")
        }
        guard let currentBar = Self.elementAttribute(root, kAXMenuBarAttribute), CFEqual(currentBar, bar),
              let fresh = route.command(in: currentBar, shouldContinue: shouldContinue),
              CFEqual(item.element, fresh.element), let checked = shortcut(fresh.values),
              checked.keyCode == advertised.keyCode, checked.flags == advertised.flags else { return false }
        try key(code: checked.keyCode, flags: checked.flags)
        return true
    }

    /// Uses the same attribute batch that proved the mounted command, rather
    /// than rereading role/title/description/identifier/enabled individually.
    private func pressMountedMenuItem(_ route: FinalCutMenuPath<AXUIElement>, index: Int,
                                      bar: AXUIElement, container: AXUIElement,
                                      willDispatch: (AXUIElement) -> Void) throws -> (item: AXUIElement, action: String) {
        try Task.checkCancellation()
        try assertInputFocus()
        guard let currentBar = Self.elementAttribute(root, kAXMenuBarAttribute), CFEqual(currentBar, bar) else {
            throw FinalCutCaptureError.unavailable("The Final Cut Pro menu bar changed before input.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        guard let target = route.input(in: currentBar, index: index, container: container,
            shouldContinue: { !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline }),
              let action = FinalCutControlAction.preferred(from: target.actions) else {
            try Task.checkCancellation()
            throw FinalCutCaptureError.unavailable("\(operationStage): The Final Cut Pro menu command changed or is unavailable.")
        }
        // There is exactly one AX action. Its error may be reported after the
        // host accepts it; the caller's existing final-attempt marker remains
        // the only authority for observation, never for another dispatch.
        try Task.checkCancellation()
        try assertInputFocus()
        willDispatch(target.element)
        let result = AXUIElementPerformAction(target.element, action as CFString)
        guard result == .success else {
            throw FinalCutCaptureError.unavailable("\(operationStage): \(action) failed for ‘\(route.titles[index])’ (AX error \(result.rawValue)).")
        }
        return (target.element, action)
    }

    func pressMenu(path: [String], allowDisabled: Bool = false, openingProject: String? = nil,
                   menuPath: FinalCutMenuPath<AXUIElement>? = nil,
                   onFinalDispatchAttempt: (() -> Void)? = nil) async throws {
#if DEBUG
        if quietPrototypeMenu {
            if let lease = QuietSharePrototype.pluginLease, !FinalCutGuardedMenuReturn.supportsCoveredPath(path) {
                lease.reveal(reason: "Visible compatibility step: " + path.joined(separator: " → "))
            } else {
                try await pressMenuUnderPrototypeCover(path: path, allowDisabled: allowDisabled,
                    onFinalDispatchAttempt: onFinalDispatchAttempt)
                return
            }
        }
#endif
        let previousStage = operationStage
        let menuStage = "\(previousStage), menu \(path.joined(separator: " → "))"
        operationStage = menuStage + ", before first input"
        defer { operationStage = previousStage }
        try await prepareInputFocus()
        guard !path.isEmpty, let bar = Self.elementAttribute(root, kAXMenuBarAttribute) else {
            throw FinalCutCaptureError.unavailable("The Final Cut Pro menu bar is unavailable.")
        }
        let startedWithClosedMenu = (attribute(bar, kAXSelectedChildrenAttribute) as? [AXUIElement])?.isEmpty == true
        var openedTopItem: AXUIElement?
        var finalAttempted = false
        do {
            var container = bar
            var menuOwner: AXUIElement?
            for (index, title) in path.enumerated() {
                let final = index == path.count - 1
                let willDispatch: (AXUIElement) -> Void = { item in
                    self.operationStage = menuStage + (final ? ", final command attempted" : ", opening \(title) attempted")
                    if final { finalAttempted = true; onFinalDispatchAttempt?() }
                    else if index == 0, startedWithClosedMenu { openedTopItem = item }
                }
                operationStage = menuStage + (final ? ", before final command" : ", before opening \(title)")
                try await prepareInputFocus()
                let item: AXUIElement
                let action: String
                if let menuPath, menuPath.titles == path, !allowDisabled {
                    let pressed = try pressMountedMenuItem(menuPath, index: index, bar: bar,
                        container: container, willDispatch: willDispatch)
                    item = pressed.item; action = pressed.action
                } else {
                    let matches = children(container).filter { string($0, kAXTitleAttribute) == title }
                    guard matches.count == 1 else { throw FinalCutCaptureError.unavailable("Menu command \(path.joined(separator: " → ")) was not found.") }
                    item = matches[0]
                    if final && allowDisabled && (attribute(item, kAXEnabledAttribute) as? NSNumber)?.boolValue == false {
                        try key(code: 53) // Dismiss only the menu just opened by this method.
                        return
                    }
                    action = try press(item) { willDispatch(item) }
                }
                if final {
                    if let menuOwner {
                        try await activatePickedMenuItem(item, menu: container, owner: menuOwner, action: action,
                                                        openingProject: openingProject)
                    }
                    return
                }
                operationStage = menuStage + ", waiting for \(title) submenu"
                // Closed menus remain in AXChildren. Prove that the exact submenu
                // is on screen and contains one intended next command. That command
                // may be outside a scrolling menu's viewport; any visible child
                // proves the menu is open. Coordinate input still checks its target.
                let nextTitle = path[index + 1]
                var openedMenu: AXUIElement?
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                while openedMenu == nil {
                    try Task.checkCancellation()
                    try await prepareInputFocus()
                    let menus = children(item).filter { string($0, kAXRoleAttribute) == kAXMenuRole }
                    if menus.count == 1 {
                        if FinalCutMenuObservation.submenuIsReady(children: children(menus[0]),
                            intended: { string($0, kAXTitleAttribute) == nextTitle },
                            onScreen: { menuItemIsOnScreen($0, menu: menus[0], owner: item) }) {
                            openedMenu = menus[0]
                            break
                        }
                    }
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        throw FinalCutCaptureError.unavailable("The Final Cut Pro submenu for \(nextTitle) did not open.")
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard let menu = openedMenu else { throw FinalCutCaptureError.unavailable("A Final Cut Pro submenu disappeared.") }
                menuOwner = item
                container = menu
            }
        } catch {
            // Final Cut can leave a menu tracking after a failed preflight.
            // Validate and dismiss our exact menu even if the caller canceled.
            if !finalAttempted, let openedTopItem {
                await Task { @MainActor in self.cancelOwnedMenu(bar: bar, item: openedTopItem) }.value
            }
            throw error
        }
    }

    private func cancelOwnedMenu(bar: AXUIElement, item: AXUIElement) {
        guard (try? assertCurrentProject()) != nil,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
              currentSheet() == nil,
              let current = Self.elementAttribute(root, kAXMenuBarAttribute), CFEqual(current, bar),
              let selected = attribute(current, kAXSelectedChildrenAttribute) as? [AXUIElement],
              selected.count == 1, CFEqual(selected[0], item) else { return }
        var actions: CFArray?
        guard AXUIElementCopyActionNames(item, &actions) == .success,
              (actions as? [String])?.contains(kAXCancelAction) == true else { return }
        _ = AXUIElementPerformAction(item, kAXCancelAction as CFString)
    }

    private func menuItemIsOnScreen(_ item: AXUIElement, menu: AXUIElement, owner: AXUIElement) -> Bool {
        guard children(owner).contains(where: { CFEqual($0, menu) }),
              children(menu).contains(where: { CFEqual($0, item) }),
              let point = controlCenter(item) else { return false }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return false }
        return CFEqual(hit, item) || children(item).contains { CFEqual($0, hit) }
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
                if try FinalCutMenuProjectTransition.openedOrAssertOriginal(
                    opened: projectOpened, assertOriginal: assertCurrentProject) { return }
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw FinalCutCaptureError.unavailable("The selected menu command did not finish.")
        }
        func menuIsOpen() -> Bool {
            // Final Cut keeps closed menus in AXChildren. Hit-testing distinguishes
            // an on-screen item from that retained accessibility representation.
            menuItemIsOnScreen(item, menu: menu, owner: owner)
        }
        func itemIsSelected() -> Bool {
            FinalCutMenuObservation.isExactlySelected(
                reported: attribute(menu, kAXSelectedChildrenAttribute) as? [AXUIElement],
                selectedChildren: {
                    children(menu).filter { (attribute($0, kAXSelectedAttribute) as? NSNumber)?.boolValue == true }
                }, intended: { CFEqual($0, item) })
        }
        // An AX action can select a menu item without executing it. Wait for
        // observed completion immediately. A merely selected item still needs
        // the existing grace period: clicking it sooner could race a delayed
        // AXPress. No other input is sent after the menu closes or a sheet opens.
        let actionStarted = ProcessInfo.processInfo.systemUptime
        try await waitForMenu(timeout: 2) {
            FinalCutMenuActivationReadiness.isReady(
                completed: self.currentSheet() != nil || !menuIsOpen(),
                exactlySelected: itemIsSelected(),
                elapsed: ProcessInfo.processInfo.systemUptime - actionStarted)
        }
        if projectOpened() { return }
        if currentSheet() != nil { return }
        do { try await prepareInputFocus() }
        catch FinalCutCaptureError.changedProject {
            guard projectOpened() else { throw FinalCutCaptureError.changedProject }
            return
        }
        if projectOpened() { return }
        if currentSheet() != nil { return }
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
        if try FinalCutMenuProjectTransition.openedOrAssertOriginal(
            opened: projectOpened, assertOriginal: assertInputFocus) { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        try await waitForMenu(timeout: 3) {
            !menuIsOpen() || self.currentSheet() != nil
        }
    }

}

/// Opening a named project replaces the original title between independent
/// AX reads. Only that exact observed handoff may satisfy a failed source pin;
/// ordinary menus, unrelated projects and other errors keep their strict guard.
enum FinalCutMenuProjectTransition {
    static func openedOrAssertOriginal(opened: () -> Bool, assertOriginal: () throws -> Void) throws -> Bool {
        if opened() { return true }
        do { try assertOriginal() }
        catch FinalCutCaptureError.changedProject {
            guard opened() else { throw FinalCutCaptureError.changedProject }
            return true
        }
        return false
    }
}

enum FinalCutMenuActivationReadiness {
    /// Observed completion never needs a delay. Selection alone cannot prove
    /// that a successful AX action has finished dispatching its command.
    static func isReady(completed: Bool, exactlySelected: Bool, elapsed: TimeInterval) -> Bool {
        completed || (exactlySelected && elapsed >= 0.2)
    }
}

enum FinalCutMenuObservation {
    static func submenuIsReady<Item>(children: [Item], intended: (Item) -> Bool,
                                    onScreen: (Item) -> Bool) -> Bool {
        children.filter(intended).count == 1 && children.contains(where: onScreen)
    }

    /// An empty aggregate selection is also returned by some valid menu hosts.
    /// Fall back to the child flags only then (or when it is absent), never when
    /// a nonempty aggregate selection identifies another item or multiple items.
    static func isExactlySelected<Item>(reported: [Item]?, selectedChildren: () -> [Item],
                                        intended: (Item) -> Bool) -> Bool {
        let selected = reported.flatMap { $0.isEmpty ? nil : $0 } ?? selectedChildren()
        return selected.count == 1 && intended(selected[0])
    }
}

#if DEBUG
extension FinalCutAXSession {
    /// Feasibility-only dispatch. There is deliberately no coordinate fallback.
    /// A dispatch or timeout is never followed by a different invocation path.
    private func pressMenuUnderPrototypeCover(path: [String], allowDisabled: Bool,
                                             onFinalDispatchAttempt: (() -> Void)?) async throws {
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
            let action = try press(item, willDispatch: index == path.count - 1 ? onFinalDispatchAttempt : nil)
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
