import XCTest
import SilentSnipCore
@testable import SilentSnipMac

final class BulkEffectTransferPolicyTests: XCTestCase {
    func testOnlyOwnHelperCanYieldToTheUnchangedOwnedPasteDialog() {
        XCTAssertTrue(BulkEffectTransferPolicy.mayReturnOwnedDialog(foregroundPID: 200, helperPID: 200,
            sameDialog: true, clipboardUnchanged: true))
        for foreground: Int32? in [100, 300, nil] {
            XCTAssertFalse(BulkEffectTransferPolicy.mayReturnOwnedDialog(foregroundPID: foreground, helperPID: 200,
                sameDialog: true, clipboardUnchanged: true))
        }
        XCTAssertFalse(BulkEffectTransferPolicy.mayReturnOwnedDialog(foregroundPID: 200, helperPID: 200,
            sameDialog: false, clipboardUnchanged: true))
        XCTAssertFalse(BulkEffectTransferPolicy.mayReturnOwnedDialog(foregroundPID: 200, helperPID: 200,
            sameDialog: true, clipboardUnchanged: false))
    }

    func testOnlyExactOwnedWorkflowAndWorkerHandoffsMayRestoreTimeline() {
        XCTAssertTrue(BulkEffectTransferPolicy.mayRestoreTimeline(foregroundPID: 100, hostPID: 100, helperPID: 200,
            focusedWindowIsBoundWorkflow: true, hasSheet: false))
        XCTAssertTrue(BulkEffectTransferPolicy.mayRestoreTimeline(foregroundPID: 200, hostPID: 100, helperPID: 200,
            focusedWindowIsBoundWorkflow: false, hasSheet: false))
        // The host's Effects/Inspector/other project window is not the bound
        // requesting Workflow window. Neither its title nor host PID suffices.
        XCTAssertFalse(BulkEffectTransferPolicy.mayRestoreTimeline(foregroundPID: 100, hostPID: 100, helperPID: 200,
            focusedWindowIsBoundWorkflow: false, hasSheet: false))
        // A stale owned-window observation never permits activation over a
        // foreign foreground, a missing process, or a still-open dialog.
        for foreground: Int32? in [300, nil] {
            XCTAssertFalse(BulkEffectTransferPolicy.mayRestoreTimeline(foregroundPID: foreground, hostPID: 100, helperPID: 200,
                focusedWindowIsBoundWorkflow: true, hasSheet: false))
        }
        for foreground: Int32? in [100, 200] {
            XCTAssertFalse(BulkEffectTransferPolicy.mayRestoreTimeline(foregroundPID: foreground, hostPID: 100, helperPID: 200,
                focusedWindowIsBoundWorkflow: true, hasSheet: true))
        }
    }

    @MainActor func testOwnedWorkflowRestorationStillRequiresStrictFocus() async throws {
        struct FocusChanged: Error {}
        var restorations = 0
        do {
            try await FinalCutOwnedInputFocus.prepare(ownsForeground: {
                BulkEffectTransferPolicy.mayRestoreTimeline(foregroundPID: 100, hostPID: 100, helperPID: 200,
                    focusedWindowIsBoundWorkflow: true, hasSheet: false)
            }, restore: {
                restorations += 1
            }, assertFocused: {
                throw FocusChanged()
            })
            XCTFail("Returning from restoration cannot replace strict project/window focus proof")
        } catch is FocusChanged { }
        XCTAssertEqual(restorations, 1)
    }

    func testPartialOrDifferentSelectionsCannotAuthorizePaste() throws {
        let first = TimeRange(start: .zero, end: RationalTime(1))
        let second = TimeRange(start: RationalTime(1), end: RationalTime(2))
        let expected = [first, second]
        XCTAssertNoThrow(try BulkEffectTransferPolicy.validateSelection(expected: expected, actual: expected, selected: [true, true]))
        XCTAssertThrowsError(try BulkEffectTransferPolicy.validateSelection(expected: expected, actual: expected, selected: [true, false]))
        XCTAssertThrowsError(try BulkEffectTransferPolicy.validateSelection(expected: expected, actual: [first], selected: [true]))
        XCTAssertThrowsError(try BulkEffectTransferPolicy.validateSelection(expected: expected, actual: [second, first], selected: [true, true]))
        XCTAssertThrowsError(try BulkEffectTransferPolicy.validateSelection(expected: [], actual: [], selected: []))
    }

    func testExactOrderedEffectInstancesAreRequiredIncludingRepeatedNames() throws {
        let expected = ["Noise Gate", "Limiter", "Limiter"]
        XCTAssertNoThrow(try BulkEffectTransferPolicy.validateEffectCheckboxes(expected: expected, actual: expected, checked: [1, 1, 1]))
        XCTAssertThrowsError(try BulkEffectTransferPolicy.validateEffectCheckboxes(expected: expected, actual: ["Noise Gate", "Limiter"], checked: [1, 1]))
        XCTAssertThrowsError(try BulkEffectTransferPolicy.validateEffectCheckboxes(expected: expected, actual: ["Limiter", "Noise Gate", "Limiter"], checked: [1, 1, 1]))
        XCTAssertThrowsError(try BulkEffectTransferPolicy.validateEffectCheckboxes(expected: expected, actual: expected, checked: [1, 0, 1]))
        XCTAssertThrowsError(try BulkEffectTransferPolicy.validateEffectCheckboxes(expected: expected, actual: expected, checked: [1, 2, 1]))
    }

    func testCopiedFromRequiresExactSourceAndRecipientCount() {
        XCTAssertTrue(BulkEffectTransferPolicy.copiedFromMatches("Copied From: Example Clip 20 Clips", source: "Example Clip", count: 20))
        XCTAssertTrue(BulkEffectTransferPolicy.copiedFromMatches("Copied From:\nExample Clip", source: "Example Clip", count: 20))
        XCTAssertFalse(BulkEffectTransferPolicy.copiedFromMatches("Copied From: Other Example Clip 20 Clips", source: "Example Clip", count: 20))
        XCTAssertFalse(BulkEffectTransferPolicy.copiedFromMatches("Copied From: Example Clip 19 Clips", source: "Example Clip", count: 20))
        XCTAssertFalse(BulkEffectTransferPolicy.copiedFromMatches("Copied From: Example Clip extra", source: "Example Clip", count: 20))
    }
}
