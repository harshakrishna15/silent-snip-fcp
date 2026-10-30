import Foundation
import SilentSnipCore
import XCTest
@testable import SilentSnipMac

final class DirectAudioRenderTests: XCTestCase {
    private func snapshot(project: String = "Original", duration: String = "00:00:05:00") throws -> FinalCutSelectionSnapshot {
        func node(_ role: String, _ description: String, _ value: String,
                  selected: Bool? = nil, children: [AccessibilityNode] = []) -> AccessibilityNode {
            .init(role: role, identifier: nil, title: nil, description: description,
                  value: value, selected: selected, enabled: true, children: children)
        }
        return try FinalCutSelectionSnapshot(projectName: project,
            timeline: node("AXLayoutArea", "Project Timeline", "", children: [
                node("AXLayoutItem", "Audio-Clip:Interview", duration, selected: true, children: [
                    node("AXTextField", "Title", "Interview"),
                    node("AXHandle", "Leading Edge", "02:00:00:00"),
                    node("AXHandle", "Trailing Edge", "02:00:05:00")])]))
    }

    func testCombinedCaptureHintRequiresFreshScopeAndExactPreRenderSourceEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RenderHint-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.wav")
        try Data([1, 2, 3]).write(to: url)
        func fixture(duration: Int = 5) -> Data {
            Data(String(decoding: self.fixture(duration: duration), as: UTF8.self)
                .replacingOccurrences(of: "file:///fixture.wav", with: url.absoluteString).utf8)
        }
        let media = try await MediaContentSnapshot.capture([url], hash: { _ in "test-digest" })
        let hint = DirectAudioRenderHint(selection: try snapshot(), sourceURLs: [url], scope: .fullProjectTarget)
        XCTAssertTrue(hint.matches(try snapshot()))
        XCTAssertFalse(hint.matches(try snapshot(project: "Another project")))
        XCTAssertFalse(hint.matches(try snapshot(duration: "00:00:04:00")))
        XCTAssertTrue(try hint.accepts(projectData: fixture(), selection: selection, media: media))
        let changedSource = Data(String(decoding: fixture(), as: UTF8.self)
            .replacingOccurrences(of: "fixture.wav", with: "new-source.wav").utf8)
        XCTAssertFalse(try hint.accepts(projectData: changedSource, selection: selection, media: media))
        XCTAssertFalse(try hint.accepts(projectData: fixture(duration: 11), selection: selection, media: media))
        // Changed opaque DSP still qualifies for a FRESH render. A hint must
        // never turn into permission to reuse the previous audio measurements.
        let changedDSP = Data(String(decoding: fixture(), as: UTF8.self)
            .replacingOccurrences(of: "opaque.preset", with: "changed.preset").utf8)
        XCTAssertTrue(try hint.accepts(projectData: changedDSP, selection: selection, media: media))
    }

    private let selection = TimelineSelection(timelineRange: .init(start: .zero, end: .init(5)))
    private func fixture(_ clip: String = "", extra: String = "", duration: Int = 5, leading: String = "", offset: String = "7200s") -> Data {
        Data("""
        <fcpxml version="1.14"><resources><format id="f" frameDuration="1/30s"/>
        <asset id="a" start="3600s" duration="30s" hasAudio="1"><media-rep kind="original-media" src="file:///fixture.wav"/></asset>
        <effect id="gate" uid="opaque-third-party"/></resources><project name="Original" uid="original">
        <sequence format="f" duration="\(duration)s" tcStart="7200s"><spine>\(leading)
        <asset-clip ref="a" offset="\(offset)" start="3602s" duration="5s" audioRole="dialogue">
        <filter-audio ref="gate" presetID="opaque.preset"/>\(clip)</asset-clip>\(extra)</spine></sequence></project></fcpxml>
        """.utf8)
    }
    func testAdaptiveScopeAvoidsRangeCommandsForSmallCleanMixes() throws {
        XCTAssertEqual(try DirectAudioRender.scope(projectData: fixture(), selection: selection), .fullProjectTarget)
        XCTAssertEqual(try DirectAudioRender.scope(projectData: fixture(extra: "<gap offset=\"7205s\" start=\"0s\" duration=\"1s\"/>", duration: 6), selection: selection), .projectSlice)
        let prior = fixture(duration: 8, leading: "<asset-clip ref=\"a\" offset=\"7200s\" start=\"3600s\" duration=\"3s\" audioRole=\"dialogue\"/>", offset: "7203s")
        XCTAssertEqual(try DirectAudioRender.scope(projectData: prior,
            selection: .init(timelineRange: .init(start: .init(3), end: .init(8)))), .selectedRange)
        let long = fixture(extra: "<gap offset=\"7205s\" start=\"0s\" duration=\"3600s\"/>", duration: 3605)
        XCTAssertEqual(try DirectAudioRender.scope(projectData: long, selection: selection), .selectedRange)
    }

    func testWholeProjectScopeAllowsOpaqueEffectsAndSourceTrim() throws {
        XCTAssertTrue(try DirectAudioRender.isEligible(projectData: fixture(), selection: selection))
        XCTAssertTrue(try DirectAudioRender.isEligible(projectData: fixture("<audio-channel-source srcCh=\"1\" role=\"dialogue.interview\"/>"), selection: selection))
        // Video and audio stay linked; Audio Only export still measures its audio.
        let camera = Data(String(decoding: fixture(), as: UTF8.self)
            .replacingOccurrences(of: "hasAudio=\"1\"", with: "hasAudio=\"1\" hasVideo=\"1\"").utf8)
        XCTAssertTrue(try DirectAudioRender.isEligible(projectData: camera, selection: selection))
    }
    func testScopeAllowsBoundedPaddingAndFollowingNeighbor() throws {
        XCTAssertTrue(try DirectAudioRender.isEligible(projectData: fixture(duration: 6), selection: selection))
        XCTAssertTrue(try DirectAudioRender.isEligible(projectData: fixture(extra: "<gap offset=\"7205s\" start=\"0s\" duration=\"1s\"/>", duration: 6), selection: selection))
        XCTAssertTrue(try DirectAudioRender.isEligible(projectData: fixture(extra: "<asset-clip ref=\"a\" offset=\"7205s\" start=\"3600s\" duration=\"1s\" audioRole=\"dialogue\"/>", duration: 6), selection: selection))
    }
    func testConnectedMusicIsExcludedFromDialogueButUnknownOrMixedRolesAreNot() throws {
        let music = "<asset-clip ref=\"a\" lane=\"-1\" offset=\"3602s\" start=\"3600s\" duration=\"5s\" audioRole=\"music\"/>"
        XCTAssertTrue(try DirectAudioRender.isEligible(projectData: fixture(music), selection: selection))
        XCTAssertFalse(try DirectAudioRender.isEligible(projectData: fixture(music.replacingOccurrences(of: "audioRole=\"music\"", with: "audioRole=\"dialogue\"")), selection: selection))
        XCTAssertFalse(try DirectAudioRender.isEligible(projectData: fixture(music.replacingOccurrences(of: " audioRole=\"music\"", with: "")), selection: selection))
    }
    func testRangeScopeRejectsOverlappingAudioConnectionsAndMixedRoles() throws {
        for data in [fixture(extra: "<asset-clip ref=\"a\" offset=\"7200s\" start=\"3600s\" duration=\"1s\" audioRole=\"dialogue\"/>", duration: 6),
                     fixture(extra: "<transition offset=\"7205s\" duration=\"1s\"/>", duration: 6),
                     fixture("<asset-clip ref=\"a\" offset=\"3602s\" start=\"3600s\" duration=\"1s\" lane=\"-1\"/>") ,
                     fixture("<audio-channel-source srcCh=\"1\" role=\"dialogue\"/><audio-channel-source srcCh=\"2\" role=\"music\"/>") ,
                     Data(String(decoding: fixture(), as: UTF8.self).replacingOccurrences(of: "audioRole=\"dialogue\"", with: "audioRole=\"effects\"").utf8)] {
            XCTAssertFalse(try DirectAudioRender.isEligible(projectData: data, selection: selection))
        }
        let priorAudio = fixture(duration: 8, leading: "<asset-clip ref=\"a\" offset=\"7200s\" start=\"3600s\" duration=\"3s\" audioRole=\"dialogue\"/>", offset: "7203s")
        XCTAssertTrue(try DirectAudioRender.isEligible(projectData: priorAudio,
            selection: .init(timelineRange: .init(start: .init(3), end: .init(8)))))
        let longProject = fixture(extra: "<gap offset=\"7205s\" start=\"0s\" duration=\"3600s\"/>", duration: 3605)
        XCTAssertTrue(try DirectAudioRender.isEligible(projectData: longProject, selection: selection))

    }
}
