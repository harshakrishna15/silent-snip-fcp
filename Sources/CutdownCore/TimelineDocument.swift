import Foundation

public enum TimelineError: Error, LocalizedError, Equatable {
    case invalidXML(String)
    case invalidTime(String)
    case unsupportedVersion(String)
    case projectCount(Int)
    case missingResource(String)
    case invalidSequence(String)
    case targetNotFound
    case ambiguousTarget
    case unsupportedTarget([String])
    case missingMedia(String)

    public var errorDescription: String? {
        switch self {
        case .invalidXML(let reason): "Invalid FCPXML: \(reason)"
        case .invalidTime(let value): "Invalid FCPXML time: \(value)"
        case .unsupportedVersion(let version): "FCPXML \(version) is not supported. Export version 1.10–1.14."
        case .projectCount(let count): "Export exactly one project; this document contains \(count)."
        case .missingResource(let id): "The FCPXML resource \(id) is missing."
        case .invalidSequence(let reason): "The project cannot be analyzed: \(reason)"
        case .targetNotFound: "The selected clip's exact position and duration were not found in the primary storyline."
        case .ambiguousTarget: "The selection matches more than one timeline item. Select a single clip and export again."
        case .unsupportedTarget(let reasons): "This clip cannot be cut automatically: " + reasons.joined(separator: "; ") + "."
        case .missingMedia(let path): "Original media is missing or unreadable: \(path)"
        }
    }
}

/// All timeline ranges use seconds from the first frame of the project, not display timecode.
public struct TimelineSelection: Codable, Hashable, Sendable {
    public let timelineRange: TimeRange
    public let sourceURL: URL?
    public let sourceStart: RationalTime?

    public init(timelineRange: TimeRange, sourceURL: URL? = nil, sourceStart: RationalTime? = nil) {
        self.timelineRange = timelineRange
        self.sourceURL = sourceURL
        self.sourceStart = sourceStart
    }
}

public struct TimelineClip: Codable, Hashable, Sendable, Identifiable {
    /// An XML instance path, unique even when the same source occurs more than once.
    public let id: String
    public let name: String
    public let kind: String
    public let timelineRange: TimeRange
    /// The clip's local/source timecode origin. Subtract assetStart for a media-file offset.
    public let sourceStart: RationalTime
    public let assetStart: RationalTime
    public let mediaURL: URL?
    public let assetID: String?
    public let parentID: String?
    public let lane: Int
    public let isPrimaryStoryline: Bool
    public let enabled: Bool
    /// Whether this timeline instance includes video. Video items remain part of
    /// project context, but cannot be selected as Cutdown's audio-only target.
    public let hasVideo: Bool
    /// Whether source audio is present and enabled in this timeline instance.
    public let hasAudio: Bool
    public let dialogueRoles: [String]
    /// Child timing cannot be safely projected through a time map or speed conform.
    public let hasUnresolvedTiming: Bool
    public let unsupportedReasons: [String]
    /// Rendering settings excluding boundary-relative fades (tracked separately).
    public let effectsFingerprint: String
    public var audioFadeIn: RationalTime = .zero
    public var audioFadeOut: RationalTime = .zero

    public var sourceFileStart: RationalTime { sourceStart - assetStart }
}

public struct TimelineProtectedRange: Codable, Hashable, Sendable {
    public let range: TimeRange
    public let reason: String
    public init(range: TimeRange, reason: String) {
        self.range = range
        self.reason = reason
    }
}

public struct TimelineMarker: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let parentClipID: String
    public let timelinePosition: RationalTime
    public let sourcePosition: RationalTime
    public let kind: String
    public let value: String
    public let note: String?
    public let duration: RationalTime
    public let completed: String?
}

public struct TimelineFingerprintExclusions: Sendable {
    /// Exact Audio Unit effect resource UIDs proven to belong to Cutdown.
    /// No name matching or inferred Audio Unit identifier is permitted.
    /// The verified local Cutdown AU also excludes its nonrendering effectState
    /// archive when explicitly present in this allowlist; other data is preserved.
    public let controllerEffectUIDs: Set<String>
    public init(controllerEffectUIDs: Set<String> = []) {
        self.controllerEffectUIDs = controllerEffectUIDs
    }
}

public struct TimelineDocument: Codable, Sendable {
    public let version: String
    public let projectName: String
    public let projectUID: String?
    public let projectTimecodeStart: RationalTime
    public let projectRange: TimeRange
    public let frameDuration: RationalTime
    public let clips: [TimelineClip]
    public let markers: [TimelineMarker]
    public let dialogueRoles: [String]
    /// Semantic sequence hash, including effects and referenced resource definitions.
    /// Project name/UID and exporter modification dates are deliberately outside this hash.
    public let fingerprint: String
    public let warnings: [String]

    public static let missingDialogueWarning = "No enabled Dialogue role or Dialogue subrole was found. Do not treat an absent dialogue export as silence."

    /// Selects one direct, normal-speed audio-only primary-storyline instance.
    /// Other timeline items remain available for dialogue context and validation.
    public func selectedTarget(_ selection: TimelineSelection, requireExistingMedia: Bool = true) throws -> TimelineClip {
        let matches = clips.filter { clip in
            clip.isPrimaryStoryline && clip.timelineRange == selection.timelineRange
                && (selection.sourceStart == nil || clip.sourceStart == selection.sourceStart)
                && (selection.sourceURL == nil || clip.mediaURL?.standardizedFileURL == selection.sourceURL?.standardizedFileURL)
        }
        guard !matches.isEmpty else { throw TimelineError.targetNotFound }
        guard matches.count == 1 else { throw TimelineError.ambiguousTarget }
        let target = matches[0]
        guard !target.hasVideo else {
            throw TimelineError.unsupportedTarget(["Cutdown supports audio-only timeline clips; video clips with audio are not supported"])
        }
        guard target.unsupportedReasons.isEmpty else { throw TimelineError.unsupportedTarget(target.unsupportedReasons) }
        guard target.hasAudio else { throw TimelineError.unsupportedTarget(["enabled source audio is required"]) }
        guard let mediaURL = target.mediaURL, mediaURL.isFileURL else {
            throw TimelineError.missingMedia(target.name)
        }
        if requireExistingMedia && !FileManager.default.isReadableFile(atPath: mediaURL.path) {
            throw TimelineError.missingMedia(mediaURL.path)
        }
        return target
    }

    /// Dialogue on another connected item cannot be shortened without making an independent edit.
    /// Conservatively protect its entire overlap, even when its rendered waveform contains silence.
    public func protectedRanges(for target: TimelineClip) throws -> [TimelineProtectedRange] {
        let duration = try target.timelineRange.checkedDuration()
        var protected: [TimelineProtectedRange] = []
        if target.audioFadeIn > .zero {
            protected.append(.init(range: .init(start: target.timelineRange.start,
                end: try target.timelineRange.start.adding(min(duration, target.audioFadeIn))), reason: "Preserve the original fade-in curve"))
        }
        if target.audioFadeOut > .zero {
            protected.append(.init(range: .init(start: try target.timelineRange.end.subtracting(min(duration, target.audioFadeOut)),
                end: target.timelineRange.end), reason: "Preserve the original fade-out curve"))
        }
        return protected + clips.compactMap { clip in
            guard clip.id != target.id, clip.enabled,
                  let overlap = clip.timelineRange.intersection(target.timelineRange) else { return nil }
            if clip.kind == "transition" {
                return TimelineProtectedRange(range: overlap, reason: "Transition: \(clip.name)")
            }
            if !clip.isPrimaryStoryline && !clip.dialogueRoles.isEmpty {
                return TimelineProtectedRange(range: overlap, reason: "Connected dialogue must stay synchronized: \(clip.name)")
            }
            if !clip.isPrimaryStoryline && (clip.hasUnresolvedTiming || ["ref-clip", "mc-clip", "sync-clip", "audition"].contains(clip.kind)) {
                return TimelineProtectedRange(range: overlap, reason: "Nested audio cannot be mapped safely: \(clip.name)")
            }
            return nil
        }
    }
}
