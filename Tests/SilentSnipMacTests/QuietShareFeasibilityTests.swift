#if DEBUG
import ApplicationServices
import XCTest
@testable import SilentSnipMac

final class QuietShareFeasibilityTests: XCTestCase {
    @MainActor func testOffActorCancellationBlocksInputBeforeTheDismissalCallbackRuns() async {
        let lease = QuietSharePluginPrototypeLease(request: UUID(), cancel: { _ in })
        await Task.detached { lease.cancellation.cancel() }.value
        XCTAssertTrue(lease.inputStopped)
        XCTAssertFalse(lease.revealed, "The main-actor panel callback has not run yet")
        XCTAssertThrowsError(try lease.assertMayContinue()) { XCTAssertTrue($0 is CancellationError) }
        lease.finish()
    }

    @MainActor func testPrototypeCancelUsesItsOwnRequestOnceAndLateCallbacksDoNothing() throws {
        let id = UUID()
        var cancellations: [UUID] = []
        let lease = QuietSharePluginPrototypeLease(request: id, cancel: { cancellations.append($0) })
        lease.cancelWork()
        lease.cancelWork()
        XCTAssertEqual(cancellations, [id])
        XCTAssertTrue(lease.revealed)
        XCTAssertThrowsError(try lease.assertMayContinue()) { XCTAssertTrue($0 is CancellationError) }
        lease.finish()
        lease.cancelWork()
        XCTAssertEqual(cancellations, [id])
    }

    @MainActor func testShowFinalCutKeepsOperationAvailableAndFinishRejectsLateChanges() throws {
        var cancellations = 0
        let lease = QuietSharePluginPrototypeLease(request: UUID(), cancel: { _ in cancellations += 1 })
        lease.reveal(reason: "Show Final Cut selected.")
        XCTAssertTrue(lease.revealed)
        XCTAssertFalse(lease.inputStopped)
        XCTAssertNoThrow(try lease.assertMayContinue())
        lease.finish()
        XCTAssertThrowsError(try lease.assertMayContinue()) { XCTAssertTrue($0 is CancellationError) }
        lease.stopInput(reason: "late cancellation")
        lease.cancelWork()
        XCTAssertTrue(lease.finished)
        XCTAssertFalse(lease.inputStopped)
        XCTAssertEqual(cancellations, 0)
    }

    func testUnprovenMenuPathsRequireRevealingFinalCutBeforeLegacyDispatch() {
        XCTAssertTrue(FinalCutGuardedMenuReturn.supportsCoveredPath(["File", "Share", "Silent Snip…"]))
        XCTAssertTrue(FinalCutGuardedMenuReturn.supportsCoveredPath(["Window", "Go To", "Timeline"]))
        XCTAssertFalse(FinalCutGuardedMenuReturn.supportsCoveredPath(["Window", "Go To", "Libraries"]))
        XCTAssertFalse(FinalCutGuardedMenuReturn.supportsCoveredPath(["File", "Open Clip"]))
        XCTAssertFalse(FinalCutGuardedMenuReturn.supportsCoveredPath(["File", "Share", "Another Destination…"]))
    }

    func testPrototypeRequiresOnlyTheExactWorkspaceLibraryBeforeSendingInput() {
        let required = URL(fileURLWithPath: "/tmp/Quiet Share/Cutdown Integration.fcpbundle")
        let valid = "Cutdown Integration\n\(required.path)"
        XCTAssertTrue(QuietSharePrototypeLibrary.verifies(help: [valid], expected: required))
        XCTAssertTrue(QuietSharePrototypeLibrary.verifies(help: [valid, valid], expected: required))
        XCTAssertFalse(QuietSharePrototypeLibrary.verifies(help: [], expected: required))
        XCTAssertFalse(QuietSharePrototypeLibrary.verifies(help: ["Cutdown Integration"], expected: required))
        XCTAssertFalse(QuietSharePrototypeLibrary.verifies(help: ["/tmp/Elsewhere/Cutdown Integration.fcpbundle"], expected: required))
        XCTAssertFalse(QuietSharePrototypeLibrary.verifies(help: [valid, "/tmp/Personal.fcpbundle"], expected: required))
    }

    func testReturnRequiresTheExactSingleEnabledSelectionInAnOpenMenu() {
        XCTAssertTrue(FinalCutGuardedMenuReturn.permits(action: kAXPickAction, menuOpen: true,
            selectedCount: 1, intendedSelected: true, enabled: true))
        XCTAssertTrue(FinalCutGuardedMenuReturn.permits(action: kAXPressAction, menuOpen: true,
            selectedCount: 1, intendedSelected: true, enabled: true))
        for count in [0, 2, 3] {
            XCTAssertFalse(FinalCutGuardedMenuReturn.permits(action: kAXPickAction, menuOpen: true,
                selectedCount: count, intendedSelected: true, enabled: true))
        }
        XCTAssertFalse(FinalCutGuardedMenuReturn.permits(action: kAXPickAction, menuOpen: false,
            selectedCount: 1, intendedSelected: true, enabled: true))
        XCTAssertFalse(FinalCutGuardedMenuReturn.permits(action: kAXPickAction, menuOpen: true,
            selectedCount: 1, intendedSelected: false, enabled: true))
        XCTAssertFalse(FinalCutGuardedMenuReturn.permits(action: kAXPickAction, menuOpen: true,
            selectedCount: 1, intendedSelected: true, enabled: false))
        XCTAssertFalse(FinalCutGuardedMenuReturn.permits(action: "unknown", menuOpen: true,
            selectedCount: 1, intendedSelected: true, enabled: true))
    }
}
#endif
