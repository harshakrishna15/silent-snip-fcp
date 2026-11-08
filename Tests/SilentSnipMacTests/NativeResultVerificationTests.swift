import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import SilentSnipCore
import XCTest
@testable import SilentSnipMac

/// A native edit already has its definitive host UID. Verification must never
/// adopt another project whose XML looks identical while hidden effects differ.
final class NativeResultVerificationTests: XCTestCase {
    private var folder: URL!
    private var source: URL { folder.appendingPathComponent("Original.wav") }
    private var outputURL: URL { folder.appendingPathComponent("Silent Snip.fcpxml") }
    private var receiptURL: URL { folder.appendingPathComponent("Verification-Receipt.json") }
    private var reportURL: URL { folder.appendingPathComponent("Import-Verification.json") }
    private let nativeUID = "AAAAAAAA-0000-4000-8000-000000000001"
    private let otherUID = "BBBBBBBB-0000-4000-8000-000000000002"

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("NativeResult-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Fixture.fcpbundle"), withIntermediateDirectories: true)
        try Data("unchanged original source bytes".utf8).write(to: source)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    @MainActor func testFirstVerificationRejectsAnIdenticalExportFromAnotherProjectWithoutRecovery() async throws {
        let expected = fixture()
        let actual = try withUID(otherUID, in: expected)
        XCTAssertEqual(try TimelineParser.parse(data: expected).fingerprint,
            try TimelineParser.parse(data: actual).fingerprint,
            "Only the host project identity changes; incomplete effect XML remains indistinguishable")
        let verification = try await makeVerification(expected)
        XCTAssertEqual(verification.hostProjectUID, nativeUID, "Bind the native UID before the first host capture")
        var captures = 0
        do {
            _ = try await verification.verify(capture: {
                captures += 1
                return actual
            }, restore: { _, _ in
                XCTFail("Another project must never authorize native controller writes")
            })
            XCTFail("The first verification must reject a different native project")
        } catch {
            guard case .verificationFailed = error as? EditedProjectWriterError else {
                return XCTFail("Expected an identity verification failure, got \(error)")
            }
        }
        XCTAssertEqual(captures, 1, "A successful capture with the wrong UID cannot trigger another attempt")
        XCTAssertEqual(verification.hostProjectUID, nativeUID)
        XCTAssertEqual(verification.nativeProjectUID, nativeUID)
        let report = try JSONDecoder().decode(ProjectRoundTripReport.self, from: Data(contentsOf: reportURL))
        XCTAssertFalse(report.verified)
        XCTAssertEqual(report.sourceMediaVerified, false)
        XCTAssertTrue(report.differences.contains("imported project identity changed"))
    }

    @MainActor func testSavedNativeReceiptKeepsItsBindingAndVerifiesOnlyThatExistingProject() async throws {
        let expected = fixture()
        let verification = try await makeVerification(expected)
        try verification.savePending()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
        XCTAssertEqual(object["nativeProjectUID"] as? String, nativeUID)
        XCTAssertEqual(object["hostProjectUID"] as? String, nativeUID)
        let loaded = try ImportedResultVerification.load(outputURL: outputURL)
        XCTAssertEqual(loaded.nativeProjectUID, nativeUID)
        XCTAssertEqual(loaded.hostProjectUID, nativeUID)
        let sourceBefore = try Data(contentsOf: source)
        let report = try await loaded.verify(capture: { expected }, restore: { _, _ in
            XCTFail("An unchanged native result needs no controller writes")
        })
        XCTAssertTrue(report.verified)
        XCTAssertEqual(report.sourceMediaVerified, true)
        XCTAssertEqual(report.expectedProjectUID, nativeUID)
        XCTAssertEqual(report.actualProjectUID, nativeUID)
        XCTAssertEqual(try Data(contentsOf: source), sourceBefore)

        // A retry keeps the same binding instead of reopening the first-import
        // UUID-assignment exception after an earlier successful verification.
        let retry = try ImportedResultVerification.load(outputURL: outputURL)
        let anotherProject = try withUID(otherUID, in: expected)
        do {
            _ = try await retry.verify(capture: { anotherProject }, restore: { _, _ in
                XCTFail("A retry cannot write settings into another native project")
            })
            XCTFail("A retry must preserve the previously saved native UID")
        } catch {
            XCTAssertEqual(retry.hostProjectUID, nativeUID)
            XCTAssertEqual(retry.nativeProjectUID, nativeUID)
        }
    }

    @MainActor func testConstructorRejectsMissingOrDifferentNativeIdentity() throws {
        let expected = fixture()
        for uid in ["", otherUID] {
            XCTAssertThrowsError(try ImportedResultVerification(expected: expected, outputURL: outputURL,
                originalProjectName: "Original", request: .init(id: UUID(), settings: .defaults, outputMode: .remove),
                nativeProjectUID: uid)) { error in
                XCTAssertTrue(error.localizedDescription.contains("native edit receipt"))
            }
        }
    }

    @MainActor func testLoadingRejectsTamperedOrRemovedHostIdentityInNativeReceipt() async throws {
        let verification = try await makeVerification(fixture())
        try verification.savePending()
        let originalReceipt = try Data(contentsOf: receiptURL)
        let replacements: [Any?] = [otherUID, NSNull(), nil]
        for replacement in replacements {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: originalReceipt) as? [String: Any])
            if let replacement { object["hostProjectUID"] = replacement }
            else { object.removeValue(forKey: "hostProjectUID") }
            try JSONSerialization.data(withJSONObject: object).write(to: receiptURL, options: .atomic)
            XCTAssertThrowsError(try ImportedResultVerification.load(outputURL: outputURL)) { error in
                XCTAssertTrue(error.localizedDescription.contains("native result identity changed"))
            }
        }
    }

    @MainActor private func makeVerification(_ expected: Data) async throws -> ImportedResultVerification {
        try expected.write(to: outputURL)
        let media = try await MediaContentSnapshot.capture([source])
        return try ImportedResultVerification(expected: expected, outputURL: outputURL,
            originalProjectName: "Original", request: .init(id: UUID(), settings: .defaults, outputMode: .remove),
            sourceMedia: media, nativeProjectUID: nativeUID)
    }

    private func withUID(_ uid: String, in input: Data) throws -> Data {
        let xml = try XMLDocument(data: input)
        try XCTUnwrap(xml.nodes(forXPath: "//project/@uid").first).stringValue = uid
        return xml.xmlData
    }

    private func fixture() -> Data {
        Data("""
        <fcpxml version="1.14"><resources><format id="f" frameDuration="1/30s"/>
        <asset id="a" name="Original Audio" start="0s" duration="10s" hasAudio="1"><media-rep kind="original-media" src="\(source.absoluteString)"/></asset>
        <effect id="limiter" name="Limiter" uid="Limiter.Levels.audio.effectBundle"/>
        </resources><library location="\(folder.appendingPathComponent("Fixture.fcpbundle").absoluteString)"><event name="Fixture" uid="CCCCCCCC-0000-4000-8000-000000000003"><project name="Cleaned" uid="\(nativeUID)">
        <sequence format="f" duration="7s" tcStart="0s"><spine>
        <asset-clip ref="a" name="Voice" offset="0s" start="0s" duration="2s" audioRole="dialogue"><filter-audio ref="limiter" name="Limiter"/></asset-clip>
        <asset-clip ref="a" name="Voice" offset="2s" start="3s" duration="5s" audioRole="dialogue"><filter-audio ref="limiter" name="Limiter"/></asset-clip>
        </spine></sequence></project></event></library></fcpxml>
        """.utf8)
    }
}
