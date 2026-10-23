import Darwin
import Foundation
import XCTest
@testable import CutdownMac

final class StorageCleanupTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("StorageCleanupTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func write(_ relative: String, _ text: String = "original") throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    private func audio(_ text: String = "cache") throws -> URL {
        try write("Temporary/\(UUID())/Cached-Processed-Audio.wav", text)
    }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testAutomaticCleanupPreservesRecoveryOriginalsXMLAndUnknownFilesByteForByte() throws {
        let storage = StorageCleanup(root: root)
        let disposable = try audio()
        try storage.register(disposable, now: now.addingTimeInterval(-8 * 86400))
        let originals = try [write("Results/\(UUID())/Before-Cuts.fcpxml"),
            write("Results/\(UUID())/Silent Snip.fcpxml"), write("Media/Original.wav"),
            write("Temporary/\(UUID())/Cached-Processed-Audio.wav", "unregistered audio"),
            write("\(disposable.deletingLastPathComponent().path.dropFirst(root.path.count + 1))/Original.fcpxmld/Info.fcpxml")]
        let baseline = try originals.map { try Data(contentsOf: $0) }
        let report = storage.clean(now: now)
        XCTAssertEqual(report.removedFiles, 1)
        XCTAssertFalse(exists(disposable))
        for (url, expected) in zip(originals, baseline) { XCTAssertEqual(try Data(contentsOf: url), expected) }
    }

    func testFreshCacheIsKeptUntilManualCleanupAndActiveCacheIsAlwaysPinned() throws {
        let storage = StorageCleanup(root: root)
        let file = try audio()
        try storage.register(file, now: now)
        XCTAssertEqual(storage.clean(now: now).removedFiles, 0)
        XCTAssertEqual(storage.clean(manual: true, protectedURLs: [file], now: now).removedFiles, 0)
        XCTAssertTrue(exists(file))
        let report = storage.clean(manual: true, now: now)
        XCTAssertEqual(report.removedFiles, 1)
        XCTAssertEqual(report.removedBytes, 5)
    }

    func testByteCapEvictsOldestUnpinnedFileAndKeepsActiveFile() throws {
        let storage = StorageCleanup(root: root, byteLimit: 10)
        let first = try audio("123456"), second = try audio("abcdef"), active = try audio("active")
        try storage.register(active, now: now.addingTimeInterval(-3))
        try storage.register(first, now: now.addingTimeInterval(-2))
        try storage.register(second, now: now.addingTimeInterval(-1))
        let report = storage.clean(protectedURLs: [active], now: now)
        XCTAssertEqual(report.removedFiles, 2)
        XCTAssertTrue(exists(active))
        XCTAssertFalse(exists(first)); XCTAssertFalse(exists(second))
    }

    func testSameSizeContentEditWithRestoredTimestampIsNotDeleted() throws {
        let storage = StorageCleanup(root: root)
        let file = try audio("AAAA")
        try storage.register(file, now: now)
        var before = stat(); XCTAssertEqual(lstat(file.path, &before), 0)
        try Data("BBBB".utf8).write(to: file)
        var times = [before.st_atimespec, before.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, file.path, &times, 0), 0)
        XCTAssertEqual(storage.clean(manual: true, now: now).removedFiles, 0)
        XCTAssertEqual(try String(contentsOf: file), "BBBB")
    }

    func testReplacedSymlinkAndHardLinkedAudioArePreserved() throws {
        let storage = StorageCleanup(root: root)
        let source = try write("Media/Original.wav")
        for link in [false, true] {
            let file = try audio()
            try storage.register(file, now: now)
            try FileManager.default.removeItem(at: file)
            if link { try FileManager.default.linkItem(at: source, to: file) }
            else { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: source) }
            XCTAssertEqual(storage.clean(manual: true, now: now).removedFiles, 0)
            XCTAssertEqual(try String(contentsOf: source), "original")
            XCTAssertTrue(exists(file))
        }
    }

    func testSymlinkedJobDirectoryCannotRedirectCleanupToOriginalMedia() throws {
        let storage = StorageCleanup(root: root)
        let file = try audio()
        try storage.register(file, now: now)
        let job = file.deletingLastPathComponent()
        let saved = root.appendingPathComponent("Saved-Job")
        try FileManager.default.moveItem(at: job, to: saved)
        try FileManager.default.createSymbolicLink(at: job, withDestinationURL: saved)
        XCTAssertEqual(storage.clean(manual: true, now: now).removedFiles, 0)
        XCTAssertTrue(exists(saved.appendingPathComponent(file.lastPathComponent)))
    }

    func testSourceRecoveryAndOutsideLocationsCannotBeRegisteredOrForged() throws {
        let storage = StorageCleanup(root: root)
        for path in ["Results/\(UUID())/Before-Cuts.fcpxml", "Results/\(UUID())/Original.wav",
                     "Temporary/\(UUID())/Original.wav", "Share Inbox/\(UUID())/Before-Cuts.fcpxml"] {
            let file = try write(path)
            XCTAssertThrowsError(try storage.register(file))
        }
        let file = try audio()
        let id = try storage.register(file, now: now)
        let marker = root.appendingPathComponent("Cache Records/\(id).json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
        let recovery = try write("Results/\(json["job"]!)/Original.wav")
        json["category"] = "Results"; json["name"] = "Original.wav"
        try JSONSerialization.data(withJSONObject: json).write(to: marker)
        XCTAssertEqual(storage.clean(manual: true, now: now).removedFiles, 0)
        XCTAssertTrue(exists(file)); XCTAssertEqual(try String(contentsOf: recovery), "original")
    }

    func testRootAndRegistrySymlinksAreRejected() throws {
        let storage = StorageCleanup(root: root)
        let file = try audio()
        try storage.register(file, now: now)
        let alias = root.appendingPathComponent("Root-Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        XCTAssertEqual(StorageCleanup(root: alias).clean(manual: true, now: now).removedFiles, 0)
        let registry = root.appendingPathComponent("Cache Records")
        let moved = root.appendingPathComponent("Saved-Records")
        try FileManager.default.moveItem(at: registry, to: moved)
        try FileManager.default.createSymbolicLink(at: registry, withDestinationURL: moved)
        XCTAssertEqual(storage.clean(manual: true, now: now).removedFiles, 0)
        XCTAssertTrue(exists(file))
    }

    func testCompletedCleanupDropsOnlyItsMissingAudioRecord() throws {
        let storage = StorageCleanup(root: root)
        let file = try audio()
        let id = try storage.register(file, now: now)
        try FileManager.default.removeItem(at: file)
        let unknown = try write("Cache Records/notes.json", "important note")
        XCTAssertEqual(storage.clean(manual: true, now: now).removedFiles, 0)
        XCTAssertFalse(exists(root.appendingPathComponent("Cache Records/\(id).json")))
        XCTAssertTrue(exists(unknown))
    }

    func testLogsRemainBoundedAndOversizedEventsCannotExpandThem() throws {
        for _ in 0..<80 { BoundedShareLog.append(Data(repeating: 65, count: 65_536), root: root) }
        BoundedShareLog.append(Data(repeating: 66, count: 2_000_000), root: root)
        for name in ["events.jsonl", "events.previous.jsonl"] {
            let data = try Data(contentsOf: root.appendingPathComponent(name))
            XCTAssertLessThanOrEqual(data.count, BoundedShareLog.byteLimit)
        }
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("events.jsonl")).contains("oversized-log-entry-omitted"))
    }

    func testLogSymlinkCannotModifyAnOriginalFile() throws {
        let original = try write("Media/Original.wav")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("events.jsonl"), withDestinationURL: original)
        BoundedShareLog.append(Data("log entry".utf8), root: root)
        XCTAssertEqual(try String(contentsOf: original), "original")
    }

    @MainActor func testBusyOperationsPreventCleanupAndMemoryEviction() async {
        var busy = true, cleared = false
        let controller = StorageCleanupController(storage: StorageCleanup(root: root),
            isBusy: { busy }, protectedURLs: { [] }, clearMemory: { cleared = true })
        let skipped = await controller.clean(manual: true)
        XCTAssertNil(skipped); XCTAssertFalse(cleared); XCTAssertFalse(controller.isRunning)
        busy = false
        let completed = await controller.clean(manual: true)
        XCTAssertNotNil(completed); XCTAssertTrue(cleared)
    }

    @MainActor func testOperationWaitsForCleanupAndOverlappingSweepsAreRejected() async throws {
        let started = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
        let controller = StorageCleanupController(storage: StorageCleanup(root: root),
            isBusy: { false }, protectedURLs: { [] }, clearMemory: {})
        controller.runner = { _, _ in
            started.signal()
            _ = finish.wait(timeout: .now() + 3)
            return StorageCleanupReport()
        }
        let cleaning = Task { await controller.clean(manual: false) }
        while !controller.isRunning { await Task.yield() }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        var operationStarted = false
        let operation = Task {
            await controller.waitUntilIdle()
            XCTAssertFalse(controller.isRunning, "A resumed operation must immediately be allowed to Share.")
            operationStarted = true
        }
        await Task.yield()
        XCTAssertFalse(operationStarted)
        let overlapping = await controller.clean(manual: true)
        XCTAssertNil(overlapping)
        finish.signal()
        _ = await cleaning.value
        await operation.value
        XCTAssertTrue(operationStarted); XCTAssertFalse(controller.isRunning)
    }

    func testOversizedLegacyLogIsReducedInsteadOfCopiedIntoTheBackup() throws {
        try Data(repeating: 65, count: 2 * BoundedShareLog.byteLimit).write(to: root.appendingPathComponent("events.jsonl"))
        BoundedShareLog.append(Data("latest event\n".utf8), root: root)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("events.jsonl")), "latest event\n")
        XCTAssertFalse(exists(root.appendingPathComponent("events.previous.jsonl")))
    }

    func testCancelledMaintenanceDoesNotDeletePendingFiles() async throws {
        let storage = StorageCleanup(root: root), file = try audio()
        try storage.register(file, now: now)
        let started = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        let cleanup = Task.detached {
            started.signal()
            _ = proceed.wait(timeout: .now() + 3)
            return storage.clean(manual: true)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        cleanup.cancel(); proceed.signal()
        let report = await cleanup.value
        XCTAssertTrue(report.cancelled)
        XCTAssertEqual(report.removedFiles, 0); XCTAssertTrue(exists(file))
    }
}
