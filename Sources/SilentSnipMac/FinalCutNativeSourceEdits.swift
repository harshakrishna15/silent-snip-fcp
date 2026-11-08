import AppKit
import ApplicationServices
import Foundation
import SilentSnipCore
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A native duplicate retains state that Final Cut does not publish in XML.
/// XML remains evidence for identity, sources and edit geometry; it is not used
/// to reconstruct effects on this route.
struct NativeSourceEditResult {
    let session: FinalCutAXSession
    let baselineData: Data
    let finalData: Data
    let projectUID: UUID
    let finalXMLURL: URL
}

struct NativeSourceEditFailure: Error, LocalizedError {
    let cause: Error
    let duplicateName: String?
    let duplicateMayExist: Bool
    let journalURL: URL

    var errorDescription: String? {
        let retained = duplicateName.map { " A partial duplicate ‘\($0)’ may remain in Final Cut Pro. Check it before starting another Apply." }
            ?? (duplicateMayExist ? " A duplicate may remain in Final Cut Pro, but its name was not verified. Check the saved browser observations before starting another Apply." : "")
        return cause.localizedDescription + retained + " The original project was not edited."
    }
}

private struct NativeSourceEditJournal: Codable {
    let originalProjectUID: String
    let requestedName: String
    let plannedSteps: Int
    var nativeName: String?
    var nativeProjectUID: String?
    var stage: String
    var requestedStep: Int?
    var verifiedSteps: Int
    var failure: String?
    var failedStage: String?

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

extension FinalCutAXSession {
    /// Only the caller's successful final XML/media verification may complete
    /// the native journal. Reverification of the same completed result is
    /// idempotent; a partial or failed edit never becomes complete on Retry.
    static func markNativeSourceEditsVerified(directory: URL, projectUID: UUID) throws {
        guard directory.isFileURL else { throw FinalCutCaptureError.changedProject }
        let url = directory.appendingPathComponent("Native-Edit-Journal.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value > 0,
              size.int64Value <= 256 * 1_024 else { throw FinalCutCaptureError.changedProject }
        var journal = try JSONDecoder().decode(NativeSourceEditJournal.self, from: Data(contentsOf: url))
        guard journal.nativeProjectUID.flatMap(UUID.init(uuidString:)) == projectUID,
              journal.originalProjectUID != journal.nativeProjectUID,
              ["native edits complete; final comparison pending", "completed; verified"].contains(journal.stage),
              (1...NativeSourceEditPlan.maximumRemovals).contains(journal.plannedSteps),
              journal.verifiedSteps == journal.plannedSteps,
              journal.requestedStep == journal.plannedSteps,
              journal.nativeName == journal.requestedName,
              journal.failure == nil, journal.failedStage == nil else { throw FinalCutCaptureError.changedProject }
        guard journal.stage != "completed; verified" else { return }
        journal.stage = "completed; verified"
        try journal.save(to: url)
    }

    /// Every mutation is attempted once. A failed/uncertain native command is
    /// never replayed or "recovered" by importing XML with incomplete AU state.
    func applyNativeSourceEdits(plan: NativeSourceEditPlan, projectData: Data,
                               outputName: String, directory: URL, timing: AnalysisTiming,
                               beforeDuplicate: () async throws -> Void) async throws -> NativeSourceEditResult {
        guard projectName == plan.projectName, !outputName.isEmpty, outputName != projectName,
              outputName.utf8.count <= 1_024, directory.isFileURL,
              !FileManager.default.fileExists(atPath: directory.appendingPathComponent("Native-Edit-Journal.json").path) else {
            throw FinalCutCaptureError.changedProject
        }
        let original = try TimelineParser.parse(data: projectData)
        guard original.projectUID == plan.projectUID, original.fingerprint == plan.baselineFingerprint else {
            throw FinalCutCaptureError.changedProject
        }
        let destination = try XMLReplacementTarget(projectData: projectData)
        let journalURL = directory.appendingPathComponent("Native-Edit-Journal.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var journal = NativeSourceEditJournal(originalProjectUID: plan.projectUID,
            requestedName: outputName, plannedSteps: plan.steps.count, stage: "preparing", verifiedSteps: 0)
        try journal.save(to: journalURL)
        var duplicateMayExist = false
        var duplicateObservations: [[String: Any]] = []
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: duplicateObservations, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("Native-Duplicate-Observation.json"), options: .atomic)
            }
        }
        do {
            try await activate()
            try await prepareReplacementBrowser(destination)
            let browserReadURL = directory.appendingPathComponent("Native-Browser-Read.json")
            let browser = try nativeBrowser(containing: projectName, diagnosticURL: browserReadURL)
            guard !browser.entries.contains(where: { $0.name == outputName }) else {
                throw FinalCutCaptureError.unavailable("A project with this result name already exists. No duplicate was created.")
            }
            try nativeAssertLayout(plan.initial, plan: plan, range: nil)
            try await beforeDuplicate()
            try assertCurrentProject()
            try await prepareReplacementBrowser(destination)
            let before = try nativeBrowser(containing: projectName, diagnosticURL: browserReadURL)
            guard before.entries.map(\.name).sorted() == browser.entries.map(\.name).sorted(),
                  !before.entries.contains(where: { $0.name == outputName }) else {
                throw FinalCutCaptureError.changedProject
            }
            try nativeAssertLayout(plan.initial, plan: plan, range: nil)
            journal.stage = "duplicate requested"
            // Record the uncertain boundary before any input. No automatic
            // retry is possible, even if Final Cut acknowledges this late.
            try journal.save(to: journalURL)
            duplicateMayExist = true
            try await pressMenu(path: ["Edit", "Duplicate Project"])
            var duplicate: NativeBrowserEntry?
            var observedBrowser: NativeBrowser?
            do { try await waitUntil(timeout: 8, context: "one new native project duplicate") {
                var observation: [String: Any] = ["beforeNames": before.entries.map(\.name)]
                defer {
                    if duplicateObservations.count == 32 { duplicateObservations.removeFirst() }
                    duplicateObservations.append(observation)
                }
                do {
                    let current = try self.nativeBrowser(diagnosticURL: browserReadURL)
                    observation["afterNames"] = current.entries.map(\.name)
                    observation["selectedIndices"] = current.selectedIndices as Any? ?? NSNull()
                    observation["selectedFlags"] = current.entries.map { $0.selected as Any? ?? NSNull() }
                    observation["oldObjectsRetained"] = before.entries.filter { old in current.entries.contains { CFEqual(old.item, $0.item) && old.name == $0.name } }.count
                    observation["objectsAdded"] = current.entries.filter { entry in !before.entries.contains { CFEqual($0.item, entry.item) } }.count
                    let sameScope = (try? self.assertReplacementEvent(destination)) != nil
                    let index = try FinalCutNativeDuplicateObservation.candidateIndex(beforeNames: before.entries.map(\.name),
                        after: current.entries.map { .init(name: $0.name, selected: $0.selected) },
                        selectedIndices: current.selectedIndices, snapshotComplete: true, sameScope: sameScope)
                    duplicate = current.entries[index]
                    observedBrowser = current
                    observation["result"] = "one complete, selected semantic addition"
                    return true
                } catch {
                    observation["reason"] = error.localizedDescription
                    return false
                }
            } } catch FinalCutCaptureError.unavailable(let detail) where detail.contains("Timed out waiting for one new native project duplicate") {
                let reason = duplicateObservations.last?["reason"] as? String ?? "The complete selected addition was not observed."
                throw FinalCutCaptureError.unavailable("The duplicate command was sent once, but its new project could not be identified safely. \(reason) No cuts were made. Browser observations are saved in \(directory.appendingPathComponent("Native-Duplicate-Observation.json").path).")
            }
            guard let duplicate, observedBrowser != nil else { throw FinalCutCaptureError.changedProject }
            journal.nativeName = duplicate.name
            journal.stage = "duplicate created"
            try journal.save(to: journalURL)
            // Bind the host's new UUID and original content before modifying
            // even the duplicate's name. AX identities are presentation state.
            _ = try await selectBrowserProject(named: duplicate.name)
            let selectedBrowser = try nativeBrowser(containing: duplicate.name, diagnosticURL: browserReadURL)
            _ = try FinalCutNativeDuplicateObservation.candidateIndex(beforeNames: before.entries.map(\.name),
                after: selectedBrowser.entries.map { .init(name: $0.name, selected: $0.selected) },
                selectedIndices: selectedBrowser.selectedIndices, snapshotComplete: true,
                sameScope: (try? assertReplacementEvent(destination)) != nil)
            journal.stage = "opening native duplicate requested"
            try journal.save(to: journalURL)
            try await pressMenu(path: ["Clip", "Open Clip"], openingProject: duplicate.name)
            journal.stage = "native duplicate open command completed"
            try journal.save(to: journalURL)
            let unnamed = try await nativeOpenedSession(named: duplicate.name)
            journal.stage = "native duplicate session opened"
            try journal.save(to: journalURL)
            try await unnamed.activate()
            journal.stage = "native duplicate baseline export requested"
            try journal.save(to: journalURL)
            let unnamedURL = try await unnamed.exportProjectXML(to: directory.appendingPathComponent("Native-Unnamed-Baseline.fcpxmld"), timing: timing, sharePurpose: .apply)
            let unnamedData = try Data(contentsOf: unnamedURL)
            let baseline = try TimelineParser.parse(data: unnamedData)
            let unnamedIdentity = try XMLReplacementTarget(projectData: unnamedData)
            guard let uid = baseline.projectUID, let nativeUUID = UUID(uuidString: uid), uid != plan.projectUID,
                  unnamedIdentity.libraryURL == destination.libraryURL, unnamedIdentity.eventName == destination.eventName,
                  unnamedIdentity.eventUID == destination.eventUID, baseline.projectName == duplicate.name else {
                throw FinalCutCaptureError.changedProject
            }
            let unnamedExpected = try Self.nativeRenamedXML(projectData, name: duplicate.name)
            let report = try ProjectRoundTripVerification.compare(expected: unnamedExpected, actual: unnamedData,
                allowHostAssignedIdentity: true, expectedHostProjectUID: uid)
            guard report.verified else {
                throw EditedProjectWriterError.verificationFailed("the native duplicate differs from the original: " + report.differences.joined(separator: ", "))
            }
            journal.nativeProjectUID = uid
            journal.stage = "duplicate identity verified"
            try journal.save(to: journalURL)
            try await unnamed.prepareReplacementBrowser(unnamedIdentity, allowLibraryEventSelection: false)
            let forRename = try unnamed.nativeBrowser(containing: duplicate.name, diagnosticURL: browserReadURL)
            let renameIndex = try FinalCutNativeDuplicateObservation.candidateIndex(beforeNames: before.entries.map(\.name),
                after: forRename.entries.map { .init(name: $0.name, selected: $0.selected) },
                selectedIndices: forRename.selectedIndices, snapshotComplete: true,
                sameScope: (try? unnamed.assertReplacementEvent(unnamedIdentity)) != nil)
            let renameEntry = forRename.entries[renameIndex]
            try await unnamed.prepareInputFocus()
            guard unnamed.currentSheet() == nil, unnamed.string(renameEntry.nameField, kAXValueAttribute) == duplicate.name else {
                throw FinalCutCaptureError.changedProject
            }
            journal.stage = "verified duplicate rename requested"
            try journal.save(to: journalURL)
            guard AXUIElementSetAttributeValue(renameEntry.nameField, kAXValueAttribute as CFString, outputName as CFString) == .success else {
                throw FinalCutCaptureError.unavailable("The verified native duplicate could not be named safely.")
            }
            let edited = try await unnamed.nativeOpenedSession(named: outputName)
            journal.nativeName = outputName
            journal.stage = "duplicate named"
            try journal.save(to: journalURL)
            try await edited.activate()
            let baselineURL = try await edited.exportProjectXML(to: directory.appendingPathComponent("Native-Before-Cuts.fcpxmld"), timing: timing, sharePurpose: .apply)
            let baselineData = try Data(contentsOf: baselineURL)
            let identity = try XMLReplacementTarget(projectData: baselineData)
            let renamed = try Self.nativeRenamedXML(projectData, name: outputName)
            try ProjectRoundTripVerification.verify(expected: renamed, actual: baselineData,
                reportURL: directory.appendingPathComponent("Native-Rename-Verification.json"),
                allowHostAssignedIdentity: true, expectedHostProjectUID: uid)
            guard try TimelineParser.parse(data: baselineData).projectUID == uid,
                  identity.libraryURL == destination.libraryURL, identity.eventUID == destination.eventUID,
                  identity.eventName == destination.eventName, identity.projectName == outputName else { throw FinalCutCaptureError.changedProject }
            let boundBrowser = try edited.nativeBrowser(containing: outputName, diagnosticURL: browserReadURL)
            let boundIndex = try FinalCutNativeDuplicateObservation.candidateIndex(beforeNames: before.entries.map(\.name),
                after: boundBrowser.entries.map { .init(name: $0.name, selected: $0.selected) },
                selectedIndices: boundBrowser.selectedIndices, snapshotComplete: true,
                sameScope: (try? edited.assertReplacementEvent(identity)) != nil)
            let boundItem = boundBrowser.entries[boundIndex].item
            try await edited.focusTimeline()
            try await edited.clearTimelineRanges()
            let dropFrame = try Self.nativeDropFrame(projectData)
            try edited.nativeAssertLayout(plan.initial, plan: plan, range: nil)
            for step in plan.steps {
                try Task.checkCancellation()
                try await edited.activate()
                try await edited.focusTimeline()
                try await edited.clearTimelineRanges()
                try edited.nativeAssertLayout(step.expectedBefore, plan: plan, range: nil)
                try await edited.nativeSelect(segment: step.targetBefore, layout: step.expectedBefore, plan: plan)
                try await edited.nativeMovePlayhead(to: step.selectionRange.start, layout: step.expectedBefore,
                    plan: plan, range: nil, dropFrame: dropFrame)
                try edited.nativeAssertSelected(segment: step.targetBefore, layout: step.expectedBefore, plan: plan)
                try await edited.setRangeStartCommand()
                let initialRange = try edited.nativeRange(start: step.selectionRange.start,
                    end: step.targetBefore.timelineRange.end, plan: plan, dropFrame: dropFrame)
                try await edited.waitUntil(timeout: 3, context: "the native removal range start") {
                    (try? edited.renderedClipRange()) == initialRange
                }
                try await edited.nativeMovePlayhead(to: step.selectionRange.end.subtracting(plan.frameDuration),
                    layout: step.expectedBefore, plan: plan, range: initialRange, dropFrame: dropFrame)
                try edited.nativeAssertSelected(segment: step.targetBefore, layout: step.expectedBefore, plan: plan)
                try await edited.setRangeEndCommand() // Native out marker is inclusive.
                let removalRange = try edited.nativeRange(start: step.selectionRange.start,
                    end: step.selectionRange.end, plan: plan, dropFrame: dropFrame)
                try await edited.waitUntil(timeout: 3, context: "the exact native removal range") {
                    (try? edited.renderedClipRange()) == removalRange
                }
                try edited.nativeAssertLayout(step.expectedBefore, plan: plan, range: removalRange)
                try edited.nativeAssertSelected(segment: step.targetBefore, layout: step.expectedBefore, plan: plan)
                // A title and layout alone cannot distinguish a same-named
                // project in another event. Reveal the ACTIVE project afresh,
                // verify its original destination, then require the exact
                // native duplicate object before authorizing each Delete.
                try await edited.nativeAssertActiveDuplicate(identity: identity, browser: boundBrowser,
                    createdItem: boundItem)
                try edited.nativeAssertLayout(step.expectedBefore, plan: plan, range: removalRange)
                try edited.nativeAssertSelected(segment: step.targetBefore, layout: step.expectedBefore, plan: plan)
                journal.stage = "delete requested"
                journal.requestedStep = step.ordinal
                try journal.save(to: journalURL)
                try edited.assertInputFocus()
                try edited.nativeAssertLayout(step.expectedBefore, plan: plan, range: removalRange)
                try await edited.pressMenu(path: ["Edit", "Delete"])
                try await edited.waitUntil(timeout: 4, context: "the exact native edit result") {
                    (try? edited.nativeAssertLayout(step.expectedAfter, plan: plan, range: nil)) != nil
                }
                journal.verifiedSteps = step.ordinal
                journal.stage = "native edit verified"
                try journal.save(to: journalURL)
            }
            try edited.nativeAssertLayout(plan.final, plan: plan, range: nil)
            let finalURL = try await edited.exportProjectXML(to: directory.appendingPathComponent("Native-After-Cuts.fcpxmld"), timing: timing, sharePurpose: .apply)
            let finalData = try Data(contentsOf: finalURL)
            let finalDocument = try TimelineParser.parse(data: finalData)
            let finalIdentity = try XMLReplacementTarget(projectData: finalData)
            guard finalDocument.projectUID == uid, finalDocument.projectName == outputName,
                  finalIdentity.libraryURL == identity.libraryURL, finalIdentity.eventUID == identity.eventUID,
                  finalIdentity.eventName == identity.eventName else { throw FinalCutCaptureError.changedProject }
            try edited.nativeAssertLayout(plan.final, plan: plan, range: nil)
            journal.stage = "native edits complete; final comparison pending"
            try journal.save(to: journalURL)
            return .init(session: edited, baselineData: baselineData, finalData: finalData,
                projectUID: nativeUUID, finalXMLURL: finalURL)
        } catch {
            journal.failure = error.localizedDescription
            journal.failedStage = journal.stage
            journal.stage = "stopped; no action will be replayed"
            try? journal.save(to: journalURL)
            throw NativeSourceEditFailure(cause: error,
                duplicateName: journal.failedStage == "verified duplicate rename requested" ? nil : journal.nativeName,
                duplicateMayExist: duplicateMayExist, journalURL: journalURL)
        }
    }

    private struct NativeBrowserEntry {
        let item: AXUIElement
        let nameField: AXUIElement
        let name: String
        let selected: Bool?
    }

    private struct NativeBrowser {
        let container: AXUIElement
        let entries: [NativeBrowserEntry]
        let selectedIndices: [Int]?
    }

    private func nativeBrowser(containing name: String? = nil, diagnosticURL: URL? = nil) throws -> NativeBrowser {
        guard let organizer = find(in: mainWindow, role: kAXScrollAreaRole, description: "organizer"),
              let immediateParent = Self.elementAttribute(organizer, kAXParentAttribute),
              let organizerChildren = attribute(organizer, kAXChildrenAttribute) as? [AXUIElement],
              organizerChildren.count <= 32 else {
            throw FinalCutCaptureError.unavailable("The original event's project browser could not be read safely.")
        }
        // The selected project can move above the grouped rows, and insertion
        // can rebuild every AX item. Resolve the mounted browser structurally;
        // don't require the old original project's image to remain mounted.
        func fields(_ item: AXUIElement) -> [AXUIElement] {
            children(item).filter { string($0, kAXRoleAttribute) == kAXTextFieldRole && string($0, kAXDescriptionAttribute) == "display name" }
        }
        let containers = organizerChildren.filter { child in
            guard let items = attribute(child, kAXChildrenAttribute) as? [AXUIElement], items.count <= 600 else { return false }
            return items.contains { !fields($0).isEmpty }
        }
        guard containers.count == 1, let container = containers.first,
              let raw = attribute(container, kAXChildrenAttribute) as? [AXUIElement], raw.count <= 600 else {
            throw FinalCutCaptureError.unavailable("The project browser is incomplete or ambiguous.")
        }
        var entries: [NativeBrowserEntry] = []
        for candidate in raw {
            let itemFields = fields(candidate)
            guard !itemFields.isEmpty else { continue }
            if entries.contains(where: { CFEqual($0.item, candidate) }) { continue }
            guard itemFields.count == 1, let field = itemFields.first,
                  let value = string(field, kAXValueAttribute), !value.isEmpty,
                  children(candidate).filter({ string($0, kAXRoleAttribute) == kAXImageRole &&
                      (string($0, kAXTitleAttribute) == value || string($0, kAXDescriptionAttribute) == value) }).count == 1 else {
                throw FinalCutCaptureError.unavailable("The project browser contains ambiguous items.")
            }
            entries.append(.init(item: candidate, nameField: field, name: value,
                selected: (attribute(candidate, kAXSelectedAttribute) as? NSNumber)?.boolValue))
        }
        // Final Cut inserts AXGroup wrappers around the organizer that are
        // omitted from the visible tree. Cross only transparent single-child
        // wrappers to reach the footer's actual sibling scope; never search
        // an unrelated browser or the whole window for a plausible count.
        var parent = immediateParent
        var branch = organizer
        var parentChildren = children(parent)
        var wrapperCount = 0
        while parentChildren.count == 1, CFEqual(parentChildren[0], branch), wrapperCount < 4 {
            guard string(parent, kAXRoleAttribute) == kAXGroupRole,
                  let ancestor = Self.elementAttribute(parent, kAXParentAttribute),
                  !CFEqual(ancestor, parent), !CFEqual(ancestor, organizer) else { break }
            branch = parent
            parent = ancestor
            parentChildren = children(parent)
            wrapperCount += 1
        }
        var footerElements: [AXUIElement] = []
        for element in parentChildren where string(element, kAXRoleAttribute) == kAXStaticTextRole {
            if !footerElements.contains(where: { CFEqual($0, element) }) { footerElements.append(element) }
        }
        let footerTexts = footerElements.map { element in
            [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attributeName -> String? in
                let value = attribute(element, attributeName)
                return (value as? String) ?? (value as? NSAttributedString)?.string
            }
        }
        let reportedCount = FinalCutNativeDuplicateObservation.reportedItemCount(footerTexts: footerTexts)
        if let diagnosticURL {
            let snapshot: [String: Any] = ["entryNames": entries.map(\.name), "footerTexts": footerTexts,
                "reportedCount": reportedCount as Any? ?? NSNull(), "parentRole": string(parent, kAXRoleAttribute) ?? "",
                "transparentWrappers": wrapperCount,
                "parentChildren": parentChildren.prefix(48).map { element in
                    ["role": string(element, kAXRoleAttribute) ?? "", "value": string(element, kAXValueAttribute) ?? "",
                     "title": string(element, kAXTitleAttribute) ?? "", "description": string(element, kAXDescriptionAttribute) ?? ""]
                }]
            if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: diagnosticURL, options: .atomic)
            }
        }
        guard reportedCount == entries.count else {
            throw FinalCutCaptureError.unavailable("Final Cut Pro's browser item count has not settled. All event items must be visible before native duplication can be verified.")
        }
        if let name {
            guard entries.filter({ $0.name == name }).count == 1 else { throw FinalCutCaptureError.changedProject }
        }
        var selectedIndices: [Int]?
        if let selected = attribute(container, kAXSelectedChildrenAttribute) as? [AXUIElement] {
            selectedIndices = try selected.map { item in
                guard let index = entries.firstIndex(where: { CFEqual($0.item, item) }) else {
                    throw FinalCutCaptureError.unavailable("The browser's selected project is not part of its complete item snapshot.")
                }
                return index
            }
        }
        return .init(container: container, entries: entries, selectedIndices: selectedIndices)
    }

    private func nativeSameEntries(_ lhs: [NativeBrowserEntry], _ rhs: [NativeBrowserEntry]) -> Bool {
        lhs.count == rhs.count && lhs.allSatisfy { left in rhs.contains { CFEqual(left.item, $0.item) && left.name == $0.name } }
    }

    private func nativeSelectedBrowserItems(in container: AXUIElement) -> [AXUIElement] {
        attribute(container, kAXSelectedChildrenAttribute) as? [AXUIElement] ?? []
    }

    private func nativeAssertActiveDuplicate(identity: XMLReplacementTarget, browser: NativeBrowser,
                                             createdItem: AXUIElement) async throws {
        // prepareReplacementBrowser reveals first and checks the revealed
        // library/event before selecting by name. Merely reading a stale
        // browser selection would not bind it to the active timeline.
        try await prepareReplacementBrowser(identity, allowLibraryEventSelection: false)
        let current = try nativeBrowser(containing: identity.projectName)
        guard CFEqual(current.container, browser.container),
              nativeSameEntries(current.entries, browser.entries),
              current.entries.filter({ $0.name == identity.projectName }).map({ CFEqual($0.item, createdItem) }) == [true],
              nativeSelectedBrowserItems(in: current.container).map({ CFEqual($0, createdItem) }) == [true] else {
            throw FinalCutCaptureError.changedProject
        }
        try assertCurrentProject()
        guard currentSheet() == nil, nativeTimelineHasFocus() else { throw FinalCutCaptureError.changedProject }
    }

    private func nativeOpenedSession(named name: String) async throws -> FinalCutAXSession {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            try Task.checkCancellation()
            if let current = try? FinalCutAXSession(inheritingWorkflowFrom: self) {
                guard current.application.processIdentifier == application.processIdentifier,
                      CFEqual(current.mainWindow, mainWindow) else { throw FinalCutCaptureError.changedProject }
                if current.projectName == name { return current }
                guard current.projectName == projectName else { throw FinalCutCaptureError.changedProject }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw FinalCutCaptureError.unavailable("Final Cut Pro did not open the native duplicate. No cuts were made.")
    }

    private struct NativeClipItem {
        let element: AXUIElement
        let range: TimeRange
        let selected: Bool
    }

    /// The source mapping is independently verified in the exported final XML.
    /// Native AX supplies exact occurrence geometry before every range delete.
    private func nativeClipItems(plan: NativeSourceEditPlan) throws -> [NativeClipItem] {
        try assertCurrentProject()
        try refreshTimeline()
        guard let raw = attribute(timeline, kAXChildrenAttribute) as? [AXUIElement], raw.count <= 1_000 else {
            throw FinalCutCaptureError.changedProject
        }
        var items: [NativeClipItem] = []
        for item in raw where string(item, kAXRoleAttribute) == kAXLayoutItemRole {
            if string(item, kAXDescriptionAttribute) == "Range Selection" { continue }
            guard string(item, kAXDescriptionAttribute) == "Audio-Clip:" + plan.target.name,
                  let durationText = string(item, kAXValueAttribute), !durationText.contains(";"),
                  let selected = (attribute(item, kAXSelectedAttribute) as? NSNumber)?.boolValue else {
                throw FinalCutCaptureError.changedProject
            }
            let parts = children(item)
            guard parts.count <= 100 else { throw FinalCutCaptureError.changedProject }
            let leading = parts.filter { string($0, kAXRoleAttribute) == "AXHandle" && string($0, kAXDescriptionAttribute) == "Leading Edge" }
            let position = parts.filter { string($0, kAXRoleAttribute) == "AXHandle" && string($0, kAXDescriptionAttribute) == "Item" }
            let trailing = parts.filter { string($0, kAXRoleAttribute) == "AXHandle" && string($0, kAXDescriptionAttribute) == "Trailing Edge" }
            guard leading.count <= 1, trailing.count <= 1, position.count == 1,
                  let itemPosition = string(position[0], kAXValueAttribute) else { throw FinalCutCaptureError.changedProject }
            let absoluteStart = try FinalCutTimecode.time(itemPosition, frameDuration: plan.frameDuration)
            if let lead = leading.first {
                guard string(lead, kAXValueAttribute) == itemPosition else { throw FinalCutCaptureError.changedProject }
            }
            let start = try absoluteStart.subtracting(plan.projectTimecodeStart)
            let duration = try FinalCutTimecode.time(durationText, frameDuration: plan.frameDuration)
            let end = try start.adding(duration)
            if let tail = trailing.first {
                guard let value = string(tail, kAXValueAttribute),
                      try FinalCutTimecode.time(value, frameDuration: plan.frameDuration) == absoluteStart.adding(duration) else {
                    throw FinalCutCaptureError.changedProject
                }
            }
            guard start >= .zero, end > start else { throw FinalCutCaptureError.changedProject }
            items.append(.init(element: item, range: .init(start: start, end: end), selected: selected))
        }
        return items.sorted { $0.range.start < $1.range.start }
    }

    private func nativeAssertLayout(_ layout: NativeSourceEditPlan.Layout, plan: NativeSourceEditPlan,
                                    range: FinalCutRenderedClipRange?) throws {
        try assertInputFocus()
        guard currentSheet() == nil, try renderedClipRange() == range else { throw FinalCutCaptureError.changedProject }
        let items = try nativeClipItems(plan: plan)
        guard items.map(\.range) == layout.segments.map(\.timelineRange),
              items.last?.range.end == layout.duration else { throw FinalCutCaptureError.changedProject }
    }

    private func nativeAssertSelected(segment: NativeSourceEditPlan.Segment,
                                      layout: NativeSourceEditPlan.Layout, plan: NativeSourceEditPlan) throws {
        let selected = try nativeClipItems(plan: plan).filter(\.selected)
        guard selected.count == 1, selected[0].range == segment.timelineRange else { throw AudioControllerSettingsError.targetChanged }
    }

    private func nativeSelect(segment: NativeSourceEditPlan.Segment, layout: NativeSourceEditPlan.Layout,
                              plan: NativeSourceEditPlan) async throws {
        try await focusTimeline()
        try nativeAssertLayout(layout, plan: plan, range: nil)
        let matches = try nativeClipItems(plan: plan).filter { $0.range == segment.timelineRange }
        guard matches.count == 1,
              AXUIElementSetAttributeValue(timeline, kAXSelectedChildrenAttribute as CFString,
                [matches[0].element] as CFArray) == .success else { throw AudioControllerSettingsError.targetChanged }
        try await waitUntil(timeout: 3, context: "the exact native source segment") {
            (try? self.nativeAssertSelected(segment: segment, layout: layout, plan: plan)) != nil
        }
    }

    private func nativeRange(start: RationalTime, end: RationalTime, plan: NativeSourceEditPlan,
                             dropFrame: Bool) throws -> FinalCutRenderedClipRange {
        // Reuse the immutable value's parser initializer without fabricating a
        // mutable Final Cut selection or relying on screen coordinates.
        let startText = try FinalCutTimecode.format(start.adding(plan.projectTimecodeStart), frameDuration: plan.frameDuration, dropFrame: dropFrame)
        let endText = try FinalCutTimecode.format(end.adding(plan.projectTimecodeStart), frameDuration: plan.frameDuration, dropFrame: dropFrame)
        let durationText = try FinalCutTimecode.format(end.subtracting(start), frameDuration: plan.frameDuration)
        guard let range = FinalCutRenderedClipRange(timeline: .init(role: kAXLayoutAreaRole, identifier: nil, title: nil,
            description: "Project Timeline", value: nil, selected: nil, enabled: nil, children: [
                .init(role: kAXLayoutItemRole, identifier: nil, title: nil, description: "Range Selection",
                    value: durationText, selected: nil, enabled: nil, children: [
                        .init(role: "AXHandle", identifier: nil, title: nil, description: "Range Start", value: startText, selected: nil, enabled: nil, children: []),
                        .init(role: "AXHandle", identifier: nil, title: nil, description: "Range End", value: endText, selected: nil, enabled: nil, children: [])])])) else {
            throw FinalCutCaptureError.changedProject
        }
        return range
    }

    private func nativeTimelineHasFocus() -> Bool {
        if (attribute(timeline, kAXFocusedAttribute) as? NSNumber)?.boolValue == true { return true }
        var focused = Self.elementAttribute(root, kAXFocusedUIElementAttribute)
        for _ in 0..<12 {
            guard let item = focused else { return false }
            if CFEqual(item, timeline) { return true }
            focused = Self.elementAttribute(item, kAXParentAttribute)
        }
        return false
    }

    /// Control-P is Final Cut's explicit absolute-position editor. Unlike free
    /// digit entry it does not trim a selected clip. The owned range and clip
    /// geometry must remain unchanged through every input and before Return.
    private func nativeMovePlayhead(to time: RationalTime, layout: NativeSourceEditPlan.Layout,
                                    plan: NativeSourceEditPlan, range: FinalCutRenderedClipRange?,
                                    dropFrame: Bool) async throws {
        try nativeAssertLayout(layout, plan: plan, range: range)
        guard time >= .zero, time < layout.duration, nativeTimelineHasFocus(),
              let lcd = Self.search(mainWindow, role: kAXStaticTextRole, description: "Timecode LCD", containersOnly: true),
              let controls = Self.elementAttribute(lcd, kAXParentAttribute) else { throw FinalCutCaptureError.changedProject }
        let selection = try nativeClipItems(plan: plan).filter(\.selected).map(\.element)
        guard selection.count == 1 else { throw AudioControllerSettingsError.targetChanged }
        let value = try FinalCutTimecode.format(time.adding(plan.projectTimecodeStart),
            frameDuration: plan.frameDuration, dropFrame: dropFrame)
        func numericOpen(lcd currentLCD: AXUIElement, controls currentControls: AXUIElement) -> Bool {
            let nodes = children(currentControls)
            return nodes.count <= 100 && nodes.contains(where: { CFEqual($0, currentLCD) }) &&
                nodes.filter { string($0, kAXRoleAttribute) == kAXButtonRole &&
                    (string($0, kAXDescriptionAttribute) == "Numeric Entry Type" || string($0, kAXTitleAttribute) == "Numeric Entry Type") }.count == 1 &&
                nodes.filter { string($0, kAXRoleAttribute) == kAXImageRole &&
                    (string($0, kAXDescriptionAttribute) == "Numeric Entry Direction" || string($0, kAXTitleAttribute) == "Numeric Entry Direction") }.count == 1
        }
        func numericOpen() -> Bool { numericOpen(lcd: lcd, controls: controls) }
        func assertOwned() throws {
            try assertInputFocus()
            try nativeAssertLayout(layout, plan: plan, range: range)
            let current = try nativeClipItems(plan: plan).filter(\.selected).map(\.element)
            guard nativeTimelineHasFocus(), current.count == selection.count,
                  zip(current, selection).allSatisfy({ pair in CFEqual(pair.0, pair.1) }) else { throw AudioControllerSettingsError.targetChanged }
        }
        guard !numericOpen() else { throw FinalCutCaptureError.unavailable("Finish the current timecode entry before applying cuts.") }
        var opened = false
        var commitObservation: [String: Any] = [:]
        do {
            try await prepareInputFocus()
            try assertOwned()
            try key(code: 35, flags: .maskControl)
            opened = true
            try await waitUntil(timeout: 2, context: "the native position editor") { numericOpen() }
            let codes: [Character: CGKeyCode] = ["0": 82, "1": 83, "2": 84, "3": 85, "4": 86,
                "5": 87, "6": 88, "7": 89, "8": 91, "9": 92]
            for digit in value.filter(\.isNumber) {
                try Task.checkCancellation()
                try await prepareInputFocus()
                try assertOwned()
                guard numericOpen(), let code = codes[digit] else { throw FinalCutCaptureError.changedProject }
                try key(code: code, flags: .maskNumericPad)
            }
            try await waitUntil(timeout: 2, context: "the pending native position") { numericOpen() && string(lcd, kAXValueAttribute) == value }
            try await prepareInputFocus()
            try assertOwned()
            guard numericOpen(), string(lcd, kAXValueAttribute) == value else { throw FinalCutCaptureError.changedProject }
            // Return can commit even if a following observation fails. Do not
            // send cleanup Escape after crossing this uncertain boundary.
            opened = false
            try key(code: 36)
            // Committing absolute timecode can rebuild both the viewer controls
            // and timeline accessibility nodes. Re-read them; an old editor's
            // retained children must not make a correct committed frame fail.
            // This only waits for evidence and never sends Return a second time.
            try await waitUntil(timeout: 5, context: "the exact native playhead") {
                guard (try? self.refreshTimeline()) != nil,
                      let currentLCD = Self.search(self.mainWindow, role: kAXStaticTextRole,
                          description: "Timecode LCD", containersOnly: true),
                      let currentControls = Self.elementAttribute(currentLCD, kAXParentAttribute),
                      self.string(currentLCD, kAXValueAttribute) == value else { return false }
                let playheads = self.children(self.timeline).filter {
                    self.string($0, kAXRoleAttribute) == kAXValueIndicatorRole && self.string($0, kAXDescriptionAttribute) == "Playhead"
                }
                let editorOpen = numericOpen(lcd: currentLCD, controls: currentControls)
                let positions = playheads.map { self.string($0, kAXValueAttribute) ?? "unreadable" }
                commitObservation = ["expected": value, "lcd": self.string(currentLCD, kAXValueAttribute) ?? "unreadable",
                    "numericEditorOpen": editorOpen, "playheads": positions]
                return !editorOpen && positions == [value]
            }
            try await prepareInputFocus()
            try assertOwned()
        } catch {
            if !commitObservation.isEmpty, let directory = lastXMLShareDirectory,
               let data = try? JSONSerialization.data(withJSONObject: commitObservation, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("Native-Playhead-Observation.json"), options: .atomic)
            }
            // Dismiss only this operation's unchanged numeric editor. If the
            // user changes context, no Escape or other cleanup input is sent.
            if opened, numericOpen(), (try? assertOwned()) != nil { try? key(code: 53) }
            throw error
        }
    }

    private static func nativeRenamedXML(_ data: Data, name: String) throws -> Data {
        let xml = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        let projects = try xml.nodes(forXPath: "/fcpxml/library/event/project").compactMap { $0 as? XMLElement }
        guard projects.count == 1, let project = projects.first, let attribute = project.attribute(forName: "name") else {
            throw FinalCutCaptureError.changedProject
        }
        attribute.stringValue = name
        return xml.xmlData(options: [])
    }

    private static func nativeDropFrame(_ data: Data) throws -> Bool {
        let xml = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        let sequences = try xml.nodes(forXPath: "/fcpxml/library/event/project/sequence").compactMap { $0 as? XMLElement }
        guard sequences.count == 1, let sequence = sequences.first else { throw FinalCutCaptureError.changedProject }
        let value = sequence.attribute(forName: "tcFormat")?.stringValue ?? "NDF"
        guard value == "DF" || value == "NDF" else { throw FinalCutCaptureError.changedProject }
        return value == "DF"
    }
}
