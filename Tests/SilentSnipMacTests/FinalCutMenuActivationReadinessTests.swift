import CoreGraphics
import XCTest
@testable import SilentSnipMac

final class FinalCutMenuActivationReadinessTests: XCTestCase {
    func testAlreadyOpenedExactTargetDoesNotRequireOriginalProjectPin() throws {
        XCTAssertTrue(try FinalCutMenuProjectTransition.openedOrAssertOriginal(opened: { true }, assertOriginal: {
            XCTFail("An observed exact target handoff must not recheck the displaced source title")
        }))
    }

    func testUnchangedOriginalContinuesWaitingForMenuCompletion() throws {
        var observations = 0
        var originalChecks = 0
        XCTAssertFalse(try FinalCutMenuProjectTransition.openedOrAssertOriginal(opened: {
            observations += 1; return false
        }, assertOriginal: { originalChecks += 1 }))
        XCTAssertEqual(observations, 1)
        XCTAssertEqual(originalChecks, 1)
    }

    func testIntendedProjectArrivingBetweenAXReadsCompletesWithoutAnotherInput() throws {
        var observations = 0
        XCTAssertTrue(try FinalCutMenuProjectTransition.openedOrAssertOriginal(opened: {
            observations += 1
            return observations == 2
        }, assertOriginal: { throw FinalCutCaptureError.changedProject }))
        XCTAssertEqual(observations, 2)
    }

    func testUnrelatedProjectTransitionStillFailsTheOriginalPin() {
        var observations = 0
        XCTAssertThrowsError(try FinalCutMenuProjectTransition.openedOrAssertOriginal(opened: {
            observations += 1; return false
        }, assertOriginal: { throw FinalCutCaptureError.changedProject })) { error in
            guard case FinalCutCaptureError.changedProject = error else {
                return XCTFail("Expected strict unrelated-project rejection, received \(error)")
            }
        }
        XCTAssertEqual(observations, 2)
    }

    func testFocusAndCancellationErrorsCannotBeExcusedByALaterProjectObservation() {
        let failures: [Error] = [FinalCutCaptureError.unavailable("Focus changed"), CancellationError()]
        for failure in failures {
            var observations = 0
            XCTAssertThrowsError(try FinalCutMenuProjectTransition.openedOrAssertOriginal(opened: {
                observations += 1; return observations > 1
            }, assertOriginal: { throw failure }))
            XCTAssertEqual(observations, 1, "Only a changed original project permits the exact target recheck")
        }
    }

    func testObservedCompletionReturnsWithoutWaitingForSelectionOrGracePeriod() {
        func readSelection() -> Bool {
            XCTFail("A completed action does not need another menu selection read")
            return false
        }
        XCTAssertTrue(FinalCutMenuActivationReadiness.isReady(completed: true, exactlySelected: readSelection(), elapsed: 0))
    }

    func testSelectionDoesNotAuthorizeAnotherActivationWhileAXActionMayStillBePending() {
        XCTAssertFalse(FinalCutMenuActivationReadiness.isReady(completed: false, exactlySelected: true, elapsed: 0))
        XCTAssertFalse(FinalCutMenuActivationReadiness.isReady(completed: false, exactlySelected: true, elapsed: 0.199))
        XCTAssertTrue(FinalCutMenuActivationReadiness.isReady(completed: false, exactlySelected: true, elapsed: 0.2))
    }

    func testElapsedTimeAloneNeverAuthorizesActivationOfAnUnselectedItem() {
        XCTAssertFalse(FinalCutMenuActivationReadiness.isReady(completed: false, exactlySelected: false, elapsed: 0.2))
        XCTAssertFalse(FinalCutMenuActivationReadiness.isReady(completed: false, exactlySelected: false, elapsed: 2))
    }

    func testPreparedClickRequiresTheItemAtTheActualEventPoint() {
        let prepared = CGPoint(x: 12, y: 36)
        let moved = CGPoint(x: 12, y: 52)
        XCTAssertTrue(FinalCutMenuActivationReadiness.isReady(completed: false, exactlySelected: true, elapsed: 0.2))
        XCTAssertFalse(FinalCutMenuActivationReadiness.canClickPreparedPoint(prepared, sheetOpen: false) { $0 == moved })
        XCTAssertTrue(FinalCutMenuActivationReadiness.canClickPreparedPoint(prepared, sheetOpen: false) { $0 == prepared })
    }

    func testSheetOpeningAfterReadinessSuppressesThePreparedClick() {
        let prepared = CGPoint(x: 12, y: 36)
        XCTAssertTrue(FinalCutMenuActivationReadiness.isReady(completed: false, exactlySelected: true, elapsed: 0.2))
        XCTAssertFalse(FinalCutMenuActivationReadiness.canClickPreparedPoint(prepared, sheetOpen: true) { _ in
            XCTFail("A newly opened sheet should stop fallback before hit-testing")
            return true
        })
    }

    func testScrollingSubmenuCanAdvanceWithOffscreenTargetAndVisibleSibling() {
        XCTAssertTrue(FinalCutMenuObservation.submenuIsReady(children: ["Visible sibling", "Offscreen target"],
            intended: { $0 == "Offscreen target" }, onScreen: { $0 == "Visible sibling" }))
    }

    func testRetainedClosedSubmenuDoesNotAdvance() {
        XCTAssertFalse(FinalCutMenuObservation.submenuIsReady(children: ["Sibling", "Target"],
            intended: { $0 == "Target" }, onScreen: { _ in false }))
    }

    func testVisibleSubmenuStillRequiresUniqueIntendedCommand() {
        XCTAssertFalse(FinalCutMenuObservation.submenuIsReady(children: ["Visible sibling"],
            intended: { $0 == "Target" }, onScreen: { _ in true }))
        XCTAssertFalse(FinalCutMenuObservation.submenuIsReady(children: ["Target", "Target"],
            intended: { $0 == "Target" }, onScreen: { _ in true }))
    }

    func testMissingAndEmptyAggregateSelectionUseExactChildSelection() {
        let reports: [[String]?] = [nil, []]
        for reported in reports {
            XCTAssertTrue(FinalCutMenuObservation.isExactlySelected(reported: reported,
                selectedChildren: { ["Target"] }, intended: { $0 == "Target" }))
            XCTAssertFalse(FinalCutMenuObservation.isExactlySelected(reported: reported,
                selectedChildren: { ["Sibling"] }, intended: { $0 == "Target" }))
            XCTAssertFalse(FinalCutMenuObservation.isExactlySelected(reported: reported,
                selectedChildren: { ["Target", "Sibling"] }, intended: { $0 == "Target" }))
        }
    }

    func testNonemptyConflictingAggregateSelectionNeverFallsBackToTargetChildFlag() {
        for reported in [["Sibling"], ["Target", "Sibling"]] {
            XCTAssertFalse(FinalCutMenuObservation.isExactlySelected(reported: reported,
                selectedChildren: {
                    XCTFail("Nonempty conflicting aggregate selection must not fall back to child flags")
                    return ["Target"]
                }, intended: { $0 == "Target" }))
        }
        XCTAssertTrue(FinalCutMenuObservation.isExactlySelected(reported: ["Target"],
            selectedChildren: {
                XCTFail("An exact aggregate selection needs no fallback")
                return []
            }, intended: { $0 == "Target" }))
    }
}
