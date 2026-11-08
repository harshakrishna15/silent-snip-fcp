import Foundation
import XCTest
@testable import SilentSnipMac

final class AutomaticPreviewTransportTests: XCTestCase {
    private func command(local: Bool? = true, verify: Bool? = true, automatic: Bool? = true) -> ReviewCommand {
        ReviewCommand(request: UUID(), command: .recalculate, expectedRevision: 3, view: UUID(),
            settings: .init(threshold: -40, minimum: 0.5, before: 0.1, after: 0.1), output: "remove",
            settingsEdit: UUID(), settingsSequence: 1, verifySettings: verify, localPreview: local,
            automaticPreview: automatic)
    }
    func testAutomaticPreviewRequiresVerifiedRetainedAudioPayload() throws {
        let good = command()
        XCTAssertEqual(try ReviewWire.decodeCommand(ReviewWire.encode(good)), good)
        for invalid in [command(local: false), command(local: nil), command(verify: false), command(verify: nil)] {
            XCTAssertThrowsError(try ReviewWire.decodeCommand(ReviewWire.encode(invalid)))
        }
    }
    func testAutomaticFlagCannotBeUsedForApplyOrAnotherCommand() throws {
        let bad = ReviewCommand(request: UUID(), command: .apply, expectedRevision: 1,
            view: UUID(), applyGesture: UUID(), automaticPreview: true)
        XCTAssertThrowsError(try ReviewWire.decodeCommand(ReviewWire.encode(bad)))
    }
    func testPriorManualUpdateWireRemainsCompatible() throws {
        let old = command(automatic: nil)
        XCTAssertEqual(try ReviewWire.decodeCommand(ReviewWire.encode(old)), old)
    }
    func testCapabilityAndDeclinedEditAreSeparateFromAcceptedEdit() throws {
        let accepted = UUID(), rejected = UUID()
        let value = ReviewResponse(request: UUID(), revision: 6, state: "review", message: "",
            canApply: false, settingsEdit: accepted, automaticPreviewAvailable: true,
            rejectedSettingsEdit: rejected, rejectedSettingsSequence: 2)
        let encoded = try XCTUnwrap(ReviewWire.encode(value).data(using: .utf8))
        let decoded = try JSONDecoder().decode(ReviewResponse.self, from: encoded)
        XCTAssertEqual(decoded.settingsEdit, accepted)
        XCTAssertEqual(decoded.rejectedSettingsEdit, rejected)
        XCTAssertEqual(decoded.rejectedSettingsSequence, 2)
        XCTAssertEqual(decoded.automaticPreviewAvailable, true)
        XCTAssertFalse(decoded.canApply)
    }
}
