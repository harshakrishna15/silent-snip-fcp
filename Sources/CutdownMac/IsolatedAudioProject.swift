import CutdownCore
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct IsolatedAudioProject {
    let data: Data
    let name: String
    let originalTarget: TimelineClip
    let duration: RationalTime

    static func make(projectData: Data, selection: TimelineSelection, id: UUID = UUID()) throws -> Self {
        let original = try TimelineParser.parse(data: projectData)
        let target = try original.selectedTarget(selection)
        let xml = try XMLDocument(data: projectData, options: [.nodeLoadExternalEntitiesNever])
        guard let root = xml.rootElement(),
              let project = try xml.nodes(forXPath: "//project").first as? XMLElement,
              let sequence = project.elements(forName: "sequence").first,
              let spine = sequence.elements(forName: "spine").first,
              let resources = root.elements(forName: "resources").first,
              let library = root.elements(forName: "library").first,
              let location = library.attribute(forName: "location")?.stringValue,
              let libraryURL = URL(string: location) else { throw TimelineError.invalidXML("missing project library") }
        try XMLProjectApply.validateLibrary(libraryURL)
        let path = target.id.split(separator: "/")
        let items = elements(spine)
        guard path.count == 2, path[0] == "spine", let index = Int(path[1]), items.indices.contains(index) else {
            throw TimelineError.targetNotFound
        }
        let clip = items[index].copy() as! XMLElement
        // Remove connected timeline items, never the target's channel mapping,
        // fades, gain, enhancements, or effect children.
        let connected: Set<String> = ["asset-clip", "clip", "ref-clip", "mc-clip", "sync-clip", "spine", "gap", "title", "video", "audition", "transition"]
        for child in elements(clip) where connected.contains(child.name ?? "") { child.detach() }
        let controllers = Set(resources.elements(forName: "effect").filter {
            $0.attribute(forName: "uid")?.stringValue == AudioControllerSettings.effectUID
        }.compactMap { $0.attribute(forName: "id")?.stringValue })
        for child in clip.elements(forName: "filter-audio") where controllers.contains(child.attribute(forName: "ref")?.stringValue ?? "") {
            child.detach() // The analysis controller is verified passthrough.
        }
        set(clip, "offset", "0s")
        // Role names affect export routing, not DSP. A private project can unify
        // them without changing the user's role assignments or mixing neighbors.
        set(clip, "audioRole", "dialogue")
        for node in try clip.nodes(forXPath: ".//audio-channel-source | .//audio") {
            if let element = node as? XMLElement {
                // Final Cut expands a bare component role to this default
                // subrole on import. Generate the host-stable spelling so the
                // strict render verifier still checks every processing effect.
                set(element, "role", "dialogue.dialogue-1")
            }
        }
        spine.setChildren([clip])
        let duration = try target.timelineRange.checkedDuration()
        set(sequence, "duration", "\(duration.numerator)/\(duration.denominator)s")
        set(sequence, "tcStart", "0s")
        let name = "Cutdown Analysis " + id.uuidString
        set(project, "name", name); set(project, "uid", id.uuidString)
        // A new event contains exactly one project, avoiding browser ambiguity.
        let event = XMLElement(name: "event")
        set(event, "name", "Cutdown Analysis"); set(event, "uid", UUID().uuidString)
        project.detach(); event.addChild(project)
        library.setChildren([event])
        for options in root.elements(forName: "import-options") { options.detach() }
        let options = XMLElement(name: "import-options")
        for (key,value) in [("copy assets","0"),("suppress warnings","0"),("library location",location)] {
            let option = XMLElement(name: "option"); set(option,"key",key); set(option,"value",value); options.addChild(option)
        }
        root.insertChild(options, at: 0)
        let data = xml.xmlData
        let parsed = try TimelineParser.parse(data: data)
        guard parsed.clips.count == 1, parsed.projectRange.duration == duration,
              parsed.clips[0].sourceFileStart == target.sourceFileStart else {
            throw TimelineError.invalidXML("isolated project did not preserve the selected source trim")
        }
        return .init(data: data, name: name, originalTarget: target, duration: duration)
    }

    private static func elements(_ node: XMLElement) -> [XMLElement] { (node.children ?? []).compactMap { $0 as? XMLElement } }
    private static func set(_ node: XMLElement, _ name: String, _ value: String) {
        if let attribute = node.attribute(forName: name) { attribute.stringValue = value }
        else { node.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode) }
    }
}
