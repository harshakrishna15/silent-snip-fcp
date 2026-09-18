import XCTest
import CutdownCore
@testable import CutdownMac

final class NativeTimelineEditTests: XCTestCase {
    func testCompactFourFrameRetainedSegmentMatchesExactPositionAndDuration() {
        let item = compactItem()
        XCTAssertTrue(matchesCompact(item))
        XCTAssertFalse(matchesCompact(item, start: "00:01:11:09"))
        XCTAssertFalse(matchesCompact(item, duration: "00:00:00:05"))
        XCTAssertFalse(matchesCompact(item, name: "Another recording"))
        XCTAssertFalse(matchesCompact(item, allowed: false))
    }

    func testCompactFallbackRejectsConflictingOrMissingFields() {
        XCTAssertFalse(matchesCompact(compactItem(parts: [])))
        XCTAssertFalse(matchesCompact(compactItem(parts: [field("Item", "00:01:11:08"), field("Item", "00:01:11:08")])))
        for (label, wrong) in [("Title", "Wrong"), ("Leading Edge", "00:00:00:00"), ("Trailing Edge", "00:01:11:13")] {
            XCTAssertFalse(matchesCompact(compactItem(parts: [field("Item", "00:01:11:08"), field(label, wrong)])))
        }
        XCTAssertFalse(matchesCompact(compactItem(description: "Video-Clip:Sample Recording")))
    }

    private func field(_ name: String, _ value: String) -> AccessibilityNode {
        AccessibilityNode(role: name == "Title" ? "AXTextField" : "AXHandle", identifier: nil, title: nil,
            description: name, value: value, selected: nil, enabled: nil, children: [])
    }
    private func compactItem(parts: [AccessibilityNode]? = nil,
                             description: String = "Audio-Clip:Sample Recording") -> AccessibilityNode {
        AccessibilityNode(role: "AXLayoutItem", identifier: nil, title: nil, description: description,
            value: "00:00:00:04", selected: nil, enabled: nil,
            children: parts ?? [field("Item", "00:01:11:08")])
    }
    private func matchesCompact(_ item: AccessibilityNode, name: String = "Sample Recording",
                                start: String = "00:01:11:08", duration: String = "00:00:00:04", allowed: Bool = true) -> Bool {
        NativeTimelineItemMatch.matches(item, name: name, start: start, end: "00:01:11:12", duration: duration, allowCompactAudio: allowed)
    }

    private var data: Data { Data("""
    <fcpxml version="1.11"><resources>
    <format id="f" frameDuration="1/30s" width="1920" height="1080"/>
    <asset id="a" name="Recording" start="0s" duration="10s" hasAudio="1" audioSources="1" audioChannels="2" audioRate="48000">
    <media-rep kind="original-media" src="file:///tmp/recording.wav"/></asset>
    </resources><library><event name="Tests"><project name="Original" uid="original">
    <sequence format="f" duration="10s" tcStart="0s"><spine>
    <asset-clip name="Recording" ref="a" offset="0s" start="0s" duration="10s" audioRole="dialogue"/>
    </spine></sequence></project></event></library></fcpxml>
    """.utf8) }
    func testActualNativeRangeDeletionMatchesFullExpectedFingerprint() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("CutdownCoreTests/Fixtures")
        let beforeData = try Data(contentsOf: fixtures.appendingPathComponent("native-range-before.fcpxml"))
        let exclusions = TimelineFingerprintExclusions(controllerEffectUIDs: [AudioControllerSettings.effectUID])
        let original = try TimelineParser.parse(data: beforeData, exclusions: exclusions)
        let actual = try TimelineParser.parse(url: fixtures.appendingPathComponent("native-range-after.fcpxml"), exclusions: exclusions)
        let expected = try NativeTimelineEdit.expected(data: beforeData, selection: .init(timelineRange: .init(start: .zero, end: .init(10))), removals: [
            .init(start: .init(34,15), end: .init(101,30)), .init(start: .init(79,15), end: .init(103,15))], exclusions: exclusions)
        try NativeTimelineEdit.verify(actual, expected: expected, original: original)
        XCTAssertEqual(actual.clips.map(\.sourceStart), [.zero, .init(101,30), .init(103,15)])
    }

    func testOmittedAndExplicitZeroSourceStartAreEquivalentButNonzeroIsDifferent() throws {
        let explicit = try TimelineParser.parse(data: data)
        let xml = String(decoding: data, as: UTF8.self)
        let omitted = try TimelineParser.parse(data: Data(xml.replacingOccurrences(of: "offset=\"0s\" start=\"0s\"", with: "offset=\"0s\"").utf8))
        let shifted = try TimelineParser.parse(data: Data(xml.replacingOccurrences(of: "offset=\"0s\" start=\"0s\"", with: "offset=\"0s\" start=\"1s\"").utf8))
        XCTAssertEqual(explicit.fingerprint, omitted.fingerprint)
        XCTAssertNotEqual(explicit.fingerprint, shifted.fingerprint)
    }

    func testRecoveryPreservesExactSequenceButHasIndependentIdentity() throws {
        let original = try TimelineParser.parse(data: data)
        let recovery = try TimelineParser.parse(data: NativeTimelineEdit.recovery(data: data, name: "Before Cuts"))
        XCTAssertEqual(recovery.fingerprint, original.fingerprint)
        XCTAssertNotEqual(recovery.projectUID, original.projectUID)
        XCTAssertEqual(recovery.projectName, "Before Cuts")
    }
    func testRightToLeftExpectedStatesKeepEarlierCutCoordinatesAndSourceIntervals() throws {
        let selection = TimelineSelection(timelineRange: .init(start: .zero, end: .init(10)))
        let last = TimeRange(start: .init(6), end: .init(8))
        let first = TimeRange(start: .init(2), end: .init(3))
        let intermediate = try NativeTimelineEdit.expected(data: data, selection: selection, removals: [last], exclusions: .init())
        XCTAssertEqual(intermediate.clips.map(\.sourceStart), [.zero, .init(8)])
        XCTAssertEqual(intermediate.clips[0].timelineRange, .init(start: .zero, end: .init(6)))
        let result = try NativeTimelineEdit.expected(data: data, selection: selection, removals: [last, first], exclusions: .init())
        XCTAssertEqual(result.clips.map(\.sourceStart), [.zero, .init(3), .init(8)])
        XCTAssertEqual(result.projectRange.duration, .init(7))
        XCTAssertThrowsError(try NativeTimelineEdit.verify(intermediate, expected: result, original: TimelineParser.parse(data: data)))
    }
    func testVerificationRejectsAChangedProjectEvenWhenSequenceIsIdentical() throws {
        let original = try TimelineParser.parse(data: data)
        let other = try TimelineParser.parse(data: NativeTimelineEdit.recovery(data: data, name: "Other"))
        XCTAssertNoThrow(try NativeTimelineEdit.verify(original, expected: original, original: original))
        XCTAssertThrowsError(try NativeTimelineEdit.verify(other, expected: original, original: original))
    }
}
