import ApplicationServices
import Foundation

/// One bounded observation of a Share panel. Never retain this across host
/// changes: tab, format, and menu actions can replace the underlying controls.
struct FinalCutSharePanel<Element> {
    struct Control {
        let element: Element
        let role: String?
        let title: String?
        let value: String?
        let description: String?
        let selected: Bool

        var text: String { [title, value].compactMap { $0 }.first { !$0.isEmpty } ?? "" }
    }

    let controls: [Control]

    static func capture(root: Element, read: (Element) throws -> (Control, [Element]),
                        shouldContinue: () -> Bool, maxNodes: Int = 500, maxDepth: Int = 16) throws -> Self {
        var controls: [Control] = []
        var pending: [(Element, Int)] = [(root, 0)]
        while let (element, depth) = pending.popLast() {
            try Task.checkCancellation()
            guard controls.count < maxNodes, depth <= maxDepth, shouldContinue() else {
                throw FinalCutDialogueExport.ExportError.unverifiedDialogueOutput
            }
            let (control, children) = try read(element)
            controls.append(control)
            guard children.count <= maxNodes - controls.count else {
                throw FinalCutDialogueExport.ExportError.unverifiedDialogueOutput
            }
            pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
        return Self(controls: controls)
    }

    func tab(_ title: String) -> Control? {
        unique(controls.filter { [kAXRadioButtonRole, kAXButtonRole].contains($0.role ?? "") && $0.title == title })
    }

    func popup(after label: String) -> Control? {
        let labels = controls.indices.filter {
            controls[$0].role == kAXStaticTextRole && FinalCutDialogueExport.matchesSettingsLabel(controls[$0].text, expected: label)
        }
        guard labels.count == 1 else { return nil }
        let adjacent = controls.dropFirst(labels[0] + 1).prefix {
            $0.role != kAXStaticTextRole || $0.text.isEmpty
        }
        return unique(adjacent.filter { $0.role == kAXPopUpButtonRole })
    }

    func menuItem(_ title: String) -> Control? {
        unique(controls.filter { $0.role == kAXMenuItemRole && Self.normalized($0.text) == Self.normalized(title) })
    }

    var verifiesDialogueWAV: Bool {
        let labels = controls.filter { $0.role == kAXStaticTextRole }.map { Self.normalized($0.text) }
        let presets = controls.filter { $0.role == kAXPopUpButtonRole && $0.description == "Roles formats and presets" }
        let common = labels.filter { $0 == "alldialogue" }.count == 1
            && labels.contains("1file") && labels.contains(".wav")
            && !labels.contains { $0.hasPrefix("all") && $0 != "alldialogue" }
            && presets.count == 1
        guard common else { return false }
        if Self.normalized(presets[0].value ?? "") == "wav" {
            let track = controls.indices.filter { controls[$0].role == kAXStaticTextRole && Self.normalized(controls[$0].text) == "audiotrack-1" }
            let end = controls.indices.filter { controls[$0].role == kAXStaticTextRole && Self.normalized(controls[$0].text) == "rolesas:" }
            guard labels.filter({ $0.hasPrefix("audiotrack-") }) == ["audiotrack-1"],
                  track.count == 1, end.count == 1, track[0] < end[0] else { return false }
            return controls[(track[0] + 1)..<end[0]].filter { $0.role == kAXStaticTextRole }
                .map { Self.normalized($0.text) }.filter { !$0.isEmpty } == ["alldialogue"]
        }
        guard let files = separateAudioFiles, files.count == 1 else { return false }
        return files[0].roles == ["alldialogue"] && files[0].isWAVStereo
    }

    func verifiesFullProjectMixWAV(expectedRoles: Set<String>) -> Bool {
        // Observed Final Cut 12.4 WAV layout. The preset popup updates before
        // its track list, so the exact role set and stereo evidence are required
        // in the same fresh snapshot; a popup value alone is insufficient.
        guard !expectedRoles.isEmpty else { return false }
        var roots: Set<String> = []
        for role in expectedRoles {
            let parts = role.components(separatedBy: ".")
            guard parts.allSatisfy({ !$0.isEmpty }), let root = parts.first else { return false }
            roots.insert(root.lowercased())
        }
        let expected = Set(roots.map { "all" + Self.normalized($0) })
        // Whitespace normalization must not merge two distinct custom groups.
        guard expected.count == roots.count else { return false }
        let end = controls.indices.filter { controls[$0].role == kAXStaticTextRole && Self.normalized(controls[$0].text) == "rolesas:" }
        guard end.count == 1 else { return false }
        // The footer counts delivery attachments (WAV plus FCPXML), not audio
        // outputs. Scope only that summary count above Roles as:, while keeping
        // duplicate WAV/track detection strict throughout the whole panel.
        let labels = controls[..<end[0]].filter { $0.role == kAXStaticTextRole }.map { Self.normalized($0.text) }
        let allLabels = controls.filter { $0.role == kAXStaticTextRole }.map { Self.normalized($0.text) }
        let summaries = labels.filter {
            let number = $0.hasSuffix("files") ? String($0.dropLast(5))
                : ($0.hasSuffix("file") ? String($0.dropLast(4)) : "")
            return !number.isEmpty && number.allSatisfy(\.isNumber)
        }
        guard summaries == ["1file"], allLabels.filter({ $0 == ".wav" }).count == 1,
              allLabels.filter({ $0.hasPrefix("audiotrack-") }) == ["audiotrack-1"],
              let preset = rolePreset, Self.normalized(preset.value ?? "") == "wav" else { return false }
        let track = controls.indices.filter { controls[$0].role == kAXStaticTextRole && Self.normalized(controls[$0].text) == "audiotrack-1" }
        let layouts = controls.filter { $0.role == kAXStaticTextRole && $0.description == "audio channel layout" }
        guard track.count == 1, end.count == 1, track[0] < end[0],
              layouts.count == 1, Self.normalized(layouts[0].value ?? "") == "stereo(lr)" else { return false }
        let actual = controls[(track[0] + 1)..<end[0]].filter { $0.role == kAXStaticTextRole }
            .map { Self.normalized($0.text) }.filter { !$0.isEmpty }
        return actual.count == expected.count && Set(actual) == expected
    }

    var rolePreset: Control? {
        unique(controls.filter { $0.role == kAXPopUpButtonRole && $0.description == "Roles formats and presets" })
    }

    private struct AudioFile {
        let remove: Control
        let roles: [String]
        let isWAVStereo: Bool
    }
    private var separateAudioFiles: [AudioFile]? {
        guard let preset = rolePreset,
              ["audioonlyasseparatefiles", "audioonlyasseparatefiles(edited)"].contains(Self.normalized(preset.value ?? "")) else { return nil }
        let starts = controls.indices.filter { index in
            let control = controls[index]
            return control.role == kAXButtonRole &&
                [control.text, control.description ?? ""].contains { Self.normalized($0) == "removeaudiotrack/file" }
        }
        guard !starts.isEmpty else { return nil }
        return starts.enumerated().map { offset, start in
            let end = offset + 1 < starts.count ? starts[offset + 1] : controls.endIndex
            // The .wav label precedes each remove button. Roles and Channels
            // follow it, up to the next file. Never remove an individual role.
            let segment = controls[(start + 1)..<end]
            let roleIndexes = segment.indices.filter { index in
                controls[index].role == kAXButtonRole && Self.normalized(controls[index].description ?? "") == "removerole"
            }
            let roles = roleIndexes.map { index -> String in
                guard index + 1 < end, controls[index + 1].role == kAXStaticTextRole else { return "unverified" }
                return Self.normalized(controls[index + 1].text)
            }
            let channels = segment.filter { $0.role == kAXPopUpButtonRole && $0.description == "Audio Channels" }
            return AudioFile(remove: controls[start], roles: roles,
                isWAVStereo: start > 0 && Self.normalized(controls[start - 1].text) == ".wav" &&
                    channels.count == 1 && Self.normalized(channels[0].value ?? "") == "stereo")
        }
    }

    var separateAudioFileCount: Int? { separateAudioFiles?.count }

    /// Identify only an entire non-Dialogue output in the observed native
    /// separate-files layout. A reset preset exposes custom top-level groups as
    /// All <role> too; unqualified subrole labels remain unverified.
    var unwantedAudioFile: Control? {
        guard let files = separateAudioFiles,
              files.filter({ $0.roles == ["alldialogue"] && $0.isWAVStereo }).count == 1,
              files.allSatisfy({ $0.isWAVStereo && !$0.roles.isEmpty &&
                  $0.roles.allSatisfy { $0.hasPrefix("all") && $0.count > 3 && !$0.contains(".") } }),
              !files.contains(where: { $0.roles.contains("alldialogue") && $0.roles != ["alldialogue"] }) else { return nil }
        return files.first { !$0.roles.contains("alldialogue") }?.remove
    }

    static func normalized(_ value: String) -> String { value.lowercased().filter { !$0.isWhitespace } }
    private func unique(_ values: [Control]) -> Control? { values.count == 1 ? values[0] : nil }
}
