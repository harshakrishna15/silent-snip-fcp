import Foundation
import SilentSnipCore
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Apply the same project-time removals to direct connected assets. The base
/// writer owns the primary storyline; this layer preserves source-time DSP
/// curves while splitting and reattaching the connected retained intervals.
enum ConnectedProjectRipple {
    private struct Piece {
        let original: TimelineClip
        let source: TimeRange
        let result: TimeRange
    }

    static func write(projectData: Data, document: TimelineDocument, target: TimelineClip,
                      ranges: [TimeRange], replacementGaps: [TimeRange: RationalTime],
                      buildBase: (Data) throws -> EditedProjectOutput) throws -> EditedProjectOutput {
        let connections = document.clips.filter { !$0.isPrimaryStoryline }
        guard connections.allSatisfy(document.canRippleConnection) else {
            throw EditedProjectWriterError.unsupported("nested, compound, or retimed connections require additional timing support.")
        }
        let protected = try document.protectedRanges(for: target)
        guard !ranges.contains(where: { cut in protected.contains { $0.range.intersection(cut) != nil } }) else {
            throw EditedProjectWriterError.unsupported("a selected cut intersects connected dialogue or a protected fade.")
        }
        let xml = try XMLDocument(data: projectData, options: [.nodePreserveAll])
        guard let spine = try xml.nodes(forXPath: "//project/sequence/spine").first as? XMLElement else {
            throw EditedProjectWriterError.verificationFailed("missing primary storyline.")
        }
        var captured: [(TimelineClip, XMLElement)] = []
        for clip in connections {
            let path = clip.id.split(separator: "/").dropFirst().compactMap { Int($0) }
            let roots = children(spine)
            guard path.count == 2, roots.indices.contains(path[0]),
                  children(roots[path[0]]).indices.contains(path[1]) else {
                throw EditedProjectWriterError.verificationFailed("a connected occurrence is missing.")
            }
            let node = children(roots[path[0]])[path[1]]
            guard node.name == "asset-clip", clip.mediaURL != nil,
                  clip.timelineRange.start >= .zero, clip.timelineRange.end <= document.projectRange.end,
                  clip.unsupportedReasons.allSatisfy({
                      ["connected or nested targets are not supported", "the clip is disabled", "enabled source audio is required"].contains($0)
                  }) else {
                throw EditedProjectWriterError.unsupported("connected item \(clip.name) has unsupported source trims or timing.")
            }
            try EditedProjectWriter.validateTargetContents(node)
            captured.append((clip, node))
        }
        // Resolve every original path before detaching any sibling.
        for (_, node) in captured { node.detach() }
        xml.dtd = nil
        let base = try buildBase(xml.xmlData)
        let resultXML = try XMLDocument(data: base.xmlData, options: [.nodePreserveAll])
        let baseDocument = try TimelineParser.parse(data: base.xmlData)
        guard let resultSpine = try resultXML.nodes(forXPath: "//project/sequence/spine").first as? XMLElement else {
            throw EditedProjectWriterError.verificationFailed("missing cleaned storyline.")
        }
        let parents = baseDocument.clips.filter(\.isPrimaryStoryline)
        let parentNodes = children(resultSpine)
        var pieces: [Piece] = []
        for (clip, node) in captured {
            var cursor = clip.timelineRange.start
            var kept: [TimeRange] = []
            for cut in ranges {
                guard let overlap = clip.timelineRange.intersection(cut) else { continue }
                if cursor < overlap.start { kept.append(.init(start: cursor, end: overlap.start)) }
                cursor = max(cursor, overlap.end)
            }
            if cursor < clip.timelineRange.end { kept.append(.init(start: cursor, end: clip.timelineRange.end)) }
            for interval in kept {
                let start = try map(interval.start, cuts: ranges, gaps: replacementGaps)
                let duration = try interval.checkedDuration()
                let resultRange = TimeRange(start: start, end: try start.adding(duration))
                let sourceStart = try clip.sourceStart.adding(interval.start.subtracting(clip.timelineRange.start))
                let source = TimeRange(start: sourceStart, end: try sourceStart.adding(duration))
                guard let index = parents.firstIndex(where: {
                    $0.timelineRange.contains(start) && ($0.enabled || !clip.enabled)
                }) ?? parents.firstIndex(where: {
                    $0.timelineRange.intersection(resultRange) != nil && ($0.enabled || !clip.enabled)
                }), parentNodes.indices.contains(index) else {
                    throw EditedProjectWriterError.unsupported("a connected segment has no compatible surviving attachment.")
                }
                let parent = parents[index]
                let copy = node.copy() as! XMLElement
                try set(copy, "offset", try parent.sourceStart.adding(start.subtracting(parent.timelineRange.start)))
                try set(copy, "start", source.start)
                try set(copy, "duration", duration)
                if !clip.enabled { set(copy, "enabled", "0") }
                if copy.attribute(forName: "audioStart") != nil { try set(copy, "audioStart", source.start) }
                if copy.attribute(forName: "audioDuration") != nil { try set(copy, "audioDuration", duration) }
                for element in descendants(copy) {
                    if element.name == "fadeIn", source.start != clip.sourceStart { element.detach() }
                    if element.name == "fadeOut", source.end != (try clip.sourceStart.adding(clip.timelineRange.checkedDuration())) { element.detach() }
                }
                try EditedProjectWriter.trimAnnotations(copy, to: source, original: clip)
                let parentNode = parentNodes[index]
                // FCPXML places anchored items before markers, channels, filters
                // and metadata. Preserve each parent's existing element order.
                let following = Set(["marker", "chapter-marker", "keyword", "rating", "analysis-marker", "audio-channel-source", "filter-video", "filter-video-mask", "filter-audio", "metadata"])
                let insertion = parentNode.children?.firstIndex(where: { following.contains($0.name ?? "") }) ?? parentNode.childCount
                parentNode.insertChild(copy, at: insertion)
                pieces.append(.init(original: clip, source: source, result: resultRange))
            }
        }
        for (index, piece) in pieces.enumerated() {
            guard !pieces.dropFirst(index + 1).contains(where: {
                $0.original.id != piece.original.id && $0.original.lane == piece.original.lane && $0.result.intersection(piece.result) != nil
            }) else {
                throw EditedProjectWriterError.unsupported("overlapping connected lanes need an explicit stacking policy.")
            }
        }
        resultXML.isStandalone = false
        let data = resultXML.xmlData(options: [.nodePrettyPrint])
        let actual = try TimelineParser.parse(data: data)
        let actualConnections = actual.clips.filter { !$0.isPrimaryStoryline }
        guard actualConnections.count == pieces.count else {
            throw EditedProjectWriterError.verificationFailed("the connected segment count changed.")
        }
        var remaining = actualConnections
        for piece in pieces {
            let original = piece.original
            guard let index = remaining.firstIndex(where: {
                $0.timelineRange == piece.result && $0.sourceStart == piece.source.start &&
                $0.mediaURL == original.mediaURL && $0.assetID == original.assetID &&
                $0.lane == original.lane && $0.enabled == original.enabled &&
                $0.hasAudio == original.hasAudio && $0.hasVideo == original.hasVideo &&
                $0.dialogueRoles == original.dialogueRoles && $0.effectsFingerprint == original.effectsFingerprint &&
                $0.audioFadeIn == (piece.source.start == original.sourceStart ? original.audioFadeIn : .zero) &&
                $0.audioFadeOut == (piece.source.end == original.sourceStart + original.timelineRange.duration ? original.audioFadeOut : .zero)
            }) else {
                throw EditedProjectWriterError.verificationFailed("connected source, timing, or effects changed for \(original.name).")
            }
            remaining.remove(at: index)
        }
        let report = base.report
        return EditedProjectOutput(xmlData: data, report: .init(originalProjectName: report.originalProjectName,
            originalProjectUID: report.originalProjectUID, baselineFingerprint: document.fingerprint,
            projectName: report.projectName, projectUID: report.projectUID, eventUID: report.eventUID,
            replacementTarget: report.replacementTarget, targetID: report.targetID,
            originalProjectDuration: report.originalProjectDuration, resultProjectDuration: report.resultProjectDuration,
            removedDuration: report.removedDuration, insertedGapDuration: report.insertedGapDuration,
            selectedRanges: report.selectedRanges, retainedSegments: report.retainedSegments,
            removedPointMarkerCount: report.removedPointMarkerCount))
    }

    private static func map(_ time: RationalTime, cuts: [TimeRange], gaps: [TimeRange: RationalTime]) throws -> RationalTime {
        try cuts.filter { $0.end <= time }.reduce(time) { value, cut in
            try value.subtracting(cut.checkedDuration()).adding(gaps[cut] ?? .zero)
        }
    }
    private static func children(_ node: XMLElement) -> [XMLElement] { (node.children ?? []).compactMap { $0 as? XMLElement } }
    private static func descendants(_ node: XMLElement) -> [XMLElement] { children(node).flatMap { [$0] + descendants($0) } }
    private static func set(_ node: XMLElement, _ name: String, _ value: RationalTime) throws {
        guard value.denominator <= Int64(Int32.max) else { throw RationalTimeError.arithmeticOverflow }
        set(node, name, value.denominator == 1 ? "\(value.numerator)s" : "\(value.numerator)/\(value.denominator)s")
    }
    private static func set(_ node: XMLElement, _ name: String, _ value: String) {
        if let attribute = node.attribute(forName: name) { attribute.stringValue = value }
        else { node.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode) }
    }
}
