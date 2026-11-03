import XCTest
@testable import SilentSnipMac

final class FinalCutMenuActivationReadinessTests: XCTestCase {
    func testObservedCompletionReturnsWithoutWaitingForSelectionOrGracePeriod() {
        XCTAssertTrue(FinalCutMenuActivationReadiness.isReady(completed: true, exactlySelected: false, elapsed: 0))
        XCTAssertTrue(FinalCutMenuActivationReadiness.isReady(completed: true, exactlySelected: true, elapsed: 0.01))
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
