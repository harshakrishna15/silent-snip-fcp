import Darwin
import Foundation
import SilentSnipCore
import XCTest
@testable import SilentSnipMac

final class DirectAudioRenderHintStoreTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private enum Failure: Error { case unavailable }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("RoutingHint-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = root.appendingPathComponent("Original.wav")
        try Data("original source".utf8).write(to: source)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private var file: URL { root.appendingPathComponent(DirectAudioRenderHintStore.fileName) }

    private func selection(project: String = "Original") throws -> FinalCutSelectionSnapshot {
        func node(_ role: String, _ description: String, _ value: String,
                  selected: Bool? = nil, children: [AccessibilityNode] = []) -> AccessibilityNode {
            .init(role: role, identifier: nil, title: nil, description: description,
                  value: value, selected: selected, enabled: true, children: children)
        }
        return try FinalCutSelectionSnapshot(projectName: project,
            timeline: node("AXLayoutArea", "Project Timeline", "", children: [
                node("AXLayoutItem", "Audio-Clip:Interview", "00:00:05:00", selected: true, children: [
                    node("AXTextField", "Title", "Interview"),
                    node("AXHandle", "Leading Edge", "02:00:00:00"),
                    node("AXHandle", "Trailing Edge", "02:00:05:00")])]))
    }

    private func hint(urls: [URL]? = nil) throws -> DirectAudioRenderHint {
        try .init(selection: selection(), sourceURLs: urls ?? [source], scope: .fullProjectTarget)
    }

    private func project(sourceURL: URL? = nil, duration: Int = 5, preset: String = "opaque.preset") -> Data {
        Data("""
        <fcpxml version="1.14"><resources><format id="f" frameDuration="1/30s"/>
        <asset id="a" start="3600s" duration="30s" hasAudio="1"><media-rep kind="original-media" src="\((sourceURL ?? source).absoluteString)"/></asset>
        <effect id="fx" uid="opaque-third-party"/></resources><project name="Original" uid="original">
        <sequence format="f" duration="\(duration)s" tcStart="7200s"><spine>
        <asset-clip name="Interview" ref="a" offset="7200s" start="3602s" duration="5s" audioRole="dialogue">
        <filter-audio ref="fx" presetID="\(preset)"/></asset-clip></spine></sequence></project></fcpxml>
        """.utf8)
    }

    func testRelaunchedHelperGetsRoutingOnlyWithFreshSourceAndFreshXMLProofRequired() async throws {
        let originalHint = try hint()
        let stored = await DirectAudioRenderHintStore(root: root).save(originalHint)
        XCTAssertTrue(stored)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let fields = try XCTUnwrap(record["hint"] as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["selection", "sourceURLs", "scope"])
        let old = try await MediaContentSnapshot.capture([source])

        // A new instance models a helper restart. It must hash current bytes;
        // the persisted record has no audio/hash/effect-state authorization.
        let consumed = await DirectAudioRenderHintStore(root: root).consume()
        let recovered = try XCTUnwrap(consumed)
        XCTAssertEqual(recovered, originalHint)
        try Data("changed source bytes".utf8).write(to: source)
        let prepared = try XCTUnwrap(recovered.prepareSourceRead())
        let fresh = try await MediaContentSnapshot.capture(prepared: prepared)
        XCTAssertNotEqual(old.hashes, fresh.hashes)
        let selected = TimelineSelection(timelineRange: .init(start: .zero, end: .init(5)))
        XCTAssertTrue(try recovered.accepts(projectData: project(preset: "changed.opaque.state"), selection: selected, media: fresh))
        XCTAssertFalse(try recovered.accepts(projectData: project(sourceURL: root.appendingPathComponent("Replaced.wav")), selection: selected, media: fresh))
        XCTAssertFalse(try recovered.accepts(projectData: project(duration: 11), selection: selected, media: fresh))
        XCTAssertFalse(recovered.matches(try selection(project: "Another project")))
    }

    func testConsumedFailedHintCannotLoopOnTheNextAnalyze() async throws {
        let store = DirectAudioRenderHintStore(root: root)
        let saved = await store.save(try hint())
        let first = await DirectAudioRenderHintStore(root: root).consume()
        let second = await DirectAudioRenderHintStore(root: root).consume()
        XCTAssertTrue(saved)
        XCTAssertNotNil(first)
        XCTAssertNil(second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testReadableHintThatCannotBeConsumedIsAnOptionalCacheMiss() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory write permissions") }
        let store = DirectAudioRenderHintStore(root: root)
        let saved = await store.save(try hint())
        XCTAssertTrue(saved)
        let originalRecord = try Data(contentsOf: file)
        XCTAssertEqual(chmod(root.path, 0o500), 0)
        defer { _ = chmod(root.path, 0o700) }
        guard access(root.path, W_OK) != 0 else {
            throw XCTSkip("Current identity bypasses directory write permissions")
        }

        let first = await store.consume()
        let second = await DirectAudioRenderHintStore(root: root).consume()
        XCTAssertNil(first, "A hint must be removed before it may seed a speculative render")
        XCTAssertNil(second, "A non-consumable record must never seed repeat attempts")
        XCTAssertEqual(try Data(contentsOf: file), originalRecord)
        XCTAssertEqual(try Data(contentsOf: source), Data("original source".utf8))
    }

    func testMissingUnreadableOrNonRegularOptionalSourcesFallBackBeforeRendering() async throws {
        let candidate = try hint()
        let unavailable = try candidate.prepareSourceRead(prepare: { _ in throw Failure.unavailable })
        XCTAssertNil(unavailable)
        try FileManager.default.removeItem(at: source)
        let missing = try candidate.prepareSourceRead()
        XCTAssertNil(missing)
        for url in [root!, root.appendingPathComponent("pipe")] {
            if url != root { XCTAssertEqual(mkfifo(url.path, 0o600), 0) }
            let invalid = try hint(urls: [url])
            let prepared = try invalid.prepareSourceRead(prepare: { _ in
                XCTFail("An optional hint must not open a directory, FIFO or device")
                throw Failure.unavailable
            })
            let saved = await DirectAudioRenderHintStore(root: root).save(invalid)
            XCTAssertNil(prepared)
            XCTAssertFalse(saved)
        }
    }

    func testPreflightPreservesCancellation() throws {
        let candidate = try hint()
        do {
            _ = try candidate.prepareSourceRead(prepare: { _ in throw CancellationError() })
            XCTFail("Cancellation must not become an ordinary XML fallback")
        } catch is CancellationError { }
    }

    func testCorruptUnknownSchemaAndOversizedRecordsAreOptionalCacheMisses() async throws {
        let store = DirectAudioRenderHintStore(root: root)
        let saved = await store.save(try hint())
        XCTAssertTrue(saved)
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var unknown = valid; unknown["version"] = 3
        var invalidScope = valid
        var fields = try XCTUnwrap(invalidScope["hint"] as? [String: Any])
        fields["scope"] = "assume-current-audio"; invalidScope["hint"] = fields
        for data in [Data("{".utf8), Data("[]".utf8),
                     try JSONSerialization.data(withJSONObject: unknown),
                     try JSONSerialization.data(withJSONObject: invalidScope),
                     Data(repeating: 32, count: DirectAudioRenderHintStore.maximumBytes + 1)] {
            try data.write(to: file)
            let consumed = await store.consume()
            XCTAssertNil(consumed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
        XCTAssertEqual(try Data(contentsOf: source), Data("original source".utf8))
    }

    @MainActor func testLargeSourceCanUseHintWithFreshFullHashesOverlappingRender() async throws {
        let store = DirectAudioRenderHintStore(root: root), candidate = try hint()
        let saved = await store.save(candidate)
        XCTAssertTrue(saved)
        let handle = try FileHandle(forWritingTo: source)
        let largeSize: Int64 = 256 * 1_024 * 1_024 + 1
        try handle.truncate(atOffset: UInt64(largeSize))
        try handle.close()
        let consumed = await store.consume()
        let savedLarge = await store.save(candidate)
        XCTAssertNotNil(consumed, "Large originals no longer require a serialized source scan or size exclusion")
        XCTAssertTrue(savedLarge)
        let preparedLarge = try XCTUnwrap(candidate.prepareSourceRead())
        let combined = try await DirectAudioRenderCapture.perform(prepared: preparedLarge,
            render: { "host receipt" }, cleanup: { _ in XCTFail("Stable source must keep its successful receipt") })
        XCTAssertEqual(combined.receipt, "host receipt")
        XCTAssertEqual(combined.media.hashes.count, 1)
        XCTAssertEqual(combined.media.hashes[source]?.count, 64, "The large sparse original still receives a full SHA-256 read")
        XCTAssertEqual(candidate.sourceByteCount(), largeSize)
    }

    func testAliasesRemoteReferencesAndTooManySourcesCannotSeedCapture() async throws {
        let alias = root.appendingPathComponent("Alias.wav")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        for urls in [[alias], [try XCTUnwrap(URL(string: "file://remote/fixture.wav"))],
                     [try XCTUnwrap(URL(string: source.absoluteString + "?other=source"))],
                     [try XCTUnwrap(URL(string: source.absoluteString + "#fragment"))],
                     Array(repeating: source!, count: 257)] {
            let invalid = try hint(urls: urls)
            let saved = await DirectAudioRenderHintStore(root: root).save(invalid)
            let prepared = try invalid.prepareSourceRead(prepare: { _ in
                XCTFail("Invalid optional routing references must not be read")
                throw Failure.unavailable
            })
            XCTAssertFalse(saved)
            XCTAssertNil(prepared)
        }
    }

    func testManualCacheClearPreservesOriginalsProcessedAudioAndReceipts() async throws {
        let durable = root.appendingPathComponent("Processed Audio/\(UUID())/Processed-Audio.wav")
        let receipt = root.appendingPathComponent("Results/\(UUID())/Verification-Receipt.json")
        for url in [durable, receipt] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("preserve exactly".utf8).write(to: url)
        }
        let store = DirectAudioRenderHintStore(root: root)
        let saved = await store.save(try hint())
        XCTAssertTrue(saved)
        await store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("original source".utf8))
        for url in [durable, receipt] { XCTAssertEqual(try Data(contentsOf: url), Data("preserve exactly".utf8)) }
    }

    func testSymlinkAndHardLinkCacheDestinationsCannotAlterOriginalMedia() async throws {
        let store = DirectAudioRenderHintStore(root: root), candidate = try hint()
        for hardLink in [false, true] {
            if hardLink { try FileManager.default.linkItem(at: source, to: file) }
            else { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: source) }
            let saved = await store.save(candidate)
            let consumed = await store.consume()
            XCTAssertFalse(saved)
            XCTAssertNil(consumed)
            await store.clear()
            XCTAssertEqual(try Data(contentsOf: source), Data("original source".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            try FileManager.default.removeItem(at: file)
        }
        let alias = root.appendingPathComponent("Root Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let saved = await DirectAudioRenderHintStore(root: alias).save(candidate)
        let consumed = await DirectAudioRenderHintStore(root: alias).consume()
        XCTAssertFalse(saved)
        XCTAssertNil(consumed)
        await DirectAudioRenderHintStore(root: alias).clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
