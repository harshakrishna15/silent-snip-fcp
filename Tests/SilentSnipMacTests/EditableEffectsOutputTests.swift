import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import SilentSnipCore
import XCTest
@testable import SilentSnipMac

/// Synthetic effect identities and state bytes test diagnostic serialization
/// and comparison only. Public XML creation rejects these native filters;
/// copied XML is not proof of native effect or advanced-control preservation.
final class EditableEffectsOutputTests: XCTestCase {
    /// This test-only evidence has no send/import operation or conformance.
    private struct SerializationFixture {
        let output: EditedProjectOutput
        let outputURL: URL
        let recoveryURL: URL
        let recoveryData: Data
    }

    private var folder: URL!
    private var library: URL { folder.appendingPathComponent("Editable Effects.fcpbundle") }
    private var voice: URL { folder.appendingPathComponent("Original Voice.wav") }
    private var music: URL { folder.appendingPathComponent("Original Music.wav") }
    private let eventUID = "BBBB0000-0000-4000-8000-000000000001"
    private let originalUID = "AAAA0000-0000-4000-8000-000000000001"
    private let selection = TimelineSelection(timelineRange: .init(start: .zero, end: .init(10)))
    private let cuts = [TimeRange(start: .init(2), end: .init(3)), TimeRange(start: .init(6), end: .init(8))]

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("EditableEffects-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        // No decoder/rendering is involved in these writer and content-identity tests.
        try Data((0..<128).map(UInt8.init)).write(to: voice)
        try Data((128..<256).map(UInt8.init)).write(to: music)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private var origin: WorkflowReviewOrigin {
        get throws {
            try WorkflowReviewOrigin(view: UUID(), gesture: UUID(), libraryURL: library,
                projectUID: originalUID, projectName: "Original Interview")
        }
    }

    private var audioState: String {
        """
        <adjust-volume amount="3dB"><param name="amount"><keyframeAnimation>
          <keyframe time="102s" value="3dB"/><keyframe time="107s" value="-2dB" curve="smooth"/><keyframe time="112s" value="1dB"/>
        </keyframeAnimation></param></adjust-volume>
        <filter-audio ref="gate" name="Noise Gate" enabled="1"><data key="effectState">Z2F0ZS1zdGF0ZQ==</data><param name="Threshold" key="threshold" value="-31.5"/></filter-audio>
        <filter-audio ref="limiter" name="Limiter" enabled="1"><data key="effectState">bGltaXRlci1zdGF0ZQ==</data><param name="Output Level" key="output" value="-1.25"/></filter-audio>
        <filter-audio ref="eq" name="Channel EQ" enabled="0"><data key="effectState">ZXEtc3RhdGU=</data><param name="Gain" key="gain" value="2.5"/></filter-audio>
        """
    }

    private func fixture(videoAndConnections: Bool = false) -> Data {
        let video = videoAndConnections ? " hasVideo=\"1\" format=\"f\"" : ""
        let connection = videoAndConnections ? """
        <asset-clip ref="bed" name="Music Bed" lane="-1" offset="102s" start="5s" duration="10s" audioRole="music">
          <adjust-volume amount="-9dB"/><filter-audio ref="eq" name="Channel EQ" enabled="1"><data key="effectState">YmVkLXN0YXRl</data></filter-audio>
        </asset-clip>
        """ : ""
        let transform = videoAndConnections ? "<adjust-transform position=\"1 2\" scale=\"0.9 0.9\"/>" : ""
        let later = videoAndConnections ? "<asset-clip ref=\"source\" name=\"Later Clip\" offset=\"3610s\" start=\"122s\" duration=\"2s\" audioRole=\"dialogue\"/>" : ""
        return Data("""
        <fcpxml version="1.11"><resources><format id="f" frameDuration="1/30s"/>
        <asset id="source" name="Original Voice" start="100s" duration="30s" hasAudio="1" audioSources="1" audioChannels="2" audioRate="48000"\(video)><media-rep kind="original-media" src="\(voice.absoluteString)"/></asset>
        <asset id="bed" name="Original Music" start="0s" duration="30s" hasAudio="1"><media-rep kind="original-media" src="\(music.absoluteString)"/></asset>
        <effect id="gate" name="Noise Gate" uid="fixture.noise-gate"/><effect id="limiter" name="Limiter" uid="fixture.limiter"/><effect id="eq" name="Channel EQ" uid="fixture.eq"/>
        </resources><library location="\(library.absoluteString)"><event name="Editable Fixture" uid="\(eventUID)"><project name="Original Interview" uid="\(originalUID)">
        <sequence format="f" duration="\(videoAndConnections ? 12 : 10)s" tcStart="3600s"><spine>
        <asset-clip ref="source" name="Interview" offset="3600s" start="102s" duration="10s" audioRole="dialogue">\(transform)\(audioState)\(connection)</asset-clip>
        \(later)</spine></sequence></project></event></library></fcpxml>
        """.utf8)
    }

    private func serializationFixture(_ input: Data, mode: SilentSnipOutputMode, suffix: String) throws -> SerializationFixture {
        let document = try TimelineParser.parse(data: input)
        let gap = try mode.gapDuration(frame: document.frameDuration)
        let gaps = gap.map { duration in Dictionary(uniqueKeysWithValues: cuts.map { ($0, duration) }) } ?? [:]
        let output = try EditedProjectWriter.serializationExpectation(projectData: input, selection: selection,
            selectedRanges: cuts, outputName: "Edited Interview " + suffix, destinationLibrary: library,
            replacementGaps: gaps, useOriginalEvent: true, omitController: true)
        let recovery = try ProjectRecoverySnapshot.recovery(data: input, name: document.projectName + " — Before Cuts")
        let directory = folder.appendingPathComponent("Diagnostic-" + suffix)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let outputURL = directory.appendingPathComponent("Expected-Serialized-Geometry.fcpxml")
        let recoveryURL = directory.appendingPathComponent("Before-Cuts.fcpxml")
        try output.xmlData.write(to: outputURL, options: .withoutOverwriting)
        try recovery.write(to: recoveryURL, options: .withoutOverwriting)
        return .init(output: output, outputURL: outputURL, recoveryURL: recoveryURL, recoveryData: recovery)
    }

    private func elements(_ data: Data, path: String) throws -> [XMLElement] {
        try XMLDocument(data: data).nodes(forXPath: path).compactMap { $0 as? XMLElement }
    }

    private func state(_ clip: XMLElement, element name: String) -> [String] {
        clip.elements(forName: name).map { element in
            let copy = element.copy() as! XMLElement
            func removeIndentation(_ node: XMLElement) {
                for child in node.children ?? [] {
                    if let element = child as? XMLElement { removeIndentation(element) }
                    else if child.kind == .text,
                            (child.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        child.detach()
                    }
                }
            }
            removeIndentation(copy)
            return copy.xmlString
        }
    }

    func testPublicPrepareRejectsSerializedEffectPayloadsBeforeCreatingAnyResult() throws {
        let sourceBytes = try [voice, music].map { try Data(contentsOf: $0) }
        for linked in [false, true] {
            let input = fixture(videoAndConnections: linked)
            for mode in [SilentSnipOutputMode.remove, .gaps] {
                let suffix = (linked ? "linked-" : "audio-") + mode.rawValue
                let directory = folder.appendingPathComponent("Rejected-" + suffix)
                XCTAssertThrowsError(try XMLProjectApply.prepare(projectData: input, selection: selection, cuts: cuts,
                    settings: .defaults, mode: mode, outputName: "Blocked Interview " + suffix,
                    directory: directory, useOriginalEvent: true, omitController: true, workflowOrigin: origin)) {
                    guard let error = $0 as? EditedProjectWriterError, case .unsupported(let reason) = error else {
                        return XCTFail("Expected native effect preservation rejection, got \($0)")
                    }
                    XCTAssertTrue(reason.contains(linked ? "Channel EQ" : "Noise Gate"),
                        "The guard must also reject the connected music effect encountered before the target chain")
                    XCTAssertTrue(reason.contains("cannot safely recreate"))
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path),
                    "Plausible effect payloads must not create an importable XML result")
            }
            XCTAssertEqual(input, fixture(videoAndConnections: linked))
        }
        for (index, source) in [voice, music].enumerated() {
            XCTAssertEqual(try Data(contentsOf: source), sourceBytes[index])
        }
    }

    func testRemovalAndGapExpectationsKeepSourceIntervalsAndSerializedEffectState() throws {
        let input = fixture()
        let originalFile = folder.appendingPathComponent("Original.fcpxml")
        try input.write(to: originalFile)
        let sourceBytes = try Data(contentsOf: voice)
        let sourceStamp = try MediaContentSnapshot.FileStamp(voice)
        let original = try XCTUnwrap(elements(input, path: "//spine/asset-clip").first)
        for mode in [SilentSnipOutputMode.remove, .gaps] {
            let output = try serializationFixture(input, mode: mode, suffix: mode.rawValue)
            let result = try TimelineParser.parse(data: output.output.xmlData)
            let clips = try elements(output.output.xmlData, path: "//spine/asset-clip")
            XCTAssertNil(output.output.report.losslessAudio, "Source geometry expectations must not substitute a rendered WAV")
            XCTAssertEqual(clips.count, 3)
            XCTAssertEqual(result.clips.filter(\.hasAudio).map(\.mediaURL), [voice, voice, voice])
            XCTAssertEqual(result.clips.filter(\.hasAudio).map(\.sourceStart), [102, 105, 110].map { RationalTime($0) })
            XCTAssertEqual(result.clips.filter(\.hasAudio).map(\.timelineRange), mode == .remove
                ? [range(0, 2), range(2, 5), range(5, 7)] : [range(0, 2), range(3, 6), range(7, 9)])
            for clip in clips {
                XCTAssertEqual(state(clip, element: "filter-audio"), state(original, element: "filter-audio"),
                    "Every diagnostic slice must copy serialized bypass state, payload bytes, parameters and chain order")
                XCTAssertEqual(state(clip, element: "adjust-volume"), state(original, element: "adjust-volume"),
                    "The complete volume curve retains its original source clock")
                XCTAssertNil(clip.attribute(forName: "enabled"), "The source clips must remain audible")
                XCTAssertNil(clip.attribute(forName: "srcEnable"), "No source stream is disabled to make room for baked audio")
            }
            XCTAssertEqual(try elements(output.output.xmlData, path: "//spine/gap").count, mode == .gaps ? 2 : 0)
            XCTAssertEqual(try elements(output.output.xmlData, path: "/fcpxml/resources/asset").count, 2,
                "No generated audio asset is added")
            XCTAssertEqual(try TimelineParser.parse(data: output.recoveryData).fingerprint,
                try TimelineParser.parse(data: input).fingerprint)
            XCTAssertEqual(try XMLDocument(data: output.output.xmlData)
                .nodes(forXPath: "/fcpxml/import-options/option[@key='copy assets']/@value").first?.stringValue, "0")
        }
        XCTAssertEqual(try Data(contentsOf: voice), sourceBytes)
        XCTAssertEqual(try MediaContentSnapshot.FileStamp(voice), sourceStamp)
        XCTAssertEqual(try Data(contentsOf: originalFile), input)
    }

    func testLinkedVideoAndConnectedMusicExpectationsKeepSourceAndSerializedEffectChains() throws {
        let input = fixture(videoAndConnections: true)
        let original = try TimelineParser.parse(data: input)
        let target = try original.selectedTarget(selection, requireExistingMedia: false)
        let bed = try XCTUnwrap(original.clips.first { !$0.isPrimaryStoryline })
        let sourcesBefore = try [voice, music].map { (try Data(contentsOf: $0), try MediaContentSnapshot.FileStamp($0)) }
        for mode in [SilentSnipOutputMode.remove, .gaps] {
            let output = try serializationFixture(input, mode: mode, suffix: "linked-" + mode.rawValue)
            let document = try TimelineParser.parse(data: output.output.xmlData)
            let kept = document.clips.filter { $0.name == "Interview" }
            let musicClips = document.clips.filter { $0.name == "Music Bed" }
            XCTAssertEqual(kept.count, 3)
            XCTAssertTrue(kept.allSatisfy { $0.hasVideo && $0.hasAudio && $0.enabled
                && $0.mediaURL == voice && $0.effectsFingerprint == target.effectsFingerprint })
            XCTAssertEqual(musicClips.map(\.sourceStart), [5, 8, 13].map { RationalTime($0) })
            XCTAssertTrue(musicClips.allSatisfy { !$0.isPrimaryStoryline && $0.mediaURL == music
                && $0.enabled && $0.effectsFingerprint == bed.effectsFingerprint })
            let later = try XCTUnwrap(document.clips.first { $0.name == "Later Clip" })
            XCTAssertEqual(later.sourceStart, .init(122))
            XCTAssertEqual(later.timelineRange, mode == .remove ? range(7, 9) : range(9, 11))
            XCTAssertNil(output.output.report.losslessAudio)
            XCTAssertTrue(try ProjectRoundTripVerification.compare(expected: output.output.xmlData, actual: output.output.xmlData).verified)
        }
        for (index, source) in [voice, music].enumerated() {
            XCTAssertEqual(try Data(contentsOf: source), sourcesBefore[index].0)
            XCTAssertEqual(try MediaContentSnapshot.FileStamp(source), sourcesBefore[index].1)
        }
    }

    func testSerializedComparisonRejectsLostBypassedReorderedOrChangedEffects() throws {
        let output = try serializationFixture(fixture(), mode: .remove, suffix: "strict")
        let expected = output.output.xmlData
        let alterations: [(String, (XMLElement) throws -> Void)] = [
            ("removed filter", { $0.elements(forName: "filter-audio")[0].detach() }),
            ("bypassed filter", { $0.elements(forName: "filter-audio")[0].attribute(forName: "enabled")?.stringValue = "0" }),
            ("changed archive", { $0.elements(forName: "filter-audio")[0].elements(forName: "data")[0].stringValue = "Y2hhbmdlZA==" }),
            ("changed parameter", { $0.elements(forName: "filter-audio")[0].elements(forName: "param")[0].attribute(forName: "value")?.stringValue = "-20" }),
            ("changed volume curve", { try $0.nodes(forXPath: "adjust-volume/param/keyframeAnimation/keyframe[2]/@value").first?.stringValue = "9dB" }),
            ("reordered chain", { clip in
                let filters = clip.elements(forName: "filter-audio")
                let firstIndex = filters[0].index
                filters[1].detach()
                clip.insertChild(filters[1], at: firstIndex)
            })
        ]
        for (label, alter) in alterations {
            let xml = try XMLDocument(data: expected)
            let first = try XCTUnwrap(xml.nodes(forXPath: "//spine/asset-clip").first as? XMLElement)
            try alter(first)
            // A legitimate host-assigned project identity must not hide DSP changes.
            try xml.nodes(forXPath: "//project/@uid").first?.stringValue = "HOST-IMPORTED-PROJECT"
            let report = try ProjectRoundTripVerification.compare(expected: expected, actual: xml.xmlData,
                allowHostAssignedIdentity: true)
            XCTAssertFalse(report.verified, label)
            XCTAssertTrue(report.differences.contains("timeline, media references, or effect settings"), label)
        }
        let substituted = Data(String(decoding: expected, as: UTF8.self)
            .replacingOccurrences(of: voice.absoluteString, with: music.absoluteString).utf8)
        XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: expected, actual: substituted,
            allowHostAssignedIdentity: true).verified, "Equal-duration audio at another URL cannot replace the original source")
    }

    @MainActor func testSourceOnlyOutputEvidenceReusesModernHashesAndFullyReadsLegacySources() async throws {
        let sources = [voice, music]
        let baseline = try await MediaContentSnapshot.capture(sources)
        let reads = HashReads()
        let modern = try await ApplyAudioRenderCapture.perform(sourceMedia: baseline, hash: { url in
            reads.record(url)
            return try MediaContentSnapshot.contentHash(at: url)
        }, render: { "fresh native verification render" }, cleanup: { _ in XCTFail("Successful receipt belongs to caller") })
        let output = try await modern.captureOutputMedia(adding: [], hash: { _ in
            XCTFail("Source-backed output has no added WAV and must not reread freshly joined source hashes")
            return "unexpected"
        })
        XCTAssertTrue(modern.reusesSourceHashesForOutput)
        XCTAssertEqual(reads.count, sources.count)
        XCTAssertEqual(output, baseline)
        try await output.validate()

        for missing in [["stamps"], ["canonicalURLs"], ["stamps", "canonicalURLs"]] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(baseline)) as? [String: Any])
            for key in missing { object.removeValue(forKey: key) }
            let historical = try JSONDecoder().decode(MediaContentSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            let legacy = try await ApplyAudioRenderCapture.perform(sourceMedia: historical,
                render: { "legacy full source preflight" }, cleanup: { _ in XCTFail("Successful receipt belongs to caller") })
            let legacyReads = HashReads()
            let current = try await legacy.captureOutputMedia(adding: [], hash: { url in
                legacyReads.record(url)
                return try MediaContentSnapshot.contentHash(at: url)
            })
            XCTAssertFalse(legacy.reusesSourceHashesForOutput)
            XCTAssertEqual(legacyReads.count, sources.count, "Legacy output must retain its complete source scan")
            XCTAssertEqual(current, baseline)
            try await current.validate()
        }
        try Data("source changed after verification render".utf8).write(to: voice)
        do {
            _ = try await modern.captureOutputMedia(adding: [], hash: { _ in
                XCTFail("Empty additions cannot bypass the held source guard")
                return "unexpected"
            })
            XCTFail("A source-backed result cannot adopt source changes after its render")
        } catch ProjectAnalysisError.changedRenderArtifact { }
    }

    private func range(_ start: Int64, _ end: Int64) -> TimeRange { .init(start: .init(start), end: .init(end)) }

    private final class HashReads: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func record(_ url: URL) { lock.lock(); defer { lock.unlock() }; value += 1 }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
}
