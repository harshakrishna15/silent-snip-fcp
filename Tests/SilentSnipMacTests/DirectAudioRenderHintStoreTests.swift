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
        let prepared = try await recovered.prepareSourceMedia()
        let fresh = try XCTUnwrap(prepared)
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
        let unavailable = try await candidate.prepareSourceMedia(hash: { _ in throw Failure.unavailable })
        XCTAssertNil(unavailable)
        try FileManager.default.removeItem(at: source)
        let missing = try await candidate.prepareSourceMedia()
        XCTAssertNil(missing)
        for url in [root!, root.appendingPathComponent("pipe")] {
            if url != root { XCTAssertEqual(mkfifo(url.path, 0o600), 0) }
            let invalid = try hint(urls: [url])
            let prepared = try await invalid.prepareSourceMedia(hash: { _ in
                XCTFail("An optional hint must not open a directory, FIFO or device")
                return "unreachable"
            })
            let saved = await DirectAudioRenderHintStore(root: root).save(invalid)
            XCTAssertNil(prepared)
            XCTAssertFalse(saved)
        }
    }

    func testPreflightPreservesCancellationAndRejectsSourceMutation() async throws {
        let candidate = try hint()
        do {
            _ = try await candidate.prepareSourceMedia(hash: { _ in throw CancellationError() })
            XCTFail("Cancellation must not become an ordinary XML fallback")
        } catch is CancellationError { }
        let mutated = try await candidate.prepareSourceMedia(hash: { url in
            try Data("mutated while hashing".utf8).write(to: url)
            return try MediaContentSnapshot.contentHash(at: url)
        })
        XCTAssertNil(mutated)
    }

    func testCorruptUnknownSchemaAndOversizedRecordsAreOptionalCacheMisses() async throws {
        let store = DirectAudioRenderHintStore(root: root)
        let saved = await store.save(try hint())
        XCTAssertTrue(saved)
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var unknown = valid; unknown["version"] = 2
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

    func testLargeSourceRetainsOrdinaryXMLAndOverlappedHashingRoute() async throws {
        let store = DirectAudioRenderHintStore(root: root), candidate = try hint()
        let saved = await store.save(candidate)
        XCTAssertTrue(saved)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(DirectAudioRenderHintStore.maximumSourceBytes + 1))
        try handle.close()
        let consumed = await store.consume()
        let savedLarge = await store.save(candidate)
        // The process-local hint bypasses store.consume(), and may also refer
        // to media that grew after capture. Its actual preflight must enforce
        // the same cap before invoking the content reader.
        let preparedLarge = try await candidate.prepareSourceMedia(hash: { _ in
            XCTFail("A large process-local or grown source must not be hashed before native rendering")
            return "unreachable"
        })
        XCTAssertNil(consumed, "A source that grew after storage must not serialize a large hash before native rendering")
        XCTAssertFalse(savedLarge)
        XCTAssertNil(preparedLarge)
        XCTAssertEqual(candidate.sourceByteCount(), DirectAudioRenderHintStore.maximumSourceBytes + 1)
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
            let prepared = try await invalid.prepareSourceMedia(hash: { _ in
                XCTFail("Invalid optional routing references must not be read")
                return "unreachable"
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
