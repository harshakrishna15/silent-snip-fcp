import AppKit
import ApplicationServices
import CutdownCore
import Foundation

enum FinalCutWindowPolicy {
    /// Effect editors are nonmodal dialogs. WindowServer already keeps their
    /// visible content above the preview; opening one must not hide all lines.
    static func blocksPreview(role: String?, subrole: String?, modal: Bool?, containsCutdownReview: Bool) -> Bool {
        if role == kAXSheetRole || modal == true { return true }
        if modal == false { return false }
        return isBlockingDialog(role: role, subrole: subrole, modal: modal, containsCutdownReview: containsCutdownReview)
    }

    static func isBlockingDialog(role: String? = nil, subrole: String?, modal: Bool?, containsCutdownReview: Bool) -> Bool {
        if role == kAXSheetRole || modal == true { return true }
        return subrole == kAXDialogSubrole && !containsCutdownReview
    }
}

enum FinalCutControlAction {
    /// Standard buttons expose Press; Final Cut menu items can expose Pick.
    /// Never try a second action after a failed call: its effect may be uncertain.
    static func preferred(from supported: [String]) -> String? {
        if supported.contains(kAXPressAction) { return kAXPressAction }
        if supported.contains(kAXPickAction) { return kAXPickAction }
        return nil
    }

    static func confirmsPickedMenuItem(action: String, menuOpen: Bool, itemSelected: Bool, itemEnabled: Bool) -> Bool {
        [kAXPickAction, kAXPressAction].contains(action) && menuOpen && itemSelected && itemEnabled
    }
}

/// AX menu modifiers use Command by default; they are not CGEvent flag bits.
/// Require a complete, advertised shortcut instead of guessing a keyboard layout.
struct FinalCutMenuShortcut {
    let keyCode: CGKeyCode
    let flags: CGEventFlags

    init?(virtualKey: Int?, modifiers: Int?, character: String?, glyph: Int?, enabled: Bool?) {
        guard enabled == true, let virtualKey, (0...127).contains(virtualKey),
              let modifiers, (0...15).contains(modifiers),
              character?.isEmpty == false || (glyph ?? 0) > 0 else { return nil }
        keyCode = CGKeyCode(virtualKey)
        var flags: CGEventFlags = []
        if modifiers & 8 == 0 { flags.insert(.maskCommand) }
        if modifiers & 1 != 0 { flags.insert(.maskShift) }
        if modifiers & 2 != 0 { flags.insert(.maskAlternate) }
        if modifiers & 4 != 0 { flags.insert(.maskControl) }
        self.flags = flags
    }
}

enum FinalCutRangeCommand: String {
    case clear = "Clear Selected Ranges"
}

enum FinalCutPreviewError: Error, LocalizedError {
    case unavailable(String)
    case transient(String)
    case effectRemoved
    var errorDescription: String? {
        switch self {
        case .unavailable(let reason), .transient(let reason): return reason
        case .effectRemoved: return "Cutdown effect removed"
        }
    }
}

enum FinalCutPreviewGeometry {
    static func visibleFrame(clip: CGRect, timeline: CGRect, scrollViewports: [CGRect]) -> CGRect? {
        guard !scrollViewports.isEmpty else { return nil }
        let visible = scrollViewports.reduce(clip.intersection(timeline)) { $0.intersection($1) }
        return !visible.isNull && visible.width > 0 && visible.height > 0 ? visible : nil
    }
}

/// WindowServer returns front-to-back rectangles without requiring pixel capture.
/// Identify the pinned project for native window ordering.
struct FinalCutPreviewSurface {
    let pid: Int32
    let frame: CGRect
    let layer: Int
    let alpha: Double
    var number: Int = 0

    static func projectWindowNumber(in windows: [Self], projectPID: Int32, projectFrame: CGRect) -> Int? {
        let matches = windows.filter {
            $0.pid == projectPID && $0.layer == 0 && $0.alpha > 0 &&
            abs($0.frame.minX - projectFrame.minX) < 2 && abs($0.frame.minY - projectFrame.minY) < 2 &&
            abs($0.frame.width - projectFrame.width) < 2 && abs($0.frame.height - projectFrame.height) < 2
        }
        return matches.count == 1 ? matches[0].number : nil
    }


}

enum FinalCutReviewInspector {
    /// Audio effects are flat siblings in Final Cut's Inspector. Bind the editor
    /// to its own exact checkbox and label, stopping before another effect.
    static func editorIndex(in controls: [AccessibilityNode]) -> Int? {
        let anchors = controls.indices.filter {
            controls[$0].role == kAXCheckBoxRole
                && controls[$0].description?.lowercased() == "cutdown audio check box"
        }
        guard anchors.count == 1, let start = anchors.first else { return nil }
        let end = controls.indices.dropFirst(start + 1).first { controls[$0].role == kAXCheckBoxRole } ?? controls.count
        let group = Array(controls.indices[(start + 1)..<end])
        guard group.contains(where: { index in
            controls[index].role == kAXStaticTextRole
                && (controls[index].value == "Cutdown Audio" || controls[index].title == "Cutdown Audio")
        }) else { return nil }
        let editors = group.filter {
            controls[$0].role == kAXButtonRole && controls[$0].description == "Show effect editor"
                && controls[$0].enabled != false
        }
        return editors.count == 1 ? editors[0] : nil
    }
}

struct FinalCutSheetPath<Element> {
    let element: Element
    let lineage: [Element]
}

enum FinalCutSheetTraversal {
    /// The same panel can appear both in AXWindows and beneath another panel.
    /// Revisit its children when a longer parent chain is found so descendants
    /// retain their connection to the main or focused window.
    static func paths<Element>(roots: [Element], equals: (Element, Element) -> Bool,
                               children: (Element) -> [Element],
                               shouldContinue: () -> Bool = { true }) -> [FinalCutSheetPath<Element>] {
        var queue = roots.prefix(32).map { FinalCutSheetPath(element: $0, lineage: [$0]) }
        var result: [FinalCutSheetPath<Element>] = []
        var cursor = 0
        while cursor < queue.count, cursor < 64, shouldContinue() {
            let current = queue[cursor]
            cursor += 1
            if let index = result.firstIndex(where: { equals($0.element, current.element) }) {
                guard result[index].lineage.count < current.lineage.count else { continue }
                result[index] = current
            } else { result.append(current) }
            guard current.lineage.count < 5 else { continue }
            for child in children(current.element).prefix(48) {
                guard queue.count < 64, !current.lineage.contains(where: { equals($0, child) }) else { continue }
                queue.append(FinalCutSheetPath(element: child, lineage: current.lineage + [child]))
            }
        }
        return result
    }
}
