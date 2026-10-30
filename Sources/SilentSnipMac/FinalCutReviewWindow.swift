import AppKit
import ApplicationServices
import SilentSnipCore
import Foundation

extension FinalCutAXSession {
    func hasMultipleSilentSnipEffectsInInspector() -> Bool {
        guard let inspector = Self.search(mainWindow, role: kAXScrollAreaRole,
                                          description: "inspector", containersOnly: true) else { return false }
        let controls = children(inspector).prefix(300).map {
            AccessibilityNode(role: string($0, kAXRoleAttribute), identifier: nil,
                title: nil, description: string($0, kAXDescriptionAttribute), value: nil,
                selected: nil, enabled: nil, children: [])
        }
        return FinalCutReviewInspector.controllerCount(in: controls) > 1
    }

    func isSilentSnipReviewWindow(_ window: AXUIElement) -> Bool {
        guard string(window, kAXRoleAttribute) != kAXSheetRole,
              !["save-panel", "open-panel", "GoToWindow"].contains(string(window, kAXIdentifierAttribute) ?? "") else { return false }
        let identified = find(in: window, identifier: "silentsnip.status", maxDepth: 16, maxNodes: 250) != nil
            && find(in: window, role: kAXTextFieldRole, identifier: "silentsnip.setting.0", maxDepth: 16, maxNodes: 250) != nil
            && find(in: window, role: kAXButtonRole, identifier: "silentsnip.saveSettings", maxDepth: 16, maxNodes: 250) != nil
        if identified, let title = string(window, kAXTitleAttribute), !title.isEmpty,
           !knownReviewWindows.contains(where: { CFEqual($0.element, window) }) {
            knownReviewWindows.append((window, title))
            if knownReviewWindows.count > 32 { knownReviewWindows.removeFirst() }
        }
        return identified
    }

    func silentSnipReviewWindows() -> [AXUIElement] {
        (attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []).prefix(32)
            .filter { !CFEqual($0, mainWindow) && isSilentSnipReviewWindow($0) }
    }

    func suspendReviewWindow() async throws {
        try assertCurrentProject()
        var windows = silentSnipReviewWindows()
        if let focused = focusedReviewWindow(), !windows.contains(where: { CFEqual($0, focused) }) {
            windows.append(focused)
        }
        if windows.isEmpty, let expected = activeReviewSelection, let retained = reviewWindow(expected: expected) {
            windows.append(retained)
        }
        guard !windows.isEmpty else { return }
        guard windows.count == 1, let window = windows.first,
              let title = string(window, kAXTitleAttribute), !title.isEmpty else {
            throw FinalCutCaptureError.unavailable("Close extra Silent Snip review windows, then Analyze again from the intended clip.")
        }
        let selected = try? selectionSnapshot()
        if let selected, selected.clipName != title {
            throw FinalCutCaptureError.invalidSelection("The open Silent Snip review belongs to a different clip.")
        }
        let directCloseButtons = children(window).filter {
            string($0, kAXRoleAttribute) == kAXButtonRole && string($0, kAXSubroleAttribute) == kAXCloseButtonSubrole
        }
        guard let close = Self.elementAttribute(window, kAXCloseButtonAttribute)
            ?? (directCloseButtons.count == 1 ? directCloseButtons.first : nil) else {
            throw FinalCutCaptureError.unavailable("The Silent Snip effect window must close temporarily for Final Cut to export. Close it, then retry analysis.")
        }
        // Save the identity before the close call: an AX error can occur after
        // the window has already closed, in which case recovery still applies.
        suspendedReview = SuspendedReview(title: title, selection: selected)
        try press(close)
        try await waitUntil(timeout: 3, context: "the Silent Snip review window to close for export") {
            !(self.attribute(self.root, kAXWindowsAttribute) as? [AXUIElement] ?? []).contains { CFEqual($0, window) }
        }
    }

    private var activeReviewSelection: FinalCutSelectionSnapshot? { reviewOwnership.active }

    func rememberReviewSelection(_ selection: FinalCutSelectionSnapshot) throws {
        try reviewOwnership.remember(selection)
        // Capture the real editor before Share can omit it from AXWindows.
        _ = silentSnipReviewWindows()
    }

    func restoreReviewWindow() async -> String? {
        // Restoration also runs after cancellation. This bounded cleanup task
        // has its own cancellation state and never alters the timeline selection.
        await Task { @MainActor in await self.restoreReviewWindowIfSafe() }.value
    }

    func restoreReviewWindowIfSafe(bringToFront: Bool = false,
                                   document: TimelineDocument? = nil, target: TimelineClip? = nil) async -> String? {
        guard let expected = suspendedReview?.selection ?? activeReviewSelection else { return nil }
        let guidance = "To reopen the results, close any unfinished export dialog, select ‘\(expected.clipName)’ in ‘\(projectName)’, and click Silent Snip Audio’s Show effect editor button."
        var stage = "Checking the original project"
        do {
            try assertCurrentProject()
            guard currentSheet() == nil else { throw FinalCutCaptureError.unavailable("A Final Cut dialog is still open.") }
            if bringToFront {
                stage = "Activating the original project"
                requestActivation()
                try await waitUntil(timeout: 3, context: "Final Cut activation for Controls") {
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == self.application.processIdentifier
                }
                if (try? selectionSnapshot()) != expected, let document, let target {
                    try await selectTimelineClip(target, document: document, restoring: expected)
                }
            } else {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
                    return guidance
                }
            }
            func validate() throws {
                try assertCurrentProject()
                if let sheet = currentSheet() {
                    throw FinalCutCaptureError.unavailable("A blocking Final Cut dialog is open: \(string(sheet, kAXTitleAttribute) ?? "untitled").")
                }
                guard try selectionSnapshot() == expected else {
                    throw FinalCutCaptureError.invalidSelection("The original clip selection is no longer available.")
                }
            }
            stage = "Validating the retained review selection"
            try await FinalCutReviewPresentation.present(validate: validate, raiseExisting: {
                stage = "Raising the existing Controls window"
                return try await self.raiseReviewWindow(expected: expected)
            }, toggleEditor: {
                // Each toggle re-reads the Inspector; a remote view closing can
                // rebuild it. Never reuse a stale effect button or guess a sibling.
                stage = "Opening the exact Silent Snip editor"
                self.requestActivation()
                try await self.waitUntil(timeout: 3, context: "Final Cut activation for the effect editor") {
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == self.application.processIdentifier
                }
                try validate()
                if try await self.raiseReviewWindow(expected: expected) { return }
                let deadline = Date().addingTimeInterval(3)
                var requestedReveal = false
                var scrollLower = 0.0, scrollUpper = 1.0
                while Date() < deadline {
                    try Task.checkCancellation()
                    try validate()
                    if let inspector = Self.search(self.mainWindow, role: kAXScrollAreaRole,
                        description: "inspector", containersOnly: true) {
                        let controls = self.children(inspector)
                        guard controls.count <= 300 else { throw AudioControllerSettingsError.targetChanged }
                        let descriptors = controls.map {
                            AccessibilityNode(role: self.string($0, kAXRoleAttribute), identifier: nil,
                                title: self.string($0, kAXTitleAttribute), description: self.string($0, kAXDescriptionAttribute),
                                value: self.string($0, kAXValueAttribute), selected: nil,
                                enabled: (self.attribute($0, kAXEnabledAttribute) as? NSNumber)?.boolValue, children: [])
                        }
                        if let editor = FinalCutReviewInspector.editorIndex(in: descriptors) {
                            try validate()
                            // Final Cut resets the Inspector viewport after
                            // reopening a project. Offscreen effect buttons can
                            // reject AXPress. Reveal this exact controller, then
                            // resolve its fresh button again before pressing.
                            guard let point = self.controlCenter(controls[editor]) else {
                                throw FinalCutCaptureError.unavailable("The Silent Snip editor has no screen bounds.")
                            }
                            var hit: AXUIElement?
                            let visible = AXUIElementCopyElementAtPosition(self.root, Float(point.x), Float(point.y), &hit) == .success
                                && hit.map { found in CFEqual(found, controls[editor])
                                    || self.children(controls[editor]).contains(where: { CFEqual($0, found) }) } == true
                            if !visible {
                                if !requestedReveal {
                                    requestedReveal = true
                                    if AXUIElementPerformAction(controls[editor], "AXScrollToVisible" as CFString) == .success {
                                        try await Task.sleep(for: .milliseconds(150))
                                        continue
                                    }
                                }
                                guard let bar = Self.elementAttribute(inspector, kAXVerticalScrollBarAttribute)
                                    ?? self.children(inspector).first(where: { self.string($0, kAXRoleAttribute) == kAXScrollBarRole }),
                                      let current = (self.attribute(bar, kAXValueAttribute) as? NSNumber)?.doubleValue,
                                      let center = self.controlCenter(inspector), current >= 0, current <= 1 else {
                                    throw FinalCutCaptureError.unavailable("Scroll Silent Snip Audio into view in the Inspector, then reopen Controls.")
                                }
                                if point.y > center.y { scrollLower = max(scrollLower, current) }
                                else { scrollUpper = min(scrollUpper, current) }
                                let next = (scrollLower + scrollUpper) / 2
                                guard abs(next - current) > 0.001,
                                      AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: next)) == .success else {
                                    throw FinalCutCaptureError.unavailable("Final Cut could not reveal the Silent Snip editor.")
                                }
                                try await Task.sleep(for: .milliseconds(150))
                                continue
                            }
                            // AXPress targets this verified Inspector button directly.
                            // The floating AU editor may own keyboard focus; no
                            // keyboard or timeline edit is sent by this operation.
                            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == self.application.processIdentifier,
                                  AXUIElementPerformAction(controls[editor], kAXPressAction as CFString) == .success else {
                                throw FinalCutCaptureError.unavailable("Final Cut could not open the verified Silent Snip editor.")
                            }
                            return
                        }
                    }
                    try await Task.sleep(for: .milliseconds(150))
                }
                throw FinalCutCaptureError.unavailable("The selected clip’s unique Silent Snip editor button is not available.")
            }, awaitEditor: {
                stage = "Waiting for the remote Controls view"
                return try await FinalCutReviewPresentation.waitForEditor(assertProject: self.assertCurrentProject,
                    raiseWhenReady: {
                        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == self.application.processIdentifier,
                              (try? self.selectionSnapshot()) == expected else { return false }
                        return try await self.raiseReviewWindow(expected: expected)
                    })
            })
            suspendedReview = nil
            return nil
        } catch { return "\(guidance) (\(stage): \(error.localizedDescription))" }
    }

    private func reviewWindow(expected: FinalCutSelectionSnapshot) -> AXUIElement? {
        // The focused remote editor may be missing from AXWindows. Prefer it
        // after checking its native controls and exact clip title.
        if let focused = focusedReviewWindow(), string(focused, kAXTitleAttribute) == expected.clipName { return focused }
        var candidates = silentSnipReviewWindows()
        for known in knownReviewWindows where !candidates.contains(where: { CFEqual($0, known.element) }) {
            // Retaining the reference never substitutes for fresh native view
            // identity, clip selection, project, or Apply-gesture validation.
            if known.title == expected.clipName, isSilentSnipReviewWindow(known.element) { candidates.append(known.element) }
        }
        let matches = candidates.filter { string($0, kAXTitleAttribute) == expected.clipName }
        return matches.count == 1 ? matches[0] : nil
    }

    private func raiseReviewWindow(expected: FinalCutSelectionSnapshot) async throws -> Bool {
        try assertCurrentProject()
        guard currentSheet() == nil, try selectionSnapshot() == expected,
              let window = reviewWindow(expected: expected) else { return false }
        // Finding an existing window is insufficient: it can be behind the
        // timeline. Verify native focus after Raise before reporting success.
        requestActivation()
        try await waitUntil(timeout: 2, context: "Final Cut activation before raising Controls") {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == self.application.processIdentifier
        }
        try assertCurrentProject()
        guard currentSheet() == nil, try selectionSnapshot() == expected else { return false }
        _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else { return false }
        _ = AXUIElementSetAttributeValue(root, kAXFocusedWindowAttribute as CFString, window)
        _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            try Task.checkCancellation()
            try assertCurrentProject()
            guard currentSheet() == nil, try selectionSnapshot() == expected else { return false }
            if let focused = focusedReviewWindow(), CFEqual(focused, window),
               NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// A late Share Open Document can activate the accessory helper after the
    /// review was presented. Only the current review's exact final export may
    /// undo that activation. This path never selects clips or toggles editors.
    func raiseReviewAfterLateCompletion(directory: URL) async {
        guard directory.standardizedFileURL == lastXMLShareDirectory,
              let expected = activeReviewSelection, (try? assertCurrentProject()) != nil,
              currentSheet() == nil, (try? selectionSnapshot()) == expected else { return }
        _ = try? await raiseReviewWindow(expected: expected)
    }

    /// A UUID alone does not establish ownership. Require its native control
    /// inside the sole Silent Snip view on the pinned project and selected clip.
    func canReconnectReview(view: UUID) -> Bool {
        reviewReconnectFailure(view: view) == nil
    }

    func reviewReconnectFailure(view: UUID) -> String? {
        guard let expected = activeReviewSelection else { return "No retained review selection." }
        do { try assertCurrentProject() } catch { return "The original project is no longer active: \(error.localizedDescription)" }
        guard currentSheet() == nil else { return "A Final Cut dialog is blocking the review." }
        guard (try? selectionSnapshot()) == expected else { return "The original audio clip selection is not available." }
        guard let window = focusedReviewWindow(),
              string(window, kAXTitleAttribute) == expected.clipName else { return "The original clip's focused Controls window is not available." }
        guard find(in: window, role: kAXButtonRole,
            identifier: "silentsnip.review.reconnect.\(view.uuidString)", maxDepth: 16, maxNodes: 250) != nil else {
            return "The requesting Controls view could not be verified."
        }
        return nil
    }

    func focusedReviewWindow() -> AXUIElement? {
        // Final Cut can retain hidden AU editors or omit a reopened remote
        // editor from AXWindows after Share. AXFocusedWindow directly names
        // the native window receiving this user's edit or button gesture.
        guard let window = Self.elementAttribute(root, kAXFocusedWindowAttribute),
              !CFEqual(window, mainWindow), isSilentSnipReviewWindow(window) else { return nil }
        return window
    }

    func recoveryReviewWindow(clipName: String) -> AXUIElement? {
        FinalCutReviewPresentation.focusedEditor(focused: focusedReviewWindow(), listed: silentSnipReviewWindows(),
            matches: { self.isSilentSnipReviewWindow($0) && self.string($0, kAXTitleAttribute) == clipName },
            equals: { CFEqual($0, $1) })
    }

    /// The request UUID travels over a broadcast channel. An Apply message is
    /// accepted only while the selected clip's sole Controls view exposes the
    /// fresh gesture identifier set by its Apply button action.
    func canAuthorizeApply(view: UUID, gesture: UUID) -> Bool {
        guard canReconnectReview(view: view), let window = focusedReviewWindow(),
              let button = find(in: window, role: kAXButtonRole,
                  identifier: "silentsnip.apply.requested.\(gesture.uuidString)", maxDepth: 16, maxNodes: 250) else { return false }
        return FinalCutApplyGesture.isPending(identifier: string(button, kAXIdentifierAttribute),
            enabled: (attribute(button, kAXEnabledAttribute) as? NSNumber)?.boolValue, gesture: gesture)
    }

    func canAuthorizePreview(view: UUID, edit: UUID) -> Bool {
        guard canReconnectReview(view: view), let window = focusedReviewWindow(),
              let button = find(in: window, role: kAXButtonRole,
                  identifier: "silentsnip.preview.requested.\(edit.uuidString)", maxDepth: 16, maxNodes: 250) else { return false }
        return (attribute(button, kAXEnabledAttribute) as? NSNumber)?.boolValue == false
    }

    func makePreviewReader() -> FinalCutPreviewReader? {
        guard let expected = activeReviewSelection else { return nil }
        return FinalCutPreviewReader(pid: application.processIdentifier, root: root,
            mainWindow: mainWindow, projectName: projectName, expected: expected)
    }

}
