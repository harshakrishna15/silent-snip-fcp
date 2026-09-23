import Foundation
import CoreGraphics

/// A failed accessibility read is not evidence that the analyzed clip moved.
/// Keep the last verified drawing through host rebuilds and require sustained,
/// matching evidence before hiding for a different project or scroll viewport.
struct PreviewVisibility {
    private var unavailable: (reason: String, since: Date)?
    mutating func verified() { unavailable = nil }
    mutating func transientFailure() { unavailable = nil }
    mutating func reset() { unavailable = nil }
    mutating func confirmedUnavailable(_ reason: String, at now: Date) -> Bool {
        guard let pending = unavailable, pending.reason == reason else {
            unavailable = (reason, now)
            return false
        }
        return now.timeIntervalSince(pending.since) >= 2.5
    }
    static func needsOrdering(visible: Bool, overlay: Int, project: Int,
                              windowOrder: [Int]) -> Bool {
        guard visible else { return true }
        guard let projectIndex = windowOrder.firstIndex(of: project) else { return false }
        // A fully covered panel can disappear from WindowServer's on-screen
        // list. Keep raising it while the verified project remains present.
        guard let overlayIndex = windowOrder.firstIndex(of: overlay) else { return true }
        return overlayIndex > projectIndex
    }
}

/// A hover can briefly invalidate Final Cut's timeline accessibility tree.
/// Keep a verified clip handle during that rebuild, but bound its lifetime and
/// space out full identity scans so one failed read cannot cause a retry loop.
struct PreviewIdentityLease {
    private var verifiedAt = Date.distantPast
    private var attemptedAt = Date.distantPast

    mutating func verified(at now: Date) { verifiedAt = now }
    mutating func invalidate() { verifiedAt = .distantPast; attemptedAt = .distantPast }
    mutating func beginRevalidation(at now: Date) -> Bool {
        guard now.timeIntervalSince(verifiedAt) >= 1.0,
              now.timeIntervalSince(attemptedAt) >= 1.0 else { return false }
        attemptedAt = now
        return true
    }
    func usable(at now: Date) -> Bool { now.timeIntervalSince(verifiedAt) < 5.0 }
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

    static func scrollPosition(value: Double, enabled: Bool) -> Double? {
        // Final Cut retains a disabled scrollbar at zero when all rows fit.
        enabled ? value : nil
    }

    func visible(_ frame: CGRect) -> Bool {
        frame.height > 0 && viewport.insetBy(dx: -1, dy: -1).contains(frame)
    }
    var completeEffectsSection: Bool {
        // Effects is the last section in the Inspector's scroll area. Audio
        // Configuration is a sibling of that area, so it cannot bound a scan
        // of its children. With the section's start visible and the scroll at
        // its end, no Cutdown row can be virtualized outside the viewport.
        guard let top = anchors["Effects"] ?? anchors["Pan"] ?? anchors["Audio Enhancements"],
              visible(top) else { return false }
        guard let scrollPosition else { return true }
        return scrollPosition >= 0.99
    }
}

/// Absence only counts inside a visible, bounded effect section on the exact
/// analyzed clip. An offscreen/closed/partial Inspector supplies no evidence.
struct PreviewEffectLifetime {
    private var witness: (before: String, after: String?, viewport: CGRect, scroll: Double?)?
    private var missingSince: Date?
    private var missingObservations = 0
    private var sawCutdown = false
    private(set) var removed = false

    mutating func observe(_ inspection: PreviewEffectInspection?, at now: Date) -> Bool {
        if removed { return true }
        guard let inspection else {
            missingSince = nil; missingObservations = 0; witness = nil
            return false
        }
        if let cutdown = inspection.cutdown {
            sawCutdown = true
            missingSince = nil; missingObservations = 0
            witness = nil
            if inspection.visible(cutdown) {
                let visible = inspection.anchors.filter { inspection.visible($0.value) }
                let before = visible.filter { $0.value.maxY <= cutdown.minY }.max { $0.value.maxY < $1.value.maxY }
                let after = visible.filter { $0.value.minY >= cutdown.maxY }.min { $0.value.minY < $1.value.minY }
                if let before, after != nil || inspection.scrollPosition.map({ $0 >= 0.99 }) == true {
                    witness = (before.key, after?.key, inspection.viewport, inspection.scrollPosition)
                }
            }
            return false
        }
        var boundedAbsence = inspection.completeEffectsSection
        if let witness, witness.viewport == inspection.viewport, witness.scroll == inspection.scrollPosition,
           let before = inspection.anchors[witness.before], inspection.visible(before) {
            if let afterName = witness.after, let after = inspection.anchors[afterName],
               inspection.visible(after), before.maxY <= after.minY {
                boundedAbsence = true
            } else if witness.after == nil, inspection.scrollPosition.map({ $0 >= 0.99 }) == true {
                boundedAbsence = true
            }
        }
        // A complete-looking Inspector can temporarily omit a plugin row as
        // Final Cut rebuilds it. Require several stable reads, and give the
        // first appearance extra time before inferring an early deletion.
        guard boundedAbsence else {
            missingSince = nil; missingObservations = 0; witness = nil
            return false
        }
        missingObservations += 1
        let requiredDuration = sawCutdown ? 2.5 : 6.0
        let requiredObservations = sawCutdown ? 3 : 5
        if let missingSince, now.timeIntervalSince(missingSince) >= requiredDuration,
           missingObservations >= requiredObservations { removed = true }
        else if missingSince == nil { missingSince = now }
        return removed
    }
}
