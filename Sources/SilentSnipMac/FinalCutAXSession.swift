import AppKit
import ApplicationServices
import SilentSnipCore
import Foundation

/// A short-lived, pinned Final Cut session. Traversal is confined to the main
/// window's containers or a specific dialog/menu, never the entire app AX tree.
@MainActor final class FinalCutAXSession {
    let application: NSRunningApplication
    let root: AXUIElement
    let mainWindow: AXUIElement
    let projectName: String
    private let permitsEmptyTimeline: Bool
    private(set) var timeline: AXUIElement
    private let projectLookup: FinalCutAXLookup<AXUIElement>
    private let timelineLookup: FinalCutAXLookup<AXUIElement>
    private let windowTitle: String
    var operationStage = "Reading the selected audio-only timeline clip"
    var lastXMLShareDirectory: URL?
    var knownReviewWindows: [(element: AXUIElement, title: String)] = []
    typealias SuspendedReview = FinalCutReviewOwnership.Suspended
    var reviewOwnership = FinalCutReviewOwnership()
    var suspendedReview: SuspendedReview? {
        get { reviewOwnership.suspended }
        set { reviewOwnership.suspended = newValue }
    }

    init(allowImportDialog: Bool = false, allowEmptyTimeline: Bool = false) throws {
        guard FinalCutAccessibility.isTrusted else { throw FinalCutAccessibility.AccessibilityError.permissionRequired }
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: FinalCutAccessibility.bundleIdentifier).first else {
            throw FinalCutAccessibility.AccessibilityError.notRunning
        }
        self.application = application
        let root = AXUIElementCreateApplication(application.processIdentifier)
        self.root = root
        AXUIElementSetMessagingTimeout(root, 0.3)
        let query = FinalCutAXQuery(identifier: "editor/timelineContainer/toolbar/projectNamePopUpButton",
                                    containersOnly: true, additionalAttributes: [kAXTitleAttribute])
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var workspaces: [(window: AXUIElement, title: String, lookup: FinalCutAXLookup<AXUIElement>, project: FinalCutAXMatch<AXUIElement>?)] = []
        let window = FinalCutProjectWindow.resolve(main: Self.elementAttribute(root, kAXMainWindowAttribute),
            windows: Self.rawAttribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? [], equals: { CFEqual($0, $1) }) { candidate in
                let values = FinalCutAXAttributes.read(candidate, names: [kAXRoleAttribute, kAXSubroleAttribute, kAXModalAttribute, kAXTitleAttribute])
                guard FinalCutProjectWindow.isWorkspace(role: values[kAXRoleAttribute] as? String,
                    subrole: values[kAXSubroleAttribute] as? String, modal: (values[kAXModalAttribute] as? NSNumber)?.boolValue,
                    title: values[kAXTitleAttribute] as? String) else { return false }
                let lookup = Self.lookup(candidate, query: query)
                let shouldContinue = { !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline }
                let project = lookup.resolve(shouldContinue: shouldContinue)
                // Replacement may close the timeline entirely. Its Libraries
                // sidebar still identifies the workspace without accepting an
                // effect editor or secondary viewer as the project window.
                if project == nil {
                    guard allowEmptyTimeline else { return false }
                    let sidebar = Self.lookup(candidate, query: .init(role: kAXOutlineRole,
                        description: "Event media sidebar", containersOnly: true))
                    guard sidebar.resolve(shouldContinue: shouldContinue) != nil else { return false }
                }
                workspaces.append((candidate, values[kAXTitleAttribute] as? String ?? "", lookup, project))
                return true
            }
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline, let window,
              let workspace = workspaces.first(where: { CFEqual($0.window, window) }) else {
            throw FinalCutCaptureError.projectWindowUnavailable
        }
        mainWindow = window
        windowTitle = workspace.title
        projectLookup = workspace.lookup
        timelineLookup = Self.lookup(window, query: .init(role: kAXLayoutAreaRole, description: "Project Timeline", containersOnly: true))
        let name = workspace.project?.values[kAXTitleAttribute] as? String ?? ""
        let timeline = Self.resolve(timelineLookup)?.element
        guard !windowTitle.isEmpty, allowEmptyTimeline || (!name.isEmpty && timeline != nil) else {
            throw FinalCutCaptureError.unavailable("The active project timeline could not be identified in this Final Cut layout.")
        }
        permitsEmptyTimeline = allowEmptyTimeline
        projectName = name
        // Empty sessions are used only to reopen a replaced project in the
        // browser. A normal session is required before exporting or editing it.
        self.timeline = timeline ?? window
        // Import verification owns the bounded dialog-settling policy. Other
        // entry points still require an unobstructed project before any action.
        guard allowImportDialog || currentSheet() == nil else { throw FinalCutCaptureError.unavailable("Close the open Final Cut dialog before continuing.") }
    }

    /// Import can temporarily remove the workspace from all AX attributes.
    /// Wait only for that condition; permission, dialog and identity failures
    /// propagate immediately. This never redelivers XML or confirms Replace.
    static func forImport(allowImportDialog: Bool = true, allowEmptyTimeline: Bool) async throws -> FinalCutAXSession {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while true {
            try Task.checkCancellation()
            do { return try Self(allowImportDialog: allowImportDialog, allowEmptyTimeline: allowEmptyTimeline) }
            catch FinalCutCaptureError.projectWindowUnavailable {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw FinalCutCaptureError.projectWindowUnavailable }
                try await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? { Self.rawAttribute(element, name) }
    func string(_ element: AXUIElement, _ name: String) -> String? {
        let result = attribute(element, name)
        return (result as? String) ?? (result as? NSNumber)?.stringValue
    }
    func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

    private static func rawAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }

    static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let result = rawAttribute(element, name), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(result, to: AXUIElement.self)
    }

    func find(in element: AXUIElement, role: String? = nil, identifier: String? = nil, title: String? = nil,
              description: String? = nil, maxDepth: Int = 12, maxNodes: Int = 350) -> AXUIElement? {
        Self.search(element, role: role, identifier: identifier, title: title, description: description,
                    maxDepth: maxDepth, maxNodes: maxNodes)
    }

    static func search(_ root: AXUIElement, role: String? = nil, identifier: String? = nil,
                               title: String? = nil, description: String? = nil,
                               maxDepth: Int = 24, maxNodes: Int = 600, containersOnly: Bool = false) -> AXUIElement? {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        return FinalCutAXSearch.find(root: root,
            query: .init(role: role, identifier: identifier, title: title, description: description, containersOnly: containersOnly),
            maxDepth: maxDepth, maxNodes: maxNodes, read: { FinalCutAXAttributes.read($0, names: $1) },
            children: { Self.rawAttribute($0, kAXChildrenAttribute) as? [AXUIElement] ?? [] }, equals: { CFEqual($0, $1) },
            shouldContinue: { !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline })?.element
    }

    private static func lookup(_ window: AXUIElement, query: FinalCutAXQuery) -> FinalCutAXLookup<AXUIElement> {
        FinalCutAXLookup(root: window, query: query, read: { FinalCutAXAttributes.read($0, names: $1) },
            children: { Self.rawAttribute($0, kAXChildrenAttribute) as? [AXUIElement] ?? [] }, equals: { CFEqual($0, $1) })
    }

    private static func resolve(_ lookup: FinalCutAXLookup<AXUIElement>) -> FinalCutAXMatch<AXUIElement>? {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        return lookup.resolve { !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline }
    }

    func currentProjectTitle() -> String? { Self.resolve(projectLookup)?.values[kAXTitleAttribute] as? String }

    func refreshTimeline() throws {
        guard let current = Self.resolve(timelineLookup)?.element else {
            throw FinalCutCaptureError.unavailable("The active project timeline is no longer accessible.")
        }
        timeline = current
    }

    var projectLookupCounters: [String: Int] {
        let stats = projectLookup.statistics
        return ["capture.projectLookup.searches": stats.searches, "capture.projectLookup.cacheHits": stats.cacheHits,
            "capture.projectLookup.invalidations": stats.invalidations, "capture.projectLookup.visitedNodes": stats.visitedNodes,
            "capture.projectLookup.pathChecks": stats.pathChecks]
    }

    func assertCurrentProject() throws {
        try Task.checkCancellation()
        guard !application.isTerminated else { throw FinalCutCaptureError.unavailable("Final Cut exited during \(operationStage).") }
        // Read a fresh title only after verifying every edge from the pinned
        // window to this control. A rebuilt path falls back to bounded discovery.
        let name = currentProjectTitle() ?? ""
        guard name == projectName, permitsEmptyTimeline || !name.isEmpty else {
            throw FinalCutCaptureError.changedProject
        }
    }

    func requestActivation() {
        NSApplication.shared.yieldActivation(to: application)
        application.activate(from: NSRunningApplication.current, options: [])
    }

    func activate() async throws {
        try assertCurrentProject()
        guard currentSheet() == nil else { throw FinalCutCaptureError.unavailable("Close the open Final Cut dialog before continuing.") }
        requestActivation()
        try await waitUntil(timeout: 3) { NSWorkspace.shared.frontmostApplication?.processIdentifier == self.application.processIdentifier }
        // Analyze originates in the AU's floating panel. Activate the pinned
        // project window explicitly so subsequent shortcuts target its timeline.
        // Do not raise the project over the user’s progress window.
        _ = AXUIElementSetAttributeValue(mainWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(mainWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try await waitUntil(timeout: 3) {
            guard let focused = Self.elementAttribute(self.root, kAXFocusedWindowAttribute) else { return false }
            return CFEqual(focused, self.mainWindow)
        }
    }

    func assertInputFocus() throws {
        try assertCurrentProject()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
              let focused = Self.elementAttribute(root, kAXFocusedWindowAttribute),
              isExpectedInputWindow(focused) else {
            throw FinalCutCaptureError.unavailable("\(operationStage): Final Cut lost keyboard focus. Return to its project window and Analyze again.")
        }
    }

    func isExpectedInputWindow(_ focused: AXUIElement) -> Bool {
        if CFEqual(focused, mainWindow) { return true }
        // A nested AXSheet can own input while AXFocusedWindow reports its
        // enclosing save panel. Accept only that sheet's bounded parent chain.
        var ancestor = currentSheet()
        for _ in 0..<8 {
            guard let element = ancestor else { return false }
            if CFEqual(element, focused) { return true }
            ancestor = Self.elementAttribute(element, kAXParentAttribute)
        }
        return false
    }

    func key(code: CGKeyCode, flags: CGEventFlags = []) throws {
        try assertInputFocus()
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw FinalCutCaptureError.unavailable("A keyboard event could not be created.")
        }
        down.flags = flags; up.flags = flags
        // Used for range preparation, owned menus, and explicit playhead
        // navigation. Recheck focus immediately before posting
        // through the normal keyboard route; never retry an uncertain event.
        try assertInputFocus()
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    @discardableResult func press(_ element: AXUIElement) throws -> String {
        try assertInputFocus()
        let role = string(element, kAXRoleAttribute) ?? "unknown role"
        let name = [string(element, kAXTitleAttribute), string(element, kAXDescriptionAttribute),
                    string(element, kAXIdentifierAttribute)].compactMap { $0 }.first { !$0.isEmpty } ?? "unnamed control"
        let control = "‘\(name)’ (\(role))"
        guard (attribute(element, kAXEnabledAttribute) as? NSNumber)?.boolValue != false else {
            throw FinalCutCaptureError.unavailable("\(operationStage): \(control) is disabled.")
        }
        var actionNames: CFArray?
        let lookup = AXUIElementCopyActionNames(element, &actionNames)
        guard lookup == .success else {
            throw FinalCutCaptureError.unavailable("\(operationStage): Could not read actions for \(control) (AX error \(lookup.rawValue)).")
        }
        let supported = actionNames as? [String] ?? []
        guard let action = FinalCutControlAction.preferred(from: supported) else {
            throw FinalCutCaptureError.unavailable("\(operationStage): \(control) supports neither Press nor Pick (AX error \(AXError.actionUnsupported.rawValue)).")
        }
        let result = AXUIElementPerformAction(element, action as CFString)
        guard result == .success else {
            throw FinalCutCaptureError.unavailable("\(operationStage): \(action) failed for \(control) (AX error \(result.rawValue)).")
        }
        return action
    }

    func currentSheet() -> AXUIElement? {
        var blockers: [AXUIElement] = []
        var roots = [mainWindow]
        let windows = (attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []).prefix(32)
        for window in windows where !CFEqual(window, mainWindow) {
            let values = FinalCutAXAttributes.read(window, names: [kAXRoleAttribute, kAXModalAttribute, kAXSubroleAttribute])
            let role = values[kAXRoleAttribute] as? String
            let modal = (values[kAXModalAttribute] as? NSNumber)?.boolValue
            let subrole = values[kAXSubroleAttribute] as? String
            guard role == kAXSheetRole || modal == true || subrole == kAXDialogSubrole else { continue }
            roots.append(window)
            // The AU review window remains nonblocking. Its actual child sheets
            // are still discovered below; no real sheet inherits this exemption.
            let retainedReview = knownReviewWindows.contains {
                FinalCutReviewWindowShell.isOwned(role: role, modal: modal,
                    title: string(window, kAXTitleAttribute), recordedTitle: $0.title,
                    sameElement: CFEqual(window, $0.element))
            }
            let review = modal == false ? false : (isSilentSnipReviewWindow(window) || retainedReview)
            if FinalCutWindowPolicy.isBlockingDialog(role: role, subrole: subrole, modal: modal, containsSilentSnipReview: review) {
                blockers.append(window)
            }
        }
        // Some native panels expose sheets only as direct AXChildren. Traverse
        // only sheet edges from the pinned window or identified dialog roots,
        // never the browser/search/Inspector accessibility subtree.
        let deadline = Date().addingTimeInterval(2)
        let candidates = FinalCutSheetTraversal.paths(roots: roots, equals: { CFEqual($0, $1) }, children: { element in
            let declared = (attribute(element, "AXSheets") as? [AXUIElement] ?? []).prefix(8)
            let direct = children(element).prefix(48).filter { string($0, kAXRoleAttribute) == kAXSheetRole }
            return Array(declared) + direct
        }, shouldContinue: { Date() < deadline }).filter { path in
            path.lineage.count > 1 || blockers.contains { CFEqual($0, path.element) }
        }
        // Prefer the deepest sheet belonging to the focused window. This finds
        // GoToWindow beneath its save panel even when AXFocusedWindow names the
        // parent panel. Retain an unrelated blocker if none belongs to focus.
        if let focused = Self.elementAttribute(root, kAXFocusedWindowAttribute),
           let active = candidates.filter({ $0.lineage.contains { CFEqual($0, focused) } })
            .max(by: { $0.lineage.count < $1.lineage.count }) { return active.element }
        return candidates.max(by: { $0.lineage.count < $1.lineage.count })?.element
    }

    func waitUntil(timeout: TimeInterval, context: String? = nil, predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try assertCurrentProject()
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw FinalCutCaptureError.unavailable("\(operationStage): Timed out waiting for \(context ?? operationStage). Close any unfinished export dialog, then Analyze again.")
    }

    func controlCenter(_ element: AXUIElement) -> CGPoint? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions), dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGPoint(x: point.x + dimensions.width / 2, y: point.y + dimensions.height / 2)
    }

    func selectionSnapshot() throws -> FinalCutSelectionSnapshot {
        try assertCurrentProject()
        try refreshTimeline()
        func node(_ element: AXUIElement, children childNodes: [AccessibilityNode] = []) -> AccessibilityNode {
            let values = FinalCutAXAttributes.read(element, names: [kAXRoleAttribute, kAXDescriptionAttribute,
                kAXValueAttribute, kAXSelectedAttribute, kAXEnabledAttribute])
            func text(_ name: String) -> String? { (values[name] as? String) ?? (values[name] as? NSNumber)?.stringValue }
            return AccessibilityNode(role: text(kAXRoleAttribute), identifier: nil,
                title: nil, description: text(kAXDescriptionAttribute), value: text(kAXValueAttribute),
                selected: (values[kAXSelectedAttribute] as? NSNumber)?.boolValue,
                enabled: (values[kAXEnabledAttribute] as? NSNumber)?.boolValue, children: childNodes)
        }
        let items = children(timeline)
        guard items.count <= 10_000 else { throw FinalCutCaptureError.invalidSelection("This timeline has too many accessible items.") }
        var clips: [AccessibilityNode] = []
        let deadline = Date().addingTimeInterval(5)
        for item in items {
            try Task.checkCancellation()
            guard Date() < deadline else { throw FinalCutCaptureError.unavailable("Reading the timeline selection took too long.") }
            let values = FinalCutAXAttributes.read(item, names: [kAXRoleAttribute, kAXSelectedAttribute])
            guard values[kAXRoleAttribute] as? String == kAXLayoutItemRole,
                  (values[kAXSelectedAttribute] as? NSNumber)?.boolValue == true else { continue }
            clips.append(node(item, children: children(item).prefix(100).map { node($0) }))
        }
        return try FinalCutSelectionSnapshot(projectName: projectName, timeline: node(timeline, children: clips))
    }

    /// Start and confirm the configured Share destination through host UI.
    /// Location and XML-only delivery use Apple events, without a Save panel.
}
