import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import SilentSnipCore
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A request-local capability created only by copying the verified native source.
/// Clipboard bytes are never decoded, logged, or accepted from an unrelated copy.
@MainActor struct NativeEffectTransferToken {
    fileprivate let id: UUID
    fileprivate let clipboardStamp: Int
    fileprivate let originalSHA256: String
    fileprivate let sourceUID: String
    fileprivate let sourceName: String
    fileprivate let effectNames: [String]
    fileprivate let outputName: String

    func prepareJournal(directory: URL, expectedResultData: Data, effectFreeData: Data) throws {
        let expected = try TimelineParser.parse(data: expectedResultData)
        let identity = try XMLReplacementTarget(projectData: expectedResultData)
        guard NSPasteboard.general.changeCount == clipboardStamp, !expected.clips.isEmpty,
              expected.projectName == outputName,
              identity.originalProjectUID != sourceUID else { throw FinalCutCaptureError.changedProject }
        let journal = NativeBulkEffectTransferJournal.Record(token: id, sourceUID: sourceUID,
            clipboardStamp: clipboardStamp, expectedSHA256: bulkDigest(expectedResultData),
            effectFreeSHA256: bulkDigest(effectFreeData), projectName: expected.projectName,
            libraryURL: identity.libraryURL, eventUID: identity.eventUID.uuidString,
            clipCount: expected.clips.count, stage: "import pending")
        try journal.save(directory: directory, initial: true)
    }
}

/// Once-only mutation journal. Retry can verify an applied result but cannot
/// import, copy, or paste again. An uncertain Paste remains stopped.
@MainActor enum NativeBulkEffectTransferJournal {
    fileprivate struct Record: Codable {
        let token: UUID
        let sourceUID: String
        let clipboardStamp: Int
        let expectedSHA256: String
        let effectFreeSHA256: String
        let projectName: String
        let libraryURL: URL
        let eventUID: String
        let clipCount: Int
        var stage: String
        var hostUID: String?
        var failure: String?
        var failureStage: String?

        func save(directory: URL, initial: Bool = false) throws {
            guard directory.isFileURL else { throw FinalCutCaptureError.changedProject }
            let data = try JSONEncoder().encode(self)
            try data.write(to: Self.url(directory), options: initial ? .withoutOverwriting : .atomic)
        }
        static func url(_ directory: URL) -> URL { directory.appendingPathComponent("Bulk-Effect-Transfer-Journal.json") }
    }

    fileprivate static func load(_ directory: URL) throws -> Record {
        let url = Record.url(directory)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, size.int64Value > 0, size.int64Value <= 256 * 1_024 else {
            throw FinalCutCaptureError.changedProject
        }
        return try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
    }

    @discardableResult static func requireApplied(directory: URL, expected: Data) throws -> String {
        let journal = try load(directory)
        let document = try TimelineParser.parse(data: expected)
        let identity = try XMLReplacementTarget(projectData: expected)
        guard ["effects applied; result verification pending", "completed; verified"].contains(journal.stage),
              journal.failure == nil, journal.failureStage == nil, journal.expectedSHA256 == bulkDigest(expected),
              journal.projectName == document.projectName, journal.clipCount == document.clips.count,
              journal.libraryURL == identity.libraryURL, journal.eventUID == identity.eventUID.uuidString,
              let uid = journal.hostUID, !uid.isEmpty, uid != journal.sourceUID else {
            throw EditedProjectWriterError.verificationFailed("the original native effects were not applied to this exact result; no import or paste was repeated")
        }
        return uid
    }

    static func markVerified(directory: URL, hostUID: String) throws {
        var journal = try load(directory)
        guard ["effects applied; result verification pending", "completed; verified"].contains(journal.stage),
              journal.hostUID == hostUID, journal.failure == nil, journal.failureStage == nil else { throw FinalCutCaptureError.changedProject }
        guard journal.stage != "completed; verified" else { return }
        journal.stage = "completed; verified"
        try journal.save(directory: directory)
    }
}

private func bulkDigest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// Pure checks shared by native observations and regression tests.
enum BulkEffectTransferPolicy {
    /// A known title alone never authorizes activation. Workflow ownership is
    /// established separately from its bound native view marker, and only the
    /// pinned host or this exact worker may own the foreground at that point.
    static func mayRestoreTimeline(foregroundPID: Int32?, hostPID: Int32, helperPID: Int32,
                                   focusedWindowIsBoundWorkflow: Bool, hasSheet: Bool) -> Bool {
        guard !hasSheet, let foregroundPID, hostPID > 0, helperPID > 0 else { return false }
        return foregroundPID == helperPID || (foregroundPID == hostPID && focusedWindowIsBoundWorkflow)
    }

    static func mayReturnOwnedDialog(foregroundPID: Int32?, helperPID: Int32,
                                     sameDialog: Bool, clipboardUnchanged: Bool) -> Bool {
        helperPID > 0 && foregroundPID == helperPID && sameDialog && clipboardUnchanged
    }

    static func validateSelection(expected: [TimeRange], actual: [TimeRange], selected: [Bool]) throws {
        guard !expected.isEmpty, expected == actual, selected.count == expected.count,
              selected.allSatisfy({ $0 }) else { throw FinalCutCaptureError.changedProject }
    }

    static func validateEffectCheckboxes(expected: [String], actual: [String], checked: [Int]) throws {
        guard !expected.isEmpty, expected == actual, checked.count == expected.count,
              checked.allSatisfy({ $0 == 1 }) else {
            throw EditedProjectWriterError.verificationFailed("the native attribute dialog does not contain the exact original effect chain")
        }
    }

    static func copiedFromMatches(_ text: String, source: String, count: Int) -> Bool {
        func normalized(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let actual = normalized(text), name = normalized(source)
        return actual == "Copied From: \(name) \(count) Clips" ||
            (count == 1 && actual == "Copied From: \(name) 1 Clip") || actual == "Copied From: \(name)"
    }
}

extension FinalCutAXSession {
    func captureNativeEffectTransfer(plan: NativeSourceEditPlan, originalData: Data, outputName: String,
                                     timing: AnalysisTiming) async throws -> NativeEffectTransferToken {
        let priorStage = operationStage
        operationStage = "Copying the verified original effects for bulk XML cuts"
        defer { operationStage = priorStage }
        let original = try TimelineParser.parse(data: originalData)
        guard original.projectUID == plan.projectUID, original.fingerprint == plan.baselineFingerprint,
              projectName == plan.projectName else { throw FinalCutCaptureError.changedProject }
        let xml = try XMLDocument(data: originalData, options: [.nodeLoadExternalEntitiesNever])
        let filters = try xml.nodes(forXPath: "/fcpxml/library/event/project/sequence/spine/asset-clip/filter-audio").compactMap { $0 as? XMLElement }
        let all = try xml.nodes(forXPath: "//project/sequence//filter-audio")
        guard !filters.isEmpty, filters.count == all.count,
              try xml.nodes(forXPath: "//project/sequence//filter-audio//keyframeAnimation").isEmpty else {
            throw EditedProjectWriterError.unsupported("bulk native effect transfer currently requires a static effect chain on the original whole-project clip")
        }
        let resources = try xml.nodes(forXPath: "/fcpxml/resources/effect").compactMap { $0 as? XMLElement }
        let names = try filters.map { filter -> String in
            let ref = filter.attribute(forName: "ref")?.stringValue
            let resource = resources.first {
                $0.attribute(forName: "id")?.stringValue == ref
            }
            guard let name = filter.attribute(forName: "nameOverride")?.stringValue ?? filter.attribute(forName: "name")?.stringValue ?? resource?.attribute(forName: "name")?.stringValue,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !["Effects", "Audio Attributes", "Video Attributes", "Volume", "Pan"].contains(name) else { throw FinalCutCaptureError.changedProject }
            return name
        }
        try await prepareBulkTimelineInput(timing: timing)
        let sourceIdentity = try XMLReplacementTarget(projectData: originalData)
        let namesBeforeImport = try await timing.measure("apply.bulkSourceBrowser") {
            if let mounted = try bulkMountedBrowserNames(sourceIdentity) {
                timing.incrementCounter("apply.bulkSourceBrowser.revealSkipped")
                return mounted
            }
            try await prepareReplacementBrowser(sourceIdentity)
            return try bulkBrowserNames()
        }
        guard namesBeforeImport.filter({ $0 == projectName }).count == 1,
              !outputName.isEmpty, outputName != projectName, !namesBeforeImport.contains(outputName) else {
            throw EditedProjectWriterError.unsupported("a project with this result name already exists; no effects were copied or pasted")
        }
        try await clearTimelineRanges()
        try await timing.measure("apply.bulkSourceSelection") {
            try await bulkSelect(layout: plan.initial, plan: plan, timing: timing)
        }
        let stamp = NSPasteboard.general.changeCount
        try await timing.measure("apply.nativeEffectsCopy") {
            let shortcut = try await BulkNativeCommandInvocation.perform(shortcut: {
                try self.pressAdvertisedMenuShortcut(path: ["Edit", "Copy"])
            }, menu: { try await self.pressMenu(path: ["Edit", "Copy"]) })
            timing.incrementCounter(shortcut ? "apply.nativeEffectsCopy.shortcutDispatches" : "apply.nativeEffectsCopy.menuFallbacks")
        }
        try await waitUntil(timeout: 3, context: "the copied original audio effects") { NSPasteboard.general.changeCount != stamp }
        let copiedStamp = NSPasteboard.general.changeCount
        try await prepareBulkTimelineInput(timing: timing)
        try assertInputFocus()
        try bulkAssertSelected(layout: plan.initial, plan: plan)
        guard NSPasteboard.general.changeCount == copiedStamp else { throw FinalCutCaptureError.changedProject }
        let token = NativeEffectTransferToken(id: UUID(), clipboardStamp: copiedStamp,
            originalSHA256: bulkDigest(originalData), sourceUID: plan.projectUID,
            sourceName: plan.target.name, effectNames: names, outputName: outputName)
        timing.incrementCounter("apply.nativeEffectCopies")
        return token
    }

    /// One native Paste Attributes after the single XML import. The number of
    /// AX reads scales with recipients; the number of editing commands does not.
    func applyBulkEffects(token: NativeEffectTransferToken, plan: NativeSourceEditPlan,
                          originalData: Data, expectedEffectFreeData: Data, expectedResultData: Data,
                          directory: URL, timing: AnalysisTiming) async throws -> String {
        let priorStage = operationStage
        operationStage = "Binding the imported XML project before the bulk effect transfer"
        defer { operationStage = priorStage }
        var journal = try NativeBulkEffectTransferJournal.load(directory)
        guard journal.stage == "import pending", journal.token == token.id,
              journal.clipboardStamp == token.clipboardStamp, journal.sourceUID == token.sourceUID,
              journal.expectedSHA256 == bulkDigest(expectedResultData),
              journal.effectFreeSHA256 == bulkDigest(expectedEffectFreeData),
              token.originalSHA256 == bulkDigest(originalData),
              NSPasteboard.general.changeCount == token.clipboardStamp else { throw FinalCutCaptureError.changedProject }
        do {
            let expected = try TimelineParser.parse(data: expectedEffectFreeData)
            guard projectName == expected.projectName, projectName != plan.projectName else { throw FinalCutCaptureError.changedProject }
            try await prepareBulkTimelineInput(timing: timing)
            let url = try await exportProjectXML(to: directory.appendingPathComponent("Before-Bulk-Effects.fcpxmld"), timing: timing, sharePurpose: .verification)
            let actual = try Data(contentsOf: url)
            try ProjectRoundTripVerification.verify(expected: expectedEffectFreeData, actual: actual,
                reportURL: directory.appendingPathComponent("Before-Bulk-Effects-Verification.json"), allowHostAssignedIdentity: true)
            let identity = try XMLReplacementTarget(projectData: actual)
            let source = try XMLReplacementTarget(projectData: originalData)
            let expectedIdentity = try XMLReplacementTarget(projectData: expectedEffectFreeData)
            guard identity.libraryURL == source.libraryURL, identity.eventUID == source.eventUID,
                  identity.eventName == source.eventName, identity.projectName == expectedIdentity.projectName,
                  identity.originalProjectUID != token.sourceUID,
                  journal.libraryURL == identity.libraryURL, journal.eventUID == identity.eventUID.uuidString,
                  journal.clipCount == plan.final.segments.count,
                  NSPasteboard.general.changeCount == token.clipboardStamp else { throw FinalCutCaptureError.changedProject }
            journal.hostUID = identity.originalProjectUID
            journal.stage = "import identity verified"
            try journal.save(directory: directory)
            // XML delivery can return focus to the exact requesting Workflow
            // window. This safe phase boundary moves only that owned handoff
            // back to the already pinned project, before any recipient input.
            try await prepareBulkTimelineInput(timing: timing)
            try await timing.measure("apply.bulkRecipientBrowser") {
                if try bulkMountedBrowserNames(identity) != nil {
                    timing.incrementCounter("apply.bulkRecipientBrowser.revealSkipped")
                } else {
                    try await prepareReplacementBrowser(identity)
                }
            }
            try await clearTimelineRanges()
            try await timing.measure("apply.bulkRecipientSelection") {
                try await bulkSelect(layout: plan.final, plan: plan, timing: timing)
            }
            guard NSPasteboard.general.changeCount == token.clipboardStamp else { throw FinalCutCaptureError.changedProject }
            try await prepareBulkTimelineInput(timing: timing)
            try bulkAssertSelected(layout: plan.final, plan: plan)
            operationStage = "Configuring the single native effect transfer for all XML clips"
            journal.stage = "paste attributes dialog requested"
            try journal.save(directory: directory)
            let pasteShortcut = try await BulkNativeCommandInvocation.perform(shortcut: {
                try self.pressAdvertisedMenuShortcut(path: ["Edit", "Paste Attributes…"])
            }, menu: { try await self.pressMenu(path: ["Edit", "Paste Attributes…"]) })
            timing.incrementCounter(pasteShortcut ? "apply.nativePasteAttributes.shortcutDispatches" : "apply.nativePasteAttributes.menuFallbacks")
            var sheet: AXUIElement?
            try await waitUntil(timeout: 4, context: "the native Paste Attributes dialog") { sheet = self.currentSheet(); return sheet != nil }
            guard let sheet else { throw FinalCutCaptureError.changedProject }
            try await bulkConfigureDialog(sheet: sheet, token: token, count: plan.final.segments.count, timing: timing)
            try await prepareBulkDialogInput(sheet: sheet, token: token, count: plan.final.segments.count, timing: timing)
            let ready = try bulkValidateDialog(sheet: sheet, token: token, count: plan.final.segments.count)
            try bulkAssertSelected(layout: plan.final, plan: plan)
            guard NSPasteboard.general.changeCount == token.clipboardStamp else { throw FinalCutCaptureError.changedProject }
            journal.stage = "effects paste requested"
            try journal.save(directory: directory)
            try timing.measure("apply.nativeEffectsPaste") {
                try self.bulkPressPaste(ready, willDispatch: {
                    // This write follows the final focus/control/action checks
                    // and must succeed before AX receives the mutation.
                    journal.stage = "effects paste dispatched"
                    try journal.save(directory: directory)
                    timing.incrementCounter("apply.nativeEffectsPasteDispatches")
                })
            }
            timing.incrementCounter("apply.nativeEffectsPasteReturns")
            journal.stage = "paste command acknowledged; awaiting dialog close"
            try journal.save(directory: directory)
            try await waitUntil(timeout: 8, context: "the single completed native effects transfer") { self.currentSheet() == nil }
            journal.stage = "paste dialog closed; checking recipients"
            try journal.save(directory: directory)
            operationStage = "Checking recipients after the single native effect transfer"
            // Closing Paste Attributes may foreground our retained Workflow
            // window. Restore only this owned handoff; never replay Paste.
            try await prepareBulkTimelineInput(timing: timing)
            try assertCurrentProject()
            try bulkAssertSelected(layout: plan.final, plan: plan)
            journal.stage = "effects applied; result verification pending"
            try journal.save(directory: directory)
            timing.incrementCounter("apply.nativeEffectsPastes")
            timing.recordCounters(["apply.nativeEffectRecipients": plan.final.segments.count, "apply.nativeRangeRemovals": 0])
            return identity.originalProjectUID
        } catch {
            journal.failure = error.localizedDescription
            journal.failureStage = journal.stage
            journal.stage = "stopped; no action will be replayed"
            try? journal.save(directory: directory)
            throw error
        }
    }

    private struct BulkItem { let element: AXUIElement; let range: TimeRange; let selected: Bool }

    /// Same strict control checks as press(), with a throwing dispatch boundary
    /// so an unwritable journal stops before Final Cut receives Paste. No retry
    /// is attempted after AXUIElementPerformAction, including an AX error.
    private func bulkPressPaste(_ control: AXUIElement, willDispatch: () throws -> Void) throws {
        try assertInputFocus()
        guard bulkControlName(control) == "Paste",
              string(control, kAXRoleAttribute) == kAXButtonRole,
              (attribute(control, kAXEnabledAttribute) as? NSNumber)?.boolValue == true,
              let sheet = currentSheet(),
              try bulkDialogNodes(sheet).contains(where: { CFEqual($0, control) }) else {
            throw FinalCutCaptureError.changedProject
        }
        var actionNames: CFArray?
        let result = AXUIElementCopyActionNames(control, &actionNames)
        guard result == .success,
              let action = FinalCutControlAction.preferred(from: actionNames as? [String] ?? []) else {
            throw FinalCutCaptureError.unavailable("The native Paste action could not be read safely.")
        }
        try willDispatch()
        let dispatched = AXUIElementPerformAction(control, action as CFString)
        guard dispatched == .success else {
            throw FinalCutCaptureError.unavailable("The native effects Paste returned AX error \(dispatched.rawValue); it will not be repeated.")
        }
    }

    /// Called only between completed bulk phases, never while a native dialog
    /// is tracking input. Another app, unbound host window, or changed project
    /// receives no activation request and still fails the original strict gate.
    private func prepareBulkTimelineInput(timing: AnalysisTiming) async throws {
        try assertCurrentProject()
        try await FinalCutOwnedInputFocus.prepare(ownsForeground: {
            let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let hasSheet = self.currentSheet() != nil
            var ownedWorkflow = false
            var observedWorkflow: AXUIElement?
            if !hasSheet, foregroundPID == self.application.processIdentifier,
               let focused = Self.elementAttribute(self.root, kAXFocusedWindowAttribute),
               !CFEqual(focused, self.mainWindow) {
                ownedWorkflow = self.isBoundWorkflowReviewWindow(focused)
                observedWorkflow = focused
            }
            // The bounded marker lookup can take time. A later app/window
            // switch revokes its ownership observation before any activation.
            let livePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let liveSheet = self.currentSheet() != nil
            if ownedWorkflow {
                ownedWorkflow = livePID == self.application.processIdentifier && !liveSheet
                    && observedWorkflow.flatMap { observed in
                        Self.elementAttribute(self.root, kAXFocusedWindowAttribute).map { CFEqual(observed, $0) }
                    } == true
            }
            return BulkEffectTransferPolicy.mayRestoreTimeline(foregroundPID: livePID,
                hostPID: self.application.processIdentifier, helperPID: NSRunningApplication.current.processIdentifier,
                focusedWindowIsBoundWorkflow: ownedWorkflow, hasSheet: liveSheet)
        }, restore: {
            timing.incrementCounter("apply.bulkOwnedFocusHandoffs")
            try await self.activate()
        }, assertFocused: {
            try self.assertInputFocus()
        })
        guard currentSheet() == nil else { throw FinalCutCaptureError.changedProject }
        try await focusTimeline()
        try assertInputFocus()
    }

    /// Copy and Paste Attributes act on the pinned timeline. When the browser
    /// already proves its exact event and the unique project, there is no need
    /// to reveal the project or move selection and focus through the browser.
    private func bulkMountedBrowserNames(_ target: XMLReplacementTarget) throws -> [String]? {
        try assertInputFocus()
        guard projectName == target.projectName, currentSheet() == nil else {
            throw FinalCutCaptureError.changedProject
        }
        guard (try? assertReplacementEvent(target)) != nil,
              let names = try? bulkBrowserNames(),
              names.filter({ $0 == target.projectName }).count == 1,
              (try? assertReplacementEvent(target)) != nil else {
            try Task.checkCancellation()
            return nil
        }
        try assertInputFocus()
        return names
    }

    /// A complete mounted snapshot of the exact source event, including its
    /// footer count. A filtered, virtualized or partially loaded browser cannot
    /// establish that an older same-name result is absent.
    private func bulkBrowserNames() throws -> [String] {
        guard let organizer = find(in: mainWindow, role: kAXScrollAreaRole, description: "organizer"),
              let immediateParent = Self.elementAttribute(organizer, kAXParentAttribute),
              let organizerChildren = attribute(organizer, kAXChildrenAttribute) as? [AXUIElement], organizerChildren.count <= 32 else {
            throw FinalCutCaptureError.changedProject
        }
        func fields(_ item: AXUIElement) -> [AXUIElement] {
            children(item).filter { string($0, kAXRoleAttribute) == kAXTextFieldRole && string($0, kAXDescriptionAttribute) == "display name" }
        }
        let containers = organizerChildren.filter { child in
            guard let items = attribute(child, kAXChildrenAttribute) as? [AXUIElement], items.count <= 600 else { return false }
            return items.contains { !fields($0).isEmpty }
        }
        guard containers.count == 1, let container = containers.first,
              let raw = attribute(container, kAXChildrenAttribute) as? [AXUIElement], raw.count <= 600 else { throw FinalCutCaptureError.changedProject }
        var names: [String] = []
        for candidate in raw {
            let itemFields = fields(candidate)
            guard !itemFields.isEmpty else { continue }
            guard itemFields.count == 1, let name = string(itemFields[0], kAXValueAttribute), !name.isEmpty,
                  children(candidate).filter({ string($0, kAXRoleAttribute) == kAXImageRole &&
                      (string($0, kAXTitleAttribute) == name || string($0, kAXDescriptionAttribute) == name) }).count == 1 else { throw FinalCutCaptureError.changedProject }
            names.append(name)
        }
        var parent = immediateParent, branch = organizer
        var siblings = children(parent), depth = 0
        while siblings.count == 1, CFEqual(siblings[0], branch), depth < 4 {
            guard string(parent, kAXRoleAttribute) == kAXGroupRole,
                  let ancestor = Self.elementAttribute(parent, kAXParentAttribute), !CFEqual(ancestor, parent) else { break }
            branch = parent; parent = ancestor; siblings = children(parent); depth += 1
        }
        let texts = siblings.filter { string($0, kAXRoleAttribute) == kAXStaticTextRole }.map { node in
            [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].compactMap { name -> String? in
                let value = attribute(node, name)
                return (value as? String) ?? (value as? NSAttributedString)?.string
            }
        }
        guard FinalCutNativeDuplicateObservation.reportedItemCount(footerTexts: texts) == names.count else {
            throw FinalCutCaptureError.unavailable("Show every item in the original event before creating the XML result; a hidden same-name project cannot be excluded.")
        }
        return names
    }

    private func bulkItems(plan: NativeSourceEditPlan) throws -> [BulkItem] {
        try assertInputFocus()
        try refreshTimeline()
        guard let raw = attribute(timeline, kAXChildrenAttribute) as? [AXUIElement], raw.count <= 10_000 else { throw FinalCutCaptureError.changedProject }
        func text(_ value: Any?) -> String? { (value as? String) ?? (value as? NSNumber)?.stringValue }
        let clipDescription = "Audio-Clip:" + plan.target.name
        var items: [BulkItem] = []
        for element in raw {
            try Task.checkCancellation()
            let values = FinalCutAXAttributes.read(element, names: [kAXRoleAttribute, kAXDescriptionAttribute,
                kAXValueAttribute, kAXSelectedAttribute, kAXChildrenAttribute])
            guard values[kAXRoleAttribute] as? String == kAXLayoutItemRole else { continue }
            guard text(values[kAXDescriptionAttribute]) == clipDescription,
                  let duration = text(values[kAXValueAttribute]), !duration.contains(";"),
                  let selected = (values[kAXSelectedAttribute] as? NSNumber)?.boolValue,
                  let children = values[kAXChildrenAttribute] as? [AXUIElement] else {
                throw FinalCutCaptureError.changedProject
            }
            var positions: [String?] = []
            for child in children {
                let handle = FinalCutAXAttributes.read(child, names: [kAXRoleAttribute, kAXDescriptionAttribute, kAXValueAttribute])
                if handle[kAXRoleAttribute] as? String == "AXHandle", text(handle[kAXDescriptionAttribute]) == "Item" {
                    positions.append(text(handle[kAXValueAttribute]))
                }
            }
            guard positions.count == 1, let position = positions[0] else { throw FinalCutCaptureError.changedProject }
            let start = try FinalCutTimecode.time(position, frameDuration: plan.frameDuration).subtracting(plan.projectTimecodeStart)
            let length = try FinalCutTimecode.time(duration, frameDuration: plan.frameDuration)
            items.append(.init(element: element, range: .init(start: start, end: try start.adding(length)), selected: selected))
        }
        return items.sorted { $0.range.start < $1.range.start }
    }

    private func bulkAssertSelected(layout: NativeSourceEditPlan.Layout, plan: NativeSourceEditPlan) throws {
        try bulkVerifySelection(bulkItems(plan: plan), layout: layout)
    }

    private func bulkVerifySelection(_ items: [BulkItem], layout: NativeSourceEditPlan.Layout) throws {
        try BulkEffectTransferPolicy.validateSelection(expected: layout.segments.map(\.timelineRange), actual: items.map(\.range), selected: items.map(\.selected))
        if let aggregate = attribute(timeline, kAXSelectedChildrenAttribute) as? [AXUIElement] {
            // All mounted clip occurrences have already supplied individual
            // selected=true and exact unique geometry above. Only the aggregate
            // count remains; avoid a quadratic AX identity cross-product.
            guard aggregate.count == items.count else { throw FinalCutCaptureError.changedProject }
        }
    }

    private func bulkSelect(layout: NativeSourceEditPlan.Layout, plan: NativeSourceEditPlan, timing: AnalysisTiming) async throws {
        let items = try bulkItems(plan: plan)
        if (try? bulkVerifySelection(items, layout: layout)) != nil {
            timing.incrementCounter("apply.bulkSelection.alreadyExact")
            return
        }
        guard items.map(\.range) == layout.segments.map(\.timelineRange),
              AXUIElementSetAttributeValue(timeline, kAXSelectedChildrenAttribute as CFString, items.map(\.element) as CFArray) == .success else { throw FinalCutCaptureError.changedProject }
        timing.incrementCounter("apply.bulkSelection.axSets")
        try await waitUntil(timeout: 3, context: "all exact retained audio clips") { (try? self.bulkAssertSelected(layout: layout, plan: plan)) != nil }
    }

    private func bulkDialogNodes(_ sheet: AXUIElement) throws -> [AXUIElement] {
        guard let current = currentSheet(), CFEqual(current, sheet) else { throw FinalCutCaptureError.changedProject }
        var queue: [(AXUIElement, Int)] = [(sheet, 0)], nodes: [AXUIElement] = []
        var cursor = 0
        while cursor < queue.count {
            guard cursor < 256, queue.count <= 256 else { throw FinalCutCaptureError.changedProject }
            let (node, depth) = queue[cursor]; cursor += 1
            guard depth <= 12 else { throw FinalCutCaptureError.changedProject }
            nodes.append(node)
            queue.append(contentsOf: children(node).map { ($0, depth + 1) })
        }
        return nodes
    }

    private func bulkControlName(_ node: AXUIElement) -> String {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { string(node, $0) }.first { !$0.isEmpty } ?? ""
    }

    /// Share delivery can foreground this exact accessory worker after the Paste
    /// dialog opens. Return only our own activation to Final Cut; activate()
    /// would wrongly raise the project over this still-owned modal dialog.
    private func prepareBulkDialogInput(sheet: AXUIElement, token: NativeEffectTransferToken,
                                         count: Int, timing: AnalysisTiming) async throws {
        func validateOwnership() throws {
            try assertCurrentProject()
            guard let current = currentSheet(), CFEqual(current, sheet),
                  string(sheet, kAXTitleAttribute) == "Paste Attributes",
                  NSPasteboard.general.changeCount == token.clipboardStamp else { throw FinalCutCaptureError.changedProject }
            let nodes = try bulkDialogNodes(sheet)
            let boxes = nodes.filter { string($0, kAXRoleAttribute) == kAXCheckBoxRole }
            for required in ["Effects", "Volume", "Pan", "Audio Attributes", "Video Attributes"] {
                guard boxes.filter({ bulkControlName($0) == required }).count == 1 else { throw FinalCutCaptureError.changedProject }
            }
            let effects = boxes.map(bulkControlName).filter { token.effectNames.contains($0) }
            guard effects == token.effectNames, bulkCopiedFromMatches(nodes, token: token, count: count),
                  nodes.filter({ string($0, kAXRoleAttribute) == kAXButtonRole && bulkControlName($0) == "Paste" }).count == 1,
                  nodes.filter({ string($0, kAXRoleAttribute) == kAXButtonRole && bulkControlName($0) == "Cancel" }).count == 1 else {
                throw FinalCutCaptureError.changedProject
            }
        }
        try validateOwnership()
        try await FinalCutOwnedInputFocus.prepare(ownsForeground: {
            let current = self.currentSheet()
            return BulkEffectTransferPolicy.mayReturnOwnedDialog(
                foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                helperPID: NSRunningApplication.current.processIdentifier,
                sameDialog: current.map { CFEqual($0, sheet) } == true,
                clipboardUnchanged: NSPasteboard.general.changeCount == token.clipboardStamp)
        }, restore: {
            try validateOwnership()
            // Recheck the foreground immediately before relinquishing this
            // worker's activation. Another app never gets activated over.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == NSRunningApplication.current.processIdentifier else {
                throw FinalCutCaptureError.changedProject
            }
            timing.incrementCounter("apply.bulkOwnedDialogHandoffs")
            self.requestActivation()
            try await self.waitUntil(timeout: 2, context: "returning our activation to the owned Paste Attributes dialog") {
                guard let current = self.currentSheet(), CFEqual(current, sheet) else { return false }
                return NSWorkspace.shared.frontmostApplication?.processIdentifier == self.application.processIdentifier
            }
        }, assertFocused: {
            try validateOwnership()
            try self.assertInputFocus()
        })
    }

    private func bulkConfigureDialog(sheet: AXUIElement, token: NativeEffectTransferToken, count: Int,
                                     timing: AnalysisTiming) async throws {
        // Reobserve after each checkbox action; Final Cut may rebuild controls
        // when a group changes. A stale list must never configure another field.
        for _ in 0..<128 {
            try await prepareBulkDialogInput(sheet: sheet, token: token, count: count, timing: timing)
            let nodes = try bulkDialogNodes(sheet)
            let boxes = nodes.filter { string($0, kAXRoleAttribute) == kAXCheckBoxRole }
            var effectIndex = 0
            var change: AXUIElement?
            for box in boxes {
                let name = bulkControlName(box)
                if ["Audio Attributes", "Video Attributes"].contains(name) { continue }
                let desired: Int
                if name == "Effects" { desired = 1 }
                else if effectIndex < token.effectNames.count, name == token.effectNames[effectIndex] { desired = 1; effectIndex += 1 }
                else { desired = 0 }
                guard let value = (attribute(box, kAXValueAttribute) as? NSNumber)?.intValue else { throw FinalCutCaptureError.changedProject }
                if value != desired, change == nil { change = box }
            }
            guard let change else { break }
            try press(change)
        }
        try await prepareBulkDialogInput(sheet: sheet, token: token, count: count, timing: timing)
        let nodes = try bulkDialogNodes(sheet)
        let maintain = nodes.filter { string($0, kAXRoleAttribute) == kAXRadioButtonRole && bulkControlName($0) == "Maintain" }
        guard maintain.count == 1, let checked = (attribute(maintain[0], kAXValueAttribute) as? NSNumber)?.intValue else { throw FinalCutCaptureError.changedProject }
        if checked != 1 { try press(maintain[0]) }
        try await prepareBulkDialogInput(sheet: sheet, token: token, count: count, timing: timing)
        _ = try bulkValidateDialog(sheet: sheet, token: token, count: count)
    }

    private func bulkCopiedFromMatches(_ nodes: [AXUIElement], token: NativeEffectTransferToken, count: Int) -> Bool {
        let texts = nodes.filter { string($0, kAXRoleAttribute) == kAXStaticTextRole }.map(bulkControlName)
        return texts.indices.contains { index in
            (1...3).contains { length in
                let end = min(texts.count, index + length)
                return BulkEffectTransferPolicy.copiedFromMatches(texts[index..<end].joined(separator: " "), source: token.sourceName, count: count)
            }
        }
    }

    private func bulkValidateDialog(sheet: AXUIElement, token: NativeEffectTransferToken, count: Int) throws -> AXUIElement {
        try assertInputFocus()
        let nodes = try bulkDialogNodes(sheet)
        let boxes = nodes.filter { string($0, kAXRoleAttribute) == kAXCheckBoxRole }
        for required in ["Effects", "Volume", "Pan", "Audio Attributes", "Video Attributes"] {
            guard boxes.filter({ bulkControlName($0) == required }).count == 1 else { throw FinalCutCaptureError.changedProject }
        }
        var names: [String] = [], checked: [Int] = []
        for box in boxes {
            let name = bulkControlName(box)
            guard let value = (attribute(box, kAXValueAttribute) as? NSNumber)?.intValue else { throw FinalCutCaptureError.changedProject }
            if name == "Audio Attributes" { continue }
            if name == "Video Attributes" { guard value == 0 else { throw FinalCutCaptureError.changedProject }; continue }
            if name == "Effects" { guard value == 1 else { throw FinalCutCaptureError.changedProject }; continue }
            if token.effectNames.contains(name) { names.append(name); checked.append(value) }
            else { guard value == 0 else { throw FinalCutCaptureError.changedProject } }
        }
        try BulkEffectTransferPolicy.validateEffectCheckboxes(expected: token.effectNames, actual: names, checked: checked)
        let radios = nodes.filter { string($0, kAXRoleAttribute) == kAXRadioButtonRole }
        guard radios.count == 2, radios.allSatisfy({
            let name = bulkControlName($0)
            let value = (attribute($0, kAXValueAttribute) as? NSNumber)?.intValue
            return (name == "Maintain" && value == 1) || (name == "Stretch to Fit" && value == 0)
        }) else { throw FinalCutCaptureError.changedProject }
        guard bulkCopiedFromMatches(nodes, token: token, count: count) else { throw FinalCutCaptureError.changedProject }
        let paste = nodes.filter { string($0, kAXRoleAttribute) == kAXButtonRole && bulkControlName($0) == "Paste" }
        guard paste.count == 1, (attribute(paste[0], kAXEnabledAttribute) as? NSNumber)?.boolValue == true else { throw FinalCutCaptureError.changedProject }
        return paste[0]
    }
}
