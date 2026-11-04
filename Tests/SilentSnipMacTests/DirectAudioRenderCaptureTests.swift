import Darwin
import Foundation
import XCTest
@testable import SilentSnipMac

final class DirectAudioRenderCaptureTests: XCTestCase {
    private var directory: URL!
    private var source: URL!
    private enum Failure: Error { case unavailable }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("RenderCapture-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("Original.wav")
        try Data([1, 2, 3, 4]).write(to: source)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    @MainActor func testRenderStartsWhileHashIsBlockedAndCannotReturnBeforeHashJoins() async throws {
        let prepared = try MediaContentSnapshot.prepareRead([source])
        let hashing = expectation(description: "source capture started")
        let rendering = expectation(description: "host render started")
        let releaseHash = AsyncGate()
        var renders = 0, cleanups = 0
        var returned = false
        let operation = Task { @MainActor in
            let combined = try await DirectAudioRenderCapture.perform(prepared: prepared, captureSources: { prepared in
                XCTAssertFalse(Thread.isMainThread, "Full source reads must leave the helper UI responsive")
                hashing.fulfill()
                await releaseHash.wait()
                return try await MediaContentSnapshot.capture(prepared: prepared)
            }, render: {
                renders += 1
                rendering.fulfill()
                return "single host receipt"
            }, cleanup: { _ in cleanups += 1 })
            returned = true
            return combined
        }
        await fulfillment(of: [hashing, rendering], timeout: 2)
        XCTAssertEqual(renders, 1, "The host must start before a slow source scan finishes")
        XCTAssertFalse(returned, "PCM/XML must not be accepted while full hashes remain pending")
        await releaseHash.open()
        let combined = try await operation.value
        let remainingWaiters = await releaseHash.waitingCount
        XCTAssertEqual(remainingWaiters, 0)
        XCTAssertEqual(combined.receipt, "single host receipt")
        XCTAssertTrue(combined.media.covers([source]))
        XCTAssertTrue(returned)
        XCTAssertEqual(cleanups, 0)
    }

    @MainActor func testSourceChangedThenRestoredAfterHashBeforeRenderCompletesStillRejects() async throws {
        let original = try Data(contentsOf: source)
        let sourceURL = try XCTUnwrap(source)
        let prepared = try MediaContentSnapshot.prepareRead([sourceURL])
        let before = try XCTUnwrap(prepared.stamps[sourceURL])
        let hashed = expectation(description: "complete source hash and snapshot validation finished")
        var renders = 0, cleanups = 0
        do {
            _ = try await DirectAudioRenderCapture.perform(prepared: prepared, captureSources: { prepared in
                let media = try await MediaContentSnapshot.capture(prepared: prepared)
                // The entire snapshot, including its post-read guard, has
                // finished before the simulated host touches the source.
                hashed.fulfill()
                return media
            }, render: {
                renders += 1
                await self.fulfillment(of: [hashed], timeout: 2)
                let file = try FileHandle(forWritingTo: sourceURL)
                try file.write(contentsOf: Data([4, 3, 2, 1]))
                try file.seek(toOffset: 0)
                try file.write(contentsOf: original)
                try file.close()
                var current = stat()
                XCTAssertEqual(lstat(sourceURL.path, &current), 0)
                var times = [current.st_atimespec,
                    timespec(tv_sec: before.modifiedSeconds, tv_nsec: before.modifiedNanoseconds)]
                XCTAssertEqual(utimensat(AT_FDCWD, sourceURL.path, &times, 0), 0)
                let after = try MediaContentSnapshot.FileStamp(sourceURL)
                XCTAssertTrue(before.sameIdentitySizeAndModification(as: after), "Identity, size and exact mtime were restored")
                XCTAssertNotEqual(before, after, "ctime must retain evidence of the transient render-time change")
                return "owned receipt"
            }, cleanup: { receipt in
                XCTAssertEqual(receipt, "owned receipt")
                cleanups += 1
            })
            XCTFail("A completed hash cannot authorize a later render-time mutation")
        } catch ProjectAnalysisError.changedRenderArtifact { }
        XCTAssertEqual(renders, 1)
        XCTAssertEqual(cleanups, 1, "The delivered render must be disposed instead of retrying Share")
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
    }

    @MainActor func testSourceHashFailureAfterDispatchCleansDeliveredReceiptAndNeverRetries() async throws {
        let prepared = try MediaContentSnapshot.prepareRead([source])
        let rendered = AsyncGate()
        var renders = 0, cleanups = 0
        do {
            _ = try await DirectAudioRenderCapture.perform(prepared: prepared, captureSources: { _ in
                await rendered.wait()
                throw Failure.unavailable
            }, render: {
                renders += 1
                await rendered.open()
                return 42
            }, cleanup: { receipt in
                XCTAssertEqual(receipt, 42)
                cleanups += 1
            })
            XCTFail("A post-dispatch hash failure must stop the exchange")
        } catch Failure.unavailable { }
        let remainingWaiters = await rendered.waitingCount
        XCTAssertEqual(remainingWaiters, 0)
        XCTAssertEqual(renders, 1)
        XCTAssertEqual(cleanups, 1)
    }

    @MainActor func testMutationDuringConcurrentHashCleansRenderInsteadOfFallingBack() async throws {
        let prepared = try MediaContentSnapshot.prepareRead([source])
        let sourceURL = try XCTUnwrap(source)
        var renders = 0, cleanups = 0
        do {
            _ = try await DirectAudioRenderCapture.perform(prepared: prepared, captureSources: { prepared in
                try await MediaContentSnapshot.capture(prepared: prepared, hash: { url in
                    try Data([4, 3, 2, 1]).write(to: url)
                    return try MediaContentSnapshot.contentHash(at: url)
                })
            }, render: {
                renders += 1
                return 17
            }, cleanup: { _ in cleanups += 1 })
            XCTFail("Mutation during a concurrent content scan must stop")
        } catch ProjectAnalysisError.changedRenderArtifact { }
        XCTAssertEqual(renders, 1)
        XCTAssertEqual(cleanups, 1)
        XCTAssertEqual(try Data(contentsOf: sourceURL), Data([4, 3, 2, 1]))
    }

    @MainActor func testCancellationWhileHashPendingJoinsChildAndCleansReceipt() async throws {
        let prepared = try MediaContentSnapshot.prepareRead([source])
        let hashing = expectation(description: "source read is in progress")
        let rendering = expectation(description: "host delivered its receipt")
        let sourceExited = CompletionFlag()
        let releaseHash = AsyncGate()
        var renders = 0, cleanups = 0
        let operation = Task { @MainActor in
            try await DirectAudioRenderCapture.perform(prepared: prepared, captureSources: { prepared in
                defer { sourceExited.mark() }
                hashing.fulfill()
                await releaseHash.wait()
                try Task.checkCancellation()
                return try await MediaContentSnapshot.capture(prepared: prepared)
            }, render: {
                renders += 1
                rendering.fulfill()
                return "owned receipt"
            }, cleanup: { _ in cleanups += 1 })
        }
        await fulfillment(of: [hashing, rendering], timeout: 2)
        operation.cancel()
        // Opening is explicit even after cancellation: checked continuations
        // must all resume before the structured operation is drained.
        await releaseHash.open()
        do { _ = try await operation.value; XCTFail("Cancellation must stop capture") }
        catch is CancellationError { }
        let remainingWaiters = await releaseHash.waitingCount
        XCTAssertEqual(remainingWaiters, 0)
        XCTAssertTrue(sourceExited.isSet, "The structured source read must exit before its parent returns cancellation")
        XCTAssertEqual(renders, 1)
        XCTAssertEqual(cleanups, 1)
    }

    @MainActor func testAlreadyCancelledCaptureSendsNoHostInput() async throws {
        let prepared = try MediaContentSnapshot.prepareRead([source])
        var renders = 0
        let operation = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DirectAudioRenderCapture.perform(prepared: prepared, render: {
                renders += 1
                return "unexpected"
            }, cleanup: { _ in XCTFail("No receipt should have been produced") })
        }
        do { _ = try await operation.value; XCTFail("A cancelled exchange must not start") }
        catch is CancellationError { }
        XCTAssertEqual(renders, 0)
    }

    @MainActor func testRenderFailureCancelsAndJoinsSourceChildBeforeReturningOriginalError() async throws {
        let prepared = try MediaContentSnapshot.prepareRead([source])
        let hashing = expectation(description: "source child started")
        let sourceExited = CompletionFlag()
        var renders = 0
        do {
            _ = try await DirectAudioRenderCapture.perform(prepared: prepared, captureSources: { prepared in
                defer { sourceExited.mark() }
                hashing.fulfill()
                try await Task.sleep(for: .seconds(5))
                XCTFail("A failed render must cancel its source child instead of leaving it running")
                return try await MediaContentSnapshot.capture(prepared: prepared)
            }, render: {
                renders += 1
                await self.fulfillment(of: [hashing], timeout: 2)
                throw Failure.unavailable
            }, cleanup: { (_: String) in XCTFail("The failed render returned no receipt to own") })
            XCTFail("The original render error must propagate")
        } catch Failure.unavailable { }
        XCTAssertEqual(renders, 1)
        XCTAssertTrue(sourceExited.isSet, "Structured hashing must be drained before render failure returns")
    }

    private actor AsyncGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }

        var waitingCount: Int { waiters.count }
    }

    private final class CompletionFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func mark() { lock.lock(); defer { lock.unlock() }; value = true }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
}
