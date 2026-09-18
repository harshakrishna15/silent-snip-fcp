import CutdownCore
import Foundation
import XCTest
@testable import CutdownMac

@MainActor final class ShareReviewSessionTests: XCTestCase {
    private var directory: URL!
    private var savedSettings: [String: Any] = [:]
    private let settingsKeys = ["share.threshold", "share.minimum", "share.before", "share.after"]

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CutdownShareReview-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        savedSettings = settingsKeys.reduce(into: [:]) { result, key in result[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDownWithError() throws {
        for key in settingsKeys {
            if let value = savedSettings[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try? FileManager.default.removeItem(at: directory)
    }

    func testRepeatedSourceSelectionUsesExactTimelineOccurrence() async throws {
        let fixture = try fixture(repeated: true)
        let session = session()
        defer { session.cancel() }
        session.receive(xmlURL: fixture.xml, mediaURLs: [fixture.audio])
        try await wait { !session.busy }
        XCTAssertEqual(session.targets.count, 2, session.message)
        XCTAssertEqual(session.target?.timelineRange, range(0, 3))
        XCTAssertEqual(session.selectedRanges, [TimeRange(start: .init(11, 10), end: .init(19, 10))])
        session.targetID = try XCTUnwrap(session.targets.last).id
        XCTAssertEqual(session.target?.timelineRange, range(3, 6))
        XCTAssertEqual(session.selectedRanges, [TimeRange(start: .init(41, 10), end: .init(49, 10))])
        XCTAssertEqual(session.target?.sourceStart, RationalTime(1))
        XCTAssertTrue(session.canCreate, session.message)
    }

    func testCachedSettingRecalculationPreservesIdenticalChoicesAndResetsChangedRanges() async throws {
        let fixture = try fixture()
        let session = session()
        defer { session.cancel() }
        session.receive(xmlURL: fixture.xml, mediaURLs: [fixture.audio])
        try await wait { !session.busy }
        let first = try XCTUnwrap(session.rows.first, session.message)
        session.include(first.id, false)
        XCTAssertTrue(session.included.isEmpty)
        session.threshold = -30
        try await wait { session.outputBlock == nil }
        XCTAssertEqual(session.rows.map(\.range), [first.range])
        XCTAssertTrue(session.included.isEmpty)
        session.before = 0.2
        try await wait { session.outputBlock == nil }
        XCTAssertNotEqual(session.rows.map(\.range), [first.range])
        XCTAssertEqual(session.included.count, 1)
        XCTAssertTrue(session.hasCachedAudio)
    }

    func testChoiceChangesCannotEnableCreationWhileSettingsAreRecalculating() async throws {
        let fixture = try fixture()
        let session = session()
        defer { session.cancel() }
        session.receive(xmlURL: fixture.xml, mediaURLs: [fixture.audio])
        try await wait { !session.busy }
        XCTAssertTrue(session.canCreate, session.message)
        session.minimum = 2.0
        session.selectAll(true)
        XCTAssertFalse(session.canCreate, "The old cut ranges must remain disabled until the new minimum is calculated.")
        try await wait { session.outputBlock == nil }
        XCTAssertTrue(session.rows.isEmpty)
        XCTAssertFalse(session.canCreate)
    }

    func testContinuousDialogueProducesNoOutput() async throws {
        let fixture = try fixture(quiet: false)
        let session = session()
        defer { session.cancel() }
        session.receive(xmlURL: fixture.xml, mediaURLs: [fixture.audio])
        try await wait { !session.busy }
        XCTAssertTrue(session.hasCachedAudio, session.message)
        XCTAssertTrue(session.rows.isEmpty)
        XCTAssertFalse(session.canCreate)
        XCTAssertThrowsError(try session.createOutput(in: directory.appendingPathComponent("No result")))
        XCTAssertTrue(session.message.contains("No qualifying silence"))
    }

    func testCancelExistingReviewDisablesItsRemovalPlan() async throws {
        let fixture = try fixture()
        let session = session()
        session.receive(xmlURL: fixture.xml, mediaURLs: [fixture.audio])
        try await wait { !session.busy }
        XCTAssertTrue(session.canCreate, session.message)
        session.cancel()
        XCTAssertFalse(session.canCreate)
        XCTAssertTrue(session.rows.isEmpty)
        XCTAssertFalse(session.hasCachedAudio)
        XCTAssertThrowsError(try session.createOutput(in: directory.appendingPathComponent("Cancelled")))
    }

    func testImmediateCancellationCannotPublishLateResults() async throws {
        let fixture = try fixture()
        let session = session()
        var accepted = false
        session.receive(xmlURL: fixture.xml, mediaURLs: [fixture.audio]) { accepted = true }
        session.cancel()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(session.busy)
        XCTAssertFalse(accepted)
        XCTAssertFalse(session.hasCachedAudio)
        XCTAssertFalse(session.canCreate)
        XCTAssertTrue(session.rows.isEmpty)
    }

    func testChangedDeliveredFilesRejectedByCompletionHookDisableResults() async throws {
        let fixture = try fixture()
        let session = session()
        defer { session.cancel() }
        session.receive(xmlURL: fixture.xml, mediaURLs: [fixture.audio]) {
            throw ShareDestinationError.changedDelivery
        }
        try await wait { !session.busy }
        XCTAssertFalse(session.hasCachedAudio)
        XCTAssertTrue(session.rows.isEmpty)
        XCTAssertFalse(session.canCreate)
        XCTAssertEqual(session.message, ShareDestinationError.changedDelivery.localizedDescription)
    }

    func testInvalidNextShareClearsPreviousTargetDetails() async throws {
        let fixture = try fixture()
        let session = session()
        defer { session.cancel() }
        session.receive(xmlURL: fixture.xml, mediaURLs: [fixture.audio])
        try await wait { !session.busy }
        XCTAssertNotNil(session.document)
        let invalid = directory.appendingPathComponent("Invalid.fcpxml")
        try Data("not XML".utf8).write(to: invalid)
        session.receive(xmlURL: invalid, mediaURLs: [fixture.audio])
        try await wait { !session.busy }
        XCTAssertNil(session.document)
        XCTAssertTrue(session.targets.isEmpty)
        XCTAssertNil(session.target)
        XCTAssertFalse(session.canCreate)
    }

    func testCreateConsumesOutputActionAndPreservesInputAndSourceMedia() async throws {
        let fixture = try fixture()
        let originalXML = try Data(contentsOf: fixture.xml)
        let originalSource = try Data(contentsOf: fixture.source)
        let session = session()
        defer { session.cancel() }
        session.receive(xmlURL: fixture.xml, mediaURLs: [fixture.audio])
        try await wait { !session.busy }
        let resultFolder = directory.appendingPathComponent("Results")
        let result = try session.createOutput(in: resultFolder)
        XCTAssertEqual(session.outputURL, result)
        XCTAssertFalse(session.canCreate)
        XCTAssertThrowsError(try session.createOutput(in: resultFolder))
        let generated = try TimelineParser.parse(url: result)
        XCTAssertEqual(generated.projectRange.duration, RationalTime(11, 5))
        XCTAssertEqual(generated.clips.count, 2)
        XCTAssertTrue(generated.clips.allSatisfy { $0.mediaURL == fixture.source })
        XCTAssertEqual(try Data(contentsOf: fixture.xml), originalXML)
        XCTAssertEqual(try Data(contentsOf: fixture.source), originalSource)
        let files = try FileManager.default.contentsOfDirectory(at: resultFolder, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files.filter { $0.pathExtension == "fcpxml" }.count, 2)
        XCTAssertEqual(files.filter { $0.pathExtension == "json" }.count, 1)
    }

    private func session() -> ShareReviewSession {
        let session = ShareReviewSession()
        session.useSettings(try! AnalysisSettings())
        return session
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the share review operation.")
    }

    private func range(_ start: Int64, _ end: Int64) -> TimeRange {
        TimeRange(start: RationalTime(start), end: RationalTime(end))
    }

    private struct Fixture { let xml: URL; let audio: URL; let source: URL }
    private func fixture(repeated: Bool = false, quiet: Bool = true) throws -> Fixture {
        let source = try wave(name: "Source.wav", seconds: 5) { frame in
            quiet && (96_000..<144_000).contains(frame) ? 0 : 8_192
        }
        let audio = try wave(name: "Render.wav", seconds: repeated ? 6 : 3) { frame in
            quiet && (48_000..<96_000).contains(frame % 144_000) ? 0 : 8_192
        }
        let xml = directory.appendingPathComponent("Project.fcpxml")
        let second = repeated ? "<asset-clip ref=\"a\" name=\"Repeated Voice\" offset=\"3s\" start=\"1s\" duration=\"3s\" audioRole=\"dialogue\"/>" : ""
        try Data("""
        <fcpxml version="1.14"><resources>
          <format id="f" frameDuration="1/30s" width="1920" height="1080"/>
          <asset id="a" name="Voice" start="0s" duration="5s" hasAudio="1" audioSources="1" audioChannels="1">
            <media-rep kind="original-media" src="\(source.absoluteString)"/>
          </asset>
        </resources><library><event name="Test"><project name="Share Audio" uid="share-audio-test">
          <sequence format="f" duration="\(repeated ? 6 : 3)s" tcStart="0s"><spine>
            <asset-clip ref="a" name="Voice" offset="0s" start="1s" duration="3s" audioRole="dialogue"/>
            \(second)
          </spine></sequence>
        </project></event></library></fcpxml>
        """.utf8).write(to: xml)
        return Fixture(xml: xml, audio: audio, source: source)
    }

    private func wave(name: String, seconds: Int, sample: (Int) -> Int16) throws -> URL {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        let frames = seconds * 48_000
        text("RIFF"); integer(UInt32(36 + frames * 2)); text("WAVE")
        text("fmt "); integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1))
        integer(UInt32(48_000)); integer(UInt32(96_000)); integer(UInt16(2)); integer(UInt16(16))
        text("data"); integer(UInt32(frames * 2))
        for frame in 0..<frames { integer(sample(frame)) }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
