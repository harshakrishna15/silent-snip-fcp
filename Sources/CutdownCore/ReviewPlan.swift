import Foundation

public struct ReviewCut: Encodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let range: TimeRange
    public let unavailableReason: String?
    public fileprivate(set) var included: Bool
    public var isEligible: Bool { unavailableReason == nil }
}

/// Review choices are separate from detection and never modify the source plan.
/// Plans can be encoded for diagnostics, but cannot be restored without validating
/// their target and analysis against a fresh project document through this initializer.
public struct ReviewPlan: Encodable, Sendable {
    public let jobID: UUID
    public let projectName: String
    public let projectUID: String?
    public let baselineFingerprint: String
    public let target: TimelineClip
    public let frameDuration: RationalTime
    public private(set) var cuts: [ReviewCut]

    public init(jobID: UUID, document: TimelineDocument, target: TimelineClip, analysis: SilenceAnalysisResult, requireDialogue: Bool = true) throws {
        guard !requireDialogue || !document.dialogueRoles.isEmpty else { throw ReviewError.noDialogue }
        let selected = try document.selectedTarget(.init(timelineRange: target.timelineRange,
            sourceURL: target.mediaURL, sourceStart: target.sourceStart), requireExistingMedia: false)
        guard selected == target else { throw ReviewError.invalidTarget }
        self.jobID = jobID
        self.projectName = document.projectName
        self.projectUID = document.projectUID
        self.baselineFingerprint = document.fingerprint
        self.target = target
        self.frameDuration = document.frameDuration
        self.cuts = try Self.makeCuts(analysis, target: target, protected: document.protectedRanges(for: target), frame: document.frameDuration)
    }

    public var selectedCuts: [ReviewCut] { cuts.filter { $0.included && $0.isEligible } }
    public var selectedDuration: RationalTime {
        get throws { try selectedCuts.reduce(.zero) { try $0.adding($1.range.checkedDuration()) } }
    }

    public mutating func setIncluded(_ included: Bool, cutID: String) throws {
        guard let index = cuts.firstIndex(where: { $0.id == cutID }) else { throw ReviewError.unknownCut }
        guard cuts[index].isEligible || !included else { throw ReviewError.unavailableCut }
        cuts[index].included = included
    }

    public mutating func selectAllEligible(_ selected: Bool) {
        for index in cuts.indices { cuts[index].included = selected && cuts[index].isEligible }
    }

    /// Returns true when changed ranges reset the user's include/exclude choices.
    @discardableResult public mutating func recalculate(
        _ analysis: SilenceAnalysisResult, document: TimelineDocument
    ) throws -> Bool {
        guard document.projectName == projectName, document.projectUID == projectUID,
              document.fingerprint == baselineFingerprint else { throw ReviewError.staleProject }
        var refreshed = try Self.makeCuts(analysis, target: target, protected: document.protectedRanges(for: target), frame: frameDuration)
        let changed = refreshed.map(\.range) != cuts.map(\.range)
        if !changed {
            for index in refreshed.indices {
                refreshed[index].included = refreshed[index].isEligible && cuts[index].included
            }
        }
        cuts = refreshed
        return changed
    }

    private static func makeCuts(_ analysis: SilenceAnalysisResult, target: TimelineClip,
                                 protected: [TimelineProtectedRange], frame: RationalTime) throws -> [ReviewCut] {
        let cuts = try analysis.candidates.map { range in
            guard !range.isEmpty, range.start >= target.timelineRange.start, range.end <= target.timelineRange.end,
                  try range.start.roundedDown(toFrame: frame) == range.start,
                  try range.end.roundedDown(toFrame: frame) == range.end else { throw ReviewError.invalidRange }
            let reason: String?
            if range == target.timelineRange { reason = "Whole-clip deletion is unavailable." }
            else { reason = protected.first(where: { $0.range.intersection(range) != nil })?.reason }
            let id = "\(range.start.numerator)/\(range.start.denominator):\(range.end.numerator)/\(range.end.denominator)"
            return ReviewCut(id: id, range: range, unavailableReason: reason, included: reason == nil)
        }
        // A malformed caller could split a wholly silent target into adjacent
        // candidates, bypassing the single-range whole-clip safeguard. Reject it
        // before any review can select all of those ranges for native deletion.
        if cuts.count > 1, analysis.removedDuration == (try target.timelineRange.checkedDuration()) {
            throw ReviewError.wholeClipCoverage
        }
        return cuts
    }
}

public enum ReviewError: LocalizedError {
    case noDialogue, unknownCut, unavailableCut, staleProject, invalidRange, invalidTarget, wholeClipCoverage
    public var errorDescription: String? {
        switch self {
        case .noDialogue: return "No enabled Dialogue role was found in the project. Assign the speech audio to Dialogue and analyze again."
        case .unknownCut: return "The selected cut is no longer in this review."
        case .unavailableCut: return "This cut cannot be applied automatically."
        case .staleProject: return "The project changed after analysis. Analyze again before applying cuts."
        case .invalidRange: return "A proposed cut is outside the target or not aligned to project frames."
        case .invalidTarget: return "The target does not match the selected clip in the analyzed project. Analyze again."
        case .wholeClipCoverage: return "The proposed cuts together would delete the entire clip. Whole-clip deletion is unavailable."
        }
    }
}
