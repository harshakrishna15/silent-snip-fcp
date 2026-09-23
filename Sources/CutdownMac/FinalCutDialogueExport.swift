import AppKit
import ApplicationServices
import CutdownCore
import Foundation

@MainActor public enum FinalCutDialogueExport {

    /// One private directory per analysis request. Callers can also place their
    /// initial project XML here. This method does not touch any Final Cut library.
    public static func makeJobDirectory(jobID: UUID) throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cutdown/Temporary", isDirectory: true)
            .appendingPathComponent(jobID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw ExportError.invalidWorkspace
        }
        return directory
    }

    static func configureShare(_ dialog: AXUIElement, session: FinalCutAXSession) async throws {
        try await selectTab("Settings", in: dialog, session: session)
        try await selectPopup(after: "Export File Format:", value: "Audio Only", in: dialog, session: session)
        try await selectPopup(after: "Audio Format:", value: "WAV", in: dialog, session: session)
        try await selectTab("Roles", in: dialog, session: session)
        try await session.waitUntil(timeout: 5, context: "isolated Dialogue WAV output") {
            (try? verifyDialogueRolePanel(dialog, session: session)) != nil
        }
    }

    private static func selectTab(_ title: String, in dialog: AXUIElement, session: FinalCutAXSession) async throws {
        let matches = try nodes(in: dialog, session: session).filter {
            [kAXRadioButtonRole, kAXButtonRole].contains(session.string($0, kAXRoleAttribute) ?? "")
                && session.string($0, kAXTitleAttribute) == title
        }
        guard matches.count == 1 else { throw ExportError.unverifiedControl(title) }
        // Radio tabs expose their selected state as AXValue. A selected tab
        // already owns the panel; pressing it again only rebuilds host UI.
        if session.string(matches[0], kAXRoleAttribute) == kAXRadioButtonRole,
           (session.attribute(matches[0], kAXValueAttribute) as? NSNumber)?.intValue == 1 { return }
        try session.press(matches[0])
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    private static func selectPopup(after label: String, value: String, in dialog: AXUIElement,
                                    session: FinalCutAXSession) async throws {
        // Final Cut replaces this subtree asynchronously after a tab or format
        // change. Resolve the label and its adjacent popup from each fresh tree.
        func resolvePopup() throws -> AXUIElement? {
            let elements = try nodes(in: dialog, session: session)
            let labels = elements.indices.filter { index in
                session.string(elements[index], kAXRoleAttribute) == kAXStaticTextRole
                    && matchesSettingsLabel(text(elements[index], session: session), expected: label)
            }
            guard labels.count == 1 else { return nil }
            return elements.dropFirst(labels[0] + 1).prefix(while: {
                session.string($0, kAXRoleAttribute) != kAXStaticTextRole || text($0, session: session).isEmpty
            }).first(where: { session.string($0, kAXRoleAttribute) == kAXPopUpButtonRole })
        }
        do {
            try await session.waitUntil(timeout: 5, context: "\(label) export control") {
                (try? resolvePopup()) != nil
            }
        } catch {
            if error is CancellationError { throw error }
            let observed = (try? nodes(in: dialog, session: session)) ?? []
            let controls = observed.prefix(40).map {
                "\(session.string($0, kAXRoleAttribute) ?? "?") title=\(session.string($0, kAXTitleAttribute) ?? "nil") value=\(session.string($0, kAXValueAttribute) ?? "nil")"
            }.joined(separator: "; ")
            throw ExportError.unverifiedControl("\(label) [\(controls)]")
        }
        guard let popup = try resolvePopup() else { throw ExportError.unverifiedControl(label) }
        if normalized(session.string(popup, kAXValueAttribute) ?? "") == normalized(value) { return }
        try session.press(popup)
        try await session.waitUntil(timeout: 3) {
            guard let menuNodes = try? nodes(in: popup, session: session) else { return false }
            return menuNodes.contains {
                session.string($0, kAXRoleAttribute) == kAXMenuItemRole && normalized(text($0, session: session)) == normalized(value)
            }
        }
        let items = try nodes(in: popup, session: session).filter {
            session.string($0, kAXRoleAttribute) == kAXMenuItemRole && normalized(text($0, session: session)) == normalized(value)
        }
        guard items.count == 1 else { throw ExportError.unverifiedControl(value) }
        try session.press(items[0])
        try await session.waitUntil(timeout: 3) {
            normalized(session.string(popup, kAXValueAttribute) ?? "") == normalized(value)
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

    private static func verifyDialogueRolePanel(_ dialog: AXUIElement, session: FinalCutAXSession) throws {
        let elements = try nodes(in: dialog, session: session)
        let labels = elements.filter { session.string($0, kAXRoleAttribute) == kAXStaticTextRole }
            .map { normalized(text($0, session: session)) }
        let tracks = labels.filter { $0.hasPrefix("audiotrack-") }
        guard labels.filter({ $0 == "alldialogue" }).count == 1,
              labels.contains("1file"), labels.contains(".wav"), tracks == ["audiotrack-1"],
              !labels.contains(where: { $0.hasPrefix("all") && $0 != "alldialogue" }),
              let preset = session.find(in: dialog, role: kAXPopUpButtonRole, description: "Roles formats and presets"),
              normalized(session.string(preset, kAXValueAttribute) ?? "") == "wav" else {
            throw ExportError.unverifiedDialogueOutput
        }
    }

    private static func nodes(in root: AXUIElement, session: FinalCutAXSession) throws -> [AXUIElement] {
        var result: [AXUIElement] = []
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while let (node, depth) = pending.popLast() {
            try Task.checkCancellation()
            guard result.count < 500, depth <= 16, ProcessInfo.processInfo.systemUptime < deadline else {
                throw ExportError.unverifiedDialogueOutput
            }
            result.append(node)
            pending.append(contentsOf: session.children(node).reversed().map { ($0, depth + 1) })
        }
        return result
    }

    private static func text(_ element: AXUIElement, session: FinalCutAXSession) -> String {
        [session.string(element, kAXTitleAttribute), session.string(element, kAXValueAttribute)]
            .compactMap { $0 }.first(where: { !$0.isEmpty }) ?? ""
    }

    nonisolated private static func normalized(_ value: String) -> String {
        value.lowercased().filter { !$0.isWhitespace }
    }

    public enum ExportError: LocalizedError {
        case invalidWorkspace
        case unverifiedControl(String), unverifiedDialogueOutput
        public var errorDescription: String? {
            switch self {
            case .invalidWorkspace: return "Cutdown could not create a private temporary export directory."
            case .unverifiedControl(let name): return "Cutdown could not verify Final Cut's \(name) export control."
            case .unverifiedDialogueOutput: return "Cutdown could not verify one WAV output containing All Dialogue. No audio mix was assumed."
            }
        }
    }
}
