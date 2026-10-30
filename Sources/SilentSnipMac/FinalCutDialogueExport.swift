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

    static func configureShare(_ dialog: AXUIElement, session: FinalCutAXSession, timing: AnalysisTiming? = nil) async throws {
        let timing = timing ?? AnalysisTiming(request: UUID())
        try await timing.measure("share.render.settingsTab") { try await selectTab("Settings", in: dialog, session: session) }
        try await timing.measure("share.render.fileFormat") {
            try await selectPopup(after: "Export File Format:", value: "Audio Only", in: dialog, session: session)
        }
        try await timing.measure("share.render.audioFormat") {
            try await selectPopup(after: "Audio Format:", value: "WAV", in: dialog, session: session)
        }
        try await timing.measure("share.render.rolesTab") { try await selectTab("Roles", in: dialog, session: session) }
        try await timing.measure("share.render.rolesVerification") {
            if try !panel(in: dialog).verifiesDialogueWAV {
                try await configureDialogueFile(in: dialog, session: session, timing: timing)
            }
            try await session.waitUntil(timeout: 5, context: "isolated Dialogue WAV output") {
                (try? panel(in: dialog).verifiesDialogueWAV) == true
            }
        }
    }

    private typealias Panel = FinalCutSharePanel<AXUIElement>

    private static func configureDialogueFile(in dialog: AXUIElement, session: FinalCutAXSession, timing: AnalysisTiming) async throws {
        guard let preset = try panel(in: dialog).rolePreset else { throw ExportError.unverifiedDialogueOutput }
        try await session.restoreOwnShareActivation(panel: dialog)
        try session.press(preset.element)
        var choice: Panel.Control?
        try await session.waitUntil(timeout: 3, context: "separate audio role preset") {
            choice = (try? panel(in: preset.element))?.menuItem("Audio Only as Separate Files")
            return choice != nil
        }
        guard let choice else { throw ExportError.unverifiedDialogueOutput }
        try session.press(choice.element)
        timing.recordCounters(["share.render.rolePresetResets": 1])
        try await session.waitUntil(timeout: 3, context: "separate audio role layout") {
            (try? panel(in: dialog).separateAudioFileCount) != nil
        }
        // Bounded, one fresh snapshot per mutation. These controls remove an
        // export output, never a project role or any source media.
        for removed in 0..<32 {
            let current = try panel(in: dialog)
            if current.verifiesDialogueWAV { return }
            guard let remove = current.unwantedAudioFile, let count = current.separateAudioFileCount else { throw ExportError.unverifiedDialogueOutput }
            try await session.restoreOwnShareActivation(panel: dialog)
            try session.press(remove.element)
            timing.recordCounters(["share.render.nonDialogueFilesRemoved": removed + 1])
            try await session.waitUntil(timeout: 3, context: "removed non-Dialogue export output") {
                guard let updated = try? panel(in: dialog).separateAudioFileCount else { return false }
                return updated == count - 1
            }
        }
        throw ExportError.unverifiedDialogueOutput
    }

    private static func selectTab(_ title: String, in dialog: AXUIElement, session: FinalCutAXSession) async throws {
        guard let tab = try panel(in: dialog).tab(title) else { throw ExportError.unverifiedControl(title) }
        if tab.role == kAXRadioButtonRole, tab.selected { return }
        try await session.restoreOwnShareActivation(panel: dialog)
        try session.press(tab.element)
        // The next operation waits for the actual Settings or Roles controls.
        // A fixed pause neither proves readiness nor helps an already-ready host.
    }

    private static func selectPopup(after label: String, value: String, in dialog: AXUIElement,
                                    session: FinalCutAXSession) async throws {
        var popup: Panel.Control?
        do {
            try await session.waitUntil(timeout: 5, context: "\(label) export control") {
                popup = (try? panel(in: dialog))?.popup(after: label)
                return popup != nil
            }
        } catch {
            if error is CancellationError { throw error }
            let observed = (try? panel(in: dialog).controls) ?? []
            let controls = observed.prefix(40).map {
                "\($0.role ?? "?") title=\($0.title ?? "nil") value=\($0.value ?? "nil")"
            }.joined(separator: "; ")
            throw ExportError.unverifiedControl("\(label) [\(controls)]")
        }
        // Reuse the successful observation rather than immediately walking the
        // same unchanged panel a second time. press() still validates live focus.
        guard let popup else { throw ExportError.unverifiedControl(label) }
        if Panel.normalized(popup.value ?? "") == Panel.normalized(value) { return }
        try await session.restoreOwnShareActivation(panel: dialog)
        try session.press(popup.element)
        var item: Panel.Control?
        try await session.waitUntil(timeout: 3, context: "\(value) export menu item") {
            item = (try? panel(in: popup.element))?.menuItem(value)
            return item != nil
        }
        guard let item else { throw ExportError.unverifiedControl(value) }
        try session.press(item.element)
        try await session.waitUntil(timeout: 3, context: "\(value) export setting") {
            // A format change can destroy the old popup. Resolve its replacement
            // from the fresh dialog instead of polling a detached AX element.
            guard let current = (try? panel(in: dialog))?.popup(after: label) else { return false }
            return Panel.normalized(current.value ?? "") == Panel.normalized(value)
        }
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

    private static func panel(in root: AXUIElement) throws -> Panel {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        return try Panel.capture(root: root, read: { element in
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
        case unverifiedControl(String), unverifiedDialogueOutput
        public var errorDescription: String? {
            switch self {
            case .invalidWorkspace: return "Silent Snip could not create a private temporary export directory."
            case .unverifiedControl(let name): return "Silent Snip could not verify Final Cut's \(name) export control."
            case .unverifiedDialogueOutput: return "Silent Snip could not verify one WAV output containing All Dialogue. No audio mix was assumed."
            }
        }
    }
}
