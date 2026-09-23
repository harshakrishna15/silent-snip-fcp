import CutdownCore
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Source decoding is an optimization only for an unprocessed direct asset.
/// Unknown processing must go through Final Cut, never silently fall back to PCM.
enum ClipAudioAnalysisRoute: Equatable {
    case source
    case finalCutRender

    static func resolve(projectData: Data, selection: TimelineSelection) throws -> Self {
        let document = try TimelineParser.parse(data: projectData)
        let target = try document.selectedTarget(selection, requireExistingMedia: false)
        let xml = try XMLDocument(data: projectData, options: [.nodeLoadExternalEntitiesNever])
        let paths = target.id.split(separator: "/")
        guard paths.count == 2, paths[0] == "spine", let index = Int(paths[1]),
              let spine = try xml.nodes(forXPath: "//project/sequence/spine").first as? XMLElement else {
            throw TimelineError.targetNotFound
        }
        let children = (spine.children ?? []).compactMap { $0 as? XMLElement }
        guard children.indices.contains(index), children[index].name == "asset-clip" else {
            throw TimelineError.targetNotFound
        }
        let effects = try xml.nodes(forXPath: "/fcpxml/resources/effect").compactMap { $0 as? XMLElement }
        let controllers = Set(effects.filter {
            $0.attribute(forName: "uid")?.stringValue == AudioControllerSettings.effectUID
        }.compactMap { $0.attribute(forName: "id")?.stringValue })
        let neutral: Set<String> = ["marker", "chapter-marker", "rating", "keyword", "metadata", "note"]
        for child in (children[index].children ?? []).compactMap({ $0 as? XMLElement }) {
            if neutral.contains(child.name ?? "") { continue }
            if child.name == "filter-audio", let ref = child.attribute(forName: "ref")?.stringValue,
               controllers.contains(ref) { continue }
            // Includes gain/keyframes, fades, channel mapping, pan, audio
            // enhancements, built-in effects, and opaque third-party AU state.
            return .finalCutRender
        }
        return .source
    }
}
