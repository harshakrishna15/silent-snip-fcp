import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import SilentSnipCore

/// The project mix includes every project audio role, rather than just Dialogue.
/// Declared role names come from the immutable XML used to bind the export.
enum FinalCutAudioMixScope: Equatable, Sendable {
    case dialogue
    case fullProjectMix(expectedRoles: Set<String>)

    func permitsSelectionRange(_ selectedRange: Bool) -> Bool {
        switch self {
        case .dialogue: return true
        case .fullProjectMix(let roles): return !selectedRange && !roles.isEmpty
        }
    }

    /// Final Cut's WAV Roles track lists declared groups, including disabled
    /// clips/components and source audio disabled on video-only AV instances.
    /// Preserve every serialized audio role and separately require provable
    /// audible routing. Custom groups are never filtered to built-in names.
    static func expectedRoles(projectData: Data) throws -> Set<String> {
        _ = try TimelineParser.parse(data: projectData)
        let xml = try XMLDocument(data: projectData, options: [.nodeLoadExternalEntitiesNever])
        let spines = try xml.nodes(forXPath: "//project/sequence/spine")
            .compactMap { $0 as? XMLElement }
        guard spines.count == 1 else { throw Failure.unverifiableRoles }
        let assets = try xml.nodes(forXPath: "/fcpxml/resources/asset").compactMap { $0 as? XMLElement }
        var byID: [String: XMLElement] = [:]
        for asset in assets {
            guard let id = asset.attribute(forName: "id")?.stringValue, byID[id] == nil else { throw Failure.unverifiableRoles }
            byID[id] = asset
        }
        let storyNames: Set<String> = ["asset-clip", "clip", "ref-clip", "mc-clip", "sync-clip", "audio", "video", "gap", "title", "caption", "live-drawing", "audition", "transition"]
        var roles: Set<String> = []
        var visited = 0

        func active(_ node: XMLElement, _ key: String) throws -> Bool {
            guard let value = node.attribute(forName: key)?.stringValue else { return true }
            guard ["0", "1"].contains(value) else { throw Failure.unverifiableRoles }
            return value == "1"
        }
        func appendRole(_ role: String?) throws {
            guard let role, !role.isEmpty, role.trimmingCharacters(in: .whitespacesAndNewlines) == role,
                  role.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  role.components(separatedBy: ".").allSatisfy({ !$0.isEmpty }) else {
                throw Failure.unverifiableRoles
            }
            roles.insert(role)
        }
        func collect(_ node: XMLElement, depth: Int, parentAudible: Bool) throws {
            visited += 1
            guard depth <= 16, visited <= 10_000 else { throw Failure.unverifiableRoles }
            // Disabled parents silence descendants but do not remove their
            // declared role groups from the native Share configuration.
            let audible = try parentAudible && active(node, "enabled")
            guard ["asset-clip", "gap"].contains(node.name ?? "") else { throw Failure.unverifiableRoles }
            let children = (node.children ?? []).compactMap { $0 as? XMLElement }
            guard !children.contains(where: { ["spine", "timeMap"].contains($0.name ?? "") ||
                ($0.name == "conform-rate" && $0.attribute(forName: "scaleEnabled")?.stringValue != "0") }) else {
                throw Failure.unverifiableRoles
            }
            if node.name == "asset-clip" {
                guard let ref = node.attribute(forName: "ref")?.stringValue, let asset = byID[ref] else { throw Failure.unverifiableRoles }
                let audio = asset.attribute(forName: "hasAudio")?.stringValue
                if let audio, !["0", "1"].contains(audio) { throw Failure.unverifiableRoles }
                let source = node.attribute(forName: "srcEnable")?.stringValue ?? "all"
                guard ["all", "audio", "video"].contains(source) else { throw Failure.unverifiableRoles }
                let components = children.filter { ["audio-channel-source", "audio-role-source"].contains($0.name ?? "") }
                guard components.isEmpty || audio == "1" else { throw Failure.unverifiableRoles }
                if audio == "1" {
                    let declared = node.attribute(forName: "audioRole")?.stringValue ?? node.attribute(forName: "role")?.stringValue
                    if let declared { try appendRole(declared) }
                    if components.isEmpty {
                        if audible, source != "video", declared == nil { throw Failure.unverifiableRoles }
                    } else {
                        for component in components {
                            let componentEnabled = try active(component, "enabled")
                            let componentActive = try active(component, "active")
                            if let role = component.attribute(forName: "role")?.stringValue {
                                try appendRole(role)
                            } else if audible, source != "video", componentEnabled, componentActive, declared == nil {
                                throw Failure.unverifiableRoles
                            }
                        }
                    }
                }
            }
            for child in children where storyNames.contains(child.name ?? "") {
                try collect(child, depth: depth + 1, parentAudible: audible)
            }
        }
        for node in (spines[0].children ?? []).compactMap({ $0 as? XMLElement }) {
            guard storyNames.contains(node.name ?? "") else { throw Failure.unverifiableRoles }
            try collect(node, depth: 0, parentAudible: true)
        }
        guard !roles.isEmpty else { throw Failure.unverifiableRoles }
        return roles
    }

    enum Failure: LocalizedError {
        case unverifiableRoles
        var errorDescription: String? {
            "The full project audio roles could not be proved from this timeline. No project mix was assumed."
        }
    }
}
