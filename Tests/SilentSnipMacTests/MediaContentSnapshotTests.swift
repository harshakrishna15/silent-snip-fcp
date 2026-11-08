import Foundation
import Darwin
import XCTest
@testable import SilentSnipMac

final class MediaContentSnapshotTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SilentSnipMedia-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testFileStampRejectsNonregularSourcesBeforeReading() throws {
        XCTAssertThrowsError(try MediaContentSnapshot.FileStamp(directory)) {
            guard case ProjectAnalysisError.changedRenderArtifact = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        try withFiniteFIFO { url in
            XCTAssertThrowsError(try MediaContentSnapshot.FileStamp(url)) {
                guard case ProjectAnalysisError.changedRenderArtifact = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
        }
    }

    func testContentHashRejectsPipeInsteadOfWaitingForAudio() throws {
        try withFiniteFIFO { url in
            XCTAssertThrowsError(try MediaContentSnapshot.contentHash(at: url)) {
                guard case ProjectAnalysisError.changedRenderArtifact = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
        }
    }

    func testSourceReplacedByPipeStopsHistoricalValidation() async throws {
        let source = directory.appendingPathComponent("replaced.wav")
        try Data([1, 2, 3]).write(to: source)
        let snapshot = try await MediaContentSnapshot.capture([source])
        try FileManager.default.removeItem(at: source)
        try withFiniteFIFO(at: source) { _ in
            // The historical preflight rejects this before a host export or a
            // content read, without adopting the replacement's identity.
            XCTAssertThrowsError(try snapshot.prepareValidationRead()) {
                guard case ProjectAnalysisError.changedRenderArtifact = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
        }
    }

    /// A temporary writer makes regressions fail with an assertion rather than
    /// hanging the test runner in an old blocking open/read implementation.
    private func withFiniteFIFO(at path: URL? = nil, _ body: (URL) throws -> Void) throws {
        let url = path ?? directory.appendingPathComponent("pipe-\(UUID()).wav")
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
        let keeper = open(url.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard keeper >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let released = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            close(keeper)
            released.signal()
        }
        defer { XCTAssertEqual(released.wait(timeout: .now() + 1), .success) }
        try body(url)
    }

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

    func testPermutedAliasesRejectEvenWhenAllCanonicalHashesAndStampsAreUnchanged() async throws {
        let first = directory.appendingPathComponent("first.wav")
        let second = directory.appendingPathComponent("second.wav")
        let firstAlias = directory.appendingPathComponent("first-alias.wav")
        let secondAlias = directory.appendingPathComponent("second-alias.wav")
        try Data([1, 2, 3]).write(to: first)
        try Data([4, 5, 6]).write(to: second)
        try FileManager.default.createSymbolicLink(at: firstAlias, withDestinationURL: first)
        try FileManager.default.createSymbolicLink(at: secondAlias, withDestinationURL: second)
        let originals = [firstAlias, secondAlias]
        let snapshot = try await MediaContentSnapshot.capture(originals)
        let before = try MediaContentSnapshot.prepareRead(originals)

        try FileManager.default.removeItem(at: firstAlias)
        try FileManager.default.removeItem(at: secondAlias)
        try FileManager.default.createSymbolicLink(at: firstAlias, withDestinationURL: second)
        try FileManager.default.createSymbolicLink(at: secondAlias, withDestinationURL: first)
        let swapped = try await MediaContentSnapshot.capture(originals)
        let after = try MediaContentSnapshot.prepareRead(originals)
        XCTAssertEqual(snapshot.hashes, swapped.hashes, "Unordered content hashes cannot detect an alias permutation")
        XCTAssertEqual(before.stamps, after.stamps, "Neither canonical source was modified")
        XCTAssertNotEqual(before.canonicalURLs, after.canonicalURLs)
        XCTAssertNotEqual(snapshot, swapped, "A snapshot must bind each original reference to its original file")

        do { try await snapshot.validate(); XCTFail("An alias permutation changed which source each clip plays") }
        catch ProjectAnalysisError.changedRenderArtifact { }
        do { _ = try await snapshot.validatedForImport(renderedAudio: nil); XCTFail("Import must preserve historical reference associations") }
        catch ProjectAnalysisError.changedRenderArtifact { }
        XCTAssertThrowsError(try snapshot.restricting(to: [firstAlias])) {
            guard case ProjectAnalysisError.changedRenderArtifact = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: first), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: second), Data([4, 5, 6]))
    }

    func testLegacyAliasesWithoutHistoricalMappingRequireFreshAnalysis() async throws {
        let source = directory.appendingPathComponent("source.wav")
        let alias = directory.appendingPathComponent("alias.wav")
        try Data([1, 2, 3]).write(to: source)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let snapshot = try await MediaContentSnapshot.capture([alias])
        let legacy = try removingFields(["canonicalURLs"], from: snapshot)

        do { try await legacy.validate(); XCTFail("Fresh hashes cannot prove an unrecorded historical alias association") }
        catch ProjectAnalysisError.changedRenderArtifact { }
        do { _ = try await legacy.validatedForImport(renderedAudio: nil); XCTFail("Legacy aliases cannot adopt their current targets") }
        catch ProjectAnalysisError.changedRenderArtifact { }
        XCTAssertThrowsError(try legacy.restricting(to: [alias]))
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
    }

    func testLegacyCanonicalReferencesInferIdentityAndRetainFullContentChecks() async throws {
        let source = directory.resolvingSymlinksInPath().appendingPathComponent("source.wav")
        try Data([1, 2, 3]).write(to: source)
        let snapshot = try await MediaContentSnapshot.capture([source])
        let legacy = try removingFields(["canonicalURLs", "stamps"], from: snapshot)
        try await legacy.validate()
        let imported = try await legacy.validatedForImport(renderedAudio: nil)
        XCTAssertEqual(imported.hashes, snapshot.hashes)
        let restricted = try legacy.restricting(to: [source])
        try await restricted.validate()

        try Data([3, 2, 1]).write(to: source)
        do { try await legacy.validate(); XCTFail("Legacy canonical receipts must still compare full hashes") }
        catch ProjectAnalysisError.changedRenderArtifact { }
        do { _ = try await legacy.validatedForImport(renderedAudio: nil); XCTFail("Legacy import must still compare full hashes") }
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

    func testAdditionalCaptureCannotRebindHistoricalSnapshotToANewerGuard() async throws {
        let source = directory.appendingPathComponent("source.wav")
        let durable = directory.appendingPathComponent("durable.wav")
        try Data([1, 2, 3]).write(to: source)
        try Data([4, 5, 6]).write(to: durable)
        let snapshot = try await MediaContentSnapshot.capture([source])
        try Data([3, 2, 1]).write(to: source)
        let newerGuard = try MediaContentSnapshot.prepareRead([source])
        do {
            _ = try await snapshot.capturingAdditionalFiles([durable.resolvingSymlinksInPath()], protectedBy: newerGuard,
                hash: { _ in XCTFail("A newer metadata guard cannot stand in for the completed original read"); return "unexpected" })
            XCTFail("Composition must bind the exact original guard, including historical mutation stamps")
        } catch ProjectAnalysisError.changedRenderArtifact { }
    }

    func testAdditionalCaptureRejectsDifferentGuardReferencesWithEqualSourceContents() async throws {
        let source = directory.appendingPathComponent("source.wav")
        let equalOther = directory.appendingPathComponent("equal-other.wav")
        let durable = directory.appendingPathComponent("durable.wav")
        try Data([1, 2, 3]).write(to: source)
        try Data([1, 2, 3]).write(to: equalOther)
        try Data([4, 5, 6]).write(to: durable)
        let snapshot = try await MediaContentSnapshot.capture([source])
        let otherGuard = try MediaContentSnapshot.prepareRead([equalOther])
        do {
            _ = try await snapshot.capturingAdditionalFiles([durable.resolvingSymlinksInPath()], protectedBy: otherGuard,
                hash: { _ in XCTFail("Exact original URLs and associations must match before added reads"); return "unexpected" })
            XCTFail("Matching content at another URL cannot replace the source phase's identity")
        } catch ProjectAnalysisError.changedRenderArtifact { }
    }

    private func removingFields(_ fields: [String], from snapshot: MediaContentSnapshot) throws -> MediaContentSnapshot {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        for field in fields { object.removeValue(forKey: field) }
        return try JSONDecoder().decode(MediaContentSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
}
