import CutdownCore
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct EditedProjectSegment: Codable, Equatable, Sendable {
    public let originalProjectRange: TimeRange
    public let resultProjectRange: TimeRange
    /// Absolute source timecode, including the asset's source timecode origin.
    public let sourceRange: TimeRange
    public let mediaFileRange: TimeRange
}

public struct EditedProjectReport: Codable, Sendable {
    public let originalProjectName: String
    public let originalProjectUID: String?
    public let baselineFingerprint: String
    public let projectName: String
    public let projectUID: UUID
    public let eventUID: UUID
    public var replacementTarget: XMLReplacementTarget? = nil
    public let targetID: String
    public let originalProjectDuration: RationalTime
    public let resultProjectDuration: RationalTime
    public let removedDuration: RationalTime
    public let insertedGapDuration: RationalTime
    public let selectedRanges: [TimeRange]
    public let retainedSegments: [EditedProjectSegment]
    public let removedPointMarkerCount: Int
}

public struct EditedProjectOutput: Sendable {
    public let xmlData: Data
    public let report: EditedProjectReport
}

public enum EditedProjectWriterError: Error, LocalizedError, Equatable {
    case noSelectedCuts
    case invalidName
    case invalidRange
    case overlappingRanges
    case wholeClipDeletion
    case unsupported(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noSelectedCuts: return "Select at least one eligible cut before creating an edited project."
        case .invalidName: return "Give the edited project a name."
        case .invalidRange: return "Every cut must be inside the audio target and aligned to project frames."
        case .overlappingRanges: return "Selected cut ranges overlap. Analyze again."
        case .wholeClipDeletion: return "The selected cuts would remove the entire target. Whole-clip deletion is unavailable."
        case .unsupported(let reason): return "This project cannot be returned automatically: \(reason)"
        case .verificationFailed(let reason): return "The generated project failed verification: \(reason)"
        }
    }
}

/// Generates edited XML without modifying the input document or media.
/// Replacement retains the original event/name; ordinary output creates a copy.
/// This deliberately supports a narrow set of timeline edits: splitting one
/// direct audio asset, then shifting later primary-storyline items. Connections
/// on the target and any connected content crossing a cut require native Final
/// Cut connection semantics and are rejected, rather than silently rearranged.
public enum EditedProjectWriter {
    public static func write(
        projectData: Data,
        selection: TimelineSelection,
        selectedRanges: [TimeRange],
        outputName: String,
        projectUID: UUID = UUID(),
        eventUID: UUID = UUID(),
        destinationLibrary: URL? = nil,
        replacementGaps: [TimeRange: RationalTime] = [:],
        replaceOriginal: Bool = false
    ) throws -> EditedProjectOutput {
        let name = outputName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw EditedProjectWriterError.invalidName }
        // Run the bounded/entity-safe parser before FoundationXML. All later
        // changes use this exact data, never a caller-supplied stale document.
        let document = try TimelineParser.parse(data: projectData)
        let replacement = try replaceOriginal ? XMLReplacementTarget(projectData: projectData) : nil
        if let replacement {
            guard outputName == replacement.projectName, name == outputName,
                  destinationLibrary == nil || destinationLibrary?.standardizedFileURL == replacement.libraryURL else {
                throw EditedProjectWriterError.unsupported("replacement must retain the original project name and library")
            }
        }
        let target = try document.selectedTarget(selection, requireExistingMedia: false)
        let ranges = try validatedRanges(selectedRanges, target: target, frame: document.frameDuration)
        let fadeRanges = try document.protectedRanges(for: target).filter { $0.reason.hasPrefix("Preserve the original fade-") }
        guard !ranges.contains(where: { cut in fadeRanges.contains { $0.range.intersection(cut) != nil } }) else {
            throw EditedProjectWriterError.unsupported("a selected cut overlaps a fade. Deselect that cut to retain the original fade curve.")
        }
        let removed = try ranges.reduce(RationalTime.zero) { try $0.adding($1.checkedDuration()) }
        guard replacementGaps.isEmpty || Set(replacementGaps.keys) == Set(ranges) else {
            throw EditedProjectWriterError.invalidRange
        }
        for duration in replacementGaps.values {
            guard duration > .zero, try duration.roundedDown(toFrame: document.frameDuration) == duration else {
                throw EditedProjectWriterError.invalidRange
            }
        }
        let added = try replacementGaps.values.reduce(RationalTime.zero) { try $0.adding($1) }
        let netRemoved = try removed.subtracting(added)
        guard removed < (try target.timelineRange.checkedDuration()) else {
            throw EditedProjectWriterError.wholeClipDeletion
        }
        guard document.projectUID?.caseInsensitiveCompare(projectUID.uuidString) != .orderedSame else {
            throw EditedProjectWriterError.unsupported("the result must have a different project identity.")
        }

        let xml = try XMLDocument(data: projectData, options: [.nodePreserveAll])
        guard let root = xml.rootElement(),
              let project = try root.nodes(forXPath: ".//project").first as? XMLElement,
              let sequence = project.elements(forName: "sequence").first,
              let spine = sequence.elements(forName: "spine").first else {
            throw EditedProjectWriterError.verificationFailed("missing project storyline.")
        }
        let story = elementChildren(spine)
        let path = target.id.split(separator: "/")
        guard path.count == 2, path[0] == "spine", let targetIndex = Int(path[1]),
              story.indices.contains(targetIndex), story[targetIndex].name == "asset-clip" else {
            throw EditedProjectWriterError.verificationFailed("the selected timeline instance is missing.")
        }
        let targetNode = story[targetIndex]
        try validateTopology(document: document, target: target, ranges: ranges, spine: spine, root: root)
        try validateTargetContents(targetNode)

        let kept = retainedRanges(target: target.timelineRange, removals: ranges)
        var cursor = target.timelineRange.start
        var segments: [EditedProjectSegment] = []
        var replacements: [XMLElement] = []
        var gapRanges: [TimeRange] = []
        let pieces = (kept + Array(replacementGaps.keys)).sorted { $0.start < $1.start }
        for range in pieces {
            if let gapDuration = replacementGaps[range] {
                let gap = XMLElement(name: "gap")
                set(gap, "name", "Gap")
                set(gap, "offset", try timeString(cursor.adding(document.projectTimecodeStart)))
                set(gap, "start", "3600s")
                set(gap, "duration", try timeString(gapDuration))
                replacements.append(gap)
                let end = try cursor.adding(gapDuration)
                gapRanges.append(.init(start: cursor, end: end))
                cursor = end
                continue
            }
            let duration = try range.checkedDuration()
            let sourceStart = try target.sourceStart.adding(range.start.subtracting(target.timelineRange.start))
            let sourceEnd = try sourceStart.adding(duration)
            let sourceRange = TimeRange(start: sourceStart, end: sourceEnd)
            let resultEnd = try cursor.adding(duration)
            let segment = EditedProjectSegment(originalProjectRange: range,
                resultProjectRange: .init(start: cursor, end: resultEnd), sourceRange: sourceRange,
                mediaFileRange: .init(start: try sourceStart.subtracting(target.assetStart),
                                     end: try sourceEnd.subtracting(target.assetStart)))
            let copy = targetNode.copy() as! XMLElement
            set(copy, "offset", try timeString(cursor.adding(document.projectTimecodeStart)))
            set(copy, "start", try timeString(sourceStart))
            set(copy, "duration", try timeString(duration))
            if copy.attribute(forName: "audioStart") != nil { set(copy, "audioStart", try timeString(sourceStart)) }
            if copy.attribute(forName: "audioDuration") != nil { set(copy, "audioDuration", try timeString(duration)) }
            // Keyframes retain their complete source-time curve, including
            // surrounding control points needed for smooth interpolation.
            // Boundary-relative fades belong only to the original outer edges.
            for node in descendants(copy) {
                if node.name == "fadeIn", sourceStart != target.sourceStart { node.detach() }
                if node.name == "fadeOut", sourceEnd != (try target.sourceStart.adding(target.timelineRange.duration)) { node.detach() }
            }
            try trimAnnotations(copy, to: sourceRange, original: target)
            replacements.append(copy)
            segments.append(segment)
            cursor = resultEnd
        }

        // Adjust only each later root item's parent-coordinate offset. Its source
        // trims, effects, children, and connection offsets remain byte-for-byte
        // equivalent as XML nodes. Repeated media references are not conflated.
        for clip in document.clips where clip.isPrimaryStoryline && clip.timelineRange.start >= target.timelineRange.end {
            guard let indexText = clip.id.split(separator: "/").last,
                  let index = Int(indexText), story.indices.contains(index) else {
                throw EditedProjectWriterError.verificationFailed("a later storyline item is missing.")
            }
            set(story[index], "offset", try timeString(clip.timelineRange.start
                .adding(document.projectTimecodeStart).subtracting(netRemoved)))
        }
        let insertionIndex = targetNode.index
        targetNode.detach()
        for (index, node) in replacements.enumerated() { spine.insertChild(node, at: insertionIndex + index) }
        let resultDuration = try document.projectRange.checkedDuration().subtracting(netRemoved)
        set(sequence, "duration", try timeString(resultDuration))
        set(project, "name", name)
        set(project, "uid", projectUID.uuidString)
        project.removeAttribute(forName: "id")
        project.removeAttribute(forName: "modDate")

        // Emit only the new event/project, retaining resource definitions and
        // original media bookmarks. No source library events are re-imported.
        let originalLibrary = root.elements(forName: "library").first
        let originalLocation = originalLibrary?.attribute(forName: "location")?.stringValue
        let colorProcessing = originalLibrary?.attribute(forName: "colorProcessing")?.stringValue
        let resultRoot = XMLElement(name: "fcpxml")
        for attribute in root.attributes ?? [] { resultRoot.addAttribute(attribute.copy() as! XMLNode) }
        // Apple's documented import options keep media in place and expose any
        // importer warning. Do not inherit an input option requesting asset copies.
        let importOptions = XMLElement(name: "import-options")
        for (key, value) in [("copy assets", "0"), ("suppress warnings", "0")] {
            let option = XMLElement(name: "option")
            set(option, "key", key)
            set(option, "value", value)
            importOptions.addChild(option)
        }
        if let location = destinationLibrary?.absoluteString ?? originalLocation {
            let option = XMLElement(name: "option")
            set(option, "key", "library location")
            set(option, "value", location)
            importOptions.addChild(option)
        }
        resultRoot.addChild(importOptions)
        if let resources = root.elements(forName: "resources").first {
            resultRoot.addChild(resources.copy() as! XMLNode)
        }
        let library = XMLElement(name: "library")
        if let destinationLibrary {
            guard destinationLibrary.isFileURL, destinationLibrary.pathExtension.lowercased() == "fcpbundle" else {
                throw EditedProjectWriterError.unsupported("the destination must be a local Final Cut library.")
            }
            set(library, "location", destinationLibrary.absoluteString)
        } else if let originalLocation { set(library, "location", originalLocation) }
        if let colorProcessing { set(library, "colorProcessing", colorProcessing) }
        let event = XMLElement(name: "event")
        guard try replacement != nil || (root.nodes(forXPath: ".//event").allSatisfy({ node in
            (node as? XMLElement)?.attribute(forName: "uid")?.stringValue?
                .caseInsensitiveCompare(eventUID.uuidString) != .orderedSame
        })) else { throw EditedProjectWriterError.unsupported("the result must have a different event identity.") }
        set(event, "name", replacement?.eventName ?? "Cutdown Results")
        set(event, "uid", (replacement?.eventUID ?? eventUID).uuidString)
        event.addChild(project.copy() as! XMLNode)
        library.addChild(event)
        resultRoot.addChild(library)
        xml.setRootElement(resultRoot)
        // FCPXML is validated with Apple's external DTD. Foundation otherwise
        // emits standalone="yes", invalid with the DTD's element-only whitespace.
        xml.isStandalone = false
        let outputData = xml.xmlData(options: [.nodePrettyPrint])
        let outputDocument = try TimelineParser.parse(data: outputData)
        try verify(outputDocument, original: document, target: target, segments: segments, removed: netRemoved, gaps: gapRanges)
        let removedPointMarkers = document.markers.filter { marker in
            marker.parentClipID == target.id && !segments.contains { $0.sourceRange.contains(marker.sourcePosition) }
        }.count
        return EditedProjectOutput(xmlData: outputData, report: .init(
            originalProjectName: document.projectName, originalProjectUID: document.projectUID,
            baselineFingerprint: document.fingerprint, projectName: name, projectUID: projectUID,
            eventUID: replacement?.eventUID ?? eventUID, replacementTarget: replacement, targetID: target.id,
            originalProjectDuration: try document.projectRange.checkedDuration(),
            resultProjectDuration: resultDuration, removedDuration: removed, insertedGapDuration: added, selectedRanges: ranges,
            retainedSegments: segments, removedPointMarkerCount: removedPointMarkers))
    }

    private static func validatedRanges(_ input: [TimeRange], target: TimelineClip,
                                        frame: RationalTime) throws -> [TimeRange] {
        guard !input.isEmpty else { throw EditedProjectWriterError.noSelectedCuts }
        let sorted = input.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var end: RationalTime?
        for range in sorted {
            guard !range.isEmpty, range.start >= target.timelineRange.start,
                  range.end <= target.timelineRange.end,
                  try range.start.roundedDown(toFrame: frame) == range.start,
                  try range.end.roundedDown(toFrame: frame) == range.end else {
                throw EditedProjectWriterError.invalidRange
            }
            if let end, range.start < end { throw EditedProjectWriterError.overlappingRanges }
            end = range.end
        }
        return sorted
    }

    private static func retainedRanges(target: TimeRange, removals: [TimeRange]) -> [TimeRange] {
        var cursor = target.start
        var kept: [TimeRange] = []
        for cut in removals {
            if cursor < cut.start { kept.append(.init(start: cursor, end: cut.start)) }
            cursor = cut.end
        }
        if cursor < target.end { kept.append(.init(start: cursor, end: target.end)) }
        return kept
    }

    private static func validateTopology(document: TimelineDocument, target: TimelineClip,
                                         ranges: [TimeRange], spine: XMLElement, root: XMLElement) throws {
        guard spine.attribute(forName: "offset") == nil, spine.attribute(forName: "lane") == nil else {
            throw EditedProjectWriterError.unsupported("the root storyline uses unsupported coordinates.")
        }
        // A projectRef can point back to the original project and silently make
        // a new result depend on it. Nested project resources need separate work.
        guard try root.nodes(forXPath: ".//media[@projectRef]").isEmpty else {
            throw EditedProjectWriterError.unsupported("project-linked compound resources are not supported.")
        }
        let primary = document.clips.filter(\.isPrimaryStoryline)
        guard primary.count == elementChildren(spine).count,
              primary.allSatisfy({ ["asset-clip", "gap"].contains($0.kind) }) else {
            throw EditedProjectWriterError.unsupported("transitions, compound storylines, and non-asset primary items require native editing.")
        }
        var end = RationalTime.zero
        for clip in primary {
            guard clip.timelineRange.start == end else {
                throw EditedProjectWriterError.unsupported("overlapping or implicit-gap primary storylines require native editing.")
            }
            end = clip.timelineRange.end
        }
        guard end == document.projectRange.end else {
            throw EditedProjectWriterError.unsupported("the project duration extends beyond its primary storyline.")
        }
        for clip in document.clips where !clip.isPrimaryStoryline {
            if clip.id.hasPrefix(target.id + "/") {
                throw EditedProjectWriterError.unsupported("\(clip.name) is connected to the target; its attachment cannot yet be preserved automatically.")
            }
            if ranges.contains(where: { $0.intersection(clip.timelineRange) != nil }) {
                throw EditedProjectWriterError.unsupported("\(clip.name) crosses a selected cut and must stay synchronized.")
            }
            // Connections belonging to later primary clips move with their
            // parents. Earlier connections extending past the first cut would
            // instead remain stationary while following audio ripples.
            let rootID = clip.id.split(separator: "/").prefix(2).joined(separator: "/")
            if let parent = primary.first(where: { $0.id == rootID }),
               parent.timelineRange.start < target.timelineRange.start,
               clip.timelineRange.end > ranges[0].start {
                throw EditedProjectWriterError.unsupported("an earlier connected item extends across the edited region.")
            }
            if clip.hasUnresolvedTiming {
                throw EditedProjectWriterError.unsupported("nested retimed content cannot be verified automatically.")
            }
        }
    }

    private static let annotationNames: Set<String> = ["marker", "chapter-marker", "keyword", "rating", "analysis-marker"]
    private static let allowedTargetElements: Set<String> = [
        "note", "conform-rate", "adjust-volume", "adjust-panner", "audio-channel-source",
        "adjust-loudness", "adjust-noiseReduction", "adjust-humReduction", "adjust-EQ", "adjust-matchEQ",
        "adjust-voiceIsolation", "keyframeAnimation", "keyframe", "fadeIn", "fadeOut", "filter-audio", "data", "param", "metadata", "md", "array", "string",
        "marker", "chapter-marker", "keyword", "rating", "analysis-marker", "shot-type", "stabilization-type"
    ]

    private static func validateTargetContents(_ target: XMLElement) throws {
        // Traverse this subtree directly. Foundation's XPath evaluation can use
        // the document context for a child node and include unrelated elements.
        for node in descendants(target) {
            let name = node.name ?? "unknown"
            guard allowedTargetElements.contains(name) else {
                throw EditedProjectWriterError.unsupported("the target contains \(name), whose timing cannot yet be preserved when splitting.")
            }
            if name == "keyframeAnimation" {
                let frames = node.elements(forName: "keyframe")
                guard !frames.isEmpty else { throw EditedProjectWriterError.unsupported("an animation has no keyframes.") }
                var previous: RationalTime?
                for frame in frames {
                    guard let raw = frame.attribute(forName: "time")?.stringValue,
                          let value = frame.attribute(forName: "value")?.stringValue, !value.isEmpty else {
                        throw EditedProjectWriterError.unsupported("a keyframe is missing its source time or value.")
                    }
                    let time = try RationalTime.parse(raw)
                    guard previous == nil || time > previous! else { throw EditedProjectWriterError.unsupported("keyframe times must increase.") }
                    previous = time
                }
            }
            if name == "audio-channel-source", node.attribute(forName: "start") != nil || node.attribute(forName: "duration") != nil {
                throw EditedProjectWriterError.unsupported("trimmed audio components require native editing.")
            }
            if name == "conform-rate", node.attribute(forName: "scaleEnabled")?.stringValue != "0" {
                throw EditedProjectWriterError.unsupported("speed-conformed audio cannot be split automatically.")
            }
        }
    }

    private static func trimAnnotations(_ clip: XMLElement, to kept: TimeRange,
                                        original: TimelineClip) throws {
        for annotation in elementChildren(clip) where annotationNames.contains(annotation.name ?? "") {
            let name = annotation.name ?? ""
            let originalEnd = try original.sourceStart.adding(original.timelineRange.checkedDuration())
            let start = try annotation.attribute(forName: "start")?.stringValue.map(RationalTime.parse) ?? original.sourceStart
            let duration = try annotation.attribute(forName: "duration")?.stringValue.map(RationalTime.parse)
            if ["marker", "chapter-marker"].contains(name) {
                guard kept.contains(start) else { annotation.detach(); continue }
                if let duration, duration > .zero {
                    let end = min(try start.adding(duration), kept.end)
                    set(annotation, "duration", try timeString(end.subtracting(start)))
                }
                if let poster = annotation.attribute(forName: "posterOffset")?.stringValue,
                   !kept.contains(try start.adding(RationalTime.parse(poster))) {
                    throw EditedProjectWriterError.unsupported("a chapter marker's poster frame lies outside its retained segment.")
                }
            } else {
                let end = try duration.map { try start.adding($0) } ?? originalEnd
                guard end >= start else { throw EditedProjectWriterError.unsupported("a clip annotation has invalid timing.") }
                guard let overlap = kept.intersection(.init(start: start, end: end)) else { annotation.detach(); continue }
                set(annotation, "start", try timeString(overlap.start))
                set(annotation, "duration", try timeString(overlap.checkedDuration()))
            }
        }
    }

    private static func verify(_ output: TimelineDocument, original: TimelineDocument, target: TimelineClip,
                               segments: [EditedProjectSegment], removed: RationalTime, gaps: [TimeRange]) throws {
        let expectedCount = original.clips.count - 1 + segments.count + gaps.count
        guard output.clips.count == expectedCount,
              output.projectRange.end == (try original.projectRange.end.subtracting(removed)),
              output.frameDuration == original.frameDuration,
              output.projectTimecodeStart == original.projectTimecodeStart else {
            throw EditedProjectWriterError.verificationFailed("project duration, clip count, or frame clock changed unexpectedly.")
        }
        for gap in gaps {
            guard output.clips.filter({ $0.kind == "gap" && $0.isPrimaryStoryline && $0.timelineRange == gap && !$0.hasAudio && !$0.hasVideo }).count == 1 else {
                throw EditedProjectWriterError.verificationFailed("a replacement gap is missing or has the wrong duration.")
            }
        }
        for segment in segments {
            let matches = output.clips.filter { $0.isPrimaryStoryline && $0.timelineRange == segment.resultProjectRange }
            guard matches.count == 1, let clip = matches.first,
                  clip.mediaURL == target.mediaURL, clip.assetID == target.assetID,
                  clip.sourceStart == segment.sourceRange.start, !clip.hasVideo,
                  clip.hasAudio, clip.dialogueRoles == target.dialogueRoles,
                  clip.effectsFingerprint == target.effectsFingerprint,
                  clip.audioFadeIn == (segment.sourceRange.start == target.sourceStart ? target.audioFadeIn : .zero),
                  clip.audioFadeOut == (segment.sourceRange.end == (try target.sourceStart.adding(target.timelineRange.duration)) ? target.audioFadeOut : .zero) else {
                throw EditedProjectWriterError.verificationFailed("a retained source segment or its audio effects changed unexpectedly.")
            }
        }
        for clip in original.clips where clip.id != target.id {
            let rootID = clip.id.split(separator: "/").prefix(2).joined(separator: "/")
            let parent = original.clips.first { $0.id == rootID }
            let shifts = (parent?.timelineRange.start ?? clip.timelineRange.start) >= target.timelineRange.end
            let start = shifts ? try clip.timelineRange.start.subtracting(removed) : clip.timelineRange.start
            let end = shifts ? try clip.timelineRange.end.subtracting(removed) : clip.timelineRange.end
            let matches = output.clips.filter { $0.timelineRange == TimeRange(start: start, end: end)
                && $0.kind == clip.kind && $0.sourceStart == clip.sourceStart && $0.mediaURL == clip.mediaURL
                && $0.lane == clip.lane && $0.isPrimaryStoryline == clip.isPrimaryStoryline }
            guard matches.contains(where: { $0.effectsFingerprint == clip.effectsFingerprint
                && $0.enabled == clip.enabled && $0.dialogueRoles == clip.dialogueRoles
                && $0.audioFadeIn == clip.audioFadeIn && $0.audioFadeOut == clip.audioFadeOut }) else {
                throw EditedProjectWriterError.verificationFailed("surrounding item \(clip.name) changed unexpectedly.")
            }
        }
    }

    private static func elementChildren(_ node: XMLElement) -> [XMLElement] {
        (node.children ?? []).compactMap { $0 as? XMLElement }
    }

    private static func descendants(_ node: XMLElement) -> [XMLElement] {
        elementChildren(node).flatMap { [$0] + descendants($0) }
    }

    private static func set(_ node: XMLElement, _ name: String, _ value: String) {
        if let attribute = node.attribute(forName: name) { attribute.stringValue = value }
        else { node.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode) }
    }

    private static func timeString(_ time: RationalTime) throws -> String {
        guard time.denominator <= Int64(Int32.max) else { throw RationalTimeError.arithmeticOverflow }
        return time.denominator == 1 ? "\(time.numerator)s" : "\(time.numerator)/\(time.denominator)s"
    }
}
