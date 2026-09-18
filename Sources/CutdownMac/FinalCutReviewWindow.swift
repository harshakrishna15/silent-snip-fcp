import AppKit
import ApplicationServices
import CutdownCore
import Foundation

extension FinalCutAXSession {
    func isCutdownReviewWindow(_ window: AXUIElement) -> Bool {
        guard string(window, kAXRoleAttribute) != kAXSheetRole,
              string(window, kAXSubroleAttribute) == kAXDialogSubrole,
              (attribute(window, kAXModalAttribute) as? NSNumber)?.boolValue != true else { return false }
        return (find(in: window, role: kAXTableRole, identifier: "cutdown.review.cuts", maxDepth: 16, maxNodes: 250) != nil
            || find(in: window, role: kAXTextAreaRole, identifier: "cutdown.review.results", maxDepth: 16, maxNodes: 250) != nil)
            && (find(in: window, role: kAXButtonRole, title: "Analyze", maxDepth: 16, maxNodes: 250) != nil
                || find(in: window, role: kAXButtonRole, title: "Analyze Again", maxDepth: 16, maxNodes: 250) != nil)
    }

    func cutdownReviewWindows() -> [AXUIElement] {
        (attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []).prefix(32)
            .filter { !CFEqual($0, mainWindow) && isCutdownReviewWindow($0) }
    }

    func suspendReviewWindow() async throws {
        try assertCurrentProject()
        let windows = cutdownReviewWindows()
        guard !windows.isEmpty else { return }
        guard windows.count == 1, let window = windows.first,
              let title = string(window, kAXTitleAttribute), !title.isEmpty else {
            throw FinalCutCaptureError.unavailable("Close extra Cutdown review windows, then Analyze again from the intended clip.")
        }
        let selected = try? selectionSnapshot()
        if let selected, selected.clipName != title {
            throw FinalCutCaptureError.invalidSelection("The open Cutdown review belongs to a different clip.")
        }
        let directCloseButtons = children(window).filter {
            string($0, kAXRoleAttribute) == kAXButtonRole && string($0, kAXSubroleAttribute) == kAXCloseButtonSubrole
        }
        guard let close = Self.elementAttribute(window, kAXCloseButtonAttribute)
            ?? (directCloseButtons.count == 1 ? directCloseButtons.first : nil) else {
            throw FinalCutCaptureError.unavailable("The Cutdown effect window must close temporarily for Final Cut to export. Close it, then retry analysis.")
        }
        // Save the identity before the close call: an AX error can occur after
        // the window has already closed, in which case recovery still applies.
        suspendedReview = SuspendedReview(title: title, selection: selected)
        try press(close)
        try await waitUntil(timeout: 3, context: "the Cutdown review window to close for export") {
            !(self.attribute(self.root, kAXWindowsAttribute) as? [AXUIElement] ?? []).contains { CFEqual($0, window) }
        }
    }

    private var activeReviewSelection: FinalCutSelectionSnapshot? { reviewOwnership.active }

    func rememberReviewSelection(_ selection: FinalCutSelectionSnapshot) throws {
        try reviewOwnership.remember(selection)
    }

    func restoreReviewWindow() async -> String? {
        // Restoration also runs after cancellation. This bounded cleanup task
        // has its own cancellation state and never alters the timeline selection.
        await Task { @MainActor in await self.restoreReviewWindowIfSafe() }.value
    }

    func restoreReviewWindowIfSafe() async -> String? {
        guard let expected = suspendedReview?.selection ?? activeReviewSelection else { return nil }
        let suspended = suspendedReview ?? SuspendedReview(title: expected.clipName, selection: expected)
        let guidance = "To reopen the results, close any unfinished export dialog, select ‘\(suspended.title)’ in ‘\(projectName)’, and click Cutdown Audio’s Show effect editor button."
        do {
            try assertCurrentProject()
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
                return guidance
            }
            guard let expected = suspended.selection else { return guidance }
            let existing = cutdownReviewWindows()
            if !existing.isEmpty {
                guard existing.count == 1, string(existing[0], kAXTitleAttribute) == suspended.title,
                      try selectionSnapshot() == expected else { return guidance }
                suspendedReview = nil
                return nil
            }
            try await activate()
            try await focusTimeline()
            guard try selectionSnapshot() == expected,
                  let inspector = Self.search(mainWindow, role: kAXScrollAreaRole, description: "inspector", containersOnly: true) else {
                return guidance
            }
            let controls = children(inspector)
            guard controls.count <= 300 else { return guidance }
            let descriptors = controls.map {
                AccessibilityNode(role: string($0, kAXRoleAttribute), identifier: nil,
                    title: string($0, kAXTitleAttribute), description: string($0, kAXDescriptionAttribute),
                    value: string($0, kAXValueAttribute), selected: nil,
                    enabled: (attribute($0, kAXEnabledAttribute) as? NSNumber)?.boolValue, children: [])
            }
            guard let editor = FinalCutReviewInspector.editorIndex(in: descriptors) else { return guidance }
            try assertCurrentProject()
            guard try selectionSnapshot() == expected else { return guidance }
            try press(controls[editor])
            try await waitUntil(timeout: 3, context: "the Cutdown review window to reopen") {
                let opened = self.cutdownReviewWindows()
                return opened.count == 1 && self.string(opened[0], kAXTitleAttribute) == suspended.title
            }
            suspendedReview = nil
            return nil
        } catch {
            return guidance
        }
    }

    /// A UUID alone does not establish ownership. Require its native control
    /// inside the sole Cutdown view on the pinned project and selected clip.
    func canReconnectReview(view: UUID) -> Bool {
        guard let expected = activeReviewSelection,
              (try? assertCurrentProject()) != nil, currentSheet() == nil,
              (try? selectionSnapshot()) == expected else { return false }
        let windows = cutdownReviewWindows()
        guard windows.count == 1, let window = windows.first,
              string(window, kAXTitleAttribute) == expected.clipName else { return false }
        return find(in: window, role: kAXButtonRole,
            identifier: "cutdown.review.reconnect.\(view.uuidString)", maxDepth: 16, maxNodes: 250) != nil
    }

    func makePreviewReader() -> FinalCutPreviewReader? {
        guard let expected = activeReviewSelection else { return nil }
        return FinalCutPreviewReader(pid: application.processIdentifier, root: root,
            mainWindow: mainWindow, projectName: projectName, expected: expected)
    }

}
