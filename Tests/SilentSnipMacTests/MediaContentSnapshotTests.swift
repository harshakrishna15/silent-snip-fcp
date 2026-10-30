import Foundation
import XCTest
@testable import SilentSnipMac

final class MediaContentSnapshotTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SilentSnipMedia-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    @MainActor func testRepeatedSourcesAndAliasesHashOnceOffMainThread() async throws {
        let source = directory.appendingPathComponent("source.wav")
        let alias = directory.appendingPathComponent("alias.wav")
        try Data([1, 2, 3]).write(to: source)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let reads = Reads()
        let snapshot = try await MediaContentSnapshot.capture([source, source, alias]) { url in
            XCTAssertFalse(Thread.isMainThread, "Content reads must not freeze the effect/helper UI")
            reads.increment()
            return try MediaContentSnapshot.contentHash(at: url)
        }
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(snapshot.hashes.count, 1)
        try await snapshot.validate()
        let restored = try JSONDecoder().decode(MediaContentSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored, snapshot)
        XCTAssertTrue(restored.covers([alias, source, source]))
        XCTAssertFalse(restored.covers([source]), "A receipt must retain every original reference, including aliases")
        try await restored.validate()
    }

    func testSameSizeSameModificationDateReplacementStillRejects() async throws {
        let source = directory.appendingPathComponent("source.wav")
        try Data([1, 2, 3]).write(to: source)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let snapshot = try await MediaContentSnapshot.capture([source])
        try Data([3, 2, 1]).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: source.path)
        do { try await snapshot.validate(); XCTFail("Metadata alone cannot authorize edits") }
        catch ProjectAnalysisError.changedRenderArtifact { }
    }

    func testRepointedAliasRejectsEvenWhenOldSourceIsUnchanged() async throws {
        let source = directory.appendingPathComponent("source.wav")
        let other = directory.appendingPathComponent("other.wav")
        let alias = directory.appendingPathComponent("alias.wav")
        try Data([1]).write(to: source)
        try Data([2]).write(to: other)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let snapshot = try await MediaContentSnapshot.capture([alias])
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: other)
        do { try await snapshot.validate(); XCTFail("A source alias changed during analysis") }
        catch ProjectAnalysisError.changedRenderArtifact { }
    }

    func testCancelledCaptureDoesNotReadAnotherFile() async throws {
        let reads = Reads()
        let url = directory.appendingPathComponent("not-opened.wav")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MediaContentSnapshot.capture([url]) { _ in reads.increment(); return "unexpected" }
        }
        do { _ = try await task.value; XCTFail("Cancelled hashing must stop") }
        catch is CancellationError { }
        XCTAssertEqual(reads.count, 0)
    }

    func testConcurrentMutationBeforeHashReachesSourceIsRejected() async throws {
        let source = directory.appendingPathComponent("source.wav")
        try Data([1, 2, 3]).write(to: source)
        let prepared = try MediaContentSnapshot.prepareRead([source])
        try Data([3, 2, 1]).write(to: source)
        do { _ = try await MediaContentSnapshot.capture(prepared: prepared); XCTFail("Rendering must not race the initial source hash") }
        catch ProjectAnalysisError.changedRenderArtifact { }
    }

    func testMutationDuringHashIsRejected() async throws {
        let source = directory.appendingPathComponent("source.wav")
        try Data([1, 2, 3]).write(to: source)
        do {
            _ = try await MediaContentSnapshot.capture([source]) { url in
                try Data([3, 2, 1]).write(to: url)
                return try MediaContentSnapshot.contentHash(at: url)
            }
            XCTFail("The initial hash must cover a stable source")
        } catch ProjectAnalysisError.changedRenderArtifact { }
    }

    func testSourceChangedThenRestoredDuringRenderStillRejects() async throws {
        let source = directory.appendingPathComponent("source.wav")
        let data = Data([1, 2, 3])
        try data.write(to: source)
        let snapshot = try await MediaContentSnapshot.capture([source])
        try Data([3, 2, 1]).write(to: source)
        try data.write(to: source)
        XCTAssertEqual(try MediaContentSnapshot.contentHash(at: source), snapshot.hashes[source])
        do { try await snapshot.validate(); XCTFail("A transient source mutation can contaminate an overlapping render") }
        catch ProjectAnalysisError.changedRenderArtifact { }
    }

    func testLegacyRecoveryReceiptRetainsFullContentVerification() async throws {
        let source = directory.appendingPathComponent("source.wav")
        try Data([1, 2, 3]).write(to: source)
        let snapshot = try await MediaContentSnapshot.capture([source])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        object.removeValue(forKey: "stamps")
        let legacy = try JSONDecoder().decode(MediaContentSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        try await legacy.validate()
        try Data([3, 2, 1]).write(to: source)
        do { try await legacy.validate(); XCTFail("Legacy recovery must still hash source contents") }
        catch ProjectAnalysisError.changedRenderArtifact { }
    }

    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
}
