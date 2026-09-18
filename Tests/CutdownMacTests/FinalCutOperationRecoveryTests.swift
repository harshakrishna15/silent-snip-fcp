import XCTest
@testable import CutdownMac

@MainActor final class FinalCutOperationRecoveryTests: XCTestCase {
    private func selection(_ start: String, end: String) throws -> FinalCutSelectionSnapshot {
        func node(_ role: String, _ description: String, _ value: String?, selected: Bool? = nil,
                  children: [AccessibilityNode] = []) -> AccessibilityNode {
            AccessibilityNode(role: role, identifier: nil, title: nil, description: description,
                value: value, selected: selected, enabled: true, children: children)
        }
        return try FinalCutSelectionSnapshot(projectName: "Imported", timeline:
            node("AXLayoutArea", "Project Timeline", nil, children: [
                node("AXLayoutItem", "", "00:00:01:00", selected: true, children: [
                    node("AXTextField", "Title", "Same clip name"),
                    node("AXHandle", "Leading Edge", start), node("AXHandle", "Trailing Edge", end)
                ])
            ]))
    }

    func testSequentialRecoveryRebindsSameNamedSegmentsWithoutWeakeningCaptureGuard() throws {
        let first = try selection("00:00:00:00", end: "00:00:01:00")
        let second = try selection("00:00:02:00", end: "00:00:03:00")
        var ownership = FinalCutReviewOwnership()
        ownership.bindVerifiedRecovery(first)
        // Closing the first recovered editor leaves this suspended identity.
        XCTAssertThrowsError(try ownership.remember(second))
        XCTAssertEqual(ownership.active, first, "Failed capture must not update ownership")
        ownership.bindVerifiedRecovery(second)
        try ownership.remember(second)
        XCTAssertEqual(ownership.active, second)
        XCTAssertEqual(ownership.suspended?.selection, second)
        XCTAssertThrowsError(try ownership.remember(first))
    }

    func testSettingsTextRoundTripsSmallAndNormalFloat32ValuesAcrossLocales() throws {
        let values: [Float] = [-80, -40.123456, 0, 0.1, 0.00123456789, 1e-9,
                               .leastNormalMagnitude, .leastNonzeroMagnitude, 2, 10]
        for locale in ["en_US", "de_DE", "fr_FR", "ar_EG"] {
            let formatter = CutdownSettingText.formatter(locale: Locale(identifier: locale))
            for value in values {
                let text = try XCTUnwrap(formatter.string(from: NSNumber(value: value)))
                let restored = try XCTUnwrap(formatter.number(from: text)).floatValue
                XCTAssertEqual(restored, value, "\(locale): \(text)")
            }
        }
    }

    private enum Failure: Error { case entry, cleanup }

    func testOwnedEntryCleansUpOnErrorButNotOnSuccess() async throws {
        var open = false, cleanups = 0
        do {
            try await FinalCutOwnedInput.perform(operation: {
                open = true; throw Failure.entry
            }, cleanup: { open = false; cleanups += 1 })
            XCTFail("Expected entry error")
        } catch Failure.entry { }
        XCTAssertFalse(open)
        XCTAssertEqual(cleanups, 1)
        try await FinalCutOwnedInput.perform(operation: { }, cleanup: { cleanups += 1 })
        XCTAssertEqual(cleanups, 1)
    }

    func testCancellationDoesNotCancelOwnedEntryCleanup() async throws {
        var closed = false
        let operation = Task {
            try await FinalCutOwnedInput.perform(operation: {
                withUnsafeCurrentTask { $0?.cancel() }
                try Task.checkCancellation()
            }, cleanup: {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(1))
                closed = true
            })
        }
        do { try await operation.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertTrue(closed)
    }

    func testCleanupFailureIsReportedWithOriginalError() async throws {
        do {
            try await FinalCutOwnedInput.perform(operation: { throw Failure.entry },
                cleanup: { throw Failure.cleanup })
            XCTFail("Expected cleanup error")
        } catch FinalCutCaptureError.reviewRestoration(let original, let guidance) {
            XCTAssertEqual(original, Failure.entry.localizedDescription)
            XCTAssertTrue(guidance.contains("cleanup could not finish"))
        }
    }
}
