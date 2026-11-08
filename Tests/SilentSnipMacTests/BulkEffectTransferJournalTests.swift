import CryptoKit
import Foundation
import XCTest
@testable import SilentSnipMac

@MainActor final class BulkEffectTransferJournalTests: XCTestCase {
    private let sourceUID = "EC04F8EF-F25B-4373-BD7D-BFA273B5C3CD"
    private let hostUID = "CED1AB1A-9336-4DB1-9355-F76C189FEA99"
    private let filename = "Bulk-Effect-Transfer-Journal.json"

    func testOnlyConfirmedAppliedStatePermitsReadOnlyVerification() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for stage in ["import pending", "import identity verified", "paste attributes dialog requested", "effects paste requested", "effects paste dispatched", "paste command acknowledged; awaiting dialog close", "paste dialog closed; checking recipients", "stopped; no action will be replayed"] {
            try write(directory, stage: stage)
            XCTAssertThrowsError(try NativeBulkEffectTransferJournal.requireApplied(directory: directory, expected: expected), stage)
        }
        for stage in ["effects applied; result verification pending", "completed; verified"] {
            try write(directory, stage: stage)
            XCTAssertEqual(try NativeBulkEffectTransferJournal.requireApplied(directory: directory, expected: expected), hostUID)
        }
    }

    func testUncertainPasteCannotBecomeVerifiedByMarkComplete() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(directory, stage: "effects paste requested")
        XCTAssertThrowsError(try NativeBulkEffectTransferJournal.markVerified(directory: directory, hostUID: hostUID))
        try write(directory, stage: "effects applied; result verification pending", failureStage: "paste dialog closed; checking recipients")
        XCTAssertThrowsError(try NativeBulkEffectTransferJournal.requireApplied(directory: directory, expected: expected))
        XCTAssertThrowsError(try NativeBulkEffectTransferJournal.markVerified(directory: directory, hostUID: hostUID))
        try write(directory, stage: "effects applied; result verification pending", failure: "uncertain paste")
        XCTAssertThrowsError(try NativeBulkEffectTransferJournal.requireApplied(directory: directory, expected: expected))
        XCTAssertThrowsError(try NativeBulkEffectTransferJournal.markVerified(directory: directory, hostUID: hostUID))
    }

    func testReceiptBindsExactExpectedBytesAndDifferentNativeHostIdentity() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(directory, stage: "effects applied; result verification pending")
        XCTAssertThrowsError(try NativeBulkEffectTransferJournal.requireApplied(directory: directory, expected: expected + Data("\n".utf8)))
        try write(directory, stage: "effects applied; result verification pending", returnedUID: sourceUID)
        XCTAssertThrowsError(try NativeBulkEffectTransferJournal.requireApplied(directory: directory, expected: expected))
    }

    func testSuccessfulCompletionIsIdempotentAndCannotBindAnotherProject() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(directory, stage: "effects applied; result verification pending")
        XCTAssertThrowsError(try NativeBulkEffectTransferJournal.markVerified(directory: directory, hostUID: UUID().uuidString))
        try NativeBulkEffectTransferJournal.markVerified(directory: directory, hostUID: hostUID)
        let first = try Data(contentsOf: directory.appendingPathComponent(filename))
        try NativeBulkEffectTransferJournal.markVerified(directory: directory, hostUID: hostUID)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(filename)), first)
        XCTAssertEqual(try NativeBulkEffectTransferJournal.requireApplied(directory: directory, expected: expected), hostUID)
    }

    func testRestartLoadsAppliedJournalIdentityBeforeWorkflowRecovery() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("Silent Snip.fcpxml")
        try expected.write(to: output)
        let result = try ImportedResultVerification(expected: expected, outputURL: output,
            originalProjectName: "Original", request: .init(id: UUID(), settings: .defaults, outputMode: .remove),
            bulkEffectTransfer: true)
        try result.savePending()
        XCTAssertNil(result.hostProjectUID)
        try write(directory, stage: "effects applied; result verification pending")
        let loaded = try ImportedResultVerification.load(outputURL: output)
        XCTAssertEqual(loaded.hostProjectUID, hostUID)
        let origin = try WorkflowReviewOrigin(view: UUID(), gesture: UUID(),
            libraryURL: URL(fileURLWithPath: "/tmp/Integration.fcpbundle"),
            projectUID: hostUID, projectName: "Bulk Result")
        XCTAssertNoThrow(try loaded.validateWorkflowRecovery(origin))
    }

    func testRestartCannotAdoptAnIncompleteTransferOrConflictingSavedUID() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("Silent Snip.fcpxml")
        try expected.write(to: output)
        let result = try ImportedResultVerification(expected: expected, outputURL: output,
            originalProjectName: "Original", request: .init(id: UUID(), settings: .defaults, outputMode: .remove),
            bulkEffectTransfer: true)
        try result.savePending()
        try write(directory, stage: "effects paste requested")
        XCTAssertThrowsError(try ImportedResultVerification.load(outputURL: output))
        try write(directory, stage: "effects applied; result verification pending")
        let receiptURL = directory.appendingPathComponent("Verification-Receipt.json")
        var receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
        receipt["hostProjectUID"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: receipt).write(to: receiptURL)
        XCTAssertThrowsError(try ImportedResultVerification.load(outputURL: output))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func write(_ directory: URL, stage: String, failure: String? = nil, returnedUID: String? = nil, failureStage: String? = nil) throws {
        var receipt: [String: Any] = ["token": UUID().uuidString, "sourceUID": sourceUID, "clipboardStamp": 1,
            "expectedSHA256": SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined(),
            "effectFreeSHA256": "unused-by-read-only-verification", "projectName": "Bulk Result",
            "libraryURL": "file:///tmp/Integration.fcpbundle/", "eventUID": "857D09F8-5AF1-4275-934F-DDA604D2B17D",
            "clipCount": 2, "stage": stage, "hostUID": returnedUID ?? hostUID]
        if let failure { receipt["failure"] = failure }
        if let failureStage { receipt["failureStage"] = failureStage }
        try JSONSerialization.data(withJSONObject: receipt).write(to: directory.appendingPathComponent(filename))
    }

    private var expected: Data {
        Data("""
        <fcpxml version="1.14"><resources><format id="f" frameDuration="1/30s"/>
        <asset id="a" name="Audio" start="0s" duration="3s" hasAudio="1" audioSources="1" audioChannels="1"><media-rep kind="original-media" src="file:///tmp/Audio.wav"/></asset></resources>
        <library location="file:///tmp/Integration.fcpbundle/"><event name="Test" uid="857D09F8-5AF1-4275-934F-DDA604D2B17D">
        <project name="Bulk Result" uid="3C28EF20-27EB-49F5-B526-9AF9B9364365"><sequence format="f" duration="2s" tcStart="0s"><spine>
        <asset-clip name="Audio" ref="a" offset="0s" start="0s" duration="1s" audioRole="dialogue"/>
        <asset-clip name="Audio" ref="a" offset="1s" start="2s" duration="1s" audioRole="dialogue"/>
        </spine></sequence></project></event></library></fcpxml>
        """.utf8)
    }
}
