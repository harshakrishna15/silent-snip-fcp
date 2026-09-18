import XCTest
@testable import CutdownMac

final class FinalCutRangePreparationTests: XCTestCase {
    private enum Failure: Error { case unreadable, undelivered, unverified }

    @MainActor func testFullTimelineShareSendsNoRangeCommand() async throws {
        try await FinalCutRangePreparation.clearIfNeeded(hasRanges: { false }, clear: {
            XCTFail("An isolated project without ranges needs no keyboard or menu input")
        }, verifyCleared: {
            XCTFail("No command was sent to verify")
        })
    }

    @MainActor func testSelectedRangeIsClearedOnceBeforeVerification() async throws {
        var events: [String] = []
        try await FinalCutRangePreparation.clearIfNeeded(hasRanges: { true }, clear: {
            events.append("clear")
        }, verifyCleared: {
            events.append("verify")
        })
        XCTAssertEqual(events, ["clear", "verify"])
    }

    @MainActor func testUnreadableSelectionStopsWithoutSendingInput() async {
        do {
            try await FinalCutRangePreparation.clearIfNeeded(hasRanges: { throw Failure.unreadable }, clear: {
                XCTFail("Unknown selection must not trigger input")
            }, verifyCleared: { XCTFail("Unknown selection must stop preparation") })
            XCTFail("Unreadable selection must not be accepted as the full timeline")
        } catch { XCTAssertTrue(error is Failure) }
    }

    @MainActor func testUncertainCommandIsNotRetried() async {
        var calls = 0
        do {
            try await FinalCutRangePreparation.clearIfNeeded(hasRanges: { true }, clear: {
                calls += 1
                throw Failure.undelivered
            }, verifyCleared: { XCTFail("Failed delivery must stop preparation") })
            XCTFail("Failed delivery must propagate")
        } catch { XCTAssertTrue(error is Failure) }
        XCTAssertEqual(calls, 1)
    }

    @MainActor func testUnverifiedClearStopsWithoutRetry() async {
        var calls = 0
        do {
            try await FinalCutRangePreparation.clearIfNeeded(hasRanges: { true }, clear: {
                calls += 1
            }, verifyCleared: { throw Failure.unverified })
            XCTFail("A range that could remain selected must block sharing")
        } catch { XCTAssertTrue(error is Failure) }
        XCTAssertEqual(calls, 1)
    }
}
