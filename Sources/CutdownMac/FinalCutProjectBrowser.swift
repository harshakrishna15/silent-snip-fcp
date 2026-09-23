import AppKit
import ApplicationServices
import CutdownCore
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

extension FinalCutAXSession {
    func openImportedProject(named name: String, importedXML: URL, replacement: XMLReplacementTarget? = nil,
                             acceptReplacement: Bool = false) async throws -> FinalCutAXSession {
        try await waitForImportCompletion(named: name, importedXML: importedXML, replacement: replacement, acceptReplacement: acceptReplacement)
        if let replacement {
            // Replace closes the old timeline and may expose a previous project
            // or an empty timeline. Re-pin solely to navigate the browser, then
            // return a normal session; semantic verification precedes writes.
            let browserSession = try FinalCutAXSession(allowEmptyTimeline: true)
            try browserSession.assertReplacementEvent(replacement)
            _ = try await browserSession.selectBrowserProject(named: name)
            try await browserSession.pressMenu(path: ["Clip", "Open Clip"], openingProject: name)
            return try await browserSession.waitForProject(named: name)
        }
        if let current = try? FinalCutAXSession(), current.projectName == name { return current }
        _ = try await selectBrowserProject(named: name)
        try await pressMenu(path: ["Clip", "Open Clip"], openingProject: name)
        return try await waitForProject(named: name)
    }

    private func waitForImportCompletion(named name: String, importedXML: URL, replacement: XMLReplacementTarget?,
                                         acceptReplacement: Bool) async throws {
        let started = Date()
        var replacementAccepted = false
        var readiness = FinalCutImportReadiness()
        var browserReveal = FinalCutImportBrowserReveal()
        var observed: [FinalCutImportDialog] = []
        var acknowledged: [AXUIElement] = []
        var lastDialog: FinalCutImportDialog?
        let reportURL = importedXML.deletingLastPathComponent().appendingPathComponent("Import-Dialogs.json")
        while Date().timeIntervalSince(started) < 30 {
            try Task.checkCancellation()
            guard !application.isTerminated else { throw FinalCutCaptureError.changedProject }
            // Import may itself open the result. Permit only the original or
            // our exact generated project; don't repin to another user project.
            let control = Self.search(mainWindow, identifier: "editor/timelineContainer/toolbar/projectNamePopUpButton", containersOnly: true)
            let currentName = control.flatMap { string($0, kAXTitleAttribute) }
            if replacement == nil, let currentName, currentName != projectName && currentName != name { throw FinalCutCaptureError.changedProject }
            let panel = currentSheet()
            if let panel {
                let elements = importElements(in: panel)
                let buttons = elements.filter { string($0, kAXRoleAttribute) == kAXButtonRole }
                let dialog = FinalCutImportDialog(title: string(panel, kAXTitleAttribute) ?? "Untitled Final Cut dialog",
                    text: elements.flatMap { element -> [String] in
                        guard [kAXStaticTextRole, kAXRowRole, kAXTextAreaRole].contains(string(element, kAXRoleAttribute) ?? "") else { return [] }
                        return [string(element, kAXTitleAttribute), string(element, kAXValueAttribute), string(element, kAXDescriptionAttribute)]
                            .compactMap { $0 }.filter { !$0.isEmpty }
                    }, buttons: buttons.compactMap { string($0, kAXTitleAttribute) })
                lastDialog = dialog
                if observed.last != dialog {
                    observed.append(dialog)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(observed).write(to: reportURL, options: .atomic)
                }
                if let replacement, acceptReplacement, !replacementAccepted,
                   currentName == replacement.projectName,
                   (try? assertReplacementEvent(replacement)) != nil,
                   dialog.isReplacementConfirmation(libraryName: replacement.libraryURL.deletingPathExtension().lastPathComponent),
                   let replace = buttons.first(where: { string($0, kAXTitleAttribute) == "Replace" }),
                   (attribute(replace, kAXEnabledAttribute) as? NSNumber)?.boolValue == true {
                    application.activate(options: [])
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
                       let focused = Self.elementAttribute(root, kAXFocusedWindowAttribute), isExpectedInputWindow(focused),
                       let current = currentSheet(), CFEqual(current, panel) {
                        // This delivery contains exactly one project, in its
                        // original event/library, after a fresh baseline check.
                        replacementAccepted = true
                        guard AXUIElementPerformAction(replace, kAXPressAction as CFString) == .success else {
                            throw FinalCutCaptureError.unavailable("Final Cut could not confirm project replacement. Check the result before retrying verification.")
                        }
                    }
                }
                if dialog.isCompletedWarning(for: importedXML.lastPathComponent), buttons.count == 1,
                   !acknowledged.contains(where: { CFEqual($0, panel) }),
                   let ok = buttons.first, (attribute(ok, kAXEnabledAttribute) as? NSNumber)?.boolValue == true {
                    application.activate(options: [])
                    // Use only this identified panel's OK action, once. Import
                    // navigation intentionally cannot use assertCurrentProject.
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
                       let focused = Self.elementAttribute(root, kAXFocusedWindowAttribute), isExpectedInputWindow(focused),
                       let current = currentSheet(), CFEqual(current, panel) {
                        acknowledged.append(panel)
                        let result = AXUIElementPerformAction(ok, kAXPressAction as CFString)
                        guard result == .success else {
                            throw FinalCutCaptureError.unavailable("Could not acknowledge the completed XML import warning (AX error \(result.rawValue)). Warning details: \(reportURL.path)")
                        }
                    }
                }
            } else { lastDialog = nil }
            let browser = Self.search(mainWindow, role: kAXScrollAreaRole, description: "organizer", containersOnly: true)
                ?? Self.search(mainWindow, role: kAXScrollAreaRole, description: "Organizer filmlist scroll view", containersOnly: true)
            let visible = currentName == name || browser.map { browser in
                importElements(in: browser).contains { element in
                    [kAXImageRole, kAXTextFieldRole].contains(string(element, kAXRoleAttribute) ?? "")
                        && [string(element, kAXTitleAttribute), string(element, kAXDescriptionAttribute), string(element, kAXValueAttribute)].contains(name)
                }
            } == true
            // Some deliveries complete without leaving the confirmation visible
            // to us. Closing the original timeline is also an import transition;
            // the subsequent export must still prove a new UID and exact edits.
            let replacementTransition = replacement != nil && currentName != name
            if readiness.observe(projectVisible: visible, hasDialog: panel != nil, elapsed: Date().timeIntervalSince(started),
                                 awaitingReplacement: acceptReplacement, replacementConfirmed: replacementAccepted,
                                 originalTimelineClosed: replacementTransition) { return }
            if replacement == nil, browserReveal.observe(projectVisible: visible, originalProjectCurrent: currentName == projectName,
                                     hasDialog: panel != nil, elapsed: Date().timeIntervalSince(started)) {
                try await activate()
                try await pressMenu(path: ["Window", "Go To", "Libraries"])
                // Some list layouts omit project names from the exposed AX
                // rows. Use the same filmstrip representation as selection.
                if let toggle = find(in: mainWindow, role: kAXButtonRole, description: "Show clips in filmstrip view") {
                    try press(toggle)
                }
                // Re-read the project and dialog state on the next iteration.
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        if let dialog = lastDialog {
            throw FinalCutCaptureError.unavailable("Verification is blocked by Final Cut’s ‘\(dialog.title)’ dialog. Close it before checking the existing result. Details: \(reportURL.path)")
        }
        throw FinalCutCaptureError.unavailable("Final Cut did not finish presenting the imported project ‘\(name)’ within 30 seconds. Open the result in its event before retrying verification.")
    }

    /// Reveal the current project before delivery. Replacement by name must
    /// never target duplicate browser items or an event in another library.
    func prepareReplacementBrowser(_ target: XMLReplacementTarget) async throws {
        guard projectName == target.projectName else { throw FinalCutCaptureError.changedProject }
        try await activate()
        try await pressMenu(path: ["File", "Reveal Project in Browser"])
        try await waitUntil(timeout: 5, context: "the replacement's original event") {
            (try? self.assertReplacementEvent(target)) != nil
        }
        _ = try await selectBrowserProject(named: target.projectName)
        try await focusTimeline()
    }

    private func assertReplacementEvent(_ target: XMLReplacementTarget) throws {
        guard let sidebar = Self.search(mainWindow, role: kAXOutlineRole, description: "Event media sidebar", containersOnly: true) else {
            throw FinalCutCaptureError.unavailable("Show the original project’s event in the Libraries sidebar before replacement verification.")
        }
        var libraryPath: String?
        var matches = 0
        for row in children(sidebar) where string(row, kAXRoleAttribute) == kAXRowRole {
            let fields = importElements(in: row).filter { string($0, kAXRoleAttribute) == kAXTextFieldRole }
            for field in fields {
                if let help = string(field, kAXHelpAttribute),
                   let path = help.split(separator: "\n").last, path.hasSuffix(".fcpbundle"), path.hasPrefix("/") {
                    libraryPath = URL(fileURLWithPath: String(path)).standardizedFileURL.path
                }
            }
            if (attribute(row, kAXSelectedAttribute) as? NSNumber)?.boolValue == true,
               libraryPath == target.libraryURL.path,
               fields.contains(where: { string($0, kAXValueAttribute) == target.eventName }) { matches += 1 }
        }
        guard matches == 1 else {
            throw FinalCutCaptureError.unavailable("Select the ‘\(target.eventName)’ event in ‘\(target.libraryURL.deletingPathExtension().lastPathComponent)’ before verifying its replacement project.")
        }
    }

    /// Restrict traversal to the import panel/browser. Never inspect field
    /// editors, search widgets, Inspector or the entire host accessibility tree.
    private func importElements(in element: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(element, 0)]
        var cursor = 0
        let deadline = Date().addingTimeInterval(2)
        let leaves = Set([kAXTextFieldRole, kAXTextAreaRole, kAXStaticTextRole, kAXButtonRole, kAXImageRole])
        while cursor < queue.count, cursor < 600, Date() < deadline {
            let (item, depth) = queue[cursor]; cursor += 1
            result.append(item)
            guard depth < 12, !leaves.contains(string(item, kAXRoleAttribute) ?? "") else { continue }
            for child in children(item) where queue.count < 600 { queue.append((child, depth + 1)) }
        }
        return result
    }

    /// Selection is shared by opening and cleanup. Only one exact browser item
    /// may be selected; a focused timeline is never a deletion target.
    private func selectBrowserProject(named name: String) async throws -> AXUIElement {
        try await activate()
        func projectImage() -> AXUIElement? {
            guard let browser = find(in: mainWindow, role: kAXScrollAreaRole, description: "organizer"),
                  let image = find(in: browser, role: kAXImageRole, title: name)
                    ?? find(in: browser, role: kAXImageRole, description: name) else { return nil }
            return image
        }
        func visibleProjectImage() -> AXUIElement? {
            guard let image = projectImage(), let point = controlCenter(image) else { return nil }
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &hit) == .success,
                  let hit, CFEqual(hit, image) || children(image).contains(where: { CFEqual($0, hit) }) else { return nil }
            return image
        }
        var image = projectImage()
        if image == nil {
            try await pressMenu(path: ["Window", "Go To", "Libraries"])
            if let toggle = find(in: mainWindow, role: kAXButtonRole, description: "Show clips in filmstrip view") {
                try press(toggle)
            }
        }
        try await waitUntil(timeout: 15, context: "imported project in the browser") {
            image = projectImage()
            return image != nil
        }
        guard let image,
              let item = Self.elementAttribute(image, kAXParentAttribute),
              let container = Self.elementAttribute(item, kAXParentAttribute) else {
            throw FinalCutCaptureError.unavailable("The imported project is not visible in the browser.")
        }
        let matches = children(container).filter { candidate in
            children(candidate).contains {
                string($0, kAXRoleAttribute) == kAXImageRole
                    && (string($0, kAXTitleAttribute) == name || string($0, kAXDescriptionAttribute) == name)
            }
        }
        guard matches.count == 1, CFEqual(matches[0], item) else {
            throw FinalCutCaptureError.unavailable("The imported project name is ambiguous in the browser.")
        }
        try assertInputFocus()
        // Use AX selection when supported. The single-click fallback establishes
        // selection and browser focus; never rely on a burst of double-clicks.
        let selectedDirectly = AXUIElementSetAttributeValue(container, kAXSelectedChildrenAttribute as CFString,
                                                           [item] as CFArray) == .success
        let focusedDirectly = AXUIElementSetAttributeValue(container, kAXFocusedAttribute as CFString,
                                                          kCFBooleanTrue) == .success
        func browserHasFocus() -> Bool {
            var focused = Self.elementAttribute(root, kAXFocusedUIElementAttribute)
            for _ in 0..<8 {
                guard let current = focused else { return false }
                if CFEqual(current, container) { return true }
                focused = Self.elementAttribute(current, kAXParentAttribute)
            }
            return false
        }
        if !selectedDirectly || !focusedDirectly || !browserHasFocus() {
            // Imported projects can be outside the scroll viewport. Reveal only
            // this exact item when the host exposes the native AX action.
            for element in [item, image] {
                var actions: CFArray?
                if AXUIElementCopyActionNames(element, &actions) == .success,
                   (actions as? [String] ?? []).contains("AXScrollToVisible") {
                    _ = AXUIElementPerformAction(element, "AXScrollToVisible" as CFString)
                }
            }
            // Resolve the hit again after AX changes; a floating effect window
            // must never receive the fallback click.
            guard let visible = visibleProjectImage(), CFEqual(visible, image), let point = controlCenter(image) else {
                throw FinalCutCaptureError.unavailable("The imported project is covered by another window. Move the effect window away from the browser and Analyze again.")
            }
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
                    throw FinalCutCaptureError.unavailable("Could not select the imported project.")
                }
                event.setIntegerValueField(.mouseEventClickState, value: 1)
                event.post(tap: .cghidEventTap)
            }
        }
        try await waitUntil(timeout: 3, context: "the exact imported project selection") {
            guard let selected = self.attribute(container, kAXSelectedChildrenAttribute) as? [AXUIElement] else { return false }
            return selected.count == 1 && CFEqual(selected[0], item) && browserHasFocus()
        }
        return container
    }

    func removeAnalysisProject(_ isolated: IsolatedAudioProject, verifiedData: Data) async throws {
        try AnalysisProjectCleanup.validate(isolated: isolated, delivered: verifiedData, currentProject: projectName)
        try await activate()
        try await pressMenu(path: ["File", "Reveal Project in Browser"])
        try await waitUntil(timeout: 5, context: "the analysis project's original event") {
            (try? self.assertReplacementEvent(isolated.destination)) != nil
        }
        let container = try await selectBrowserProject(named: isolated.name)
        try await pressMenu(path: ["File", "Move to Trash"])
        func projectStillVisible() -> Bool {
            self.children(container).contains { candidate in
                self.children(candidate).contains {
                    self.string($0, kAXRoleAttribute) == kAXImageRole &&
                    (self.string($0, kAXTitleAttribute) == isolated.name || self.string($0, kAXDescriptionAttribute) == isolated.name)
                }
            }
        }
        try await waitUntil(timeout: 5, context: "the temporary project's Trash confirmation") {
            self.currentSheet() != nil || !projectStillVisible()
        }
        if let panel = currentSheet() {
            let elements = importElements(in: panel)
            let message = elements.filter { string($0, kAXRoleAttribute) == kAXStaticTextRole }
                .flatMap { [string($0, kAXValueAttribute), string($0, kAXTitleAttribute)] }
                .compactMap { $0 }.joined(separator: " ")
            let buttons = elements.filter { string($0, kAXRoleAttribute) == kAXButtonRole }
            guard message.contains("Media Moving to Trash"),
                  message.contains("External files remain where they are."),
                  buttons.count == 2,
                  buttons.contains(where: { string($0, kAXTitleAttribute) == "Cancel" }),
                  let confirm = buttons.first(where: { string($0, kAXTitleAttribute) == "OK" }) else {
                throw FinalCutCaptureError.unavailable("Final Cut showed an unexpected Trash dialog; the temporary project was left for review.")
            }
            try press(confirm)
        }
        try await waitUntil(timeout: 5, context: "temporary analysis project removal") {
            !projectStillVisible()
        }
        try await focusTimeline()
    }

    func returnToPreviousProject(named name: String) async throws -> FinalCutAXSession {
        if let current = try? FinalCutAXSession(), current.projectName == name { return current }
        try await activate()
        guard let back = find(in: mainWindow, role: kAXButtonRole, description: "Timeline Navigation Back") else {
            throw FinalCutCaptureError.unavailable("Could not return to the original project.")
        }
        try press(back)
        return try await waitForProject(named: name)
    }

    /// Project navigation intentionally replaces the pinned timeline. Ordinary
    /// waitUntil retains its strict original-project check for all other actions.
    private func waitForProject(named name: String) async throws -> FinalCutAXSession {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            try Task.checkCancellation()
            guard !application.isTerminated else { throw FinalCutCaptureError.changedProject }
            if let current = try? FinalCutAXSession() {
                guard current.application.processIdentifier == application.processIdentifier,
                      CFEqual(current.mainWindow, mainWindow) else { throw FinalCutCaptureError.changedProject }
                if current.projectName == name { return current }
                guard current.projectName == projectName else { throw FinalCutCaptureError.changedProject }
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw FinalCutCaptureError.unavailable("Final Cut did not open the requested project ‘\(name)’.")
    }

}
