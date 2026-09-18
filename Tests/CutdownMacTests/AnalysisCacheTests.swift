import CutdownCore
import Foundation
import XCTest
@testable import CutdownMac

@MainActor final class AnalysisCacheTests: XCTestCase {
    private var directory: URL!
    private var source: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CacheTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("Source.wav")
        try Data([1, 2, 3, 4]).write(to: source)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private let gate = "<filter-audio ref=\"gate\"><data key=\"effectState\">AQIDBA==</data></filter-audio>"
    private let secondGate = "<filter-audio ref=\"gate\"><data key=\"effectState\">AgMEBQ==</data><param key=\"gain\" value=\"2\"/></filter-audio>"
    private func xml(_ processing: String = "") -> Data {
        Data("""
        <fcpxml version="1.11"><resources><format id="f" frameDuration="1/30s"/>
        <asset id="a" start="0s" duration="6s" hasAudio="1"><media-rep kind="original-media" src="\(source.absoluteString)"/></asset>
        <effect id="c" uid="\(AudioControllerSettings.effectUID)"/>
        <effect id="gate" uid="AudioUnit: 0x61756678000000b3454d4147"/>
        <effect id="limiter" uid="Limiter.Levels.audio.effectBundle"/>
        <effect id="third" uid="opaque.vendor"/></resources>
        <library><event name="Event"><project name="Test" uid="original"><sequence format="f" duration="5s"><spine>
        <asset-clip ref="a" offset="0s" start="0s" duration="5s" audioRole="dialogue">\(processing)
        <filter-audio ref="c"><param key="cutdown.setting.0" value="-40"/></filter-audio>
        </asset-clip></spine></sequence></project></event></library></fcpxml>
        """.utf8)
    }
    private func document(_ data: Data) throws -> TimelineDocument {
        try TimelineParser.parse(data: data, exclusions: .init(controllerEffectUIDs: [AudioControllerSettings.effectUID]))
    }
    private func key(_ data: Data, window: Double = 0.01) async throws -> AnalysisCacheKey? {
        let doc = try document(data)
        return try await AnalysisCacheKey.make(data: data, document: doc, target: doc.clips[0],
            media: MediaContentSnapshot.capture([source]), windowDuration: window)
    }
    private func analysis(_ data: Data, rendered: Bool) async throws -> AnalyzedAudioProject {
        let doc = try document(data), target = doc.clips[0]
        let context = rendered ? try DialogueRenderContext.capturedIsolated(document: doc, target: target, audioURL: source)
            : try await DialogueRenderContext.capturedSource(document: doc, target: target, media: MediaContentSnapshot.capture([source]))
        let windows: [AudioLevelWindow] = [
            .init(range: .init(start: .zero, end: .init(1)), channelRMS: [0.2]),
            .init(range: .init(start: .init(1), end: .init(2)), channelRMS: [0]),
            .init(range: .init(start: .init(2), end: .init(5)), channelRMS: [0.2])]
        let detected = try SilenceDetector.analyze(windows: windows, target: target.timelineRange, frameDuration: doc.frameDuration)
        return try AnalyzedAudioProject(document: doc, target: target, dialogueContext: context,
            audio: .init(windows: windows, duration: .init(5), sampleRate: 48000, channelCount: 1),
            settings: .defaults, analysis: detected,
            review: ReviewPlan(jobID: UUID(), document: doc, target: target, analysis: detected))
    }
    func testSettingsOnlyHitRecalculatesAndCreatesFreshJobPlan() async throws {
        let data = xml(), original = try await analysis(data, rendered: false)
        let cache = AnalysisCache(); defer { cache.clear() }
        let baseline = try await key(data)
        try await cache.store(key: baseline, analysis: original, directory: directory)
        let changed = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "value=\"-40\"", with: "value=\"-30\"").utf8)
        let changedKey = try await key(changed)
        XCTAssertEqual(baseline, changedKey)
        let id = UUID(), settings = try AnalysisSettings(beforeSpeechPadding: 0.2, afterSpeechPadding: 0.2)
        let reused = try await cache.reuse(key: changedKey, document: document(changed), target: document(changed).clips[0], settings: settings, jobID: id)
        let result = try XCTUnwrap(reused)
        XCTAssertEqual(result.audio.windows, original.audio.windows)
        XCTAssertEqual(result.review.jobID, id)
        XCTAssertNotEqual(result.review.selectedCuts.map(\.range), original.review.selectedCuts.map(\.range))
        XCTAssertEqual(result.settings, settings)
        cache.clear()
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testProcessingChangesInvalidateFullSemanticKey() async throws {
        let data = xml(gate + secondGate), original = try await key(data)
        XCTAssertNotNil(original)
        let text = String(decoding: data, as: UTF8.self)
        for (before, after) in [("AQIDBA==", "BQYHCA=="), ("value=\"2\"", "value=\"6\""),
            (gate + secondGate, secondGate + gate), (gate, ""), ("<filter-audio ref=\"gate\">", "<filter-audio ref=\"gate\" enabled=\"0\">"),
            ("duration=\"5s\" audioRole", "duration=\"4s\" audioRole"), ("start=\"0s\" duration=\"5s\"", "start=\"1s\" duration=\"5s\""),
            ("audioRole=\"dialogue\"", "audioRole=\"music\"")] {
            XCTAssertTrue(text.contains(before))
            let updated = try await key(Data(text.replacingOccurrences(of: before, with: after).utf8))
            XCTAssertNotEqual(original, updated, before)
        }
        for adjustment in ["<adjust-volume amount=\"3dB\"/>", "<adjust-volume amount=\"3dB\"><param key=\"amount\"><keyframeAnimation><keyframe time=\"0s\" value=\"0dB\"/></keyframeAnimation></param></adjust-volume>",
            "<adjust-panner mode=\"stereo\" amount=\"20\"/>", "<audio-channel-source srcCh=\"1\" role=\"dialogue\"/>", "<fadeIn type=\"linear\" duration=\"1s\"/>"] {
            let updated = try await key(xml(adjustment + gate + secondGate))
            XCTAssertNotEqual(original, updated)
        }
        let differentWindow = try await key(data, window: 0.02)
        XCTAssertNotEqual(original, differentWindow)
    }
    func testUnknownAndPresetOnlyStateAlwaysRerenders() async throws {
        for processing in ["<filter-audio ref=\"gate\"/>", "<filter-audio ref=\"gate\" presetID=\"Voice.aupreset\"/>",
            "<filter-audio ref=\"third\"><data key=\"effectState\">AQID</data></filter-audio>",
            "<filter-audio ref=\"limiter\"/>", "<filter-audio ref=\"limiter\"><param key=\"gain\" value=\"2\"/></filter-audio>",
            "<audio-channel-source srcCh=\"1\"><adjust-noiseReduction amount=\"20\"/></audio-channel-source>",
            "<adjust-noiseReduction amount=\"20\"/>"] {
            let value = try await key(xml(processing))
            XCTAssertNil(value)
        }
    }
    func testSameSizeSourceReplacementInvalidatesDespiteSameDate() async throws {
        let data = xml(), original = try await key(data)
        let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
        try Data([4, 3, 2, 1]).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: attrs[.modificationDate]!], ofItemAtPath: source.path)
        let updated = try await key(data)
        XCTAssertNotEqual(original, updated)
    }
    func testDifferentHostLaunchAndRepointedMediaAliasInvalidate() async throws {
        let data = xml(), doc = try document(data)
        let media = try await MediaContentSnapshot.capture([source])
        let first = try AnalysisCacheKey.make(data: data, document: doc, target: doc.clips[0], media: media,
            windowDuration: 0.01, hostSession: "pid:launch1")
        let next = try AnalysisCacheKey.make(data: data, document: doc, target: doc.clips[0], media: media,
            windowDuration: 0.01, hostSession: "pid:launch2")
        XCTAssertNotEqual(first, next)
        let alias = directory.appendingPathComponent("Alias.wav")
        let other = directory.appendingPathComponent("Other.wav")
        try Data([4, 3, 2, 1]).write(to: other)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let oldSource = source!; source = alias
        let aliasData = xml(), baseline = try await key(aliasData)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: other)
        let changed = try await key(aliasData)
        XCTAssertNotEqual(baseline, changed)
        source = oldSource
    }
    func testRenderedCopySurvivesShareCleanupButTamperingCausesMiss() async throws {
        let data = xml(secondGate), original = try await analysis(data, rendered: true)
        let baseline = try await key(data)
        let cache = AnalysisCache(); defer { cache.clear() }
        try await cache.store(key: baseline, analysis: original, directory: directory)
        let copy = directory.appendingPathComponent("Cached-Processed-Audio.wav")
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: source))
        let reused = try await cache.reuse(key: baseline, document: original.document, target: original.target, settings: .defaults, jobID: UUID())
        XCTAssertNotNil(reused)
        XCTAssertEqual(reused?.dialogueContext.audioURL, copy)
        try Data([4, 3, 2, 1]).write(to: copy)
        let stale = try await cache.reuse(key: baseline, document: original.document, target: original.target, settings: .defaults, jobID: UUID())
        XCTAssertNil(stale); XCTAssertFalse(cache.hasEntry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testCacheMissEvictsItsOwnedCopy() async throws {
        let data = xml(secondGate), original = try await analysis(data, rendered: true)
        let cache = AnalysisCache(); defer { cache.clear() }
        try await cache.store(key: key(data), analysis: original, directory: directory)
        let miss = try await cache.reuse(key: nil, document: original.document, target: original.target, settings: .defaults, jobID: UUID())
        XCTAssertNil(miss); XCTAssertFalse(cache.hasEntry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Cached-Processed-Audio.wav").path))
    }
    func testStageTimingIncludesRepeatedStagesFailureAndPreviewLatency() {
        var now = 10.0
        let timing = AnalysisTiming(request: UUID(), clock: { now })
        timing.begin("capture"); now = 12; timing.begin("render"); now = 17
        timing.markPreviewReady(); timing.begin("cleanup"); now = 18
        timing.begin("capture"); now = 19
        let report = timing.report(outcome: "failed")
        XCTAssertEqual(report.stages["capture"], 3)
        XCTAssertEqual(report.stages["render"], 5)
        XCTAssertEqual(report.stages["cleanup"], 1)
        XCTAssertEqual(report.previewReadySeconds, 7)
        XCTAssertEqual(report.totalSeconds, 9)
        XCTAssertEqual(report.outcome, "failed")
    }
}
