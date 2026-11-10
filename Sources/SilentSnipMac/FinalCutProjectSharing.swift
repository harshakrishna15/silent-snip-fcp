import AppKit
import ApplicationServices
import SilentSnipCore
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

extension FinalCutAXSession {
    func exportProjectXML(to destination: URL, timing: AnalysisTiming? = nil,
                          sharePurpose: DirectShareAXPurpose = .ordinary) async throws -> URL {
        let timing = timing ?? AnalysisTiming(request: UUID())
        try assertCurrentProject()
        guard currentSheet() == nil, destination.isFileURL,
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw FinalCutCaptureError.unavailable("Close the current dialog before requesting project XML.")
        }
        let delivered = try await timing.measure("share.xml.exchange") {
            try await ShareDestinationManager.shared.captureXML(projectName: projectName) {
                try await timing.measure("share.xml.setup") { try await self.beginShare(renderAudio: false, timing: timing, sharePurpose: sharePurpose) }
            }
        }
        lastXMLShareDirectory = delivered.deletingLastPathComponent().standardizedFileURL
        let output = try timing.measure("share.xml.deliveryValidation") { () throws -> URL in
            try assertCurrentProject()
            let input = delivered.pathExtension.lowercased() == "fcpxmld"
                ? delivered.appendingPathComponent("Info.fcpxml") : delivered
            let data = try Data(contentsOf: input)
            _ = try TimelineParser.parse(data: data)
#if DEBUG
            if QuietSharePrototype.pluginLease != nil { try QuietSharePrototype.verifyLibrary(data) }
#endif
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Save the exact bytes that were validated above.
            let output: URL
            if destination.pathExtension.lowercased() == "fcpxmld" {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                output = destination.appendingPathComponent("Info.fcpxml")
            } else { output = destination }
            try data.write(to: output, options: .withoutOverwriting)
            return output
        }
        try await timing.measure("share.xml.panelClose") {
            try await waitUntil(timeout: 5, context: "the completed XML exchange") { self.currentSheet() == nil }
        }
        // The host's Open Document message may activate this accessory helper.
        // Return input to the pinned project before checking the same selection.
        try await restoreProjectFocusAfterShare(timing: timing, prefix: "share.xml")
        return output
    }

    func shareRenderedAudio(timing: AnalysisTiming? = nil,
                            renderSelection: FinalCutSelectionSnapshot? = nil,
                            mixScope: FinalCutAudioMixScope = .dialogue,
                            sharePurpose: DirectShareAXPurpose = .ordinary) async throws -> ShareDestinationReceipt {
        // Full-project mix evidence cannot authorize a selected-range export.
        // Reject before activation, range preparation, or any Share dispatch.
        guard mixScope.permitsSelectionRange(renderSelection != nil) else {
            throw FinalCutDialogueExport.ExportError.unverifiedFullProjectMixOutput
        }
        let timing = timing ?? AnalysisTiming(request: UUID())
        // Hashing can yield after capture focused the timeline. A delayed AU
        // field commit or our own URL delivery may then raise Controls again.
        // Restore only this pinned project, before any range command is sent.
        if (try? assertInputFocus()) == nil {
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard foreground == application.processIdentifier || foreground == NSRunningApplication.current.processIdentifier else {
                throw FinalCutCaptureError.unavailable("The audio export lost focus to another application. Return to Final Cut Pro and analyze the clip again.")
            }
            try assertCurrentProject()
            if let expected = reviewOwnership.active, try selectionSnapshot() != expected {
                throw AudioControllerSettingsError.targetChanged
            }
            try await timing.measure("share.render.restoreProjectFocus") { try await activate() }
        }
        var receipt: ShareDestinationReceipt?
        var preparedRange = false
        do {
            if let renderSelection {
                try await timing.measure("share.render.selectClipRange") { try await prepareRenderedClipRange(selection: renderSelection) }
                preparedRange = true
            } else if let expected = reviewOwnership.active {
                if let range = try renderedClipRange() {
                    try await timing.measure("share.render.clearRanges") {
                        try await clearRenderedClipRange(selection: expected, expectedRange: range)
                    }
                }
            } else {
                try await timing.measure("share.render.clearRanges") { try await clearTimelineRanges() }
            }
            let delivered = try await timing.measure("share.render.exchange") {
                try await ShareDestinationManager.shared.captureMedia(projectName: projectName) {
                    try await timing.measure("share.render.setup") {
                        try await self.beginShare(renderAudio: true, timing: timing, renderSelection: renderSelection,
                            mixScope: mixScope, sharePurpose: sharePurpose)
                    }
                }
            }
            receipt = delivered
#if DEBUG
            if QuietSharePrototype.pluginLease != nil { try QuietSharePrototype.verifyLibrary(delivered.xmlURL) }
#endif
            // The real Open Document delivery can activate the accessory helper.
            // Direct rendering stays in this project, so there is no return-project
            // navigation to restore focus on its behalf.
            try await restoreProjectFocusAfterShare(timing: timing, prefix: "share.render.postDelivery")
            if let renderSelection {
                preparedRange = false // Never retry an uncertain Clear command.
                try await timing.measure("share.render.restoreClipSelection") { try await clearRenderedClipRange(selection: renderSelection) }
            }
            return delivered
        } catch {
            if preparedRange, let renderSelection {
                await Task { @MainActor in
                    guard self.currentSheet() == nil else { return }
                    try? await self.clearRenderedClipRange(selection: renderSelection)
                }.value
            }
            // A post-delivery focus/range failure must not orphan its WAV just
            // because the receipt never reached the caller's cleanup scope.
            if let receipt { try? ShareDestinationManager.shared.cleanupRenderedMedia(receipt: receipt) }
            throw error
        }
    }

    private func restoreProjectFocusAfterShare(timing: AnalysisTiming, prefix: String) async throws {
        let before = activationCounters
        defer {
            let prior = timing.report(outcome: "in progress").counters
            timing.recordCounters(Dictionary(uniqueKeysWithValues: activationCounters.map {
                let name = prefix + ".activation." + $0.key
                return (name, (prior[name] ?? 0) + $0.value - (before[$0.key] ?? 0))
            }))
        }
        try await timing.measure(prefix + ".restoreProjectFocus") { try await activate() }
    }

    private func beginShare(renderAudio: Bool, timing: AnalysisTiming,
                            renderSelection: FinalCutSelectionSnapshot? = nil,
                            mixScope: FinalCutAudioMixScope = .dialogue,
                            sharePurpose: DirectShareAXPurpose = .ordinary) async throws {
#if DEBUG
        let previousPrototypeMenu = quietPrototypeMenu
        if renderAudio, let lease = QuietSharePrototype.pluginLease {
            // The 12.4 Return probe delivered WAV/XML without exposing the
            // settings panel. That cannot prove the required Dialogue mix.
            // Choose visible legacy input before a NEW render dispatch; never
            // retry the already delivered probe or accept its unverified audio.
            lease.reveal(reason: "Processed-audio Share requires visible settings verification.")
            quietPrototypeInvocation?("Processed-audio Share: visible legacy path selected before dispatch")
            quietPrototypeMenu = false
        }
        defer { quietPrototypeMenu = previousPrototypeMenu }
#endif
        let prefix = renderAudio ? "share.render" : "share.xml"
        let confirmationControls = FinalCutShareConfirmationControls<AXUIElement>(
            read: { FinalCutAXAttributes.read($0, names: $1) },
            children: { self.children($0) }, equals: { CFEqual($0, $1) })
        defer {
            let prior = timing.report(outcome: "in progress").counters
            timing.recordCounters(Dictionary(uniqueKeysWithValues: confirmationControls.counters.map {
                let name = prefix + "." + $0.key
                return (name, (prior[name] ?? 0) + $0.value)
            }))
        }
        var observedPanel: AXUIElement?
        let integration = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Silent Snip/Integration", isDirectory: true).standardizedFileURL
        // A disable-only diagnostic switch permits same-binary comparisons of
        // the ordinary route. It never bypasses audio or project verification.
        let probe: DirectShareAXProbe?
        do {
            if let diagnostic = try DirectShareAXConfiguration.load(directory: integration, origin: workflowOrigin) {
                probe = DirectShareAXProbe(configuration: diagnostic, directory: integration,
                    request: timing.report(outcome: "in progress").request, phase: prefix)
            } else if !FileManager.default.fileExists(atPath: integration.appendingPathComponent("DisableAutomaticDirectShareAX").path),
                      let configuration = DirectShareAXConfiguration.production(origin: workflowOrigin,
                purpose: sharePurpose, projectName: projectName) {
                probe = DirectShareAXProbe(configuration: configuration,
                    request: timing.report(outcome: "in progress").request, phase: prefix, mode: .production)
            } else { probe = nil }
        } catch {
            DirectShareAXProbe.rejected(request: timing.report(outcome: "failed").request,
                phase: prefix, error: error, directory: integration)
            timing.recordCounters([prefix + ".directAX.enabled": 1, prefix + ".directAX.configurationRejected": 1,
                prefix + ".directAX.attempts": 0, prefix + ".directAX.fallbacks": 0])
            throw error
        }
        defer { probe?.record(timing: timing, prefix: prefix) }
        var ownsPanel = false
        do {
            probe?.update {
                $0.foregroundBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
                $0.projectBefore = self.currentProjectTitle().map { String($0.prefix(512)) }
            }
            try assertCurrentProject()
            guard currentSheet() == nil else { throw FinalCutCaptureError.unavailable("Close the current dialog before sharing.") }
            if probe == nil || probe?.mode == .production {
                try await timing.measure(prefix + ".focus") { try await focusTimeline() }
            }
            try await timing.measure(prefix + ".openPanel") {
                var useOrdinaryRoute = probe == nil
                if let probe {
                    do {
                        let existing = try invokeClosedShareAX(probe: probe, timing: timing, prefix: prefix)
                        try await timing.measure(prefix + ".directAX.observePanel") {
                            do {
                                try await waitUntil(timeout: 10, context: "a new owned Share panel after the single closed-menu AX action") {
                                    guard let panel = self.currentSheet() else { return false }
                                    var owner: pid_t = 0
                                    let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
                                    let observation = DirectShareAXPanelObservation(
                                        existedBeforeDispatch: existing.contains { CFEqual($0, panel) },
                                        ownedByPinnedHost: AXUIElementGetPid(panel, &owner) == .success && owner == self.application.processIdentifier,
                                        title: self.string(panel, kAXTitleAttribute),
                                        enabledNextFound: confirmationControls.next(in: panel, shouldContinue: { !Task.isCancelled }) != nil,
                                        projectMatches: self.currentProjectTitle() == self.projectName,
                                        foregroundIsHostOrHelper: foreground == self.application.processIdentifier || foreground == NSRunningApplication.current.processIdentifier)
                                    guard observation.provesCompletion else { return false }
                                    observedPanel = panel
                                    probe.update { $0.observedOwnedPanel = true }
                                    return true
                                }
                            } catch {
                                if error is CancellationError || Task.isCancelled { throw error }
                                throw DirectShareAXError.uncertain(String(error.localizedDescription.prefix(1_024)))
                            }
                        }
                    } catch {
                        // Only a production preflight miss may choose ordinary
                        // input. An attempted action, even an AX error, remains
                        // consumed and can only be observed, never dispatched again.
                        guard probe.mode == .production, probe.report.attemptCount == 0 else { throw error }
                        try Task.checkCancellation()
                        try assertCurrentProject()
                        try assertInputFocus()
                        guard currentSheet() == nil, let expected = reviewOwnership.active,
                              try selectionSnapshot() == expected else {
                            throw AudioControllerSettingsError.targetChanged
                        }
                        guard probe.selectOrdinaryFallback(for: error) else { throw error }
                        useOrdinaryRoute = true
                    }
                }
                if useOrdinaryRoute {
                    let path = ["File", "Share", "Silent Snip…"]
                    let menuPath = makeMenuPath(path: path)
                    defer {
                        let prior = timing.report(outcome: "in progress").counters
                        timing.recordCounters(Dictionary(uniqueKeysWithValues: menuPath.counters.map {
                            let name = prefix + "." + $0.key
                            return (name, (prior[name] ?? 0) + $0.value)
                        }))
                    }
                    let usedShortcut = try await FinalCutShareInvocation.perform(shortcut: {
#if DEBUG
                        // Explicit legacy probes and the processed-audio prototype
                        // select visible menu input before dispatch. Preserve that
                        // choice without disabling the normal Release shortcut.
                        if (self.quietPrototypeStage != nil || QuietSharePrototype.pluginLease != nil),
                           !self.quietPrototypeMenu {
                            self.quietPrototypeInvocation?("File → Share → Silent Snip…: legacy-visible-menu")
                            return false
                        }
#endif
                        let used = try self.pressAdvertisedMenuShortcut(path: path, menuPath: menuPath)
#if DEBUG
                        if used { self.quietPrototypeInvocation?("File → Share → Silent Snip…: advertised-shortcut") }
#endif
                        return used
                    }, menu: {
                        let observed = try await FinalCutShareInvocation.performMenu(menu: { markFinalAttempt in
                            try await self.pressMenu(path: path, menuPath: menuPath,
                                onFinalDispatchAttempt: markFinalAttempt)
                        }, observeCompletion: {
                            try await self.observePendingShareConfirmation()
                        })
                        if observed { timing.recordCounters([prefix + ".panelObservedAfterFinalMenuAttempt": 1]) }
                    })
                    timing.recordCounters([prefix + ".advertisedShortcut": usedShortcut ? 1 : 0])
                    try await waitUntil(timeout: 10, context: "Silent Snip Share confirmation") {
#if DEBUG
                        if self.quietPrototypeStage != nil,
                           ShareDestinationManager.shared.prototypeShareHasResponse(projectName: self.projectName) { return true }
#endif
                        guard let panel = self.currentSheet() else { return false }
                        guard self.string(panel, kAXTitleAttribute) == "Silent Snip",
                              confirmationControls.next(in: panel, shouldContinue: { !Task.isCancelled }) != nil else { return false }
                        observedPanel = panel
                        return true
                    }
                }
            }
#if DEBUG
            if probe == nil, quietPrototypeStage != nil, ShareDestinationManager.shared.prototypeShareHasResponse(projectName: projectName) {
                // Some hosts complete XML without showing a confirmation. A
                // rendered response cannot stand in for verified live settings.
                guard !renderAudio else { throw FinalCutDialogueExport.ExportError.unverifiedDialogueOutput }
                quietPrototypeStage?("xmlDeliveredWithoutPanel")
                return
            }
#endif
            ownsPanel = true
            // restoreOwnShareActivation immediately revalidates this panel's
            // ownership; reuse the successful readiness observation here.
            guard let panel = observedPanel else { throw FinalCutCaptureError.unavailable("Share panel disappeared.") }
            try await restoreOwnShareActivation(panel: panel)
            if renderAudio { try await FinalCutDialogueExport.configureShare(panel, session: self, timing: timing, mixScope: mixScope) }
            if let renderSelection,
               try renderedClipRange() != FinalCutRenderedClipRange(selection: renderSelection) {
                throw FinalCutCaptureError.invalidSelection("The selected clip export range changed before rendering.")
            }
            if case .fullProjectMix = mixScope {
                // Recheck immediately before dispatch. Failed AX reads must not
                // become an empty range and silently accept a partial mix.
                try refreshTimeline()
                guard string(timeline, kAXRoleAttribute) == kAXLayoutAreaRole,
                      string(timeline, kAXDescriptionAttribute) == "Project Timeline",
                      let items = attribute(timeline, kAXChildrenAttribute) as? [AXUIElement],
                      items.count <= 10_000,
                      !items.contains(where: { string($0, kAXDescriptionAttribute) == "Range Selection" }) else {
                    throw FinalCutDialogueExport.ExportError.unverifiedFullProjectMixOutput
                }
            }
#if DEBUG
            quietPrototypeStage?("beforeConfirmation")
            try Task.checkCancellation()
#endif
            try await restoreOwnShareActivation(panel: panel)
            guard let next = confirmationControls.next(in: panel, shouldContinue: { !Task.isCancelled }) else {
                throw FinalCutCaptureError.unavailable("The Share confirmation is unavailable.")
            }
            _ = try timing.measure(prefix + ".confirm") {
                // An AX error after dispatch can still mean Final Cut accepted
                // Next. Cleanup may only cancel the exact untouched panel.
                try press(next) { ownsPanel = false }
            }
            probe?.finish(foreground: NSWorkspace.shared.frontmostApplication?.processIdentifier, project: currentProjectTitle())
#if DEBUG
            quietPrototypeStage?("delivery")
#endif
        } catch {
            probe?.finish(error: error, foreground: NSWorkspace.shared.frontmostApplication?.processIdentifier, project: currentProjectTitle())
            if ownsPanel {
                await Task { @MainActor in
                    if let panel = self.currentSheet(), self.string(panel, kAXTitleAttribute) == "Silent Snip",
                       observedPanel.map({ CFEqual($0, panel) }) == true,
                       let cancel = self.find(in: panel, role: kAXButtonRole, title: "Cancel") {
                        try? await self.restoreOwnShareActivation(panel: panel)
                        _ = try? self.press(cancel)
                    }
                }.value
            }
            throw error
        }
    }

    /// A final AXPick can complete while its compatibility activation is still
    /// checking the menu. Observe that same command's pending confirmation only;
    /// never issue another menu action, shortcut, activation, or confirmation.
    private func observePendingShareConfirmation() async throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        repeat {
            try Task.checkCancellation()
            try assertCurrentProject()
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let ownForeground = foreground == application.processIdentifier
                || foreground == NSRunningApplication.current.processIdentifier
            guard ownForeground else { return false }
            if let panel = currentSheet() {
                let observation = FinalCutShareConfirmationObservation(projectName: currentProjectTitle(),
                    panelTitle: string(panel, kAXTitleAttribute),
                    hasNext: find(in: panel, role: kAXButtonRole, title: "Next…", maxNodes: 250) != nil,
                    hasCancel: find(in: panel, role: kAXButtonRole, title: "Cancel", maxNodes: 250) != nil,
                    foregroundIsHostOrHelper: ownForeground)
                if observation.matches(expectedProject: projectName) { return true }
                // An unrelated dialog is never evidence of Share completion.
                guard observation.projectName == projectName, observation.panelTitle == "Silent Snip" else { return false }
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            try await Task.sleep(for: .milliseconds(40))
        } while true
    }

    /// A late XML Open Document can activate our own helper during the next
    /// Share panel. Return only that activation, without raising the project
    /// over its sheet or reclaiming focus from another application.
    func restoreOwnShareActivation(panel: AXUIElement) async throws {
        try assertCurrentProject()
        guard let current = currentSheet(), CFEqual(current, panel),
              string(panel, kAXTitleAttribute) == "Silent Snip" else {
            throw FinalCutCaptureError.unavailable("The owned Silent Snip Share panel changed.")
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == NSRunningApplication.current.processIdentifier {
            requestActivation()
            try await waitUntil(timeout: 2, context: "returning our Share activation to Final Cut") {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == self.application.processIdentifier
            }
        }
        // Final Cut may keep AXFocusedWindow on its remote AU editor even
        // though its Share sheet is already visible. Raise only the exact
        // request-owned sheet, and only while Final Cut itself is foreground.
        if (try? assertInputFocus()) == nil,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
            _ = AXUIElementPerformAction(panel, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(panel, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            try await waitUntil(timeout: 2, context: "focus on the owned Silent Snip Share panel") {
                guard let current = self.currentSheet(), CFEqual(current, panel) else { return false }
                return (try? self.assertInputFocus()) != nil
            }
        }
        do { try assertInputFocus() }
        catch {
            let owner = NSWorkspace.shared.frontmostApplication?.localizedName ?? "an unavailable application"
            throw FinalCutCaptureError.unavailable("The Silent Snip Share panel lost input focus to \(owner). Bring the Share window in Final Cut Pro to the front, then analyze the clip again.")
        }
    }

    /// Open only an exact, uniquely named generated project. XML verification
    /// after opening establishes its UID and contents; a name alone never does.
}

/// Share may deliver after an input call reports failure. The alternate route
/// is available only when shortcut discovery returned without posting input.
enum FinalCutShareInvocation {
    @MainActor static func perform(shortcut: () throws -> Bool,
                                   menu: () async throws -> Void) async throws -> Bool {
        if try shortcut() { return true }
        try await menu()
        return false
    }

    /// Observation may resolve an uncertain FINAL menu dispatch, never a failure
    /// opening File/Share or validating input. The menu closure runs exactly
    /// once; no input is repeated when the original command opens its panel.
    @MainActor static func performMenu(menu: (_ markFinalAttempt: @escaping () -> Void) async throws -> Void,
                                       observeCompletion: () async throws -> Bool) async throws -> Bool {
        var finalAttempted = false
        do {
            try await menu { finalAttempted = true }
            return false
        } catch {
            let original = error
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            guard finalAttempted else { throw original }
            let completed = try await observeCompletion()
            try Task.checkCancellation()
            guard completed else { throw original }
            return true
        }
    }
}

struct FinalCutShareConfirmationObservation {
    let projectName: String?
    let panelTitle: String?
    let hasNext: Bool
    let hasCancel: Bool
    let foregroundIsHostOrHelper: Bool

    func matches(expectedProject: String) -> Bool {
        foregroundIsHostOrHelper && !expectedProject.isEmpty && projectName == expectedProject
            && panelTitle == "Silent Snip" && hasNext && hasCancel
    }
}
