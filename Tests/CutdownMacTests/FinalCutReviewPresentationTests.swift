import XCTest
@testable import CutdownMac

@MainActor final class FinalCutReviewPresentationTests: XCTestCase {
    private enum Failure: Error { case changedProject, uncertainPress }

    func testLateHostActivationCanArriveAfterTheCompletionCallback() async {
        var checks = 0, restores = 0
        await FinalCutReviewPresentation.returnOwnActivation(stillOwnsRequest: { true },
            helperIsActive: { checks += 1; return checks == 3 }, restore: { restores += 1 },
            attempts: 4, pollInterval: .milliseconds(1))
        XCTAssertEqual(checks, 4)
        XCTAssertEqual(restores, 1)
    }

    func testLateDeliveryNeverReclaimsActivationFromAnotherApp() async {
        var restores = 0
        await FinalCutReviewPresentation.returnOwnActivation(stillOwnsRequest: { true },
            helperIsActive: { false }, restore: { restores += 1 }, attempts: 3, pollInterval: .milliseconds(1))
        XCTAssertEqual(restores, 0)
    }

    func testLateDeliveryStopsWhenItsRequestIsReplacedOrCancelled() async {
        var owned = true, restores = 0
        await FinalCutReviewPresentation.returnOwnActivation(stillOwnsRequest: { owned },
            helperIsActive: { true }, restore: { restores += 1; owned = false },
            attempts: 4, pollInterval: .milliseconds(1))
        XCTAssertEqual(restores, 1)
    }

    func testRemoteEditorMayLoadBeforeOwnershipControlsBecomeAvailable() async throws {
        var checks = 0, raises = 0
        let ready = try await FinalCutReviewPresentation.waitForEditor(assertProject: { checks += 1 },
            raiseWhenReady: {
                // Two incomplete native snapshots must not be mistaken for a
                // failed operation or trigger another Show Effect Editor toggle.
                guard checks >= 3 else { return false }
                raises += 1; return true
            }, pollInterval: .milliseconds(1))
        XCTAssertTrue(ready)
        XCTAssertEqual(checks, 3)
        XCTAssertEqual(raises, 1)
    }

    func testRemoteEditorLoadingStopsIfProjectChanges() async {
        var checks = 0, attempts = 0
        do {
            _ = try await FinalCutReviewPresentation.waitForEditor(assertProject: {
                checks += 1
                if checks == 2 { throw Failure.changedProject }
            }, raiseWhenReady: { attempts += 1; return false }, pollInterval: .milliseconds(1))
            XCTFail("Must stop waiting for an editor in a different project")
        } catch Failure.changedProject { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(attempts, 1)
    }

    func testRemoteEditorLoadingHasABoundedDeadline() async throws {
        let ready = try await FinalCutReviewPresentation.waitForEditor(assertProject: {},
            raiseWhenReady: { XCTFail("Expired deadline"); return true }, timeout: 0)
        XCTAssertFalse(ready)
    }

    func testExistingWindowIsRaisedWithoutTogglingItClosed() async throws {
        var raised = false
        try await FinalCutReviewPresentation.present(validate: {}, raiseExisting: {
            raised = true; return true
        }, toggleEditor: { XCTFail("Must not close the existing editor") },
        awaitEditor: { XCTFail("No reopen needed"); return false })
        XCTAssertTrue(raised)
    }

    func testHiddenUnlistedEditorCanCloseThenReopenButStopsAtVerifiedFocus() async throws {
        var toggles = 0, checks = 0
        try await FinalCutReviewPresentation.present(validate: {}, raiseExisting: { false },
            toggleEditor: { toggles += 1 }, awaitEditor: {
                checks += 1; return toggles == 2
            })
        XCTAssertEqual(toggles, 2)
        XCTAssertEqual(checks, 2)
    }

    func testClosedEditorOpensOnce() async throws {
        var toggles = 0
        try await FinalCutReviewPresentation.present(validate: {}, raiseExisting: { false },
            toggleEditor: { toggles += 1 }, awaitEditor: { true })
        XCTAssertEqual(toggles, 1)
    }

    func testUnavailableEditorHasBoundedRetriesAndReportsFailure() async {
        var toggles = 0
        do {
            try await FinalCutReviewPresentation.present(validate: {}, raiseExisting: { false },
                toggleEditor: { toggles += 1 }, awaitEditor: { false })
            XCTFail("An unverified window must not count as success")
        } catch { }
        XCTAssertEqual(toggles, 2)
    }

    func testChangedProjectOrSelectionStopsBeforeAnotherToggle() async {
        var changed = false, toggles = 0
        do {
            try await FinalCutReviewPresentation.present(validate: {
                if changed { throw Failure.changedProject }
            }, raiseExisting: { false }, toggleEditor: { toggles += 1 },
            awaitEditor: { changed = true; return false })
            XCTFail("A different project/clip must not be reopened")
        } catch Failure.changedProject { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(toggles, 1)
    }

    func testFocusSuccessCannotHideAConcurrentProjectChange() async {
        var changed = false
        do {
            try await FinalCutReviewPresentation.present(validate: {
                if changed { throw Failure.changedProject }
            }, raiseExisting: { changed = true; return true },
            toggleEditor: { XCTFail("Must not toggle another project") }, awaitEditor: { false })
            XCTFail("Recheck ownership after waiting for focus")
        } catch Failure.changedProject { } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testUncertainPressIsNeverBlindlyRepeated() async {
        var toggles = 0
        do {
            try await FinalCutReviewPresentation.present(validate: {}, raiseExisting: { false },
                toggleEditor: { toggles += 1; throw Failure.uncertainPress },
                awaitEditor: { XCTFail("Press failed"); return false })
            XCTFail("Expected error")
        } catch Failure.uncertainPress { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(toggles, 1)
    }

    func testCancelledAnalysisCannotToggleAnEditorDuringForegroundHandoff() async {
        var toggles = 0
        let task = Task {
            try await FinalCutReviewPresentation.present(validate: {}, raiseExisting: {
                withUnsafeCurrentTask { $0?.cancel() }; return false
            }, toggleEditor: { toggles += 1 }, awaitEditor: { false })
        }
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(toggles, 0)
    }
}
