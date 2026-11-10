import Foundation

public struct ReviewCut: Encodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let proposedRange: TimeRange
    public fileprivate(set) var range: TimeRange
    public let unavailableReason: String?
    public fileprivate(set) var included: Bool
    public fileprivate(set) var needsReview = false
    public var isEligible: Bool { unavailableReason == nil }
}

public enum ReviewBoundaryEdit: Int, Codable, Sendable {
    case startEarlier = 1, startLater = 2, endEarlier = 4, endLater = 8, reset = 16
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
    public let cutGrid: RationalTime
    public let analysisRange: TimeRange
    public private(set) var cuts: [ReviewCut]

    public init(jobID: UUID, document: TimelineDocument, target: TimelineClip, analysis: SilenceAnalysisResult,
                requireDialogue: Bool = true, cutGrid: RationalTime? = nil, analysisRange: TimeRange? = nil) throws {
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
        self.cutGrid = cutGrid ?? document.frameDuration
        self.analysisRange = analysisRange ?? target.timelineRange
        guard self.cutGrid >= document.frameDuration,
              try self.cutGrid.roundedDown(toFrame: document.frameDuration) == self.cutGrid,
              target.timelineRange.intersection(self.analysisRange) == self.analysisRange else {
            throw ReviewError.invalidRange
        }
        self.cuts = try Self.makeCuts(analysis, target: target, scope: self.analysisRange,
            protected: document.automaticCutRestrictions(for: target), frame: self.cutGrid)
    }

    public var selectedCuts: [ReviewCut] { cuts.filter { $0.included && $0.isEligible } }
    public var selectedDuration: RationalTime {
        get throws { try selectedCuts.reduce(.zero) { try $0.adding($1.range.checkedDuration()) } }
    }

    public mutating func setIncluded(_ included: Bool, cutID: String) throws {
        guard let index = cuts.firstIndex(where: { $0.id == cutID }) else { throw ReviewError.unknownCut }
        guard cuts[index].isEligible || !included else { throw ReviewError.unavailableCut }
        cuts[index].included = included
        cuts[index].needsReview = false
    }

    public mutating func selectAllEligible(_ selected: Bool) {
        for index in cuts.indices {
            cuts[index].included = selected && cuts[index].isEligible
            cuts[index].needsReview = false
        }
    }

    public mutating func setIncluded(_ included: Bool, from firstID: String, through lastID: String) throws {
        guard let first = cuts.firstIndex(where: { $0.id == firstID }),
              let last = cuts.firstIndex(where: { $0.id == lastID }), first <= last else {
            throw ReviewError.unknownCut
        }
        for index in first...last where cuts[index].isEligible {
            cuts[index].included = included
            cuts[index].needsReview = false
        }
    }

    public func boundaryEditMask(for cut: ReviewCut) -> Int {
        guard cut.isEligible else { return 0 }
        var mask = 0
        if cut.range.duration > cutGrid { mask |= ReviewBoundaryEdit.startLater.rawValue | ReviewBoundaryEdit.endEarlier.rawValue }
        if cut.range.start > cut.proposedRange.start { mask |= ReviewBoundaryEdit.startEarlier.rawValue | ReviewBoundaryEdit.reset.rawValue }
        if cut.range.end < cut.proposedRange.end { mask |= ReviewBoundaryEdit.endLater.rawValue | ReviewBoundaryEdit.reset.rawValue }
        return mask
    }

    public mutating func editBoundary(_ edit: ReviewBoundaryEdit, cutID: String) throws {
        guard let index = cuts.firstIndex(where: { $0.id == cutID }) else { throw ReviewError.unknownCut }
        let cut = cuts[index]
        guard boundaryEditMask(for: cut) & edit.rawValue != 0 else { throw ReviewError.unavailableBoundaryEdit }
        let current = cut.range
        let adjusted: TimeRange
        switch edit {
        case .startEarlier: adjusted = TimeRange(start: try current.start.subtracting(cutGrid), end: current.end)
        case .startLater: adjusted = TimeRange(start: try current.start.adding(cutGrid), end: current.end)
        case .endEarlier: adjusted = TimeRange(start: current.start, end: try current.end.subtracting(cutGrid))
        case .endLater: adjusted = TimeRange(start: current.start, end: try current.end.adding(cutGrid))
        case .reset: adjusted = cut.proposedRange
        }
        cuts[index].range = adjusted
    }

    /// Returns true when the detected ranges change.
    @discardableResult public mutating func recalculate(
        _ analysis: SilenceAnalysisResult, document: TimelineDocument
    ) throws -> Bool {
        guard document.projectName == projectName, document.projectUID == projectUID,
              document.fingerprint == baselineFingerprint else { throw ReviewError.staleProject }
        var refreshed = try Self.makeCuts(analysis, target: target, scope: analysisRange,
            protected: document.automaticCutRestrictions(for: target), frame: cutGrid)
        let changed = refreshed.map(\.proposedRange) != cuts.map(\.proposedRange)
        let previous = Dictionary(uniqueKeysWithValues: cuts.map { ($0.id, $0) })
        let kept = cuts.filter { $0.isEligible && (!$0.included || $0.range != $0.proposedRange) }
        var firstKept = kept.startIndex
        for index in refreshed.indices where refreshed[index].isEligible {
            if let match = previous[refreshed[index].id] {
                refreshed[index].included = match.included
                refreshed[index].needsReview = match.needsReview
                refreshed[index].range = match.range
                continue
            }
            let range = refreshed[index].range
            while firstKept < kept.endIndex && kept[firstKept].proposedRange.end <= range.start {
                firstKept += 1
            }
            if firstKept < kept.endIndex && kept[firstKept].proposedRange.start < range.end {
                refreshed[index].included = false
                refreshed[index].needsReview = true
            }
        }
        cuts = refreshed
        return changed
    }

    private static func makeCuts(_ analysis: SilenceAnalysisResult, target: TimelineClip, scope: TimeRange,
                                 protected: [TimelineProtectedRange], frame: RationalTime) throws -> [ReviewCut] {
        let cuts = try analysis.candidates.map { range in
            guard !range.isEmpty, range.start >= scope.start, range.end <= scope.end,
                  try range.start.roundedDown(toFrame: frame) == range.start,
                  try range.end.roundedDown(toFrame: frame) == range.end else { throw ReviewError.invalidRange }
            let reason: String?
            if range == target.timelineRange { reason = "Whole-clip deletion is unavailable." }
            else { reason = protected.first(where: { $0.range.intersection(range) != nil })?.reason }
            let id = "\(range.start.numerator)/\(range.start.denominator):\(range.end.numerator)/\(range.end.denominator)"
            return ReviewCut(id: id, proposedRange: range, range: range, unavailableReason: reason, included: reason == nil)
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
    case noDialogue, unknownCut, unavailableCut, unavailableBoundaryEdit, staleProject, invalidRange, invalidTarget, wholeClipCoverage
    public var errorDescription: String? {
        switch self {
        case .noDialogue: return "No enabled Dialogue role was found in the project. Assign the speech audio to the Dialogue role, then analyze the clip again."
        case .unknownCut: return "The selected cut is no longer in this review."
        case .unavailableCut: return "This cut cannot be applied automatically."
        case .unavailableBoundaryEdit: return "The cut must stay inside its proposed range and span at least one edit step."
        case .staleProject: return "The project changed after analysis. Click Analyze Again before applying cuts."
        case .invalidRange: return "A proposed cut is outside the target or not aligned to project frames."
        case .invalidTarget: return "The selected clip does not match the clip that was analyzed. Click Analyze Again."
        case .wholeClipCoverage: return "The proposed cuts together would delete the entire clip. Whole-clip deletion is unavailable."
        }
    }
}
