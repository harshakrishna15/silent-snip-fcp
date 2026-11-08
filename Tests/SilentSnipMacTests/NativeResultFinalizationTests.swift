import Foundation
import XCTest
@testable import SilentSnipMac

/// Read-only result verification reaches this filesystem boundary on both
/// initial Apply and a later Retry. None of these tests sends native input.
@MainActor final class NativeResultFinalizationTests: XCTestCase {
    private var folder: URL!
    private var journalURL: URL { folder.appendingPathComponent("Native-Edit-Journal.json") }
    private var statusURL: URL { folder.appendingPathComponent("Native-Edit-Status.txt") }
    private let nativeUID = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
    private let otherUID = UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("NativeFinalization-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func testSuccessfulRetryCompletesPendingJournalAndReplacesPartialCopyStatus() throws {
        try writeJournal()
        try Data("A partial copy may remain; verification failed.".utf8).write(to: statusURL)
        try NativeResultFinalization.complete(directory: folder, projectUID: nativeUID, projectName: "Cleaned")
        let completed = try journal()
        XCTAssertEqual(completed["stage"] as? String, "completed; verified")
        XCTAssertEqual(completed["verifiedSteps"] as? Int, 2)
        XCTAssertEqual(completed["requestedStep"] as? Int, 2)
        let status = try String(contentsOf: statusURL)
        XCTAssertTrue(status.contains("Verified native result ‘Cleaned’"))
        XCTAssertTrue(status.contains(nativeUID.uuidString))
        XCTAssertFalse(status.contains("partial"))
    }

    func testRepeatedVerificationOfCompletedMatchingUIDIsIdempotent() throws {
        try writeJournal()
        try NativeResultFinalization.complete(directory: folder, projectUID: nativeUID, projectName: "Cleaned")
        let completedJournal = try Data(contentsOf: journalURL)
        let completedStatus = try Data(contentsOf: statusURL)
        try NativeResultFinalization.complete(directory: folder, projectUID: nativeUID, projectName: "Cleaned")
        XCTAssertEqual(try Data(contentsOf: journalURL), completedJournal,
            "A later Verify must not reset a completed journal or replay mutations")
        XCTAssertEqual(try Data(contentsOf: statusURL), completedStatus)
    }

    func testWrongUIDCannotFinalizeEvenAnAlreadyCompletedJournal() throws {
        try writeJournal(overrides: ["stage": "completed; verified"])
        let before = try Data(contentsOf: journalURL)
        try Data("Keep this prior status".utf8).write(to: statusURL)
        XCTAssertThrowsError(try NativeResultFinalization.complete(directory: folder,
            projectUID: otherUID, projectName: "Cleaned"))
        XCTAssertEqual(try Data(contentsOf: journalURL), before)
        XCTAssertEqual(try String(contentsOf: statusURL), "Keep this prior status")
    }

    func testPartialOrFailedMutationJournalCannotBecomeVerifiedThroughRetry() throws {
        let invalid: [[String: Any]] = [
            ["stage": "preparing"],
            ["stage": "native edit verified"],
            ["stage": "stopped; no action will be replayed"],
            ["verifiedSteps": 1],
            ["requestedStep": 1],
            ["plannedSteps": 0],
            ["nativeName": "Another Project"],
            ["failure": "Delete result was uncertain"],
            ["failedStage": "delete requested"]
        ]
        for overrides in invalid {
            try writeJournal(overrides: overrides)
            let before = try Data(contentsOf: journalURL)
            XCTAssertThrowsError(try NativeResultFinalization.complete(directory: folder,
                projectUID: nativeUID, projectName: "Cleaned"), "\(overrides)")
            XCTAssertEqual(try Data(contentsOf: journalURL), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: statusURL.path))
        }
    }

    func testStatusWriteFailureCanFinishOnReadOnlyRetryAfterJournalCompletion() throws {
        try writeJournal()
        // A directory cannot be replaced by the atomic status-file write.
        try FileManager.default.createDirectory(at: statusURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try NativeResultFinalization.complete(directory: folder,
            projectUID: nativeUID, projectName: "Cleaned"))
        XCTAssertEqual(try journal()["stage"] as? String, "completed; verified")
        try FileManager.default.removeItem(at: statusURL)
        try NativeResultFinalization.complete(directory: folder, projectUID: nativeUID, projectName: "Cleaned")
        XCTAssertEqual(try journal()["stage"] as? String, "completed; verified")
        XCTAssertTrue(try String(contentsOf: statusURL).contains(nativeUID.uuidString))
    }

    private func journal() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
    }

    private func writeJournal(overrides: [String: Any] = [:]) throws {
        var value: [String: Any] = [
            "originalProjectUID": otherUID.uuidString,
            "requestedName": "Cleaned",
            "plannedSteps": 2,
            "nativeName": "Cleaned",
            "nativeProjectUID": nativeUID.uuidString,
            "stage": "native edits complete; final comparison pending",
            "requestedStep": 2,
            "verifiedSteps": 2
        ]
        value.merge(overrides) { _, replacement in replacement }
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: journalURL)
    }
}
