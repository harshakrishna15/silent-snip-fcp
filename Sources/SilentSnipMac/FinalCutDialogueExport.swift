import AppKit
import ApplicationServices
import SilentSnipCore
import Foundation

@MainActor public enum FinalCutDialogueExport {

    /// One private directory per analysis request. Callers can also place their
    /// initial project XML here. This method does not touch any Final Cut library.
    public static func makeJobDirectory(jobID: UUID) throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Silent Snip/Temporary", isDirectory: true)
            .appendingPathComponent(jobID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw ExportError.invalidWorkspace
        }
        return directory
    }

    static func configureShare(_ dialog: AXUIElement, session: FinalCutAXSession, timing: AnalysisTiming? = nil,
                               mixScope: FinalCutAudioMixScope = .dialogue) async throws {
        let timing = timing ?? AnalysisTiming(request: UUID())
        let reader = PanelReader()
        defer {
            let prior = timing.report(outcome: "in progress").counters
            timing.recordCounters(["share.render.panelSnapshots": (prior["share.render.panelSnapshots"] ?? 0) + reader.snapshots,
                "share.render.panelNodeReads": (prior["share.render.panelNodeReads"] ?? 0) + reader.nodeReads,
                "share.render.samePhaseReuses": (prior["share.render.samePhaseReuses"] ?? 0) + reader.samePhaseReuses])
        }
        try await timing.measure("share.render.settingsTab") { try await selectTab("Settings", in: dialog, session: session, reader: reader) }
        let format = try await timing.measure("share.render.fileFormat") {
            try await selectPopup(after: "Export File Format:", value: "Audio Only", in: dialog, session: session, reader: reader)
        }
        _ = try await timing.measure("share.render.audioFormat") {
            try await selectPopup(after: "Audio Format:", value: "WAV", in: dialog, session: session, reader: reader, initial: format)
        }
        try await timing.measure("share.render.rolesTab") { try await selectTab("Roles", in: dialog, session: session, reader: reader) }
        try await timing.measure("share.render.rolesVerification") {
            switch mixScope {
            case .dialogue:
                let roles = try reader.capture(in: dialog)
                if !roles.verifiesDialogueWAV {
                    try await configureDialogueFile(in: dialog, session: session, timing: timing, reader: reader, initial: roles)
                    try await session.waitUntil(timeout: 5, context: "isolated Dialogue WAV output") {
                        (try? reader.capture(in: dialog).verifiesDialogueWAV) == true
                    }
                } else {
                    // This fresh complete role proof needs no second identical
                    // traversal when no setting or export-output action ran.
                    reader.samePhaseReuses += 1
                }
            case .fullProjectMix(let roles):
                // Full-project rendering must never fall through to the
                // Dialogue-only configuration, which removes other outputs.
                let observed = try reader.capture(in: dialog)
                if !observed.verifiesFullProjectMixWAV(expectedRoles: roles) {
                    try await configureFullProjectMix(in: dialog, session: session, timing: timing, expectedRoles: roles, reader: reader, initial: observed)
                }
            }
        }
    }

    private typealias Panel = FinalCutSharePanel<AXUIElement>

    private static func configureFullProjectMix(in dialog: AXUIElement, session: FinalCutAXSession,
                                                timing: AnalysisTiming, expectedRoles: Set<String>, reader: PanelReader, initial: Panel) async throws {
        var phase = "rolePreset"
        var observed: Panel?
        var captureError: String?
        do {
            observed = initial
            guard !expectedRoles.isEmpty, let preset = initial.rolePreset else {
                throw ExportError.unverifiedFullProjectMixOutput
            }
            try await session.restoreOwnShareActivation(panel: dialog)
            try session.press(preset.element)
            phase = "WAVMenuChoice"
            var choice: Panel.Control?
            try await session.waitUntil(timeout: 3, context: "full-project WAV role preset") {
                choice = (try? reader.capture(in: preset.element))?.menuItem("WAV")
                return choice != nil
            }
            guard let choice else { throw ExportError.unverifiedFullProjectMixOutput }
            try session.press(choice.element)
            timing.recordCounters(["share.render.fullMixPresetResets": 1])
            phase = "completeStereoRoleLayout"
            // Native 12.4 changes the popup first and asynchronously restores
            // the all-role track. A popup value alone never proves that layout.
            try await session.waitUntil(timeout: 5, context: "one stereo WAV containing every project role") {
                do {
                    let current = try reader.capture(in: dialog)
                    observed = current
                    return current.verifiesFullProjectMixWAV(expectedRoles: expectedRoles)
                } catch {
                    captureError = error.localizedDescription
                    return false
                }
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            if let current = try? reader.capture(in: dialog) { observed = current }
            // Keep the complete bounded observation in the existing request's
            // diagnostic folder, rather than dumping host controls into the UI.
            func field(_ value: String?) -> Any {
                guard let value else { return NSNull() }
                return String(value.prefix(512))
            }
            let controls: [[String: Any]] = (observed?.controls ?? []).prefix(500).map {
                ["role": field($0.role), "title": field($0.title), "value": field($0.value),
                 "description": field($0.description)]
            }
            let details: [String: Any] = ["phase": phase,
                "expectedRoles": expectedRoles.sorted().prefix(500).map { String($0.prefix(512)) },
                "expectedRoleCount": expectedRoles.count, "observedControlCount": observed?.controls.count ?? 0,
                "controls": controls, "error": String(error.localizedDescription.prefix(2048)),
                "captureError": field(captureError)]
            let diagnostic: URL?
            do {
                let directory = try makeJobDirectory(jobID: timing.report(outcome: "failed").request)
                let url = directory.appendingPathComponent("Full-Mix-Share-Diagnostic-\(UUID().uuidString).json")
                try JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys])
                    .write(to: url, options: .withoutOverwriting)
                diagnostic = url
            } catch { diagnostic = nil }
            if let diagnostic {
                throw FinalCutCaptureError.unavailable("\(error.localizedDescription) Share diagnostic: \(diagnostic.path)")
            }
            throw error
        }
    }

    private static func configureDialogueFile(in dialog: AXUIElement, session: FinalCutAXSession, timing: AnalysisTiming, reader: PanelReader, initial: Panel) async throws {
        guard let preset = initial.rolePreset else { throw ExportError.unverifiedDialogueOutput }
        try await session.restoreOwnShareActivation(panel: dialog)
        try session.press(preset.element)
        var choice: Panel.Control?
        try await session.waitUntil(timeout: 3, context: "separate audio role preset") {
            choice = (try? reader.capture(in: preset.element))?.menuItem("Audio Only as Separate Files")
            return choice != nil
        }
        guard let choice else { throw ExportError.unverifiedDialogueOutput }
        try session.press(choice.element)
        timing.recordCounters(["share.render.rolePresetResets": 1])
        try await session.waitUntil(timeout: 3, context: "separate audio role layout") {
            (try? reader.capture(in: dialog).separateAudioFileCount) != nil
        }
        // Bounded, one fresh snapshot per mutation. These controls remove an
        // export output, never a project role or any source media.
        for removed in 0..<32 {
            let current = try reader.capture(in: dialog)
            if current.verifiesDialogueWAV { return }
            guard let remove = current.unwantedAudioFile, let count = current.separateAudioFileCount else { throw ExportError.unverifiedDialogueOutput }
            try await session.restoreOwnShareActivation(panel: dialog)
            try session.press(remove.element)
            timing.recordCounters(["share.render.nonDialogueFilesRemoved": removed + 1])
            try await session.waitUntil(timeout: 3, context: "removed non-Dialogue export output") {
                guard let updated = try? reader.capture(in: dialog).separateAudioFileCount else { return false }
                return updated == count - 1
            }
        }
        throw ExportError.unverifiedDialogueOutput
    }

    private static func selectTab(_ title: String, in dialog: AXUIElement, session: FinalCutAXSession,
                                  reader: PanelReader) async throws {
        let observed = try reader.capture(in: dialog)
        guard let tab = observed.tab(title) else { throw ExportError.unverifiedControl(title) }
        if tab.role == kAXRadioButtonRole, tab.selected { return }
        try await session.restoreOwnShareActivation(panel: dialog)
        try session.press(tab.element)
        // The next operation waits for the actual Settings or Roles controls.
        // A fixed pause neither proves readiness nor helps an already-ready host.
    }

    private static func selectPopup(after label: String, value: String, in dialog: AXUIElement,
                                    session: FinalCutAXSession, reader: PanelReader, initial: Panel? = nil) async throws -> Panel {
        var popup: Panel.Control?
        var successful: Panel?
        var prior = initial
        do {
            try await session.waitUntil(timeout: 5, context: "\(label) export control") {
                let current: Panel?
                if let prior { current = prior; reader.samePhaseReuses += 1 }
                else { current = try? reader.capture(in: dialog) }
                prior = nil // Consume once; a missing control always triggers a fresh poll.
                popup = current?.popup(after: label)
                if popup != nil { successful = current }
                return popup != nil
            }
        } catch {
            if error is CancellationError { throw error }
            let observed = (try? reader.capture(in: dialog).controls) ?? []
            let controls = observed.prefix(40).map {
                "\($0.role ?? "?") title=\($0.title ?? "nil") value=\($0.value ?? "nil")"
            }.joined(separator: "; ")
            throw ExportError.unverifiedControl("\(label) [\(controls)]")
        }
        // Reuse the successful observation rather than immediately walking the
        // same unchanged panel a second time. press() still validates live focus.
        guard let popup, let successful else { throw ExportError.unverifiedControl(label) }
        if Panel.normalized(popup.value ?? "") == Panel.normalized(value) { return successful }
        try await session.restoreOwnShareActivation(panel: dialog)
        // A reused Settings snapshot may skip an already-correct value, but
        // never supplies an action target after activation yielded to the host.
        let actionPopup: Panel.Control
        if initial != nil {
            let refreshed = try reader.capture(in: dialog)
            guard let current = refreshed.popup(after: label) else { throw ExportError.unverifiedControl(label) }
            if Panel.normalized(current.value ?? "") == Panel.normalized(value) { return refreshed }
            actionPopup = current
        } else { actionPopup = popup }
        try session.press(actionPopup.element)
        var item: Panel.Control?
        try await session.waitUntil(timeout: 3, context: "\(value) export menu item") {
            item = (try? reader.capture(in: actionPopup.element))?.menuItem(value)
            return item != nil
        }
        guard let item else { throw ExportError.unverifiedControl(value) }
        try session.press(item.element)
        var updated: Panel?
        try await session.waitUntil(timeout: 3, context: "\(value) export setting") {
            // A format change can destroy the old popup. Resolve its replacement
            // from the fresh dialog instead of polling a detached AX element.
            guard let observed = try? reader.capture(in: dialog), let current = observed.popup(after: label),
                  Panel.normalized(current.value ?? "") == Panel.normalized(value) else { return false }
            updated = observed
            return true
        }
        guard let updated else { throw ExportError.unverifiedControl(value) }
        return updated
    }

    /// Accept the observed compact and expanded Settings layouts. The container
    /// format can be labelled Format: or Export File Format:, while disabled
    /// video fields may be grouped with Audio Format:. Keep these exact aliases
    /// so the container and audio codec popups cannot be confused.
    nonisolated static func matchesSettingsLabel(_ actual: String, expected: String) -> Bool {
        let actual = normalized(actual), expected = normalized(expected)
        if actual == expected { return true }
        if expected == "exportfileformat:", actual == "format:" { return true }
        return expected == "audioformat:"
            && actual == "videocodec:noneresolution:nonecolorspace:noneaudioformat:"
    }

    @MainActor private final class PanelReader {
        var snapshots = 0
        var nodeReads = 0
        var samePhaseReuses = 0
        func capture(in root: AXUIElement) throws -> Panel {
            snapshots += 1
            return try FinalCutDialogueExport.panel(in: root) { self.nodeReads += 1 }
        }
    }

    private static func panel(in root: AXUIElement, didReadNode: () -> Void) throws -> Panel {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        return try Panel.capture(root: root, read: { element in
            didReadNode()
            // One batch per node supplies both matching fields and children.
            // FinalCutAXAttributes retains compatibility with individual reads
            // when a host cannot supply a usable batch.
            let values = FinalCutAXAttributes.read(element, names: [kAXRoleAttribute, kAXTitleAttribute,
                kAXValueAttribute, kAXDescriptionAttribute, kAXChildrenAttribute])
            guard let role = values[kAXRoleAttribute] as? String else { throw ExportError.unverifiedDialogueOutput }
            let children = values[kAXChildrenAttribute] as? [AXUIElement]
            if children == nil && [kAXSheetRole, kAXGroupRole, kAXScrollAreaRole, kAXSplitGroupRole, kAXMenuRole].contains(role) {
                throw ExportError.unverifiedDialogueOutput
            }
            let raw = values[kAXValueAttribute]
            let value = (raw as? String) ?? (raw as? NSNumber)?.stringValue
            return (Panel.Control(element: element, role: role,
                title: values[kAXTitleAttribute] as? String, value: value,
                description: values[kAXDescriptionAttribute] as? String,
                selected: (raw as? NSNumber)?.intValue == 1), children ?? [])
        }, shouldContinue: { ProcessInfo.processInfo.systemUptime < deadline })
    }

    nonisolated private static func normalized(_ value: String) -> String {
        value.lowercased().filter { !$0.isWhitespace }
    }

    public enum ExportError: LocalizedError {
        case invalidWorkspace
        case unverifiedControl(String), unverifiedDialogueOutput, unverifiedFullProjectMixOutput
        public var errorDescription: String? {
            switch self {
            case .invalidWorkspace: return "Silent Snip could not create a private temporary export directory."
            case .unverifiedControl(let name): return "Silent Snip could not verify Final Cut's \(name) export control."
            case .unverifiedDialogueOutput: return "Silent Snip could not verify one WAV output containing All Dialogue. No audio mix was assumed."
            case .unverifiedFullProjectMixOutput: return "Silent Snip could not verify one stereo WAV containing every project audio role over the full project range. No audio mix was assumed."
            }
        }
    }
}
