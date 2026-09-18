import Foundation

public struct PreviewMarkerDraft: Codable, Hashable, Sendable {
    public let cutID: String
    public let parentClipID: String
    public let timelinePosition: RationalTime
    public let sourcePosition: RationalTime
    public let value: String
    public let note: String
}

public struct PreviewMarkerCollision: Sendable {
    public let draft: PreviewMarkerDraft
    public let existingMarkers: [TimelineMarker]
}

public struct MarkerPreview: Sendable {
    public let additions: [PreviewMarkerDraft]
    public let collisions: [PreviewMarkerCollision]

    /// Supply only non-owned current markers after resolving the existing manifest.
    /// A one-frame removal has one combined marker, never two markers at one frame.
    public init(review: ReviewPlan, existingMarkers: [TimelineMarker]) throws {
        var additions: [PreviewMarkerDraft] = []
        var collisions: [PreviewMarkerCollision] = []
        for (index, cut) in review.cuts.enumerated() where cut.included && cut.isEligible {
            let lastFrame = try cut.range.end.subtracting(review.frameDuration)
            let points: [(String, RationalTime)] = lastFrame == cut.range.start
                ? [("Start/End", cut.range.start)]
                : [("Start", cut.range.start), ("End", lastFrame)]
            for (label, position) in points {
                let source = try review.target.sourceStart.adding(position.subtracting(review.target.timelineRange.start))
                let draft = PreviewMarkerDraft(cutID: cut.id, parentClipID: review.target.id,
                    timelinePosition: position, sourcePosition: source,
                    value: String(format: "Cutdown %02d %@", index + 1, label),
                    note: "cutdown-preview:\(review.jobID.uuidString):\(cut.id):\(label)")
                let existing = existingMarkers.filter {
                    $0.parentClipID == draft.parentClipID && $0.timelinePosition == position
                }
                if existing.isEmpty { additions.append(draft) }
                else { collisions.append(PreviewMarkerCollision(draft: draft, existingMarkers: existing)) }
            }
        }
        self.additions = additions
        self.collisions = collisions
    }
}

public struct OwnedPreviewMarker: Codable, Hashable, Sendable {
    public let parentClipID: String
    public let timelinePosition: RationalTime
    public let sourcePosition: RationalTime
    public let semanticFingerprint: String
}

public struct MarkerOwnershipResolution: Sendable {
    public let exactMatches: [TimelineMarker]
    public let unresolved: [OwnedPreviewMarker]
    public var exclusions: Set<TimelineMarkerIdentity> { Set(exactMatches.map(\.identity)) }
}

/// Ownership is captured only after insertion has been verified in a fresh export.
/// Raw XML child indexes may change when other markers are added or removed.
/// Resolving this manifest never authorizes a timeline edit or cleanup on its own.
/// The caller must also verify the current project against the analysis baseline,
/// excluding only the exact owned markers returned by that fresh resolution.
public struct MarkerOwnershipManifest: Codable, Sendable {
    public let jobID: UUID
    public let projectName: String
    public let projectUID: String?
    public private(set) var markers: [OwnedPreviewMarker] = []

    public init(jobID: UUID, document: TimelineDocument) {
        self.jobID = jobID
        self.projectName = document.projectName
        self.projectUID = document.projectUID
    }

    public mutating func record(_ draft: PreviewMarkerDraft, in document: TimelineDocument) throws {
        guard sameProject(document), draft.note.hasPrefix("cutdown-preview:\(jobID.uuidString):") else {
            throw MarkerOwnershipError.wrongProjectOrJob
        }
        let matches = document.markers.filter {
            $0.parentClipID == draft.parentClipID && $0.sourcePosition == draft.sourcePosition
                && $0.timelinePosition == draft.timelinePosition && $0.kind == "marker"
                && $0.value == draft.value && $0.note == draft.note
        }
        guard matches.count == 1, let marker = matches.first else { throw MarkerOwnershipError.insertionNotVerified }
        let owned = OwnedPreviewMarker(parentClipID: marker.parentClipID, timelinePosition: marker.timelinePosition,
                                       sourcePosition: marker.sourcePosition,
                                       semanticFingerprint: marker.semanticFingerprint)
        if !markers.contains(owned) { markers.append(owned) }
    }

    public func resolve(in document: TimelineDocument) throws -> MarkerOwnershipResolution {
        guard sameProject(document) else { throw MarkerOwnershipError.wrongProjectOrJob }
        var exact: [TimelineMarker] = []
        var unresolved: [OwnedPreviewMarker] = []
        for owned in markers {
            let matches = document.markers.filter {
                $0.parentClipID == owned.parentClipID && $0.sourcePosition == owned.sourcePosition
                    && $0.timelinePosition == owned.timelinePosition
                    && $0.semanticFingerprint == owned.semanticFingerprint
            }
            if matches.count == 1 { exact.append(matches[0]) }
            else { unresolved.append(owned) }
        }
        return MarkerOwnershipResolution(exactMatches: exact, unresolved: unresolved)
    }

    private func sameProject(_ document: TimelineDocument) -> Bool {
        document.projectName == projectName && document.projectUID == projectUID
    }
}

public enum MarkerOwnershipError: LocalizedError {
    case wrongProjectOrJob, insertionNotVerified
    public var errorDescription: String? {
        switch self {
        case .wrongProjectOrJob: return "These preview markers belong to another project or analysis."
        case .insertionNotVerified: return "The preview marker could not be uniquely verified. Stop before creating more markers."
        }
    }
}
