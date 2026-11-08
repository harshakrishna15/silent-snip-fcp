import ApplicationServices
import Foundation

/// A pending setting edit is an authorization anchor in the real settings
/// group, not an action button. Only the exact currently displayed values may
/// recalculate this already-owned audio snapshot. This never authorizes input.
enum WorkflowAutomaticPreviewSnapshot {
    static func marker(edit: UUID) -> String {
        "silentsnip.workflow.settings.requested.\(edit.uuidString)"
    }

    static func matches<Element>(group: Element, edit: UUID, settings: ReviewWireSettings,
                                 output: SilentSnipOutputMode,
                                 read: (Element, [String]) -> [String: Any],
                                 equals: (Element, Element) -> Bool,
                                 shouldContinue: () -> Bool = { !Task.isCancelled }) -> Bool {
        guard let desired = try? settings.analysisSettings(),
              (try? WorkflowReviewOrigin.validate(settings: desired)) != nil,
              shouldContinue() else { return false }
        let identifier = marker(edit: edit)
        let values = read(group, [kAXRoleAttribute, kAXIdentifierAttribute, kAXChildrenAttribute])
        guard values[kAXRoleAttribute] as? String == kAXGroupRole,
              values[kAXIdentifierAttribute] as? String == identifier,
              let children = values[kAXChildrenAttribute] as? [Element], children.count <= 64 else { return false }
        let ids = (0..<4).map { "silentsnip.workflow.setting.\($0)" } + ["silentsnip.workflow.output"]
        let expected = [settings.threshold, settings.minimum, settings.before, settings.after]
        var controls: [String: [Element]] = [:]
        var queue = children.map { [group, $0] }, cursor = 0
        while cursor < queue.count {
            guard cursor < 128, shouldContinue() else { return false }
            let path = queue[cursor], element = path[path.count - 1]
            cursor += 1
            guard path.count <= 12 else { return false }
            let value = read(element, [kAXRoleAttribute, kAXIdentifierAttribute, kAXValueAttribute, kAXChildrenAttribute])
            guard let role = value[kAXRoleAttribute] as? String else { return false }
            if let id = value[kAXIdentifierAttribute] as? String, ids.contains(id) {
                guard controls[id] == nil else { return false }
                controls[id] = path
            }
            if [kAXGroupRole, kAXSplitGroupRole].contains(role) {
                guard let descendants = value[kAXChildrenAttribute] as? [Element], descendants.count <= 64 else { return false }
                for child in descendants {
                    guard !path.contains(where: { equals($0, child) }), queue.count < 128 else { return false }
                    queue.append(path + [child])
                }
            }
        }
        guard controls.count == ids.count else { return false }
        // Mounts and values are fresh after discovery. A current edit may have
        // replaced the marker or detached/replaced one field during the scan.
        for (index, id) in ids.enumerated() {
            guard shouldContinue(), let path = controls[id] else { return false }
            for (parent, child) in zip(path, path.dropFirst()) {
                let parentValues = read(parent, [kAXChildrenAttribute])
                guard shouldContinue(), let children = parentValues[kAXChildrenAttribute] as? [Element],
                      children.filter({ equals($0, child) }).count == 1 else { return false }
            }
            guard let field = path.last else { return false }
            let value = read(field, [kAXRoleAttribute, kAXIdentifierAttribute, kAXValueAttribute])
            guard value[kAXIdentifierAttribute] as? String == id else { return false }
            if index < expected.count {
                guard value[kAXRoleAttribute] as? String == kAXTextFieldRole,
                      let text = value[kAXValueAttribute] as? String,
                      let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                      number.isFinite, number == expected[index] else { return false }
            } else {
                let title = output == .remove ? "Remove Silence" : "Replace with 1-Second Gaps"
                guard value[kAXRoleAttribute] as? String == kAXPopUpButtonRole,
                      value[kAXValueAttribute] as? String == title else { return false }
            }
        }
        let final = read(group, [kAXRoleAttribute, kAXIdentifierAttribute])
        return shouldContinue() && final[kAXRoleAttribute] as? String == kAXGroupRole
            && final[kAXIdentifierAttribute] as? String == identifier
    }
}
