import Foundation
import CryptoKit
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum TimelineParser {
    public static func parse(url: URL, exclusions: TimelineFingerprintExclusions = .init()) throws -> TimelineDocument {
        let xmlURL = url.pathExtension.lowercased() == "fcpxmld" ? url.appendingPathComponent("Info.fcpxml") : url
        return try parse(data: Data(contentsOf: xmlURL), exclusions: exclusions)
    }

    public static func parse(data: Data, exclusions: TimelineFingerprintExclusions = .init()) throws -> TimelineDocument {
        guard data.count <= 64 * 1_024 * 1_024 else { throw TimelineError.invalidXML("document exceeds 64 MB") }
        guard let xml = String(data: data, encoding: .utf8) else { throw TimelineError.invalidXML("export UTF-8 FCPXML") }
        // Foundation may suppress entity-declaration callbacks when resolution is
        // disabled. Reject custom DTDs before parsing rather than depending on them.
        guard !xml.contains("<!ENTITY") else { throw TimelineError.invalidXML("custom XML entities are not supported") }
        if let start = xml.range(of: "<!DOCTYPE") {
            guard let end = xml[start.lowerBound...].firstIndex(of: ">") else { throw TimelineError.invalidXML("unterminated document type") }
            let declaration = String(xml[start.lowerBound...end])
            guard declaration.range(of: "^<!DOCTYPE\\s+fcpxml\\s*>$", options: .regularExpression) != nil else {
                throw TimelineError.invalidXML("external or custom document types are not supported")
            }
        }
        let delegate = TimelineXMLDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root, root.name == "fcpxml" else {
            throw TimelineError.invalidXML(delegate.failure ?? parser.parserError?.localizedDescription ?? "missing fcpxml root")
        }
        if let failure = delegate.failure { throw TimelineError.invalidXML(failure) }
        return try TimelineBuilder(root: root, exclusions: exclusions).build()
    }
}

private final class TimelineXMLNode {
    let name: String
    let attributes: [String: String]
    var children: [TimelineXMLNode] = []
    var text = ""
    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }
    func descendants(named name: String) -> [TimelineXMLNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(named: name) }
    }
}

private final class TimelineXMLDelegate: NSObject, XMLParserDelegate {
    var root: TimelineXMLNode?
    var stack: [TimelineXMLNode] = []
    var count = 0
    var textBytes = 0
    var failure: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        count += 1
        guard stack.count < 128, count <= 500_000 else {
            failure = "document is too deeply nested or has too many elements"
            parser.abortParsing()
            return
        }
        let node = TimelineXMLNode(name: elementName, attributes: attributeDict)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBytes += string.utf8.count
        guard textBytes <= 64 * 1_024 * 1_024 else {
            failure = "expanded XML text exceeds 64 MB"
            parser.abortParsing()
            return
        }
        stack.last?.text += string
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self))
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        failure = "custom XML entities are not supported"
        parser.abortParsing()
    }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        failure = "external XML entities are not supported"
        parser.abortParsing()
    }
}

private final class TimelineCanonicalCache {
    var resourceHashes: [String: String] = [:]
    var remainingNodes = 2_000_000
}

private struct TimelineBuilder {
    let root: TimelineXMLNode
    let exclusions: TimelineFingerprintExclusions
    private let canonicalCache = TimelineCanonicalCache()
    private static let storyElements: Set<String> = ["asset-clip", "clip", "ref-clip", "mc-clip", "sync-clip", "audio", "video", "gap", "title", "caption", "live-drawing", "audition", "transition"]
    private static let timeAttributes: Set<String> = ["offset", "start", "duration", "tcStart", "frameDuration", "audioStart", "audioDuration", "time"]
    // Verified in the native Final Cut 12.3 export. This local AU passes audio
    // through; its archived effectState contains the same nonrendering controls.
    private static let cutdownAudioStateUID = "AudioUnit: 0x617566786374646e4374646e"

    func build() throws -> TimelineDocument {
        let version = root.attributes["version"] ?? "unknown"
        guard ["1.10", "1.11", "1.12", "1.13", "1.14"].contains(version) else { throw TimelineError.unsupportedVersion(version) }
        let projects = root.descendants(named: "project")
        guard projects.count == 1 else { throw TimelineError.projectCount(projects.count) }
        let project = projects[0]
        guard let sequence = project.children.first(where: { $0.name == "sequence" }),
              let spine = sequence.children.first(where: { $0.name == "spine" }) else {
            throw TimelineError.invalidSequence("a sequence and primary storyline are required")
        }
        let resourceNodes = root.children.first(where: { $0.name == "resources" })?.children ?? []
        var resources: [String: TimelineXMLNode] = [:]
        for resource in resourceNodes {
            guard let id = resource.attributes["id"], resources[id] == nil else { throw TimelineError.invalidXML("resource IDs must be present and unique") }
            resources[id] = resource
        }
        try validateTimes(in: root)
        let tcStart = try time(sequence, "tcStart")
        guard let formatID = sequence.attributes["format"], let format = resources[formatID] else {
            throw TimelineError.missingResource(sequence.attributes["format"] ?? "sequence format")
        }
        let frameDuration = try time(format, "frameDuration", required: true)
        guard frameDuration > .zero else { throw TimelineError.invalidSequence("frame duration must be positive") }
        var clips: [TimelineClip] = []
        var markers: [TimelineMarker] = []
        var warnings: [String] = []
        // FCPXML offsets on the root spine are in project timecode coordinates.
        // Example: tcStart=3600s, offset=3630s means 30s into the exported dialogue file.
        for (index, node) in spine.children.enumerated() where Self.storyElements.contains(node.name) {
            try walk(node, path: "spine/\(index)", parentID: nil, parentTimelineStart: .zero,
                     parentLocalStart: tcStart, primary: true, parentEnabled: true,
                     resources: resources, clips: &clips, markers: &markers, warnings: &warnings)
        }
        let duration: RationalTime
        if sequence.attributes["duration"] != nil { duration = try time(sequence, "duration") }
        else { duration = clips.filter(\.isPrimaryStoryline).map(\.timelineRange.end).max() ?? .zero }
        guard duration > .zero else { throw TimelineError.invalidSequence("the project is empty") }
        guard clips.filter(\.isPrimaryStoryline).allSatisfy({ $0.timelineRange.start >= .zero && $0.timelineRange.end <= duration }) else {
            throw TimelineError.invalidSequence("primary-storyline offsets fall outside the sequence's timecode and duration")
        }
        let roles = Set(clips.filter(\.enabled).flatMap(\.dialogueRoles)).sorted()
        if roles.isEmpty { warnings.append(TimelineDocument.missingDialogueWarning) }
        return TimelineDocument(version: version, projectName: project.attributes["name"] ?? "Untitled",
            projectUID: project.attributes["uid"], projectTimecodeStart: tcStart,
            projectRange: TimeRange(start: .zero, end: duration), frameDuration: frameDuration,
            clips: clips, markers: markers, dialogueRoles: roles,
            fingerprint: hash(try canonical(sequence, resources: resources)), warnings: warnings)
    }

    private func walk(_ node: TimelineXMLNode, path: String, parentID: String?, parentTimelineStart: RationalTime,
                      parentLocalStart: RationalTime, primary: Bool, parentEnabled: Bool,
                      resources: [String: TimelineXMLNode], clips: inout [TimelineClip], markers: inout [TimelineMarker],
                      warnings: inout [String]) throws {
        let sourceStart = try time(node, "start")
        let timelineStart = try parentTimelineStart.adding(time(node, "offset")).subtracting(parentLocalStart)
        let resource = node.attributes["ref"].flatMap { resources[$0] }
        if let ref = node.attributes["ref"], resource == nil { throw TimelineError.missingResource(ref) }
        let asset = resource?.name == "asset" ? resource : nil
        let activeAuditionItem = node.name == "audition" ? node.children.first(where: { Self.storyElements.contains($0.name) }) : nil
        let duration = try time(node, "duration", fallback: asset?.attributes["duration"] ?? activeAuditionItem?.attributes["duration"], required: true)
        guard duration >= .zero else { throw TimelineError.invalidTime("negative duration on \(path)") }
        let timelineRange = TimeRange(start: timelineStart, end: try timelineStart.adding(duration))
        let enabled = parentEnabled && node.attributes["enabled"] != "0"
        guard let lane = Int(node.attributes["lane"] ?? "0") else { throw TimelineError.invalidXML("invalid lane on \(path)") }
        let isPrimary = primary && lane == 0
        let srcEnable = node.attributes["srcEnable"] ?? "all"
        let hasVideo = asset?.attributes["hasVideo"] == "1" && srcEnable != "audio"
        let hasAudio = asset?.attributes["hasAudio"] == "1" && srcEnable != "video"
        let components = node.children.filter { ["audio-channel-source", "audio-role-source"].contains($0.name) }
        let enabledComponents = components.filter { $0.attributes["enabled"] != "0" && $0.attributes["active"] != "0" }
        let audioActive = enabled && srcEnable != "video" && (components.isEmpty || !enabledComponents.isEmpty)
        let rawRoles = components.isEmpty
            ? [node.attributes["audioRole"] ?? node.attributes["role"] ?? ""]
            : enabledComponents.map { $0.attributes["role"] ?? node.attributes["audioRole"] ?? "" }
        let roles = audioActive && (hasAudio || node.name == "audio" || ["ref-clip", "mc-clip"].contains(node.name))
            ? Array(Set(rawRoles.filter(Self.isDialogueRole))).sorted() : []
        var unsupported: [String] = []
        if node.name != "asset-clip" { unsupported.append("only a direct asset clip in the primary storyline is supported") }
        if !isPrimary { unsupported.append("connected or nested targets are not supported") }
        if !enabled { unsupported.append("the clip is disabled") }
        // Only audio-only timeline instances can be targets. An audio-only
        // insertion has no timeline video even when its source contains video.
        if hasVideo { unsupported.append("Cutdown supports audio-only timeline clips; video clips with audio are not supported") }
        if !hasAudio || !audioActive { unsupported.append("enabled source audio is required") }
        let retimed = node.children.contains(where: { $0.name == "timeMap" })
        let speedConformed = node.children.contains(where: { $0.name == "conform-rate" && $0.attributes["scaleEnabled"] != "0" })
        if retimed { unsupported.append("retimed targets are not supported") }
        if speedConformed {
            unsupported.append("automatic speed conforming is not supported")
        }
        if let audioStart = node.attributes["audioStart"], try parseTime(audioStart) != sourceStart {
            unsupported.append("split audio/video edits are not supported")
        }
        if let audioDuration = node.attributes["audioDuration"], try parseTime(audioDuration) != duration {
            unsupported.append("split audio/video edits are not supported")
        }
        let original = asset?.children.first(where: { $0.name == "media-rep" && ($0.attributes["kind"] ?? "original-media") == "original-media" })
        let mediaURL = (original?.attributes["src"] ?? asset?.attributes["src"]).flatMap(URL.init(string:))
        let assetStart = try asset.map { try time($0, "start") } ?? .zero
        // Every TimelineClip exposes this difference as a convenience property.
        // Validate it before constructing a value from external XML.
        _ = try sourceStart.subtracting(assetStart)
        _ = try sourceStart.adding(duration)
        if let asset, node.name == "asset-clip" {
            if sourceStart < assetStart { unsupported.append("the source trim starts before the original media") }
            if let rawDuration = asset.attributes["duration"], try sourceStart.adding(duration) > assetStart.adding(parseTime(rawDuration)) {
                unsupported.append("the source trim exceeds the original media")
            }
        }
        if node.children.contains(where: { Self.storyElements.contains($0.name) && ($0.attributes["lane"] ?? "0") == "0" }) {
            unsupported.append("nested targets are not supported")
        }
        let effectNodes = node.children.filter { $0.name.hasPrefix("filter-") || $0.name.hasPrefix("adjust-") }
        let effectText = try effectNodes.map { try canonical($0, resources: resources, omitFades: true) }.joined(separator: "\n")
        let fadeIns = try node.descendants(named: "fadeIn").map { try time($0, "duration", required: true) }
        let fadeOuts = try node.descendants(named: "fadeOut").map { try time($0, "duration", required: true) }
        clips.append(TimelineClip(id: path, name: node.attributes["name"] ?? asset?.attributes["name"] ?? node.name,
            kind: node.name, timelineRange: timelineRange, sourceStart: sourceStart, assetStart: assetStart,
            mediaURL: mediaURL, assetID: asset?.attributes["id"], parentID: parentID, lane: lane,
            isPrimaryStoryline: isPrimary, enabled: enabled, hasVideo: hasVideo, hasAudio: hasAudio && audioActive,
            dialogueRoles: roles, hasUnresolvedTiming: retimed || speedConformed,
            unsupportedReasons: unsupported, effectsFingerprint: hash(effectText),
            audioFadeIn: fadeIns.max() ?? .zero, audioFadeOut: fadeOuts.max() ?? .zero))
        for (index, marker) in node.children.enumerated() where ["marker", "chapter-marker"].contains(marker.name) {
            let sourcePosition = try time(marker, "start", required: true)
            // Markers are point annotations; their duration is optional in FCPXML.
            let markerDuration = try time(marker, "duration")
            guard markerDuration >= .zero else { throw TimelineError.invalidTime("negative marker duration") }
            let value = TimelineMarker(id: "\(path)/marker\(index)", parentClipID: path,
                timelinePosition: try timelineStart.adding(sourcePosition).subtracting(sourceStart),
                sourcePosition: sourcePosition, kind: marker.name, value: marker.attributes["value"] ?? "",
                note: marker.attributes["note"], duration: markerDuration, completed: marker.attributes["completed"])
            markers.append(value)
        }
        // A retime invalidates a simple affine child mapping; protect the parent as unresolved.
        if retimed || speedConformed {
            if !isPrimary { warnings.append("Nested timing is unavailable for retimed item \(node.attributes["name"] ?? path).") }
            return
        }
        for (index, child) in node.children.enumerated() {
            // Only the first story item in an audition is active. Alternatives
            // must not contribute dialogue roles or protection outside that item.
            if node.name == "audition", let activeAuditionItem, child !== activeAuditionItem { continue }
            if child.name == "spine" {
                let spineStart = try timelineStart.adding(time(child, "offset")).subtracting(sourceStart)
                for (childIndex, item) in child.children.enumerated() where Self.storyElements.contains(item.name) {
                    try walk(item, path: "\(path)/spine\(index)/\(childIndex)", parentID: path,
                             parentTimelineStart: spineStart, parentLocalStart: .zero, primary: false,
                             parentEnabled: enabled, resources: resources, clips: &clips, markers: &markers,
                             warnings: &warnings)
                }
            } else if Self.storyElements.contains(child.name) {
                try walk(child, path: "\(path)/\(index)", parentID: path,
                         parentTimelineStart: timelineStart, parentLocalStart: sourceStart, primary: false,
                         parentEnabled: enabled, resources: resources, clips: &clips, markers: &markers,
                         warnings: &warnings)
            }
        }
    }

    private static func isDialogueRole(_ role: String) -> Bool {
        let normalized = role.lowercased()
        return normalized == "dialogue" || normalized.hasPrefix("dialogue.")
    }
    private func parseTime(_ value: String) throws -> RationalTime {
        guard value.hasSuffix("s") else { throw TimelineError.invalidTime(value) }
        do { return try RationalTime.parse(value) } catch { throw TimelineError.invalidTime(value) }
    }
    private func time(_ node: TimelineXMLNode, _ attribute: String, fallback: String? = nil, required: Bool = false) throws -> RationalTime {
        guard let raw = node.attributes[attribute] ?? fallback else {
            if required { throw TimelineError.invalidTime("missing \(node.name).\(attribute)") }
            return .zero
        }
        return try parseTime(raw)
    }
    private func validateTimes(in node: TimelineXMLNode) throws {
        for (key, value) in node.attributes where Self.timeAttributes.contains(key) {
            let parsed = try parseTime(value)
            if ["duration", "audioDuration", "frameDuration"].contains(key), parsed < .zero {
                throw TimelineError.invalidTime("negative \(node.name).\(key)")
            }
        }
        for child in node.children { try validateTimes(in: child) }
    }
    private func hash(_ string: String) -> String { SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// Sort attribute keys and replace resource IDs with content hashes so harmless XML
    /// formatting, export dates, and resource renumbering cannot invalidate a review.
    private func canonical(_ node: TimelineXMLNode, resources: [String: TimelineXMLNode], visiting: Set<String> = [],
                           depth: Int = 0, omitFades: Bool = false) throws -> String {
        guard depth < 256, canonicalCache.remainingNodes > 0 else {
            throw TimelineError.invalidXML("resource graph is too deeply nested or complex")
        }
        canonicalCache.remainingNodes -= 1
        if node.name == "bookmark" || (omitFades && ["fadeIn", "fadeOut"].contains(node.name)) { return "" }
        let effectUID = node.attributes["ref"].flatMap { resources[$0]?.attributes["uid"] }
        let controller = node.name == "filter-audio"
            && effectUID.map { exclusions.controllerEffectUIDs.contains($0) } == true
        let controllerAudioState = controller && effectUID == Self.cutdownAudioStateUID
        var parts = [node.name]
        for key in node.attributes.keys.sorted() where key != "modDate" {
            // FCP can add the last-used preset reference after Analyze without
            // changing this passthrough controller's settings. Settings are
            // checked separately by the interactive path. Other effects' preset
            // references still affect sound and must remain in the fingerprint.
            if controllerAudioState && key == "presetID" { continue }
            var value = node.attributes[key]!
            // Resource IDs are export-local and replaced by content hashes at
            // their references. Local definition IDs (for example text styles)
            // still affect the meaning of their corresponding references.
            if key == "id", resources[value] === node { continue }
            if ["ref", "format"].contains(key) {
                if let resource = resources[value] {
                    guard !visiting.contains(value) else { throw TimelineError.invalidXML("cyclic resource reference \(value)") }
                    if let cached = canonicalCache.resourceHashes[value] { value = cached }
                    else {
                        let resourceHash = hash(try canonical(resource, resources: resources, visiting: visiting.union([value]), depth: depth + 1))
                        canonicalCache.resourceHashes[value] = resourceHash
                        value = resourceHash
                    }
                } else if key == "format" || Self.storyElements.contains(node.name) || node.name.hasPrefix("filter-") {
                    throw TimelineError.missingResource(value)
                }
            } else if Self.timeAttributes.contains(key) {
                let parsed = try parseTime(value)
                // Final Cut omits a zero source start after native range edits.
                // asset-clip start defaults to zero, so this is semantically identical.
                if node.name == "asset-clip", key == "start", parsed == .zero { continue }
                value = "\(parsed.numerator)/\(parsed.denominator)s"
            }
            parts.append("\(key.utf8.count):\(key)=\(value.utf8.count):\(value)")
        }
        let text = node.children.isEmpty ? node.text : node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { parts.append("text=\(text.utf8.count):\(text)") }
        for child in node.children {
            if controller && child.name == "param" { continue }
            if controllerAudioState && child.name == "data" && child.attributes["key"] == "effectState" { continue }
            let result = try canonical(child, resources: resources, visiting: visiting, depth: depth + 1, omitFades: omitFades)
            if !result.isEmpty { parts.append(result) }
        }
        return parts.map { "\($0.utf8.count):\($0)" }.joined()
    }
}
