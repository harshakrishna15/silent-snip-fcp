import AppKit
import ApplicationServices
import Foundation
import SilentSnipCore

/// Small local observations only: diagnostics never copy project names,
/// library paths, window titles, or another app's accessibility tree.
struct WorkflowAnalyzeObservation {
    let matchingWindows: Int
    let focusedMatches: Bool?
    let hostIsActive: Bool
    let buttonFound: Bool
    let pendingIDMatches: Bool
    let buttonEnabled: Bool?
    let helperIsActive: Bool
    let foregroundBundleIdentifier: String?

    init(matchingWindows: Int, focusedMatches: Bool?, hostIsActive: Bool,
         buttonFound: Bool, pendingIDMatches: Bool, buttonEnabled: Bool?,
         helperIsActive: Bool = false, foregroundBundleIdentifier: String? = nil) {
        self.matchingWindows = matchingWindows
        self.focusedMatches = focusedMatches
        self.hostIsActive = hostIsActive
        self.buttonFound = buttonFound
        self.pendingIDMatches = pendingIDMatches
        self.buttonEnabled = buttonEnabled
        self.helperIsActive = helperIsActive
        self.foregroundBundleIdentifier = foregroundBundleIdentifier
    }

    var failureReason: String? {
        if matchingWindows == 0 { return "The requesting native Workflow Extension window was not found" }
        if matchingWindows != 1 { return "More than one distinct native window matches the requesting Workflow Extension" }
        guard let focusedMatches else { return "Final Cut did not report a focused native window" }
        if !focusedMatches { return "The requesting Workflow Extension is not Final Cut's focused native window" }
        if !WorkflowForegroundOwnership.permits(hostIsActive: hostIsActive, helperIsActive: helperIsActive) {
            return "Neither Final Cut nor this Silent Snip worker owns the foreground"
        }
        if !buttonFound { return "The fresh Analyze gesture button was not found in the requesting window" }
        if !pendingIDMatches { return "The native Analyze gesture identifier changed before verification" }
        guard let buttonEnabled else { return "The native Analyze button's pending disabled state could not be read" }
        if buttonEnabled { return "The native Analyze button is enabled instead of awaiting verification" }
        return nil
    }

    var diagnostic: String {
        func flag(_ value: Bool?) -> String { value.map { $0 ? "1" : "0" } ?? "unknown" }
        var result = "Workflow Analyze verification failed: \(failureReason ?? "unknown condition"). " +
            "[matches=\(matchingWindows), focused=\(flag(focusedMatches)), hostActive=\(flag(hostIsActive)), helperActive=\(flag(helperIsActive)), " +
            "buttonFound=\(flag(buttonFound)), pendingID=\(flag(pendingIDMatches)), enabled=\(flag(buttonEnabled))]"
        if !WorkflowForegroundOwnership.permits(hostIsActive: hostIsActive, helperIsActive: helperIsActive) {
            let identifier = foregroundBundleIdentifier?.components(separatedBy: .controlCharacters).joined() ?? "unavailable"
            result += " foregroundBundle=\(String(identifier.prefix(200)))"
        }
        return result
    }
}

enum WorkflowForegroundOwnership {
    /// macOS may activate the accessory worker while delivering its URL even
    /// when the client requested a background launch. Only this exact worker
    /// process joins the pinned Final Cut host as an allowed handoff owner.
    static func permits(hostIsActive: Bool, helperIsActive: Bool) -> Bool {
        hostIsActive || helperIsActive
    }

    static func permits(foregroundPID: Int32?, hostPID: Int32, helperPID: Int32) -> Bool {
        guard let foregroundPID, hostPID > 0, helperPID > 0 else { return false }
        return permits(hostIsActive: foregroundPID == hostPID, helperIsActive: foregroundPID == helperPID)
    }
}

enum WorkflowReviewWindowIdentity {
    static func distinct<Element>(_ candidates: [Element], equals: (Element, Element) -> Bool) -> [Element] {
        var result: [Element] = []
        for candidate in candidates where !result.contains(where: { equals($0, candidate) }) { result.append(candidate) }
        return result
    }
}

extension FinalCutAXSession {
    /// Called by the initial session before activation, focus changes or Share.
    /// A broadcast URL and UUID alone do not authorize even the capture path.
    func bindWorkflow(_ origin: WorkflowReviewOrigin, action: String = "analyze") throws {
        let hosts = NSRunningApplication.runningApplications(withBundleIdentifier: FinalCutAccessibility.bundleIdentifier)
            .filter { !$0.isTerminated }
        guard hosts.count == 1, hosts[0].processIdentifier == application.processIdentifier,
              projectName == origin.projectName else { throw FinalCutCaptureError.changedProject }
        workflowOrigin = origin
        let windows = workflowReviewWindows()
        let focused = Self.elementAttribute(root, kAXFocusedWindowAttribute)
        let expectedID = "silentsnip.workflow.\(action).requested.\(origin.gesture.uuidString)"
        let window = windows.first
        let button = window.flatMap { workflowAction(in: $0, identifier: expectedID) }
        let foreground = NSWorkspace.shared.frontmostApplication
        let observation = WorkflowAnalyzeObservation(matchingWindows: windows.count,
            focusedMatches: focused.map { focused in window.map { CFEqual(focused, $0) } ?? false },
            hostIsActive: foreground?.processIdentifier == application.processIdentifier,
            buttonFound: button != nil,
            pendingIDMatches: button.map { $0.values[kAXIdentifierAttribute] as? String == expectedID } ?? false,
            buttonEnabled: button.flatMap { ($0.values[kAXEnabledAttribute] as? NSNumber)?.boolValue },
            helperIsActive: foreground?.processIdentifier == NSRunningApplication.current.processIdentifier,
            foregroundBundleIdentifier: foreground?.bundleIdentifier)
        guard observation.failureReason == nil, let window else {
            workflowOrigin = nil
            throw FinalCutCaptureError.unavailable(action == "analyze" ? observation.diagnostic :
                observation.diagnostic.replacingOccurrences(of: "Analyze", with: "Verify Existing Result"))
        }
        retainedWorkflowWindow = window
    }

    /// Temporary project/import sessions inherit presentation only. They do not
    /// reauthorize the original gesture, and fresh XML still proves every
    /// intended original or generated project before its content is accepted.
    func inheritWorkflowPresentation(from previous: FinalCutAXSession) throws {
        guard let origin = previous.workflowOrigin else { return }
        guard application.processIdentifier == previous.application.processIdentifier,
              CFEqual(mainWindow, previous.mainWindow) else { throw FinalCutCaptureError.changedProject }
        workflowOrigin = origin
        retainedWorkflowWindow = previous.retainedWorkflowWindow
    }

    func isBoundWorkflowReviewWindow(_ window: AXUIElement) -> Bool {
        guard let origin = workflowOrigin else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        return workflowLookups.matches(window, excluding: mainWindow,
            markerIdentifier: "silentsnip.workflow.review.\(origin.view.uuidString)",
            shouldContinue: { !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline })
    }

    private func workflowReviewWindows() -> [AXUIElement] {
        guard let origin = workflowOrigin else { return [] }
        // AXWindows can repeat the same native reference. Only CFEqual copies
        // are collapsed; two actual windows carrying a view remain ambiguous.
        var candidates = WorkflowReviewWindowIdentity.distinct(
            Array(((attribute(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []).prefix(32)),
            equals: { CFEqual($0, $1) })
        for window in [Self.elementAttribute(root, kAXFocusedWindowAttribute), retainedWorkflowWindow].compactMap({ $0 }) {
            if !candidates.contains(where: { CFEqual($0, window) }) { candidates.append(window) }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        return workflowLookups.matchingWindows(candidates, excluding: mainWindow,
            markerIdentifier: "silentsnip.workflow.review.\(origin.view.uuidString)",
            shouldContinue: { !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline })
    }

    private var workflowLookups: WorkflowReviewAXLookups<AXUIElement> {
        if let workflowReviewLookups { return workflowReviewLookups }
        let lookups = WorkflowReviewAXLookups<AXUIElement>(read: { FinalCutAXAttributes.read($0, names: $1) },
            children: { Self.rawAttribute($0, kAXChildrenAttribute) as? [AXUIElement] ?? [] },
            equals: { CFEqual($0, $1) })
        workflowReviewLookups = lookups
        return lookups
    }

    private func workflowAction(in window: AXUIElement, identifier: String) -> FinalCutAXMatch<AXUIElement>? {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        return workflowLookups.action(in: window, identifier: identifier,
            shouldContinue: { !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline })
    }

    func workflowReviewLookupCounters() -> [String: Int] {
        guard let counters = workflowReviewLookups?.statistics else { return [:] }
        return ["workflowReview.searches": counters.searches, "workflowReview.cacheHits": counters.cacheHits,
            "workflowReview.invalidations": counters.invalidations, "workflowReview.visitedNodes": counters.visitedNodes,
            "workflowReview.pathChecks": counters.pathChecks, "workflowReview.mainWindowSkips": counters.mainWindowSkips]
    }

    private func workflowForegroundIsOwned() -> Bool {
        WorkflowForegroundOwnership.permits(foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            hostPID: application.processIdentifier, helperPID: NSRunningApplication.current.processIdentifier)
    }

    func workflowReconnectFailure(view: UUID) -> String? {
        workflowConnection(view: view).failure
    }

    /// One synchronous observation supplies both authorization and its window.
    /// Do not carry this observation across activation, focus changes or awaits.
    private func workflowConnection(view: UUID, requireFocused: Bool = true, requireForeground: Bool = true,
                                    projectAlreadyChecked: Bool = false) -> (window: AXUIElement?, failure: String?) {
        guard let origin = workflowOrigin, origin.view == view else { return (nil, "The requesting Workflow Extension view changed.") }
        if !projectAlreadyChecked {
            do { try assertCurrentProject() } catch { return (nil, "The original project is no longer active.") }
        }
        guard currentSheet() == nil else { return (nil, "A Final Cut Pro dialog is blocking review.") }
        guard let expected = reviewOwnership.active, (try? selectionSnapshot()) == expected else {
            return (nil, "The originally selected clip is no longer available. Analyze the clip again.")
        }
        let windows = workflowReviewWindows()
        guard windows.count == 1, let window = windows.first else {
            return (nil, "The requesting Workflow Extension is not the unique focused view.")
        }
        if requireFocused {
            guard let focused = Self.elementAttribute(root, kAXFocusedWindowAttribute), CFEqual(focused, window) else {
                return (nil, "The requesting Workflow Extension is not the unique focused view.")
            }
        }
        guard !requireForeground || workflowForegroundIsOwned() else {
            return (nil, "Another application is in front. Return to Final Cut Pro before applying cuts.")
        }
        return (window, nil)
    }

    func canAuthorizeWorkflowApply(view: UUID, gesture: UUID) -> Bool {
        canAuthorizeWorkflowAction(view: view, gesture: gesture, action: "apply")
    }

    func canAuthorizeWorkflowUpdate(view: UUID, edit: UUID) -> Bool {
        canAuthorizeWorkflowAction(view: view, gesture: edit, action: "update")
    }

    func canAuthorizeWorkflowNavigation(view: UUID, gesture: UUID) -> Bool {
        let connection = workflowConnection(view: view)
        guard connection.failure == nil, let window = connection.window, let expected = reviewOwnership.active else { return false }
        let identifier = "silentsnip.workflow.navigate.requested.\(gesture.uuidString)"
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        var queue = [window]
        var cursor = 0
        var marker: AXUIElement?
        while cursor < queue.count {
            guard !Task.isCancelled, queue.count <= 600, ProcessInfo.processInfo.systemUptime < deadline else { return false }
            let element = queue[cursor]
            cursor += 1
            let values = FinalCutAXAttributes.read(element, names: [kAXRoleAttribute, kAXIdentifierAttribute])
            let id = values[kAXIdentifierAttribute] as? String
            let role = values[kAXRoleAttribute] as? String
            if id == identifier {
                guard [kAXButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole].contains(role ?? ""),
                      (attribute(element, kAXEnabledAttribute) as? NSNumber)?.boolValue == false,
                      marker.map({ CFEqual($0, element) }) != false else { return false }
                marker = element
            }
            // The cut rows cannot own the navigation control, and their
            // number should not affect this authorization scan.
            if id != "silentsnip.workflow.cut-list" {
                let descendants = children(element)
                guard descendants.count <= 600 - queue.count else { return false }
                queue.append(contentsOf: descendants)
            }
        }
        return marker != nil && (try? selectionSnapshot()) == expected && currentSheet() == nil &&
            NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier &&
            Self.elementAttribute(root, kAXFocusedWindowAttribute).map { CFEqual($0, window) } == true
    }

    /// Setting edits may settle while the user has returned to this same
    /// timeline. Automatic refresh observes only; it never activates a host or
    /// exports, and another window/app cannot authorize the pending snapshot.
    func canAuthorizeWorkflowAutomaticPreview(view: UUID, edit: UUID, settings: ReviewWireSettings,
                                             output: SilentSnipOutputMode) -> Bool {
        func connection() -> AXUIElement? {
            guard !Task.isCancelled, application.isActive,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else { return nil }
            let observed = workflowConnection(view: view, requireFocused: false, requireForeground: true)
            guard observed.failure == nil, let window = observed.window,
                  let focused = Self.elementAttribute(root, kAXFocusedWindowAttribute),
                  CFEqual(focused, window) || CFEqual(focused, mainWindow) else { return nil }
            return window
        }
        guard let window = connection() else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        let shouldContinue = { !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline }
        let marker = WorkflowAutomaticPreviewSnapshot.marker(edit: edit)
        let query = FinalCutAXQuery(role: kAXGroupRole, identifier: marker)
        func group(in window: AXUIElement) -> FinalCutAXMatch<AXUIElement>? {
            FinalCutAXSearch.find(root: window, query: query, maxDepth: 24, maxNodes: 3000,
                read: { FinalCutAXAttributes.read($0, names: $1) },
                children: { self.children($0) }, equals: { CFEqual($0, $1) }, shouldContinue: shouldContinue)
        }
        guard let pending = group(in: window),
              WorkflowAutomaticPreviewSnapshot.matches(group: pending.element, edit: edit, settings: settings,
                output: output, read: { FinalCutAXAttributes.read($0, names: $1) },
                equals: { CFEqual($0, $1) }, shouldContinue: shouldContinue),
              let freshWindow = connection(), CFEqual(freshWindow, window),
              let freshGroup = group(in: freshWindow), CFEqual(freshGroup.element, pending.element) else { return false }
        // The second connection supplies fresh project/selection/focus proof;
        // the final native marker binds the exact values read above to this edit.
        let last = FinalCutAXAttributes.read(freshGroup.element, names: [kAXRoleAttribute, kAXIdentifierAttribute])
        return shouldContinue() && last[kAXRoleAttribute] as? String == kAXGroupRole
            && last[kAXIdentifierAttribute] as? String == marker
    }

    private func canAuthorizeWorkflowAction(view: UUID, gesture: UUID, action: String) -> Bool {
        let connection = workflowConnection(view: view)
        guard connection.failure == nil, let window = connection.window,
              let button = workflowAction(in: window,
                identifier: "silentsnip.workflow.\(action).requested.\(gesture.uuidString)") else { return false }
        return WorkflowReviewGesture.pending(identifier: button.values[kAXIdentifierAttribute] as? String,
            enabled: (button.values[kAXEnabledAttribute] as? NSNumber)?.boolValue, gesture: gesture, action: action)
    }

    func restoreWorkflowReview(bringToFront: Bool, document: TimelineDocument?, target: TimelineClip?) async -> String? {
        // An initial selection failure owns no review or clip to restore.
        // Preserve that actual error without inventing a reopen instruction.
        guard let expected = reviewOwnership.active else { return nil }
        let guidance = "Reopen the Silent Snip Workflow Extension and select the original clip to review these results."
        do {
            if bringToFront {
                try assertCurrentProject()
                guard currentSheet() == nil else { return guidance }
                requestActivation()
                try await waitUntil(timeout: 3, context: "Final Cut activation for workflow review") {
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == self.application.processIdentifier
                }
                if (try? selectionSnapshot()) != expected, let document, let target {
                    try await selectTimelineClip(target, document: document, restoring: expected)
                }
            }
            guard let origin = workflowOrigin else { return guidance }
            let connection = workflowConnection(view: origin.view, requireFocused: false)
            guard connection.failure == nil, let window = connection.window,
                  raiseWorkflowReviewWindow(window) else { return guidance }
            return try await awaitWorkflowReviewPresentation() ? nil : guidance
        } catch { return "\(guidance) (\(error.localizedDescription))" }
    }

    func raiseWorkflowReview() async throws -> Bool {
        try assertCurrentProject()
        guard let origin = workflowOrigin else { return false }
        let connection = workflowConnection(view: origin.view, requireFocused: false, requireForeground: false,
            projectAlreadyChecked: true)
        guard connection.failure == nil, let window = connection.window,
              raiseWorkflowReviewWindow(window) else { return false }
        return try await awaitWorkflowReviewPresentation()
    }

    private func raiseWorkflowReviewWindow(_ window: AXUIElement) -> Bool {
        requestActivation()
        _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else { return false }
        _ = AXUIElementSetAttributeValue(root, kAXFocusedWindowAttribute as CFString, window)
        _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return true
    }

    private func awaitWorkflowReviewPresentation() async throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            // An allowed URL handoff is sufficient to authorize capture, but
            // successful presentation must actually return focus to Final Cut.
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
               workflowOrigin.map({ workflowReconnectFailure(view: $0.view) == nil }) == true { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}
