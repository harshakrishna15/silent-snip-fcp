import XCTest
@testable import CutdownMac

final class PendingVerificationRegistryTests: XCTestCase {
    func testPendingReceiptsAreBoundedAndEvictionDoesNotDeleteEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var registry = PendingVerificationRegistry(capacity: 2)
        let ids = (0..<3).map { _ in UUID() }
        let urls = ids.map { directory.appendingPathComponent($0.uuidString) }
        for (id, url) in zip(ids, urls) {
            try Data("receipt evidence".utf8).write(to: url)
            registry.remember(id, at: url)
        }
        XCTAssertEqual(registry.count, 2)
        XCTAssertNil(registry[ids[0]])
        XCTAssertEqual(registry[ids[2]], urls[2])
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path))
        registry.remember(ids[0], at: urls[0]) // Reopening an evicted result is supported.
        XCTAssertNil(registry[ids[1]])
        registry.remove(ids[0]) // Completed results no longer advertise retry.
        XCTAssertNil(registry[ids[0]])
        registry.removeAll()
        XCTAssertEqual(registry.count, 0)
        XCTAssertTrue(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }
}
