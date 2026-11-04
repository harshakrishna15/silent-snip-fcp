import Darwin
import Foundation
import XCTest
@testable import SilentSnipMac

final class ApplyAudioRenderCaptureTests: XCTestCase {
    private var directory: URL!
    private var source: URL!
    private enum Failure: Error { case hashTimeout }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ApplyRenderCapture-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("Original.wav")
        try Data([1, 2, 3, 4]).write(to: source)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    @MainActor func testHistoricalSourceHashOverlapsOneRenderAndMustJoinBeforeAcceptance() async throws {
        let snapshot = try await MediaContentSnapshot.capture([source])
        let hashing = expectation(description: "source hash started")
        let rendering = expectation(description: "native render started")
        let gate = HashGate()
        var renders = 0, cleanups = 0
        var returned = false
        let operation = Task { @MainActor in
            let result = try await ApplyAudioRenderCapture.perform(sourceMedia: snapshot, hash: { url in
                XCTAssertFalse(Thread.isMainThread)
                hashing.fulfill()
                guard gate.wait() else { throw Failure.hashTimeout }
                return try MediaContentSnapshot.contentHash(at: url)
            }, render: {
                renders += 1
                rendering.fulfill()
                return "single native receipt"
            }, cleanup: { _ in cleanups += 1 })
            returned = true
            return result
        }
        await fulfillment(of: [hashing, rendering], timeout: 2)
        XCTAssertEqual(renders, 1)
        XCTAssertFalse(returned, "The native output cannot be accepted before exact historical content matches")
        gate.open()
        let result = try await operation.value
        XCTAssertTrue(result.overlappedSourceValidation)
        XCTAssertEqual(result.receipt, "single native receipt")
        try result.validateSourceReferences([source])
        XCTAssertEqual(cleanups, 0, "The caller now owns this successfully validated receipt")
    }

    @MainActor func testChangedHistoricalStampStopsBeforeAnyHashOrHostInput() async throws {
        let snapshot = try await MediaContentSnapshot.capture([source])
        try Data([4, 3, 2, 1]).write(to: source)
        var renders = 0
        do {
            _ = try await ApplyAudioRenderCapture.perform(sourceMedia: snapshot, hash: { _ in
                XCTFail("A changed historical identity must fail before dispatch or a new scan")
                return "unexpected"
            }, render: {
                renders += 1
                return "unexpected"
            }, cleanup: { _ in XCTFail("No host receipt was created") })
            XCTFail("Changed source evidence must stop Apply before native input")
        } catch ProjectAnalysisError.changedRenderArtifact { }
        XCTAssertEqual(renders, 0)
    }

    @MainActor func testAliasPermutationStopsBeforeAnyHostInputWithUnchangedCanonicalHashes() async throws {
        let other = directory.appendingPathComponent("Other.wav")
        try Data([5, 6, 7, 8]).write(to: other)
        let firstAlias = directory.appendingPathComponent("FirstAlias.wav")
        let secondAlias = directory.appendingPathComponent("SecondAlias.wav")
        try FileManager.default.createSymbolicLink(at: firstAlias, withDestinationURL: source)
        try FileManager.default.createSymbolicLink(at: secondAlias, withDestinationURL: other)
        let snapshot = try await MediaContentSnapshot.capture([firstAlias, secondAlias])
        try FileManager.default.removeItem(at: firstAlias)
        try FileManager.default.removeItem(at: secondAlias)
        try FileManager.default.createSymbolicLink(at: firstAlias, withDestinationURL: other)
        try FileManager.default.createSymbolicLink(at: secondAlias, withDestinationURL: source)
        let swapped = try await MediaContentSnapshot.capture([firstAlias, secondAlias])
        XCTAssertEqual(snapshot.hashes, swapped.hashes)
        var renders = 0
        do {
            _ = try await ApplyAudioRenderCapture.perform(sourceMedia: snapshot, render: {
                renders += 1
                return 42
            }, cleanup: { _ in XCTFail("No host receipt was created") })
            XCTFail("Historical source associations must match before dispatch")
        } catch ProjectAnalysisError.changedRenderArtifact { }
        XCTAssertEqual(renders, 0)
    }

    @MainActor func testExactHashMismatchAfterDispatchCleansReceiptWithoutRetry() async throws {
        let snapshot = try await MediaContentSnapshot.capture([source])
        var renders = 0, cleanups = 0
        do {
            _ = try await ApplyAudioRenderCapture.perform(sourceMedia: snapshot,
                hash: { _ in "different full content despite matching stamps" }, render: {
                    renders += 1
                    return 42
                }, cleanup: { receipt in
                    XCTAssertEqual(receipt, 42)
                    cleanups += 1
                })
            XCTFail("Metadata cannot replace the exact historical full-content comparison")
        } catch ProjectAnalysisError.changedRenderArtifact { }
        XCTAssertEqual(renders, 1)
        XCTAssertEqual(cleanups, 1)
    }

    @MainActor func testRestoredMutationDuringRenderCleansReceiptWithoutRetry() async throws {
        let sourceURL = try XCTUnwrap(source)
        let original = try Data(contentsOf: sourceURL)
        let snapshot = try await MediaContentSnapshot.capture([sourceURL])
        let before = try MediaContentSnapshot.FileStamp(sourceURL)
        let hashed = expectation(description: "source contents read")
        var renders = 0, cleanups = 0
        do {
            _ = try await ApplyAudioRenderCapture.perform(sourceMedia: snapshot, hash: { url in
                let digest = try MediaContentSnapshot.contentHash(at: url)
                hashed.fulfill()
                return digest
            }, render: {
                renders += 1
                await self.fulfillment(of: [hashed], timeout: 2)
                try self.changeAndRestore(sourceURL, original: original, stamp: before)
                return "owned receipt"
            }, cleanup: { _ in cleanups += 1 })
            XCTFail("Exact original bytes at the end cannot erase render-time mutation evidence")
        } catch ProjectAnalysisError.changedRenderArtifact { }
        XCTAssertEqual(renders, 1)
        XCTAssertEqual(cleanups, 1)
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
    }

    @MainActor func testOriginalGuardCoversLaterTargetMeasurementAndExactDeliveredReferences() async throws {
        let original = try Data(contentsOf: source)
        let snapshot = try await MediaContentSnapshot.capture([source])
        let before = try MediaContentSnapshot.FileStamp(source)
        var renders = 0
        let result = try await ApplyAudioRenderCapture.perform(sourceMedia: snapshot, render: {
            renders += 1
            return 42
        }, cleanup: { _ in XCTFail("The validated receipt is transferred to the caller") })
        let other = directory.appendingPathComponent("EqualButDifferentSource.wav")
        try original.write(to: other)
        XCTAssertEqual(try MediaContentSnapshot.contentHash(at: other), snapshot.hashes[source])
        for references: [URL] in [[], [other], [source, other]] {
            XCTAssertThrowsError(try result.validateSourceReferences(references), "Missing, substituted or added source references must fail")
        }
        try result.validateSourceReferences([source, source])
        // Simulate a transient source change in the later target-measurement
        // phase, after the full mix/hash operation has already succeeded.
        try changeAndRestore(source, original: original, stamp: before)
        XCTAssertThrowsError(try result.readGuard.validate())
        XCTAssertThrowsError(try result.validateSourceReferences([source]))
        XCTAssertEqual(renders, 1)
    }

    @MainActor func testLegacyDirectReceiptsKeepFullHashPreflightAndCannotGainOverlap() async throws {
        let snapshot = try await MediaContentSnapshot.capture([source])
        for fields in [["stamps"], ["canonicalURLs"], ["canonicalURLs", "stamps"]] {
            let legacy = try removingFields(fields, from: snapshot)
            XCTAssertNil(try legacy.prepareValidationRead())
            let result = try await ApplyAudioRenderCapture.perform(sourceMedia: legacy, hash: { _ in
                XCTFail("Legacy evidence cannot use the concurrent-hash route")
                return "unexpected"
            }, render: { "legacy full-hash preflight completed" }, cleanup: { _ in XCTFail("Validated receipt was transferred") })
            XCTAssertFalse(result.overlappedSourceValidation)
            try result.validateSourceReferences([source])
        }
        let legacy = try removingFields(["canonicalURLs", "stamps"], from: snapshot)
        try Data([4, 3, 2, 1]).write(to: source)
        var renders = 0
        do {
            _ = try await ApplyAudioRenderCapture.perform(sourceMedia: legacy, render: {
                renders += 1
                return 42
            }, cleanup: { _ in XCTFail("No receipt was created") })
            XCTFail("Legacy full hashes must reject changed content before input even without historical stamps")
        } catch ProjectAnalysisError.changedRenderArtifact { }
        XCTAssertEqual(renders, 0)
    }

    @MainActor func testAlreadyCancelledSourcePhaseSendsNoHostInput() async throws {
        let snapshot = try await MediaContentSnapshot.capture([source])
        var renders = 0
        let operation = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ApplyAudioRenderCapture.perform(sourceMedia: snapshot, hash: { _ in
                XCTFail("Cancelled preflight must not start a source read")
                return "unexpected"
            }, render: {
                renders += 1
                return 42
            }, cleanup: { _ in XCTFail("No receipt was created") })
        }
        do { _ = try await operation.value; XCTFail("Cancelled Apply must stop before host input") }
        catch is CancellationError { }
        XCTAssertEqual(renders, 0)
    }

    private func changeAndRestore(_ url: URL, original: Data, stamp: MediaContentSnapshot.FileStamp) throws {
        let file = try FileHandle(forWritingTo: url)
        try file.write(contentsOf: Data(original.reversed()))
        try file.seek(toOffset: 0)
        try file.write(contentsOf: original)
        try file.close()
        var current = stat()
        XCTAssertEqual(lstat(url.path, &current), 0)
        var times = [current.st_atimespec,
            timespec(tv_sec: stamp.modifiedSeconds, tv_nsec: stamp.modifiedNanoseconds)]
        XCTAssertEqual(utimensat(AT_FDCWD, url.path, &times, 0), 0)
        let after = try MediaContentSnapshot.FileStamp(url)
        XCTAssertTrue(stamp.sameIdentitySizeAndModification(as: after))
        XCTAssertNotEqual(stamp, after, "ctime must retain evidence of the transient source mutation")
    }

    private func removingFields(_ fields: [String], from snapshot: MediaContentSnapshot) throws -> MediaContentSnapshot {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        for field in fields { object.removeValue(forKey: field) }
        return try JSONDecoder().decode(MediaContentSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private final class HashGate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        func wait() -> Bool { semaphore.wait(timeout: .now() + 3) == .success }
        func open() { semaphore.signal() }
    }
}
