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
    func bindWorkflow(_ origin: WorkflowReviewOrigin) throws {
        let hosts = NSRunningApplication.runningApplications(withBundleIdentifier: FinalCutAccessibility.bundleIdentifier)
            .filter { !$0.isTerminated }
        guard hosts.count == 1, hosts[0].processIdentifier == application.processIdentifier,
              projectName == origin.projectName else { throw FinalCutCaptureError.changedProject }
        workflowOrigin = origin
        let windows = workflowReviewWindows()
        let focused = Self.elementAttribute(root, kAXFocusedWindowAttribute)
        let expectedID = "silentsnip.workflow.analyze.requested.\(origin.gesture.uuidString)"
        let window = windows.first
        let button = window.flatMap {
            find(in: $0, role: kAXButtonRole, identifier: expectedID, maxDepth: 24, maxNodes: 3000)
        }
        let foreground = NSWorkspace.shared.frontmostApplication
        let observation = WorkflowAnalyzeObservation(matchingWindows: windows.count,
            focusedMatches: focused.map { focused in window.map { CFEqual(focused, $0) } ?? false },
            hostIsActive: foreground?.processIdentifier == application.processIdentifier,
            buttonFound: button != nil,
            pendingIDMatches: button.map { string($0, kAXIdentifierAttribute) == expectedID } ?? false,
            buttonEnabled: button.flatMap { (attribute($0, kAXEnabledAttribute) as? NSNumber)?.boolValue },
            helperIsActive: foreground?.processIdentifier == NSRunningApplication.current.processIdentifier,
            foregroundBundleIdentifier: foreground?.bundleIdentifier)
        guard observation.failureReason == nil, let window else {
            workflowOrigin = nil
            throw FinalCutCaptureError.unavailable(observation.diagnostic)
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
        guard let origin = workflowOrigin,
              string(window, kAXRoleAttribute) != kAXSheetRole,
              !["save-panel", "open-panel", "GoToWindow"].contains(string(window, kAXIdentifierAttribute) ?? "") else { return false }
        return find(in: window, role: kAXButtonRole,
            identifier: "silentsnip.workflow.review.\(origin.view.uuidString)", maxDepth: 24, maxNodes: 3000) != nil
    }

    private func workflowReviewWindows() -> [AXUIElement] {
        // AXWindows can repeat the same native reference. Only CFEqual copies
        // are collapsed; two actual windows carrying a view remain ambiguous.
        var candidates = WorkflowReviewWindowIdentity.distinct(
            Array(((attribute(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []).prefix(32)),
            equals: { CFEqual($0, $1) })
        for window in [Self.elementAttribute(root, kAXFocusedWindowAttribute), retainedWorkflowWindow].compactMap({ $0 }) {
            if !candidates.contains(where: { CFEqual($0, window) }) { candidates.append(window) }
        }
        return candidates.filter { isBoundWorkflowReviewWindow($0) }
    }

    private func workflowForegroundIsOwned() -> Bool {
        WorkflowForegroundOwnership.permits(foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            hostPID: application.processIdentifier, helperPID: NSRunningApplication.current.processIdentifier)
    }

    func workflowReconnectFailure(view: UUID) -> String? {
        guard let origin = workflowOrigin, origin.view == view else { return "The requesting Workflow Extension view changed." }
        do { try assertCurrentProject() } catch { return "The original project is no longer active." }
        guard currentSheet() == nil else { return "A Final Cut dialog is blocking review." }
        guard let expected = reviewOwnership.active, (try? selectionSnapshot()) == expected else {
            return "The original selected clip is no longer available. Analyze again."
        }
        let windows = workflowReviewWindows()
        guard windows.count == 1, let window = windows.first,
              let focused = Self.elementAttribute(root, kAXFocusedWindowAttribute), CFEqual(focused, window) else {
            return "The requesting Workflow Extension is not the unique focused view."
        }
        guard workflowForegroundIsOwned() else { return "Another application owns the foreground; return to Final Cut before applying." }
        return nil
    }

    func canAuthorizeWorkflowApply(view: UUID, gesture: UUID) -> Bool {
        guard workflowReconnectFailure(view: view) == nil, let window = workflowReviewWindows().first,
              let button = find(in: window, role: kAXButtonRole,
                identifier: "silentsnip.workflow.apply.requested.\(gesture.uuidString)", maxDepth: 24, maxNodes: 3000) else { return false }
        return WorkflowReviewGesture.pending(identifier: string(button, kAXIdentifierAttribute),
            enabled: (attribute(button, kAXEnabledAttribute) as? NSNumber)?.boolValue, gesture: gesture, action: "apply")
    }

    func restoreWorkflowReview(bringToFront: Bool, document: TimelineDocument?, target: TimelineClip?) async -> String? {
        // An initial selection failure owns no review or clip to restore.
        // Preserve that actual error without inventing a reopen instruction.
        guard let expected = reviewOwnership.active else { return nil }
        let guidance = "Reopen the Silent Snip Workflow Extension and select the original clip to review these results."
        do {
            try assertCurrentProject()
            guard currentSheet() == nil else { return guidance }
            if bringToFront {
                requestActivation()
                try await waitUntil(timeout: 3, context: "Final Cut activation for workflow review") {
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == self.application.processIdentifier
                }
                if (try? selectionSnapshot()) != expected, let document, let target {
                    try await selectTimelineClip(target, document: document, restoring: expected)
                }
            }
            guard (try? selectionSnapshot()) == expected,
                  workflowForegroundIsOwned() else { return guidance }
            return try await raiseWorkflowReview() ? nil : guidance
        } catch { return "\(guidance) (\(error.localizedDescription))" }
    }

    func raiseWorkflowReview() async throws -> Bool {
        try assertCurrentProject()
        guard currentSheet() == nil, let expected = reviewOwnership.active,
              (try? selectionSnapshot()) == expected else { return false }
        let windows = workflowReviewWindows()
        guard windows.count == 1, let window = windows.first else { return false }
        requestActivation()
        _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else { return false }
        _ = AXUIElementSetAttributeValue(root, kAXFocusedWindowAttribute as CFString, window)
        _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
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
