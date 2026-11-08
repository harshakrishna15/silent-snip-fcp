import Foundation
import SilentSnipCore
#if canImport(FoundationXML)
import FoundationXML
#endif

enum NativeSourceEditPlanError: Error, LocalizedError, Equatable {
    case unsupported(String)
    case noRemovals
    case tooManyRemovals
    case invalidRemoval
    case overlappingRemovals
    case noRetainedAudio

    var errorDescription: String? {
        switch self {
        case .unsupported(let reason): "Native source editing is unavailable: \(reason)"
        case .noRemovals: "Select at least one range to remove."
        case .tooManyRemovals: "This native edit exceeds the bounded number of supported cuts."
        case .invalidRemoval: "A native removal must be nonempty, inside the clip, and aligned to project frames."
        case .overlappingRemovals: "Native removal ranges must not overlap or repeat."
        case .noRetainedAudio: "Native editing must leave some of the original audio clip."
        }
    }
}

/// Pure, deliberately narrow instructions for editing a host-native duplicate.
/// No effect state is reconstructed here: even a bare filter-audio is retained
/// in Final Cut's own clip objects. The runner must separately bind the new
/// native project identity and verify each actual edit against these layouts.
struct NativeSourceEditPlan: Sendable {
    static let maximumRemovals = 256
    static let maximumBulkRemovals = 8_192

    struct Segment: Codable, Hashable, Sendable {
        /// Coordinates in the untouched original project.
        let originalTimelineRange: TimeRange
        /// Coordinates in the duplicate after the corresponding edits.
        let timelineRange: TimeRange
        /// Original clip/source timecode, not a media-file sample offset.
        let sourceRange: TimeRange
    }

    struct Layout: Codable, Equatable, Sendable {
        let duration: RationalTime
        let segments: [Segment]

        var projectRange: TimeRange { .init(start: .zero, end: duration) }
    }

    struct Step: Codable, Equatable, Sendable {
        let ordinal: Int
        /// Original project coordinates. Steps are ordered latest first.
        let removal: TimeRange
        /// Exact half-open range to select in the current duplicate. A native
        /// range editor may use inclusive endpoints; its readback must prove
        /// this range and duration before any destructive input is allowed.
        let selectionRange: TimeRange
        let targetBefore: Segment
        let expectedBefore: Layout
        let expectedAfter: Layout
    }

    let libraryURL: URL
    let eventName: String
    let eventUID: String
    let projectName: String
    let projectUID: String
    let baselineFingerprint: String
    let projectTimecodeStart: RationalTime
    let frameDuration: RationalTime
    let target: TimelineClip
    /// Validated, ascending original-project ranges.
    let removals: [TimeRange]
    let removedDuration: RationalTime
    let initial: Layout
    let steps: [Step]
    /// Bulk XML edits need only the original and final geometry, never one
    /// complete intermediate layout per cut. Legacy native steps stay bounded.
    var bulkFinal: Layout? = nil

    var final: Layout { bulkFinal ?? steps.last?.expectedAfter ?? initial }

    static func make(projectData: Data, selection: TimelineSelection,
                     removals input: [TimeRange]) throws -> NativeSourceEditPlan {
        guard !input.isEmpty else { throw NativeSourceEditPlanError.noRemovals }
        guard input.count <= maximumRemovals else { throw NativeSourceEditPlanError.tooManyRemovals }
        let (document, target, identity) = try validatedSource(projectData: projectData, selection: selection)
        let (removals, removedDuration) = try validatedRemovals(input, document: document)
        var kept = [target.timelineRange]
        let initial = try layout(kept, target: target)
        var before = initial
        var steps: [Step] = []
        for (index, removal) in removals.reversed().enumerated() {
            let containing = before.segments.filter {
                $0.originalTimelineRange.start <= removal.start && removal.end <= $0.originalTimelineRange.end
            }
            guard containing.count == 1, let segment = containing.first else {
                throw NativeSourceEditPlanError.invalidRemoval
            }
            let selectionStart = try segment.timelineRange.start.adding(removal.start.subtracting(segment.originalTimelineRange.start))
            let selectionRange = TimeRange(start: selectionStart,
                end: try selectionStart.adding(removal.checkedDuration()))
            // Later removals must never move an earlier requested boundary.
            guard selectionRange == removal else { throw NativeSourceEditPlanError.invalidRemoval }
            kept = kept.flatMap { interval -> [TimeRange] in
                guard interval.start <= removal.start, removal.end <= interval.end else { return [interval] }
                var pieces: [TimeRange] = []
                if interval.start < removal.start { pieces.append(.init(start: interval.start, end: removal.start)) }
                if removal.end < interval.end { pieces.append(.init(start: removal.end, end: interval.end)) }
                return pieces
            }
            let after = try layout(kept, target: target)
            guard !after.segments.isEmpty else { throw NativeSourceEditPlanError.noRetainedAudio }
            steps.append(.init(ordinal: index + 1, removal: removal, selectionRange: selectionRange,
                targetBefore: segment, expectedBefore: before, expectedAfter: after))
            before = after
        }
        return .init(libraryURL: identity.library, eventName: identity.eventName, eventUID: identity.eventUID,
            projectName: document.projectName, projectUID: identity.projectUID,
            baselineFingerprint: document.fingerprint, projectTimecodeStart: document.projectTimecodeStart,
            frameDuration: document.frameDuration, target: target, removals: removals,
            removedDuration: removedDuration, initial: initial, steps: steps)
    }

    /// One sorted-range pass creates the final XML geometry. There are no
    /// destructive native steps and no quadratic array of intermediate layouts.
    static func makeBulk(projectData: Data, selection: TimelineSelection,
                         removals input: [TimeRange]) throws -> NativeSourceEditPlan {
        guard !input.isEmpty else { throw NativeSourceEditPlanError.noRemovals }
        guard input.count <= maximumBulkRemovals else { throw NativeSourceEditPlanError.tooManyRemovals }
        let (document, target, identity) = try validatedSource(projectData: projectData, selection: selection)
        let (removals, removedDuration) = try validatedRemovals(input, document: document)
        var kept: [TimeRange] = []
        kept.reserveCapacity(removals.count + 1)
        var cursor = target.timelineRange.start
        for removal in removals {
            if cursor < removal.start { kept.append(.init(start: cursor, end: removal.start)) }
            cursor = removal.end
        }
        if cursor < target.timelineRange.end { kept.append(.init(start: cursor, end: target.timelineRange.end)) }
        let initial = try layout([target.timelineRange], target: target)
        let final = try layout(kept, target: target)
        return .init(libraryURL: identity.library, eventName: identity.eventName, eventUID: identity.eventUID,
            projectName: document.projectName, projectUID: identity.projectUID,
            baselineFingerprint: document.fingerprint, projectTimecodeStart: document.projectTimecodeStart,
            frameDuration: document.frameDuration, target: target, removals: removals,
            removedDuration: removedDuration, initial: initial, steps: [], bulkFinal: final)
    }

    private static func validatedSource(projectData: Data, selection: TimelineSelection) throws ->
        (TimelineDocument, TimelineClip, (library: URL, eventName: String, eventUID: String, projectUID: String)) {
        // The core parser first enforces XML/entity, depth, node and byte limits.
        let document = try TimelineParser.parse(data: projectData)
        let target = try document.selectedTarget(selection, requireExistingMedia: false)
        guard document.clips.count == 1, target.kind == "asset-clip",
              target.isPrimaryStoryline, target.parentID == nil, target.lane == 0,
              target.enabled, target.hasAudio, !target.hasVideo,
              !target.hasUnresolvedTiming, target.unsupportedReasons.isEmpty,
              target.timelineRange == document.projectRange,
              target.audioFadeIn == .zero, target.audioFadeOut == .zero else {
            throw NativeSourceEditPlanError.unsupported("only one enabled audio-only asset clip filling the whole project is supported.")
        }
        guard try document.projectRange.end.roundedDown(toFrame: document.frameDuration) == document.projectRange.end,
              try document.projectTimecodeStart.roundedDown(toFrame: document.frameDuration) == document.projectTimecodeStart else {
            throw NativeSourceEditPlanError.unsupported("the project duration and timecode start must lie on project frames.")
        }
        // Hidden state must be measured in the original host, never by importing
        // an isolated reconstruction that may silently reset the audio effects.
        guard try DirectAudioRender.scope(projectData: projectData, selection: selection) != nil else {
            throw NativeSourceEditPlanError.unsupported("the original native Dialogue render is required; mixed or non-Dialogue source components cannot use this route.")
        }
        return (document, target, try validateXML(projectData, document: document, target: target))
    }

    private static func validatedRemovals(_ input: [TimeRange], document: TimelineDocument) throws -> ([TimeRange], RationalTime) {
        let removals = input.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var previousEnd: RationalTime?
        var removedDuration = RationalTime.zero
        for range in removals {
            guard !range.isEmpty, range.start >= .zero, range.end <= document.projectRange.end,
                  try range.start.roundedDown(toFrame: document.frameDuration) == range.start,
                  try range.end.roundedDown(toFrame: document.frameDuration) == range.end else {
                throw NativeSourceEditPlanError.invalidRemoval
            }
            if let previousEnd, range.start < previousEnd { throw NativeSourceEditPlanError.overlappingRemovals }
            previousEnd = range.end
            removedDuration = try removedDuration.adding(range.checkedDuration())
        }
        guard removedDuration < document.projectRange.end else { throw NativeSourceEditPlanError.noRetainedAudio }
        return (removals, removedDuration)
    }

    private static func layout(_ ranges: [TimeRange], target: TimelineClip) throws -> Layout {
        var cursor = RationalTime.zero
        var segments: [Segment] = []
        for interval in ranges {
            let duration = try interval.checkedDuration()
            let end = try cursor.adding(duration)
            let sourceStart = try target.sourceStart.adding(interval.start.subtracting(target.timelineRange.start))
            segments.append(.init(originalTimelineRange: interval,
                timelineRange: .init(start: cursor, end: end),
                sourceRange: .init(start: sourceStart, end: try sourceStart.adding(duration))))
            cursor = end
        }
        return .init(duration: cursor, segments: segments)
    }

    private static func validateXML(_ data: Data, document: TimelineDocument,
                                    target: TimelineClip) throws -> (library: URL, eventName: String, eventUID: String, projectUID: String) {
        let xml = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        let projects = try xml.nodes(forXPath: "/fcpxml/library/event/project").compactMap { $0 as? XMLElement }
        guard projects.count == 1, let project = projects.first,
              let event = project.parent as? XMLElement, let library = event.parent as? XMLElement,
              let location = library.attribute(forName: "location")?.stringValue,
              let libraryURL = URL(string: location), libraryURL.isFileURL,
              libraryURL.pathExtension.lowercased() == "fcpbundle",
              let eventName = nonempty(event, "name"), let eventUID = nonempty(event, "uid"),
              let projectUID = nonempty(project, "uid"), projectUID == document.projectUID,
              nonempty(project, "name") == document.projectName,
              let sequence = project.elements(forName: "sequence").first,
              project.elements(forName: "sequence").count == 1,
              children(project).allSatisfy({ ["sequence", "metadata"].contains($0.name ?? "") }),
              sequence.elements(forName: "spine").count == 1,
              children(sequence).allSatisfy({ ["spine", "metadata"].contains($0.name ?? "") }),
              let spine = sequence.elements(forName: "spine").first,
              (spine.attributes ?? []).isEmpty,
              children(spine).count == 1, let clip = children(spine).first, clip.name == "asset-clip",
              target.id == "spine/0" else {
            throw NativeSourceEditPlanError.unsupported("an unambiguous native project, event, library and plain primary storyline are required.")
        }
        let clipAttributes: Set<String> = ["ref", "offset", "name", "start", "duration", "enabled", "lane",
            "audioRole", "role", "srcEnable", "format", "tcFormat", "modDate", "audioStart", "audioDuration"]
        let sequenceAttributes: Set<String> = ["format", "duration", "tcStart", "tcFormat", "audioLayout", "audioRate", "renderFormat"]
        guard (clip.attributes ?? []).allSatisfy({ clipAttributes.contains($0.name ?? "") }),
              (sequence.attributes ?? []).allSatisfy({ sequenceAttributes.contains($0.name ?? "") }),
              clip.attribute(forName: "srcEnable").map({ ["all", "audio"].contains($0.stringValue ?? "") }) ?? true,
              clip.attribute(forName: "enabled").map({ $0.stringValue == "1" }) ?? true,
              clip.attribute(forName: "lane").map({ $0.stringValue == "0" }) ?? true,
              let assetID = clip.attribute(forName: "ref")?.stringValue,
              let resources = try xml.nodes(forXPath: "/fcpxml/resources").first as? XMLElement,
              let asset = resources.elements(forName: "asset").first(where: { $0.attribute(forName: "id")?.stringValue == assetID }),
              asset.attribute(forName: "hasVideo").map({ $0.stringValue == "0" }) ?? true,
              asset.attribute(forName: "hasAudio")?.stringValue == "1",
              children(asset).allSatisfy({ ["media-rep", "metadata"].contains($0.name ?? "") }),
              let sourceURL = target.mediaURL, sourceURL.isFileURL else {
            throw NativeSourceEditPlanError.unsupported("the source must be one ordinary original audio asset without video or additional clip timing.")
        }
        let representations = asset.elements(forName: "media-rep")
        guard representations.isEmpty || (representations.count == 1 && representations[0].attribute(forName: "kind")?.stringValue == "original-media") else {
            throw NativeSourceEditPlanError.unsupported("alternate, proxy or optimized source representations are not supported by this native route.")
        }
        guard let rawAssetDuration = asset.attribute(forName: "duration")?.stringValue else {
            throw NativeSourceEditPlanError.unsupported("the original audio asset duration is required.")
        }
        let assetDuration = try RationalTime.parse(rawAssetDuration)
        let sourceEnd = try target.sourceStart.adding(target.timelineRange.checkedDuration())
        guard target.sourceStart >= target.assetStart, assetDuration > .zero,
              sourceEnd <= (try target.assetStart.adding(assetDuration)) else {
            throw NativeSourceEditPlanError.unsupported("the clip's source interval lies outside its original asset.")
        }
        let allowed: Set<String> = ["adjust-volume", "adjust-panner", "adjust-loudness", "adjust-noiseReduction",
            "adjust-humReduction", "adjust-EQ", "adjust-matchEQ", "adjust-voiceIsolation", "audio-channel-source",
            "filter-audio", "param", "data", "keyframeAnimation", "keyframe", "metadata", "md", "array", "string",
            "note", "marker", "chapter-marker", "keyword", "rating", "analysis-marker"]
        let effectIDs = Set(resources.elements(forName: "effect").compactMap { element -> String? in
            guard nonempty(element, "uid") != nil else { return nil }
            return nonempty(element, "id")
        })
        let controllerIDs = Set(resources.elements(forName: "effect").filter {
            $0.attribute(forName: "uid")?.stringValue == AudioControllerSettings.effectUID
        }.compactMap { nonempty($0, "id") })
        var queue = children(clip)
        var cursor = 0
        while cursor < queue.count {
            guard cursor < 10_000 else { throw NativeSourceEditPlanError.unsupported("the clip state exceeds the native route's element bound.") }
            let node = queue[cursor]; cursor += 1
            guard let name = node.name, allowed.contains(name) else {
                throw NativeSourceEditPlanError.unsupported("the clip contains unsupported timing, fades, video, nested content or processing.")
            }
            if name == "audio-channel-source", node.attribute(forName: "start") != nil || node.attribute(forName: "duration") != nil {
                throw NativeSourceEditPlanError.unsupported("trimmed audio components are not supported.")
            }
            if name == "filter-audio" {
                guard let ref = node.attribute(forName: "ref")?.stringValue, effectIDs.contains(ref) else {
                    throw NativeSourceEditPlanError.unsupported("an audio effect does not identify its original effect resource.")
                }
                guard !controllerIDs.contains(ref) else {
                    throw NativeSourceEditPlanError.unsupported("remove the existing Silent Snip audio effect before using native source editing.")
                }
            }
            queue.append(contentsOf: children(node))
            guard queue.count <= 10_000 else { throw NativeSourceEditPlanError.unsupported("the clip state exceeds the native route's element bound.") }
        }
        return (libraryURL.standardizedFileURL, eventName, eventUID, projectUID)
    }

    private static func children(_ node: XMLElement) -> [XMLElement] {
        (node.children ?? []).compactMap { $0 as? XMLElement }
    }

    private static func nonempty(_ node: XMLElement, _ attribute: String) -> String? {
        guard let value = node.attribute(forName: attribute)?.stringValue,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= 1_024 else { return nil }
        return value
    }
}
