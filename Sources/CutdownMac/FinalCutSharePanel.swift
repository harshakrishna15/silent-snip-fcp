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
        return labels.filter { $0 == "alldialogue" }.count == 1
            && labels.contains("1file") && labels.contains(".wav")
            && labels.filter { $0.hasPrefix("audiotrack-") } == ["audiotrack-1"]
            && !labels.contains { $0.hasPrefix("all") && $0 != "alldialogue" }
            && presets.count == 1 && Self.normalized(presets[0].value ?? "") == "wav"
    }

    static func normalized(_ value: String) -> String { value.lowercased().filter { !$0.isWhitespace } }
    private func unique(_ values: [Control]) -> Control? { values.count == 1 ? values[0] : nil }
}
