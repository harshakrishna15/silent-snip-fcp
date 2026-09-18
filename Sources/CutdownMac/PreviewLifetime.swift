import Foundation
import CoreGraphics

/// A failed accessibility read is not a project change. Keep the last verified
/// drawing briefly while the host rebuilds its accessibility tree after a click.
struct PreviewVisibility {
    private var lastGood: Date?
    mutating func verified(at now: Date) { lastGood = now }
    mutating func reset() { lastGood = nil }
    func expired(at now: Date) -> Bool {
        guard let lastGood else { return true }
        return now.timeIntervalSince(lastGood) > 1.5
    }
    static func needsOrdering(visible: Bool, overlay: Int, project: Int, windowOrder: [Int]) -> Bool {
        guard visible, let overlayIndex = windowOrder.firstIndex(of: overlay),
              let projectIndex = windowOrder.firstIndex(of: project) else { return true }
        return overlayIndex > projectIndex
    }
}

struct PreviewEffectInspection {
    let viewport: CGRect
    let cutdown: CGRect?
    /// Unique, non-Cutdown effect/section headers, in screen coordinates.
    let anchors: [String: CGRect]
    let scrollPosition: Double?

    static func effectsExpanded(value: String?, title: String?) -> Bool {
        if value == "0" || value == "off" || title == "Show" { return false }
        return value == "1" || value == "on" || title == "Hide"
    }

    func visible(_ frame: CGRect) -> Bool {
        frame.height > 0 && viewport.insetBy(dx: -1, dy: -1).contains(frame)
    }
    var completeEffectsSection: Bool {
        // Final Cut can remove the Effects heading together with the last
        // effect. The surrounding native audio sections still bound that area.
        guard let top = anchors["Effects"] ?? anchors["Pan"] ?? anchors["Audio Enhancements"],
              let bottom = anchors["Audio Configuration"] else { return false }
        return visible(top) && visible(bottom) && top.maxY < bottom.minY
    }
}

/// Absence only counts inside a visible, bounded effect section on the exact
/// analyzed clip. An offscreen/closed/partial Inspector supplies no evidence.
struct PreviewEffectLifetime {
    private var witness: (before: String, after: String, viewport: CGRect, scroll: Double?)?
    private var missingSince: Date?
    private(set) var removed = false

    mutating func observe(_ inspection: PreviewEffectInspection?, at now: Date) -> Bool {
        if removed { return true }
        guard let inspection else { missingSince = nil; witness = nil; return false }
        if let cutdown = inspection.cutdown {
            missingSince = nil
            witness = nil
            if inspection.visible(cutdown) {
                let visible = inspection.anchors.filter { inspection.visible($0.value) }
                let before = visible.filter { $0.value.maxY <= cutdown.minY }.max { $0.value.maxY < $1.value.maxY }
                let after = visible.filter { $0.value.minY >= cutdown.maxY }.min { $0.value.minY < $1.value.minY }
                if let before, let after {
                    witness = (before.key, after.key, inspection.viewport, inspection.scrollPosition)
                }
            }
            return false
        }
        var boundedAbsence = inspection.completeEffectsSection
        if let witness, witness.viewport == inspection.viewport, witness.scroll == inspection.scrollPosition,
           let before = inspection.anchors[witness.before], let after = inspection.anchors[witness.after],
           inspection.visible(before), inspection.visible(after), before.maxY <= after.minY {
            boundedAbsence = true
        }
        guard boundedAbsence else { missingSince = nil; witness = nil; return false }
        if let missingSince, now.timeIntervalSince(missingSince) >= 0.35 { removed = true }
        else if missingSince == nil { missingSince = now }
        return removed
    }
}
