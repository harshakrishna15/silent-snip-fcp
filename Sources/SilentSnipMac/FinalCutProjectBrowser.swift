import AppKit
import ApplicationServices
import SilentSnipCore
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum FinalCutBrowserSelection {
    /// An acknowledged selection can settle in the caller's existing wait.
    /// Even after a setter error, the exact readback can establish selection
    /// or focus without moving the pointer.
    static func canSettleWithoutPointer(hasSelection: () -> Bool, hasFocus: () -> Bool,
                                       select: () -> Bool, focus: () -> Void) -> Bool {
        let selectionRequested = !hasSelection() && select()
        if !hasFocus() { focus() }
        return (selectionRequested || hasSelection()) && hasFocus()
    }
}

extension FinalCutAXSession {
    func openImportedProject(named name: String, importedXML: URL, replacement: XMLReplacementTarget? = nil,
                             acceptReplacement: Bool = false, originalTimelineSignature: [String]? = nil) async throws -> FinalCutAXSession {
        try await waitForImportCompletion(named: name, importedXML: importedXML, replacement: replacement,
                                          acceptReplacement: acceptReplacement, originalTimelineSignature: originalTimelineSignature)
        if let replacement {
            // Replace closes the old timeline and may expose a previous project
            // or an empty timeline. Re-pin solely to navigate the browser, then
            // return a normal session; semantic verification precedes writes.
            let browserSession = try await FinalCutAXSession.forImport(allowImportDialog: false, allowEmptyTimeline: true, inheritingWorkflowFrom: self)
            guard browserSession.application.processIdentifier == application.processIdentifier,
                  CFEqual(browserSession.mainWindow, mainWindow) else { throw FinalCutCaptureError.changedProject }
            try browserSession.assertReplacementEvent(replacement)
            // Retry can start with the result already open. Reopening it only
            // rebuilds the toolbar and invalidates this session. A fresh export
            // still has to prove the replacement UID, edits and settings.
            if browserSession.projectName == name {
                let current = try FinalCutAXSession(inheritingWorkflowFrom: self)
                try await current.activate()
                try await current.suspendReviewWindow()
                return current
            }
            do {
                _ = try await browserSession.selectBrowserProject(named: name)
                try await browserSession.pressMenu(path: ["Clip", "Open Clip"], openingProject: name)
                return try await browserSession.waitForProject(named: name)
            } catch FinalCutCaptureError.changedProject {
                // Final Cut can present the exact imported result between
                // sampling its previous timeline and navigating the browser.
                // Accept only that same-window, same-process handoff in the
                // original event; do not repeat navigation or import delivery.
                let current = try await FinalCutAXSession.forImport(allowImportDialog: false, allowEmptyTimeline: false, inheritingWorkflowFrom: self)
                guard current.application.processIdentifier == application.processIdentifier,
                      CFEqual(current.mainWindow, mainWindow), current.projectName == name else {
                    throw FinalCutCaptureError.changedProject
                }
                try current.assertReplacementEvent(replacement)
                try await current.activate()
                try await current.suspendReviewWindow()
                return current
            }
        }
        // Import can replace the toolbar and briefly leave an empty timeline.
        // Re-pin after delivery rather than using pre-import AX objects for
        // browser navigation. Never navigate from an unrelated project/window.
        let browserSession = try await FinalCutAXSession.forImport(allowImportDialog: false, allowEmptyTimeline: true, inheritingWorkflowFrom: self)
        guard browserSession.application.processIdentifier == application.processIdentifier,
              CFEqual(browserSession.mainWindow, mainWindow),
              FinalCutImportTimeline.permits(browserSession.projectName, original: projectName, imported: name) else {
            throw FinalCutCaptureError.changedProject
        }
        if browserSession.projectName == name { return try FinalCutAXSession(inheritingWorkflowFrom: self) }
        do {
            _ = try await browserSession.selectBrowserProject(named: name)
            try await browserSession.pressMenu(path: ["Clip", "Open Clip"], openingProject: name)
        } catch {
            // A first import can open the exact generated project while we
            // navigate, including between a menu-state check and its error.
            // Accept only the exact same-window destination after re-pinning;
            // no navigation is repeated and semantic XML verification follows.
            try Task.checkCancellation()
            if let current = try? FinalCutAXSession(inheritingWorkflowFrom: self),
               current.application.processIdentifier == application.processIdentifier,
               CFEqual(current.mainWindow, mainWindow), current.projectName == name { return current }
            throw error
        }
        return try await browserSession.waitForProject(named: name)
    }

    private func waitForImportCompletion(named name: String, importedXML: URL, replacement: XMLReplacementTarget?,
                                         acceptReplacement: Bool, originalTimelineSignature: [String]?) async throws {
        let started = Date()
        var replacementAccepted = false
        var timelineTransitionObserved = false
        var readiness = FinalCutImportReadiness()
        var browserReveal = FinalCutImportBrowserReveal()
        var observed: [FinalCutImportDialog] = []
        var acknowledged: [AXUIElement] = []
        var lastDialog: FinalCutImportDialog?
        let reportURL = importedXML.deletingLastPathComponent().appendingPathComponent("Import-Dialogs.json")
        let browserLookups = FinalCutImportBrowserLookups(root: mainWindow,
            read: { FinalCutAXAttributes.read($0, names: $1) },
            children: { self.children($0) }, equals: { CFEqual($0, $1) })
        var polls = 0, observations = 0, nodeReads = 0, unknownObservations = 0, modalBrowserSkips = 0
        var outcome = "failed"
        defer {
            var counters = browserLookups.counters
            counters["polls"] = polls; counters["observations"] = observations; counters["nodeReads"] = nodeReads
            counters["unknownObservations"] = unknownObservations
            counters["browser.modalSkips"] = modalBrowserSkips
            let report: [String: Any] = ["outcome": Task.isCancelled ? "cancelled" : outcome,
                "elapsedSeconds": Date().timeIntervalSince(started), "counters": counters]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: importedXML.deletingLastPathComponent().appendingPathComponent("Import-Performance.json"), options: .atomic)
            }
        }
        func observe(_ element: AXUIElement) throws -> FinalCutImportObservation<AXUIElement> {
            observations += 1
            return try importObservation(in: element) { nodeReads += 1 }
        }
        func markUnknownObservation() {
            unknownObservations += 1
            let elapsed = Date().timeIntervalSince(started)
            // An AX rebuild is neither a completed import nor evidence that
            // browser navigation is needed. Restart both quiet intervals.
            _ = readiness.observe(projectVisible: false, hasDialog: true, elapsed: elapsed)
            _ = browserReveal.observe(projectVisible: false, originalProjectCurrent: false, hasDialog: true, elapsed: elapsed)
        }
        while Date().timeIntervalSince(started) < 30 {
            polls += 1
            try Task.checkCancellation()
            guard !application.isTerminated else { throw FinalCutCaptureError.changedProject }
            // Import may itself open the result. Permit only the original or
            // our exact generated project; don't repin to another user project.
            let currentName = currentProjectTitle()
            if replacement == nil,
               !FinalCutImportTimeline.permits(currentName, original: projectName, imported: name) {
                throw FinalCutCaptureError.changedProject
            }
            let panel = currentSheet()
            if let panel {
                let observation: FinalCutImportObservation<AXUIElement>
                do { observation = try observe(panel) }
                catch {
                    try Task.checkCancellation()
                    markUnknownObservation()
                    try await Task.sleep(for: .milliseconds(150))
                    continue
                }
                let buttons = observation.buttons
                let dialog = observation.dialog
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
                   let replace = buttons.first(where: { $0.title == "Replace" }),
                   (attribute(replace.element, kAXEnabledAttribute) as? NSNumber)?.boolValue == true {
                    application.activate(options: [])
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
                       let focused = Self.elementAttribute(root, kAXFocusedWindowAttribute), isExpectedInputWindow(focused),
                       let current = currentSheet(), CFEqual(current, panel) {
                        // This delivery contains exactly one project, in its
                        // original event/library, after a fresh baseline check.
                        replacementAccepted = true
                        let confirmationURL = importedXML.deletingLastPathComponent().appendingPathComponent("Replacement-Confirmation.json")
                        var confirmation = FinalCutReplacementConfirmation(projectName: replacement.projectName,
                            libraryName: replacement.libraryURL.deletingPathExtension().lastPathComponent)
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        try encoder.encode(confirmation).write(to: confirmationURL, options: .atomic)
                        let result = AXUIElementPerformAction(replace.element, kAXPressAction as CFString)
                        confirmation.axResult = result.rawValue
                        try encoder.encode(confirmation).write(to: confirmationURL, options: .atomic)
                        guard result == .success else {
                            throw FinalCutCaptureError.unavailable("Final Cut Pro could not confirm project replacement. Check the result before retrying verification.")
                        }
                    }
                }
                if dialog.isCompletedWarning(for: importedXML.lastPathComponent), buttons.count == 1,
                   !acknowledged.contains(where: { CFEqual($0, panel) }),
                   let ok = buttons.first, (attribute(ok.element, kAXEnabledAttribute) as? NSNumber)?.boolValue == true {
                    application.activate(options: [])
                    // Use only this identified panel's OK action, once. Import
                    // navigation intentionally cannot use assertCurrentProject.
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
                       let focused = Self.elementAttribute(root, kAXFocusedWindowAttribute), isExpectedInputWindow(focused),
                       let current = currentSheet(), CFEqual(current, panel) {
                        acknowledged.append(panel)
                        let result = AXUIElementPerformAction(ok.element, kAXPressAction as CFString)
                        guard result == .success else {
                            throw FinalCutCaptureError.unavailable("Could not acknowledge the completed XML import warning (AX error \(result.rawValue)). Warning details: \(reportURL.path)")
                        }
                    }
                }
            } else { lastDialog = nil }
            var browserVisible = false
            if panel != nil {
                // The quiet period cannot start under a modal import dialog,
                // even if its result has already appeared in the browser.
                modalBrowserSkips += 1
            } else {
                let lookupDeadline = Date().addingTimeInterval(2)
                let browser = browserLookups.resolve(currentProject: currentName, importedProject: name,
                    shouldContinue: { !Task.isCancelled && Date() < lookupDeadline })
                guard browserLookups.lastResolutionComplete else {
                    try Task.checkCancellation()
                    markUnknownObservation()
                    try await Task.sleep(for: .milliseconds(150))
                    continue
                }
                if let browser {
                    do { browserVisible = try observe(browser).containsProject(named: name) }
                    catch {
                        try Task.checkCancellation()
                        markUnknownObservation()
                        try await Task.sleep(for: .milliseconds(150))
                        continue
                    }
                }
            }
            let visible = currentName == name || browserVisible
            // Some deliveries complete without leaving the confirmation visible
            // to us. Closing the original timeline is also an import transition;
            // the subsequent export must still prove a new UID and exact edits.
            if replacement != nil {
                if currentName != name { timelineTransitionObserved = true }
                else if let originalTimelineSignature, let current = timelineLayoutSignature(), current != originalTimelineSignature {
                    timelineTransitionObserved = true
                }
            }
            if readiness.observe(projectVisible: visible, hasDialog: panel != nil, elapsed: Date().timeIntervalSince(started),
                                 awaitingReplacement: acceptReplacement, replacementConfirmed: replacementAccepted,
                                 originalTimelineClosed: timelineTransitionObserved,
                                 requiresTimelineTransition: acceptReplacement && originalTimelineSignature != nil) {
                outcome = "ready"
                return
            }
            if replacement == nil, browserReveal.observe(projectVisible: visible, originalProjectCurrent: currentName == projectName,
                                     hasDialog: panel != nil, elapsed: Date().timeIntervalSince(started)) {
                // The generated project may open between sampling the toolbar
                // and this navigation. In that exact case the reveal is no
                // longer needed; re-read import state on the next iteration.
                do {
                    try await activate()
                    try await pressMenu(path: ["Window", "Go To", "Libraries"])
                } catch FinalCutCaptureError.changedProject {
                    let now = currentProjectTitle()
                    guard now == name else { throw FinalCutCaptureError.changedProject }
                    continue
                }
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
            throw FinalCutCaptureError.unavailable("Verification is blocked by Final Cut Pro’s ‘\(dialog.title)’ dialog. Close it before checking the existing result. Details: \(reportURL.path)")
        }
        throw FinalCutCaptureError.unavailable("Final Cut Pro did not finish presenting the imported project ‘\(name)’ within 30 seconds. Open the result in its event before retrying verification.")
    }

    private func importObservation(in element: AXUIElement, didReadNode: () -> Void) throws -> FinalCutImportObservation<AXUIElement> {
        let deadline = Date().addingTimeInterval(2)
        return try FinalCutImportObservation.capture(root: element, read: { item in
            didReadNode()
            let values = FinalCutAXAttributes.read(item, names: [kAXRoleAttribute, kAXTitleAttribute,
                kAXValueAttribute, kAXDescriptionAttribute, kAXChildrenAttribute])
            guard let role = values[kAXRoleAttribute] as? String else {
                throw FinalCutImportObservation<AXUIElement>.CaptureError.incomplete
            }
            let children = values[kAXChildrenAttribute] as? [AXUIElement]
            if children == nil && [kAXSheetRole, kAXGroupRole, kAXScrollAreaRole, kAXSplitGroupRole,
                                  kAXWindowRole, kAXRowRole, kAXOutlineRole, kAXTableRole].contains(role) {
                throw FinalCutImportObservation<AXUIElement>.CaptureError.incomplete
            }
            let raw = values[kAXValueAttribute]
            let control = FinalCutImportObservation<AXUIElement>.Control(element: item, role: role,
                title: values[kAXTitleAttribute] as? String,
                value: (raw as? String) ?? (raw as? NSNumber)?.stringValue,
                description: values[kAXDescriptionAttribute] as? String)
            return (control, children ?? [])
        }, shouldContinue: { !Task.isCancelled && Date() < deadline })
    }

    /// Reveal the current project before delivery. Replacement by name must
    /// never target duplicate browser items or an event in another library.
    func prepareReplacementBrowser(_ target: XMLReplacementTarget, allowLibraryEventSelection: Bool = true) async throws {
        let previousStage = operationStage
        operationStage = "Locating the source project in its event"
        defer { operationStage = previousStage }
        guard projectName == target.projectName else { throw FinalCutCaptureError.changedProject }
        try await activate()
        try await pressMenu(path: ["File", "Reveal Project in Browser"])
        // Reveal can legitimately retain the selected library (showing all its
        // projects). Select the unique source event instead of waiting for a
        // selection change that Final Cut never promised to make.
        let revealed = try await settledEventSidebar(target, allowLibrarySelection: allowLibraryEventSelection)
        if try !FinalCutEventSidebar.isSelected(revealed.index, rows: revealed.rows, selectedRows: revealed.selectedRows) {
            guard allowLibraryEventSelection,
                  try FinalCutEventSidebar.libraryIsSelected(rows: revealed.rows, libraryURL: target.libraryURL,
                    selectedRows: revealed.selectedRows) else {
                throw FinalCutCaptureError.unavailable("The revealed project is not selected in its expected source event. Select ‘\(target.eventName)’ in the source library before trying again. No unrelated event was selected automatically.")
            }
            try await prepareInputFocus()
            try selectEventRow(revealed, for: target)
            _ = try await settledEventSidebar(target, allowLibrarySelection: false)
            try await pressMenu(path: ["File", "Reveal Project in Browser"])
            // The second Reveal can change the sidebar. The branch that
            // keeps the original event already proved its exact selection.
            _ = try await settledEventSidebar(target, allowLibrarySelection: false)
        }
        _ = try await selectBrowserProject(named: target.projectName)
        try await focusTimeline()
    }

    func assertReplacementEvent(_ target: XMLReplacementTarget) throws {
        let observed = try eventSidebarObservation(target)
        guard try FinalCutEventSidebar.isSelected(observed.index, rows: observed.rows, selectedRows: observed.selectedRows) else {
            throw FinalCutCaptureError.unavailable("Select the ‘\(target.eventName)’ event in ‘\(target.libraryURL.deletingPathExtension().lastPathComponent)’ before continuing. The active project has not been edited.")
        }
    }

    private struct EventSidebarObservation {
        let sidebar: AXUIElement
        let elements: [AXUIElement]
        let rows: [FinalCutEventSidebar.Row]
        let selectedRows: [Int]?
        let index: Int
    }

    private func settledEventSidebar(_ target: XMLReplacementTarget, allowLibrarySelection: Bool) async throws -> EventSidebarObservation {
        let deadline = Date().addingTimeInterval(5)
        var reason: Error = FinalCutCaptureError.unavailable("Select the source event ‘\(target.eventName)’ in its library before trying again.")
        repeat {
            try assertCurrentProject()
            do {
                let observed = try eventSidebarObservation(target)
                if try FinalCutEventSidebar.isSelected(observed.index, rows: observed.rows, selectedRows: observed.selectedRows) {
                    return observed
                }
                if allowLibrarySelection,
                   try FinalCutEventSidebar.libraryIsSelected(rows: observed.rows, libraryURL: target.libraryURL, selectedRows: observed.selectedRows) {
                    return observed
                }
            } catch { reason = error }
            // Read-only settling never dispatches Reveal or selection again.
            try await Task.sleep(for: .milliseconds(150))
        } while Date() < deadline
        throw reason
    }

    private func eventSidebarObservation(_ target: XMLReplacementTarget) throws -> EventSidebarObservation {
        guard let sidebar = Self.search(mainWindow, role: kAXOutlineRole, description: "Event media sidebar", containersOnly: true) else {
            throw FinalCutCaptureError.unavailable("Show the source event in the Libraries sidebar before continuing.")
        }
        guard let children = attribute(sidebar, kAXChildrenAttribute) as? [AXUIElement], children.count <= 600 else {
            throw FinalCutCaptureError.unavailable("The Libraries sidebar could not be read safely.")
        }
        guard children.allSatisfy({ child in
            guard let role = string(child, kAXRoleAttribute) else { return false }
            return [kAXRowRole, kAXColumnRole, "AXHeader"].contains(role)
        }) else { throw FinalCutCaptureError.unavailable("An unreadable Libraries sidebar item prevents verifying the source event.") }
        let elements = children.filter { string($0, kAXRoleAttribute) == kAXRowRole }
        var rows: [FinalCutEventSidebar.Row] = []
        for row in elements {
            let nodes = importElements(in: row)
            let fields = nodes.filter { string($0, kAXRoleAttribute) == kAXTextFieldRole }
            // Final Cut can expose the glyph on the image nested in the cell,
            // rather than on the cell itself. Inspect this bounded row only.
            let glyphs = nodes.flatMap { node in
                [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXRoleDescriptionAttribute,
                 kAXIdentifierAttribute, kAXHelpAttribute].compactMap { string(node, $0) }
            }
            let path = fields.compactMap { field -> String? in
                guard let help = string(field, kAXHelpAttribute), let last = help.split(separator: "\n").last else { return nil }
                let path = String(last)
                guard path.hasPrefix("/"), URL(fileURLWithPath: path).pathExtension.lowercased() == "fcpbundle" else { return nil }
                return path
            }
            let kind = FinalCutEventSidebar.kind(glyphs: glyphs, hasLibraryPath: !path.isEmpty,
                disclosureLevel: (attribute(row, kAXDisclosureLevelAttribute) as? NSNumber)?.intValue,
                knownCollection: string(row, kAXValueAttribute) == "Smart Collections")
            rows.append(.init(kind: kind, name: fields.count == 1 ? string(fields[0], kAXValueAttribute) : nil,
                libraryPath: path.count == 1 ? path[0] : nil,
                selected: (attribute(row, kAXSelectedAttribute) as? NSNumber)?.boolValue))
        }
        var selectedRows: [Int]?
        if let native = attribute(sidebar, kAXSelectedRowsAttribute) as? [AXUIElement] {
            selectedRows = try native.map { selected in
                guard let index = elements.firstIndex(where: { CFEqual($0, selected) }) else {
                    throw FinalCutCaptureError.unavailable("The Libraries sidebar selection could not be verified.")
                }
                return index
            }
        }
        do {
            let index = try FinalCutEventSidebar.eventIndex(rows: rows, libraryURL: target.libraryURL, eventName: target.eventName)
            return .init(sidebar: sidebar, elements: elements, rows: rows, selectedRows: selectedRows, index: index)
        } catch {
            // Keep the bounded observation beside this operation's XML. This
            // contains sidebar metadata only, and never changes host state.
            if let directory = lastXMLShareDirectory {
                let diagnostic: [[String: Any]] = zip(elements, rows).map { element, row in
                    ["kind": String(describing: row.kind), "name": row.name as Any? ?? NSNull(),
                     "libraryPath": row.libraryPath as Any? ?? NSNull(), "selected": row.selected as Any? ?? NSNull(),
                     "nodes": importElements(in: element).map { node in
                        Dictionary(uniqueKeysWithValues: [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                            kAXRoleDescriptionAttribute, kAXIdentifierAttribute, kAXValueAttribute,
                            kAXHelpAttribute, kAXDisclosureLevelAttribute].compactMap { key in
                                string(node, key).map { (key, $0) }
                            })
                     }]
                }
                if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: directory.appendingPathComponent("Event-Sidebar.json"), options: .atomic)
                }
            }
            throw FinalCutCaptureError.unavailable("The exact source event ‘\(target.eventName)’ in ‘\(target.libraryURL.deletingPathExtension().lastPathComponent)’ is missing, unreadable or ambiguous in the Libraries sidebar. Expand that library and select its source event before trying again. No project was duplicated or edited during this check.")
        }
    }

    private func selectEventRow(_ observed: EventSidebarObservation, for target: XMLReplacementTarget) throws {
        func assertOwnedInput() throws {
            try Task.checkCancellation()
            try assertInputFocus()
            guard currentSheet() == nil else { throw FinalCutCaptureError.changedProject }
        }
        func observeAfterFailedWrite() throws -> EventSidebarObservation? {
            let current = try eventSidebarObservation(target)
            if try FinalCutEventSidebar.isSelected(current.index, rows: current.rows, selectedRows: current.selectedRows) {
                return nil
            }
            guard try FinalCutEventSidebar.libraryIsSelected(rows: current.rows, libraryURL: target.libraryURL,
                    selectedRows: current.selectedRows) else {
                throw FinalCutCaptureError.invalidSelection("The Libraries sidebar selection changed before selecting the source event.")
            }
            return current
        }

        try assertOwnedInput()
        let row = observed.elements[observed.index]
        if AXUIElementSetAttributeValue(observed.sidebar, kAXSelectedRowsAttribute as CFString, [row] as CFArray) == .success { return }
        // A failed write can still select the event. Use fresh readback before
        // issuing more input, and continue only from the same source library.
        guard let afterSidebarWrite = try observeAfterFailedWrite() else { return }
        try assertOwnedInput()
        if AXUIElementSetAttributeValue(afterSidebarWrite.elements[afterSidebarWrite.index],
                kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success { return }
        guard let afterRowWrite = try observeAfterFailedWrite() else { return }
        // Selection is reversible. The fallback clicks only a freshly hit-tested
        // descendant of this exact event row, never an overlapping window.
        let nodes = importElements(in: afterRowWrite.elements[afterRowWrite.index])
        guard let field = nodes.first(where: { string($0, kAXRoleAttribute) == kAXTextFieldRole }),
              let point = controlCenter(field) else { throw FinalCutCaptureError.unavailable("The source event row is not available for selection.") }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw FinalCutCaptureError.unavailable("The source event could not be selected.")
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        try assertOwnedInput()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &hit) == .success,
              let hit, nodes.contains(where: { CFEqual($0, hit) }) else {
            throw FinalCutCaptureError.unavailable("The source event is covered or outside the visible Libraries sidebar. Reveal it before trying again.")
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
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
    func selectBrowserProject(named name: String) async throws -> AXUIElement {
        try await activate()
        func projectImage() -> AXUIElement? {
            guard let browser = find(in: mainWindow, role: kAXScrollAreaRole, description: "organizer"),
                  let image = find(in: browser, role: kAXImageRole, title: name)
                    ?? find(in: browser, role: kAXImageRole, description: name) else { return nil }
            return image
        }
        func visibleProjectPoint(for expected: AXUIElement) -> CGPoint? {
            guard let image = projectImage(), CFEqual(image, expected), let point = controlCenter(image) else { return nil }
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &hit) == .success,
                  let hit, CFEqual(hit, image) || children(image).contains(where: { CFEqual($0, hit) }) else { return nil }
            return point
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
        func browserHasExactSelection() -> Bool {
            guard let selected = attribute(container, kAXSelectedChildrenAttribute) as? [AXUIElement] else { return false }
            return selected.count == 1 && CFEqual(selected[0], item)
        }
        func browserHasFocus() -> Bool {
            var focused = Self.elementAttribute(root, kAXFocusedUIElementAttribute)
            for _ in 0..<8 {
                guard let current = focused else { return false }
                if CFEqual(current, container) { return true }
                focused = Self.elementAttribute(current, kAXParentAttribute)
            }
            return false
        }
        let canSettleWithoutPointer = FinalCutBrowserSelection.canSettleWithoutPointer(hasSelection: browserHasExactSelection,
            hasFocus: browserHasFocus, select: {
                AXUIElementSetAttributeValue(container, kAXSelectedChildrenAttribute as CFString, [item] as CFArray) == .success
            }, focus: {
                _ = AXUIElementSetAttributeValue(container, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            })
        if !canSettleWithoutPointer {
#if DEBUG
            QuietSharePrototype.pluginLease?.reveal(reason: "Visible compatibility step: browser selection.")
#endif
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
            try assertInputFocus()
            guard currentSheet() == nil else { throw FinalCutCaptureError.changedProject }
            guard let point = visibleProjectPoint(for: image) else {
                throw FinalCutCaptureError.unavailable("The imported project is covered by another window. Move the covering window away from the browser, then analyze the clip again.")
            }
            guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
                throw FinalCutCaptureError.unavailable("Could not select the imported project.")
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
                throw FinalCutCaptureError.changedProject
            }
            for event in [down, up] {
                event.setIntegerValueField(.mouseEventClickState, value: 1)
                event.post(tap: .cghidEventTap)
            }
        }
        try await waitUntil(timeout: 3, context: "the exact imported project selection") {
            browserHasExactSelection() && browserHasFocus()
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
                throw FinalCutCaptureError.unavailable("Final Cut Pro showed an unexpected Trash dialog; the temporary project was left for review.")
            }
            try press(confirm)
        }
        try await waitUntil(timeout: 5, context: "temporary analysis project removal") {
            !projectStillVisible()
        }
        try await focusTimeline()
    }

    func returnToPreviousProject(named name: String) async throws -> FinalCutAXSession {
        if let current = try? FinalCutAXSession(inheritingWorkflowFrom: self), current.projectName == name { return current }
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
            if let current = try? FinalCutAXSession(inheritingWorkflowFrom: self) {
                guard current.application.processIdentifier == application.processIdentifier,
                      CFEqual(current.mainWindow, mainWindow) else { throw FinalCutCaptureError.changedProject }
                if current.projectName == name { return current }
                guard current.projectName == projectName else { throw FinalCutCaptureError.changedProject }
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw FinalCutCaptureError.unavailable("Final Cut Pro did not open the requested project ‘\(name)’.")
    }

}
