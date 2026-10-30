import ApplicationServices
import Foundation

struct FinalCutRenderedClipRange: Equatable {
    let start: String
    let end: String
    let duration: String

    init(selection: FinalCutSelectionSnapshot) {
        start = selection.leadingTimecode; end = selection.trailingTimecode; duration = selection.durationTimecode
    }
    init?(timeline: AccessibilityNode) {
        let ranges = timeline.children.filter { $0.role == kAXLayoutItemRole && $0.description == "Range Selection" }
        guard ranges.count == 1, let range = ranges.first, let duration = range.value else { return nil }
        func edge(_ description: String) -> String? {
            let found = range.children.filter { $0.role == "AXHandle" && $0.description == description }
            return found.count == 1 ? found[0].value : nil
        }
        guard let start = edge("Range Start"), let end = edge("Range End") else { return nil }
        self.start = start; self.end = end; self.duration = duration
    }
}

extension FinalCutAXSession {
    func renderedClipRange() throws -> FinalCutRenderedClipRange? {
        try assertCurrentProject()
        try refreshTimeline()
        let raw = children(timeline)
        guard raw.count <= 10_000 else { throw FinalCutCaptureError.invalidSelection("The timeline range cannot be bounded.") }
        var ranges: [AccessibilityNode] = []
        let deadline = Date().addingTimeInterval(3)
        for element in raw {
            guard Date() < deadline, !Task.isCancelled else { throw FinalCutCaptureError.invalidSelection("The timeline range could not be read in time.") }
            let values = FinalCutAXAttributes.read(element, names: [kAXRoleAttribute, kAXDescriptionAttribute, kAXValueAttribute])
            guard values[kAXRoleAttribute] as? String == kAXLayoutItemRole,
                  values[kAXDescriptionAttribute] as? String == "Range Selection" else { continue }
            let handles = children(element).prefix(16).map { handle -> AccessibilityNode in
                let fields = FinalCutAXAttributes.read(handle, names: [kAXRoleAttribute, kAXDescriptionAttribute, kAXValueAttribute])
                return .init(role: fields[kAXRoleAttribute] as? String, identifier: nil, title: nil,
                    description: fields[kAXDescriptionAttribute] as? String, value: fields[kAXValueAttribute] as? String,
                    selected: nil, enabled: nil, children: [])
            }
            ranges.append(.init(role: kAXLayoutItemRole, identifier: nil, title: nil, description: "Range Selection",
                value: values[kAXValueAttribute] as? String, selected: nil, enabled: nil, children: handles))
        }
        return FinalCutRenderedClipRange(timeline: .init(role: kAXLayoutAreaRole, identifier: nil, title: nil,
            description: "Project Timeline", value: nil, selected: nil, enabled: nil, children: ranges))
    }

    func prepareRenderedClipRange(selection: FinalCutSelectionSnapshot) async throws {
        guard try selectionSnapshot() == selection else { throw AudioControllerSettingsError.targetChanged }
        try await clearTimelineRanges()
        // Go to Range Start also operates on a full clip selection. This avoids
        // choosing whichever clip happens to be under a stale skimmer/playhead.
        try await pressMenu(path: ["Mark", "Go to", "Range Start"])
        try await waitUntil(timeout: 3, context: "selected clip start") {
            let playheads = children(timeline).filter { string($0, kAXRoleAttribute) == kAXValueIndicatorRole && string($0, kAXDescriptionAttribute) == "Playhead" }
            return playheads.count == 1 && string(playheads[0], kAXValueAttribute) == selection.leadingTimecode
        }
        try await selectClipRangeCommand()
        try await waitUntil(timeout: 3, context: "exact selected clip render range") {
            (try? renderedClipRange()) == FinalCutRenderedClipRange(selection: selection)
        }
        guard try selectionSnapshot() == selection else { throw AudioControllerSettingsError.targetChanged }
    }

    func clearRenderedClipRange(selection: FinalCutSelectionSnapshot) async throws {
        guard try renderedClipRange() == FinalCutRenderedClipRange(selection: selection),
              try selectionSnapshot() == selection else {
            throw FinalCutCaptureError.invalidSelection("The analysis render range changed. No unrelated range was cleared.")
        }
        let selected = children(timeline).filter {
            string($0, kAXRoleAttribute) == kAXLayoutItemRole &&
                (attribute($0, kAXSelectedAttribute) as? NSNumber)?.boolValue == true
        }
        guard selected.count == 1, let original = selected.first else { throw AudioControllerSettingsError.targetChanged }
        try await clearTimelineRanges()
        if (try? selectionSnapshot()) == selection { return }
        // Clear Selected Ranges also clears the full clip selection on this host.
        // Restore only the retained exact occurrence, only into an empty selection.
        let current = children(timeline)
        guard current.contains(where: { CFEqual($0, original) }),
              current.filter({ string($0, kAXRoleAttribute) == kAXLayoutItemRole }).allSatisfy({
                  (attribute($0, kAXSelectedAttribute) as? NSNumber)?.boolValue == false
              }) else { throw AudioControllerSettingsError.targetChanged }
        let nodes = children(original).prefix(100).map {
            AccessibilityNode(role: string($0, kAXRoleAttribute), identifier: nil, title: nil,
                description: string($0, kAXDescriptionAttribute), value: string($0, kAXValueAttribute),
                selected: nil, enabled: nil, children: [])
        }
        let clip = AccessibilityNode(role: kAXLayoutItemRole, identifier: nil, title: nil, description: nil,
            value: string(original, kAXValueAttribute), selected: true,
            enabled: (attribute(original, kAXEnabledAttribute) as? NSNumber)?.boolValue, children: nodes)
        let restored = try FinalCutSelectionSnapshot(projectName: projectName, timeline: .init(
            role: kAXLayoutAreaRole, identifier: nil, title: nil, description: "Project Timeline",
            value: nil, selected: nil, enabled: nil, children: [clip]))
        guard restored == selection else { throw AudioControllerSettingsError.targetChanged }
        try assertInputFocus()
        guard AXUIElementSetAttributeValue(timeline, kAXSelectedChildrenAttribute as CFString, [original] as CFArray) == .success else {
            throw FinalCutCaptureError.invalidSelection("Final Cut could not restore the selected clip after its range render.")
        }
        try await waitUntil(timeout: 3, context: "selected clip after range render") { (try? selectionSnapshot()) == selection }
    }
}
