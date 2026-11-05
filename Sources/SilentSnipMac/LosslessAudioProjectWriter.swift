import Foundation
import SilentSnipCore
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Substitutes fresh, durable native PCM after the ordinary editable cut/ripple
/// writer has verified its result. No source bytes or original project change.
/// A project mix replaces every audible original instance, including connected
/// music/effects, so stateful processing is not restarted at the retained joins.
enum LosslessAudioProjectWriter {
    private struct Mapping {
        let original: TimeRange
        let result: TimeRange
    }
    private struct PrimaryAudioPiece {
        let range: TimeRange
        let sourceStart: RationalTime
        let node: XMLElement
    }
    private struct VideoEvidence: Equatable {
        let range: TimeRange
        let sourceStart: RationalTime
        let mediaURL: URL?
        let assetID: String?
        let lane: Int
        let enabled: Bool
        let processing: [String]
    }
    private struct SourceStreams {
        var video: Set<String> = []
        var audio: Set<String> = []
        var channels: [String: Int] = [:]
        init(resources: XMLElement) {
            for asset in resources.elements(forName: "asset") {
                guard let id = asset.attribute(forName: "id")?.stringValue else { continue }
                if asset.attribute(forName: "hasVideo")?.stringValue == "1" { video.insert(id) }
                if asset.attribute(forName: "hasAudio")?.stringValue == "1" { audio.insert(id) }
                if let value = asset.attribute(forName: "audioChannels")?.stringValue,
                   let count = Int(value), (1...1024).contains(count) { channels[id] = count }
            }
        }
    }
    private static let audioNodes: Set<String> = [
        "filter-audio", "audio-channel-source", "audio-role-source",
        "adjust-volume", "adjust-panner", "adjust-loudness", "adjust-noiseReduction",
        "adjust-humReduction", "adjust-EQ", "adjust-matchEQ", "adjust-voiceIsolation"
    ]
    private static let annotations: Set<String> = ["marker", "chapter-marker", "keyword", "rating", "analysis-marker"]
    private static let anchors: Set<String> = ["asset-clip", "clip", "ref-clip", "mc-clip", "sync-clip", "audio", "video", "gap", "title", "caption", "audition", "spine", "live-drawing"]

    static func replacing(_ base: EditedProjectOutput, originalData: Data,
                          selection: TimelineSelection, audio: LosslessRenderedAudio,
                          replacementGaps: [TimeRange: RationalTime],
                          selectedClipOnly: Bool) throws -> EditedProjectOutput {
        try audio.validate()
        let original = try TimelineParser.parse(data: originalData)
        let target = try original.selectedTarget(selection, requireExistingMedia: false)
        let before = try TimelineParser.parse(data: base.xmlData)
        let xml = try XMLDocument(data: base.xmlData, options: [.nodePreserveAll])
        guard let root = xml.rootElement(), let resources = root.elements(forName: "resources").first,
              let sequence = try root.nodes(forXPath: ".//project/sequence").first as? XMLElement,
              let spine = sequence.elements(forName: "spine").first else {
            throw EditedProjectWriterError.verificationFailed("processed audio has no output storyline")
        }
        let rates: [Int64: String] = [32_000: "32k", 44_100: "44.1k", 48_000: "48k",
            88_200: "88.2k", 96_000: "96k", 176_400: "176.4k", 192_000: "192k"]
        guard let rate = rates[audio.sampleRate], [1, 2].contains(audio.channelCount) else {
            throw EditedProjectWriterError.unsupported("the native PCM channel count or sample rate has no verified project representation")
        }
        if audio.scope == .projectMix {
            guard audio.timelineRange == original.projectRange, !selectedClipOnly, audio.channelCount == 2 else {
                throw EditedProjectWriterError.unsupported("a complete native project mix is required for full-project sound preservation")
            }
            // The mix has already passed through Final Cut's original routing.
            // Render it at that exact PCM rate/layout rather than downmixing or
            // resampling it again through the source project's output format.
            set(sequence, "audioLayout", "stereo")
            set(sequence, "audioRate", rate)
        } else {
            _ = try audio.sourceRange(for: target.timelineRange)
        }
        let wantedVideo = try videoEvidence(before, spine: spine)
        let sourceStreams = SourceStreams(resources: resources)
        // An audio-only project has no picture edit to keep in the primary
        // storyline. Its continuous retained PCM should be the primary edit,
        // rather than connected sound underneath otherwise empty gap anchors.
        let primaryMix = audio.scope == .projectMix && !before.clips.contains(where: \.hasVideo)
        let assetID = "silentsnip-processed-" + UUID().uuidString
        let asset = XMLElement(name: "asset")
        for (key, value) in ["id": assetID, "name": "Original sound", "start": "0s",
                             "duration": try time(RationalTime(audio.frameCount, audio.sampleRate)),
                             "hasAudio": "1", "audioSources": "1",
                             "audioChannels": String(audio.channelCount), "audioRate": String(audio.sampleRate)] {
            set(asset, key, value)
        }
        let representation = XMLElement(name: "media-rep")
        set(representation, "kind", "original-media")
        set(representation, "src", audio.url.absoluteString)
        asset.addChild(representation)
        resources.addChild(asset)

        var expectedAudio: [(range: TimeRange, source: TimeRange)] = []
        if audio.scope == .projectMix {
            let mappings = try projectMappings(original.projectRange,
                cuts: base.report.selectedRanges, gaps: replacementGaps)
            if primaryMix {
                expectedAudio = try replaceAudioOnlyPrimary(spine: spine, document: before,
                    mappings: mappings, assetID: assetID, audio: audio, sources: sourceStreams)
            } else {
                // Resolve source nodes before changing paths or adding new children.
                let roots = children(spine)
                let primary = before.clips.filter(\.isPrimaryStoryline)
                guard primary.count == roots.count else {
                    throw EditedProjectWriterError.verificationFailed("processed mix primary items are ambiguous")
                }
                var parents: [(clip: TimelineClip, node: XMLElement)] = []
                for (clip, oldNode) in zip(primary, roots) {
                    let parent: XMLElement
                    if clip.hasVideo && clip.enabled {
                        parent = oldNode
                        try muteOriginalTree(parent, sources: sourceStreams)
                    } else if clip.kind == "gap" && clip.enabled {
                        parent = oldNode
                        try muteOriginalTree(parent, sources: sourceStreams)
                    } else {
                        // Audio-only originals cannot become video-only assets.
                        // An enabled gap provides a neutral anchor for the native
                        // mix. A previously disabled video's complete node remains
                        // disabled inside it, preserving its invisible source edit.
                        parent = try gap(replacing: oldNode, clip: clip, sources: sourceStreams)
                        let index = oldNode.index
                        oldNode.detach()
                        spine.insertChild(parent, at: index)
                    }
                    parents.append((clip, parent))
                }
                // Visual frame boundaries need not fall on audio samples (29.97
                // fps is a common example). Keep each continuous retained mix span
                // intact and anchor it once, allowing normal connected audio to
                // extend across subsequent primary clips. Only reviewed cut-grid
                // boundaries may split the native PCM.
                for mapping in mappings {
                    let resultFrame = try mapping.result.start.multiplied(by: RationalTime(audio.sampleRate))
                    guard resultFrame.denominator == 1 else {
                        throw EditedProjectWriterError.unsupported("the pacing gap places preserved sound between native PCM samples; no resampling or shifted audio was generated")
                    }
                    guard let parent = parents.first(where: { $0.clip.timelineRange.contains(mapping.result.start) }) else {
                        throw EditedProjectWriterError.verificationFailed("the retained native mix has no surviving primary attachment")
                    }
                    let source = try audio.sourceRange(for: mapping.original)
                    let offset = try nodeTime(parent.node, "start")
                        .adding(mapping.result.start.subtracting(parent.clip.timelineRange.start))
                    let physicalRange = TimeRange(start: mapping.result.start,
                        end: try mapping.result.start.adding(source.checkedDuration()))
                    try attachAudio(to: parent.node, assetID: assetID, offset: offset,
                                    source: source, role: "dialogue")
                    expectedAudio.append((physicalRange, source))
                }
            }
        } else {
            for segment in base.report.retainedSegments {
                let candidates = before.clips.filter {
                    $0.isPrimaryStoryline && $0.timelineRange == segment.resultProjectRange
                        && $0.mediaURL == target.mediaURL && $0.sourceStart == segment.sourceRange.start
                }
                guard candidates.count == 1, let clip = candidates.first,
                      let node = node(at: clip.id, spine: spine) else {
                    throw EditedProjectWriterError.verificationFailed("a retained processed-audio segment is ambiguous")
                }
                let source = try audio.sourceRange(for: segment.originalProjectRange)
                if clip.hasVideo {
                    try muteOriginalTree(node, sources: sourceStreams, recursive: false)
                    try attachAudio(to: node, assetID: assetID, offset: clip.sourceStart,
                                    source: source, role: target.dialogueRoles.first ?? "dialogue")
                } else {
                    let delta = try source.start.subtracting(clip.sourceStart)
                    for child in children(node) where anchors.contains(child.name ?? "") {
                        try set(child, "offset", try nodeTime(child, "offset").adding(delta))
                    }
                    try translateAnnotations(node, by: delta)
                    for child in children(node) where !anchors.contains(child.name ?? "")
                        && !annotations.contains(child.name ?? "") && !["note", "metadata"].contains(child.name ?? "") {
                        child.detach()
                    }
                    set(node, "ref", assetID)
                    node.removeAttribute(forName: "srcEnable") // The PCM asset has no video stream.
                    set(node, "audioRole", target.dialogueRoles.first ?? "dialogue")
                    try set(node, "start", source.start)
                    if node.attribute(forName: "audioStart") != nil { try set(node, "audioStart", source.start) }
                    if node.attribute(forName: "audioDuration") != nil { try set(node, "audioDuration", source.checkedDuration()) }
                }
                expectedAudio.append((segment.resultProjectRange, source))
            }
        }
        xml.isStandalone = false
        let data = xml.xmlData(options: [.nodePrettyPrint])
        let after = try TimelineParser.parse(data: data)
        guard after.projectRange == before.projectRange, after.frameDuration == before.frameDuration,
              after.projectTimecodeStart == before.projectTimecodeStart,
              let afterSpine = try XMLDocument(data: data).nodes(forXPath: "//project/sequence/spine").first as? XMLElement else {
            throw EditedProjectWriterError.verificationFailed("processed replacement changed the project clock or duration")
        }
        var actualVideo = try videoEvidence(after, spine: afterSpine)
        for expected in wantedVideo {
            guard let index = actualVideo.firstIndex(of: expected) else {
                throw EditedProjectWriterError.verificationFailed("processed replacement changed an original video source, timing, visibility, or effect")
            }
            actualVideo.remove(at: index)
        }
        guard actualVideo.isEmpty else {
            throw EditedProjectWriterError.verificationFailed("processed replacement introduced extra video")
        }
        var rendered = after.clips.filter { $0.assetID == assetID }
        guard rendered.count == expectedAudio.count else {
            throw EditedProjectWriterError.verificationFailed("processed replacement has the wrong rendered audio count")
        }
        for expected in expectedAudio {
            guard let index = rendered.firstIndex(where: {
                $0.timelineRange == expected.range && $0.sourceStart == expected.source.start
                    && $0.hasAudio && !$0.hasVideo && $0.enabled && $0.mediaURL == audio.url
                    && $0.audioFadeIn == .zero && $0.audioFadeOut == .zero
                    && (!primaryMix || ($0.isPrimaryStoryline && $0.parentID == nil && $0.lane == 0))
            }), let renderedNode = node(at: rendered[index].id, spine: afterSpine),
                  !children(renderedNode).contains(where: { audioNodes.contains($0.name ?? "") }) else {
                throw EditedProjectWriterError.verificationFailed("processed replacement changed PCM source mapping or applied additional processing")
            }
            rendered.remove(at: index)
        }
        if audio.scope == .projectMix {
            let mappedDuration = try expectedAudio.reduce(RationalTime.zero) {
                try $0.adding($1.range.checkedDuration())
            }
            guard mappedDuration == (try RationalTime(audio.frameCount, audio.sampleRate).subtracting(base.report.removedDuration)) else {
                throw EditedProjectWriterError.verificationFailed("the processed mix does not cover every retained project sample")
            }
            guard after.clips.filter({ $0.enabled && $0.hasAudio }).allSatisfy({ $0.assetID == assetID }) else {
                throw EditedProjectWriterError.verificationFailed("original audio would play alongside the processed project mix")
            }
            if primaryMix { try verifyAudioOnlyContext(before: before, after: after) }
        }
        var report = base.report
        report.losslessAudio = audio
        return EditedProjectOutput(xmlData: data, report: report)
    }

    private static func replaceAudioOnlyPrimary(spine: XMLElement, document: TimelineDocument,
                                                mappings: [Mapping], assetID: String,
                                                audio: LosslessRenderedAudio, sources: SourceStreams) throws
        -> [(range: TimeRange, source: TimeRange)] {
        let roots = children(spine)
        let primary = document.clips.filter(\.isPrimaryStoryline)
        guard roots.count == primary.count else {
            throw EditedProjectWriterError.verificationFailed("processed mix primary items are ambiguous")
        }
        var pieces: [PrimaryAudioPiece] = []
        var expected: [(range: TimeRange, source: TimeRange)] = []
        var cursor = document.projectRange.start
        func appendGap(until end: RationalTime) throws {
            guard end >= cursor else {
                throw EditedProjectWriterError.verificationFailed("processed primary sound overlaps another retained interval")
            }
            guard end > cursor else { return }
            let node = XMLElement(name: "gap")
            set(node, "name", "Gap")
            try set(node, "offset", cursor.adding(document.projectTimecodeStart))
            try set(node, "start", RationalTime(3600))
            try set(node, "duration", end.subtracting(cursor))
            pieces.append(.init(range: .init(start: cursor, end: end), sourceStart: RationalTime(3600), node: node))
            cursor = end
        }
        for mapping in mappings {
            let resultFrame = try mapping.result.start.multiplied(by: RationalTime(audio.sampleRate))
            guard resultFrame.denominator == 1 else {
                throw EditedProjectWriterError.unsupported("the pacing gap places preserved sound between native PCM samples; no resampling or shifted audio was generated")
            }
            try appendGap(until: mapping.result.start)
            let source = try audio.sourceRange(for: mapping.original)
            let end = try mapping.result.start.adding(source.checkedDuration())
            guard end <= mapping.result.end else {
                throw EditedProjectWriterError.verificationFailed("processed primary sound exceeds its retained project interval")
            }
            let node = XMLElement(name: "asset-clip")
            set(node, "name", "Original sound")
            set(node, "ref", assetID)
            set(node, "audioRole", "dialogue")
            try set(node, "offset", mapping.result.start.adding(document.projectTimecodeStart))
            try set(node, "start", source.start)
            try set(node, "duration", source.checkedDuration())
            let physicalRange = TimeRange(start: mapping.result.start, end: end)
            pieces.append(.init(range: physicalRange, sourceStart: source.start, node: node))
            expected.append((physicalRange, source))
            cursor = end
        }
        // The native WAV can end less than one sample before a fractional
        // project tail. Keep that exact logical remainder as a gap, without
        // extending, rounding, or resampling the preserved sound.
        try appendGap(until: document.projectRange.end)
        guard !pieces.isEmpty else {
            throw EditedProjectWriterError.verificationFailed("processed primary sound has no retained samples")
        }
        func owner(at position: RationalTime) throws -> Int {
            if let index = pieces.firstIndex(where: { $0.range.contains(position) }) { return index }
            if position == document.projectRange.end { return pieces.count - 1 }
            throw EditedProjectWriterError.unsupported("an existing annotation or connection lies outside the cleaned project")
        }
        let connections = document.clips.filter { !$0.isPrimaryStoryline }
        for clip in connections {
            guard primary.contains(where: { $0.id == clip.parentID }), clip.kind == "asset-clip", clip.lane != 0,
                  let original = node(at: clip.id, spine: spine),
                  !children(original).contains(where: { anchors.contains($0.name ?? "") }) else {
                throw EditedProjectWriterError.unsupported("nested connected items cannot be moved onto primary processed sound safely")
            }
            let index = try owner(at: clip.timelineRange.start)
            let parent = pieces[index]
            let copy = original.copy() as! XMLElement
            try set(copy, "offset", parent.sourceStart.adding(clip.timelineRange.start.subtracting(parent.range.start)))
            if !clip.enabled { set(copy, "enabled", "0") }
            try muteOriginalTree(copy, sources: sources)
            parent.node.addChild(copy)
        }
        for (index, clip) in connections.enumerated() {
            guard !connections.dropFirst(index + 1).contains(where: {
                $0.lane == clip.lane && $0.timelineRange.intersection(clip.timelineRange) != nil
            }) else {
                throw EditedProjectWriterError.unsupported("overlapping connected lanes cannot be merged onto primary processed sound safely")
            }
        }
        var notes: [Int: [String]] = [:]
        var metadata: [Int: [XMLElement]] = [:]
        var metadataKeys: [Int: [String: String]] = [:]
        for (clip, root) in zip(primary, roots) {
            let index = try owner(at: clip.timelineRange.start)
            for child in children(root) {
                let name = child.name ?? ""
                if name == "note" {
                    notes[index, default: []].append(child.stringValue ?? "")
                } else if name == "metadata" {
                    for item in children(child) {
                        guard item.name == "md", let key = item.attribute(forName: "key")?.stringValue, !key.isEmpty else {
                            throw EditedProjectWriterError.unsupported("existing clip metadata cannot be merged without a unique metadata key")
                        }
                        let signature = canonicalMetadata(item)
                        if let old = metadataKeys[index]?[key] {
                            guard old == signature else {
                                throw EditedProjectWriterError.unsupported("existing clips have incompatible metadata for key ‘\(key)’; their metadata was not discarded")
                            }
                            continue
                        }
                        metadataKeys[index, default: [:]][key] = signature
                        metadata[index, default: []].append(item.copy() as! XMLElement)
                    }
                } else if annotations.contains(name) {
                    let sourceStart: RationalTime
                    if child.attribute(forName: "start") == nil { sourceStart = clip.sourceStart }
                    else { sourceStart = try nodeTime(child, "start") }
                    let position = try clip.timelineRange.start.adding(sourceStart.subtracting(clip.sourceStart))
                    if ["marker", "chapter-marker"].contains(name) {
                        let destination = try owner(at: position)
                        let parent = pieces[destination]
                        let copy = child.copy() as! XMLElement
                        try set(copy, "start", parent.sourceStart.adding(position.subtracting(parent.range.start)))
                        parent.node.addChild(copy)
                    } else {
                        let duration: RationalTime
                        if child.attribute(forName: "duration") == nil {
                            duration = try clip.timelineRange.end.subtracting(position)
                        } else { duration = try nodeTime(child, "duration") }
                        guard duration >= .zero else {
                            throw EditedProjectWriterError.unsupported("an existing annotation has invalid timing")
                        }
                        let annotation = TimeRange(start: position, end: try position.adding(duration))
                        guard annotation.start >= document.projectRange.start, annotation.end <= document.projectRange.end else {
                            throw EditedProjectWriterError.unsupported("an existing annotation extends outside the cleaned project")
                        }
                        if duration == .zero {
                            let parent = pieces[try owner(at: position)]
                            let copy = child.copy() as! XMLElement
                            try set(copy, "start", parent.sourceStart.adding(position.subtracting(parent.range.start)))
                            try set(copy, "duration", .zero)
                            parent.node.addChild(copy)
                            continue
                        }
                        for parent in pieces {
                            guard let kept = parent.range.intersection(annotation) else { continue }
                            let copy = child.copy() as! XMLElement
                            try set(copy, "start", parent.sourceStart.adding(kept.start.subtracting(parent.range.start)))
                            try set(copy, "duration", kept.checkedDuration())
                            parent.node.addChild(copy)
                        }
                    }
                } else if anchors.contains(name) || audioNodes.contains(name)
                    || name.hasPrefix("adjust-") || name.hasPrefix("filter-")
                    || ["conform-rate", "timeMap"].contains(name) {
                    // Connections were copied above. Original processing and
                    // timing are already baked into the continuous native mix.
                    continue
                } else {
                    throw EditedProjectWriterError.unsupported("the audio-only primary item contains \(name), whose clip semantics cannot be preserved when combining the rendered sound")
                }
            }
        }
        for (index, piece) in pieces.enumerated() {
            let content = children(piece.node)
            var connected: [(node: XMLElement, lane: Int, offset: RationalTime)] = []
            var markers: [(node: XMLElement, start: RationalTime, order: Int)] = []
            for (order, child) in content.enumerated() {
                if anchors.contains(child.name ?? "") {
                    guard let lane = Int(child.attribute(forName: "lane")?.stringValue ?? "0") else {
                        throw EditedProjectWriterError.verificationFailed("an existing connection has an invalid lane")
                    }
                    connected.append((child, lane, try nodeTime(child, "offset")))
                } else if annotations.contains(child.name ?? "") {
                    markers.append((child, try nodeTime(child, "start"), order))
                }
            }
            connected.sort {
                if $0.lane != $1.lane { return $0.lane < $1.lane }
                return $0.offset < $1.offset
            }
            markers.sort {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.order < $1.order
            }
            piece.node.setChildren([])
            if let values = notes[index] {
                piece.node.addChild(XMLElement(name: "note", stringValue: values.joined(separator: "\n\n")))
            }
            for entry in connected { piece.node.addChild(entry.node) }
            for entry in markers { piece.node.addChild(entry.node) }
            if let values = metadata[index], !values.isEmpty {
                let node = XMLElement(name: "metadata")
                for value in values { node.addChild(value) }
                piece.node.addChild(node)
            }
        }
        spine.setChildren(pieces.map(\.node))
        return expected
    }

    private static func verifyAudioOnlyContext(before: TimelineDocument, after: TimelineDocument) throws {
        var returned = after.clips.filter { !$0.isPrimaryStoryline }
        let connections = before.clips.filter { !$0.isPrimaryStoryline }
        guard returned.count == connections.count else {
            throw EditedProjectWriterError.verificationFailed("primary processed sound changed the connected occurrence count")
        }
        for clip in connections {
            guard let index = returned.firstIndex(where: {
                $0.name == clip.name && $0.timelineRange == clip.timelineRange && $0.sourceStart == clip.sourceStart
                    && $0.mediaURL == clip.mediaURL && $0.assetID == clip.assetID && $0.lane == clip.lane
                    && !$0.hasVideo && !$0.hasAudio && !$0.enabled
            }) else {
                throw EditedProjectWriterError.verificationFailed("primary processed sound changed an original connected source or its timing")
            }
            returned.remove(at: index)
        }
        var markers = after.markers
        for marker in before.markers {
            guard let index = markers.firstIndex(where: {
                $0.timelinePosition == marker.timelinePosition && $0.kind == marker.kind && $0.value == marker.value
                    && $0.note == marker.note && $0.duration == marker.duration && $0.completed == marker.completed
            }) else {
                throw EditedProjectWriterError.verificationFailed("primary processed sound changed an original marker")
            }
            markers.remove(at: index)
        }
        guard markers.isEmpty else {
            throw EditedProjectWriterError.verificationFailed("primary processed sound introduced an extra marker")
        }
    }

    private static func canonicalMetadata(_ node: XMLElement) -> String {
        let attributes = (node.attributes ?? []).sorted { ($0.name ?? "") < ($1.name ?? "") }
            .map { ($0.name ?? "") + "=" + ($0.stringValue ?? "") }
        let elements = children(node)
        let text = (node.children ?? []).filter { $0.kind == .text }.compactMap(\.stringValue).joined()
        let payload = elements.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : ""
        let parts = [node.name ?? ""] + attributes + [payload] + elements.map(canonicalMetadata)
        return parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    private static func projectMappings(_ project: TimeRange, cuts: [TimeRange],
                                        gaps: [TimeRange: RationalTime]) throws -> [Mapping] {
        var original = project.start, result = project.start
        var mappings: [Mapping] = []
        for cut in cuts + [.init(start: project.end, end: project.end)] {
            if original < cut.start {
                let length = try cut.start.subtracting(original)
                mappings.append(.init(original: .init(start: original, end: cut.start),
                    result: .init(start: result, end: try result.adding(length))))
                result = try result.adding(length)
            }
            result = try result.adding(gaps[cut] ?? .zero)
            original = cut.end
        }
        return mappings
    }

    private static func gap(replacing original: XMLElement, clip: TimelineClip,
                            sources: SourceStreams) throws -> XMLElement {
        let gap = XMLElement(name: "gap")
        set(gap, "name", original.attribute(forName: "name")?.stringValue ?? "Original sound")
        set(gap, "offset", original.attribute(forName: "offset")?.stringValue ?? "0s")
        try set(gap, "start", RationalTime(3600))
        try set(gap, "duration", clip.timelineRange.checkedDuration())
        if clip.hasVideo {
            let retained = original.copy() as! XMLElement
            set(retained, "lane", "1")
            try set(retained, "offset", RationalTime(3600))
            try muteOriginalTree(retained, sources: sources)
            set(retained, "enabled", "0")
            gap.addChild(retained)
        } else {
            let delta = try RationalTime(3600).subtracting(clip.sourceStart)
            for child in children(original) where anchors.contains(child.name ?? "")
                || annotations.contains(child.name ?? "") || ["note", "metadata"].contains(child.name ?? "") {
                let copy = child.copy() as! XMLElement
                if anchors.contains(copy.name ?? "") {
                    try set(copy, "offset", try nodeTime(copy, "offset").adding(delta))
                    try muteOriginalTree(copy, sources: sources)
                    if !clip.enabled { set(copy, "enabled", "0") }
                } else if annotations.contains(copy.name ?? ""), copy.attribute(forName: "start") != nil {
                    try set(copy, "start", try nodeTime(copy, "start").adding(delta))
                }
                gap.addChild(copy)
            }
        }
        return gap
    }

    private static func muteOriginalTree(_ node: XMLElement, sources: SourceStreams, recursive: Bool = true) throws {
        if recursive {
            for child in children(node) where anchors.contains(child.name ?? "") {
                try muteOriginalTree(child, sources: sources)
            }
        }
        for child in children(node) where audioNodes.contains(child.name ?? "") { child.detach() }
        if node.name == "asset-clip" {
            // Keep the video stream where present. Audio-only connections are
            // retained as disabled raw-source references for inspection.
            let ref = node.attribute(forName: "ref")?.stringValue ?? ""
            if sources.video.contains(ref),
               node.attribute(forName: "srcEnable")?.stringValue != "audio" {
                // Final Cut 12.4 can omit srcEnable="video" on import. Disable
                // EVERY actual source channel explicitly instead; this native
                // channel state must survive the imported-project verification.
                node.removeAttribute(forName: "srcEnable")
                if sources.audio.contains(ref) {
                    guard let count = sources.channels[ref] else {
                        throw EditedProjectWriterError.unsupported("the source camera's complete audio channel count is unavailable; its audio was not assumed muted")
                    }
                    for channel in 1...count {
                        let component = XMLElement(name: "audio-channel-source")
                        set(component, "srcCh", String(channel))
                        set(component, "enabled", "0")
                        set(component, "role", node.attribute(forName: "audioRole")?.stringValue ?? "dialogue")
                        let following: Set<String> = ["filter-video", "filter-video-mask", "filter-audio", "metadata"]
                        let index = node.children?.firstIndex(where: { following.contains($0.name ?? "") }) ?? node.childCount
                        node.insertChild(component, at: index)
                    }
                }
            } else {
                set(node, "enabled", "0")
                if !sources.video.contains(ref) { node.removeAttribute(forName: "srcEnable") }
            }
        }
    }

    private static func attachAudio(to parent: XMLElement, assetID: String,
                                    offset: RationalTime, source: TimeRange, role: String) throws {
        let audio = XMLElement(name: "asset-clip")
        set(audio, "name", "Original sound")
        set(audio, "ref", assetID)
        let lanes = children(parent).compactMap { Int($0.attribute(forName: "lane")?.stringValue ?? "") }
        let minimum = min(lanes.min() ?? 0, 0)
        guard minimum > Int.min else { throw EditedProjectWriterError.verificationFailed("connected audio lane overflow") }
        let lane = minimum - 1
        set(audio, "lane", String(lane))
        try set(audio, "offset", offset)
        try set(audio, "start", source.start)
        try set(audio, "duration", source.checkedDuration())
        set(audio, "audioRole", role)
        let following = annotations.union(["audio-channel-source", "audio-role-source", "filter-video", "filter-video-mask", "filter-audio", "metadata"])
        // Final Cut serializes independent connected children in lane order.
        // Emit that order directly so strict native round trips need no broad
        // normalization of story elements whose stacking can affect video.
        let index = parent.children?.firstIndex(where: { child in
            if following.contains(child.name ?? "") { return true }
            guard let element = child as? XMLElement, anchors.contains(element.name ?? ""),
                  let otherLane = Int(element.attribute(forName: "lane")?.stringValue ?? "0") else { return false }
            return otherLane > lane
        }) ?? parent.childCount
        parent.insertChild(audio, at: index)
    }

    private static func videoEvidence(_ document: TimelineDocument, spine: XMLElement) throws -> [VideoEvidence] {
        try document.clips.filter(\.hasVideo).map { clip in
            guard let node = node(at: clip.id, spine: spine) else {
                throw EditedProjectWriterError.verificationFailed("video occurrence is missing")
            }
            let processing = children(node).filter {
                ($0.name?.hasPrefix("filter-video") == true || $0.name?.hasPrefix("adjust-") == true)
                    && !audioNodes.contains($0.name ?? "")
            }.map(canonicalVideoProcessing)
            return .init(range: clip.timelineRange, sourceStart: clip.sourceStart,
                mediaURL: clip.mediaURL, assetID: clip.assetID, lane: clip.enabled ? clip.lane : 0,
                enabled: clip.enabled, processing: processing)
        }
    }
    /// Compare structure, attributes and actual payload text. Foundation's
    /// preserve-empty-element option changes `<adjust-transform/>` spelling
    /// after a normal reparse; that serialization detail is not an effect edit.
    /// No rendering attribute, keyframe, resource reference or nonwhite data is
    /// excluded from this check.
    private static func canonicalVideoProcessing(_ node: XMLElement) -> String {
        var parts = [node.name ?? ""]
        for attribute in (node.attributes ?? []).sorted(by: { ($0.name ?? "") < ($1.name ?? "") }) {
            let key = attribute.name ?? "", value = attribute.stringValue ?? ""
            parts.append("\(key.utf8.count):\(key)=\(value.utf8.count):\(value)")
        }
        let text = (node.children ?? []).filter { $0.kind == .text }.compactMap(\.stringValue).joined()
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("text=\(text.utf8.count):\(text)")
        }
        parts.append(contentsOf: children(node).map(canonicalVideoProcessing))
        return parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
    private static func translateAnnotations(_ node: XMLElement, by delta: RationalTime) throws {
        for child in children(node) where annotations.contains(child.name ?? "") && child.attribute(forName: "start") != nil {
            try set(child, "start", try nodeTime(child, "start").adding(delta))
        }
    }
    private static func node(at path: String, spine: XMLElement) -> XMLElement? {
        let parts = path.split(separator: "/")
        guard parts.first == "spine" else { return nil }
        var current = spine
        for part in parts.dropFirst() {
            guard let index = Int(part), children(current).indices.contains(index) else { return nil }
            current = children(current)[index]
        }
        return current
    }
    private static func children(_ node: XMLElement) -> [XMLElement] { (node.children ?? []).compactMap { $0 as? XMLElement } }
    private static func nodeTime(_ node: XMLElement, _ key: String) throws -> RationalTime {
        try RationalTime.parse(node.attribute(forName: key)?.stringValue ?? "0s")
    }
    private static func time(_ value: RationalTime) throws -> String {
        guard value.denominator <= Int64(Int32.max) else { throw RationalTimeError.arithmeticOverflow }
        return value.denominator == 1 ? "\(value.numerator)s" : "\(value.numerator)/\(value.denominator)s"
    }
    private static func set(_ node: XMLElement, _ key: String, _ value: RationalTime) throws { set(node, key, try time(value)) }
    private static func set(_ node: XMLElement, _ key: String, _ value: String) {
        if let attribute = node.attribute(forName: key) { attribute.stringValue = value }
        else { node.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode) }
    }
}
