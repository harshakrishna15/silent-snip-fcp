import Darwin
import XCTest
@testable import SilentSnipMac

final class CompletedXMLSnapshotTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func file(_ text: String = "<complete/>") throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".fcpxml")
        try Data(text.utf8).write(to: url); return url
    }

    func testNativeClosedFileCompletesImmediatelyAndOpenWriterCannotPass() throws {
        let url = try file()
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        switch CompletedXMLSnapshot.read(url, validate: { _ in true }) {
        case .unavailable: throw XCTSkip("Kernel exclusive-open check unavailable; fallback is tested separately")
        case .inUse: break
        default: XCTFail("A producer still has this file open")
        }
        try writer.close()
        let start = ProcessInfo.processInfo.systemUptime
        guard case .snapshot(let snapshot) = CompletedXMLSnapshot.read(url, validate: { _ in true }) else {
            return XCTFail("Closed complete XML must use the fast path")
        }
        XCTAssertEqual(snapshot.data, Data("<complete/>".utf8))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
        XCTAssertTrue(snapshot.isCurrent(at: url))
    }

    func testIncompleteMissingEmptySymlinkAndHardlinkAreNotFastCompleted() throws {
        let url = try file()
        guard case .incomplete = CompletedXMLSnapshot.read(url, probe: { _ in .exclusive }, validate: { _ in false }) else {
            return XCTFail("Invalid XML cannot complete")
        }
        for input in [root.appendingPathComponent("missing"), try file("")] {
            if case .snapshot = CompletedXMLSnapshot.read(input, probe: { _ in .exclusive }, validate: { _ in true }) { XCTFail("Missing/empty file") }
        }
        let alias = root.appendingPathComponent("alias.fcpxml")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        if case .snapshot = CompletedXMLSnapshot.read(alias, probe: { _ in .exclusive }, validate: { _ in true }) { XCTFail("Symlink") }
        let link = root.appendingPathComponent("link.fcpxml")
        try FileManager.default.linkItem(at: url, to: link)
        if case .snapshot = CompletedXMLSnapshot.read(url, probe: { _ in .exclusive }, validate: { _ in true }) { XCTFail("Hardlink") }
    }

    func testChangedBytesOrReplacedPathDuringValidationCannotFinish() throws {
        for replace in [false, true] {
            let url = try file()
            let result = CompletedXMLSnapshot.read(url, probe: { _ in .exclusive }, validate: { _ in
                if replace { try? FileManager.default.removeItem(at: url) }
                try? Data("<changed-version/>".utf8).write(to: url)
                return true
            })
            if case .snapshot = result { XCTFail("Changed input cannot inherit completion evidence") }
        }
    }

    func testUnsupportedProbeAndNewWriterUseSafeNoncompletionRoutes() throws {
        let url = try file()
        guard case .unavailable = CompletedXMLSnapshot.read(url, probe: { _ in .unavailable }, validate: { _ in true }) else {
            return XCTFail("Unsupported check must retain fallback")
        }
        var calls = 0
        let result = CompletedXMLSnapshot.read(url, probe: { _ in calls += 1; return calls == 1 ? .exclusive : .inUse }, validate: { _ in true })
        guard case .inUse = result else { return XCTFail("Producer reopened while reading") }
    }

    func testSnapshotRetainsValidatedBytesAfterLaterProducerChanges() throws {
        let url = try file()
        guard case .snapshot(let snapshot) = CompletedXMLSnapshot.read(url, probe: { _ in .exclusive }, validate: { _ in true }) else {
            return XCTFail("Expected snapshot")
        }
        try Data("changed".utf8).write(to: url)
        XCTAssertFalse(snapshot.isCurrent(at: url))
        XCTAssertEqual(snapshot.data, Data("<complete/>".utf8))
    }
}
