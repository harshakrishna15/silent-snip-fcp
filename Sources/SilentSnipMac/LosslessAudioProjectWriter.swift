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
        }
        var report = base.report
        report.losslessAudio = audio
        return EditedProjectOutput(xmlData: data, report: report)
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
