import Foundation
import SilentSnipCore
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A process-local routing hint, never an authorization or effects cache. The
/// next manual Analyze must prove scope again using its new rendered XML.
struct DirectAudioRenderHint {
    let selection: FinalCutSelectionSnapshot
    let sourceURLs: [URL]
    let scope: DirectAudioRender.Scope
    func matches(_ current: FinalCutSelectionSnapshot) -> Bool { current == selection }

    func accepts(projectData: Data, selection: TimelineSelection, media: MediaContentSnapshot) throws -> Bool {
        let document = try TimelineParser.parse(data: projectData)
        guard media.covers(document.clips.filter(\.enabled).compactMap(\.mediaURL)) else { return false }
        return try DirectAudioRender.scope(projectData: projectData, selection: selection) == scope
    }
}

/// An exact selected-range Dialogue render supplies the target when no other
/// enabled Dialogue overlaps it. Normal asset bounds gate earlier DSP tails.
/// This is a scope proof, independent of effect-cache eligibility: Final Cut
/// still renders every effect, including opaque third-party Audio Units.
enum DirectAudioRender {
    enum Scope: String { case fullProjectTarget, projectSlice, selectedRange }

    static func isEligible(projectData: Data, selection: TimelineSelection) throws -> Bool {
        try scope(projectData: projectData, selection: selection) != nil
    }

    static func scope(projectData: Data, selection: TimelineSelection) throws -> Scope? {
        let document = try TimelineParser.parse(data: projectData)
        let target = try document.selectedTarget(selection, requireExistingMedia: false)
        guard !target.dialogueRoles.isEmpty else { return nil }
        // Reject nested routing, transitions, expanded audio and unknown timing.
        // Only a direct range render can avoid exporting the rest of an edit.
        guard document.clips.allSatisfy({ clip in
            !clip.hasUnresolvedTiming && (clip.isPrimaryStoryline
                ? (clip.kind == "gap" || (clip.kind == "asset-clip" && clip.unsupportedReasons.allSatisfy {
                    ["the clip is disabled", "enabled source audio is required"].contains($0)
                }))
                : (document.canRippleConnection(clip) && clip.unsupportedReasons.allSatisfy {
                    ["connected or nested targets are not supported", "the clip is disabled", "enabled source audio is required"].contains($0)
                }))
        }) else { return nil }
        let xml = try XMLDocument(data: projectData, options: [.nodeLoadExternalEntitiesNever])
        guard let spine = try xml.nodes(forXPath: "//project/sequence/spine").first as? XMLElement else { return nil }
        let items = (spine.children ?? []).compactMap { $0 as? XMLElement }
        guard items.count == document.clips.filter(\.isPrimaryStoryline).count,
              items.allSatisfy({ ["asset-clip", "gap"].contains($0.name ?? "") }) else { return nil }
        func element(_ clip: TimelineClip) -> XMLElement? {
            let path = clip.id.split(separator: "/").dropFirst().compactMap { Int($0) }
            guard let root = path.first, items.indices.contains(root) else { return nil }
            if path.count == 1 { return items[root] }
            let nested = (items[root].children ?? []).compactMap { $0 as? XMLElement }
            guard path.count == 2, nested.indices.contains(path[1]) else { return nil }
            return nested[path[1]]
        }
        func isDialogue(_ value: String?) -> Bool {
            guard let value = value?.lowercased() else { return false }
            return value == "dialogue" || value.hasPrefix("dialogue.")
        }
        func roles(_ node: XMLElement, satisfy predicate: (String?) -> Bool) -> Bool {
            let components = node.elements(forName: "audio-channel-source") + node.elements(forName: "audio-role-source")
            if components.isEmpty {
                return predicate(node.attribute(forName: "audioRole")?.stringValue ?? node.attribute(forName: "role")?.stringValue)
            }
            return components.filter {
                $0.attribute(forName: "enabled")?.stringValue != "0" && $0.attribute(forName: "active")?.stringValue != "0"
            }.allSatisfy {
                predicate($0.attribute(forName: "role")?.stringValue ?? node.attribute(forName: "audioRole")?.stringValue)
            }
        }
        guard let targetNode = element(target), roles(targetNode, satisfy: isDialogue) else { return nil }
        var hasEarlierDialogue = false
        for clip in document.clips where clip.id != target.id && clip.enabled && clip.hasAudio {
            guard let node = element(clip) else { return nil }
            let excluded = roles(node) { value in
                guard let role = value?.lowercased() else { return false }
                return ["music", "effects"].contains { role == $0 || role.hasPrefix($0 + ".") }
            }
            if !excluded {
                if clip.timelineRange.intersection(target.timelineRange) != nil { return nil }
                if clip.timelineRange.start < target.timelineRange.start { hasEarlierDialogue = true }
            }
        }
        if target.timelineRange == document.projectRange { return .fullProjectTarget }
        let extra = try document.projectRange.checkedDuration().subtracting(target.timelineRange.checkedDuration())
        if !hasEarlierDialogue, extra >= .zero, extra <= RationalTime(30), extra <= target.timelineRange.duration {
            return .projectSlice
        }
        return .selectedRange
    }
}
