import XCTest
@testable import SilentSnipMac

final class FinalCutShareInvocationTests: XCTestCase {
    private enum Failure: Error { case input }

    @MainActor func testAdvertisedShortcutDoesNotAlsoInvokeMenu() async throws {
        var deliveries = 0
        let usedShortcut = try await FinalCutShareInvocation.perform(shortcut: {
            deliveries += 1
            return true
        }, menu: {
            deliveries += 1
            XCTFail("A successful shortcut must not dispatch a second Share")
        })
        XCTAssertTrue(usedShortcut)
        XCTAssertEqual(deliveries, 1)
    }

    @MainActor func testUnavailableAssignmentFallsBackBeforeInput() async throws {
        var deliveries = 0
        let usedShortcut = try await FinalCutShareInvocation.perform(shortcut: {
            // The exact menu command has no usable assignment; no key was sent.
            false
        }, menu: { deliveries += 1 })
        XCTAssertFalse(usedShortcut)
        XCTAssertEqual(deliveries, 1)
    }

    @MainActor func testUncertainShortcutDeliveryNeverRetriesThroughMenu() async {
        enum Failure: Error { case uncertainDelivery }
        var attemptedDeliveries = 0
        do {
            _ = try await FinalCutShareInvocation.perform(shortcut: {
                attemptedDeliveries += 1
                throw Failure.uncertainDelivery
            }, menu: {
                attemptedDeliveries += 1
                XCTFail("A possibly delivered Share must never be retried")
            })
            XCTFail("The original input failure must propagate")
        } catch Failure.uncertainDelivery {
            XCTAssertEqual(attemptedDeliveries, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor func testLateFinalMenuCompletionIsObservedWithoutRepeatingAnyInput() async throws {
        var dispatches = 0
        var observations = 0
        let usedShortcut = try await FinalCutShareInvocation.perform(shortcut: { false }, menu: {
            let observed = try await FinalCutShareInvocation.performMenu(menu: { finalAttempt in
                dispatches += 1
                finalAttempt() // The final AXPick was attempted, and may already have opened its panel.
                throw Failure.input
            }, observeCompletion: {
                observations += 1
                return self.confirmation().matches(expectedProject: "Pinned")
            })
            XCTAssertTrue(observed)
        })
        XCTAssertFalse(usedShortcut)
        XCTAssertEqual(dispatches, 1)
        XCTAssertEqual(observations, 1)
    }

    @MainActor func testFailureBeforeFinalDispatchCannotBeAcceptedEvenIfMatchingPanelAppears() async {
        var observations = 0
        do {
            _ = try await FinalCutShareInvocation.performMenu(menu: { _ in
                throw Failure.input // Focus/action validation or an earlier File/Share step failed.
            }, observeCompletion: {
                observations += 1
                return true
            })
            XCTFail("No final dispatch means no completion may be inferred")
        } catch Failure.input {
            XCTAssertEqual(observations, 0)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor func testUnrelatedPanelProjectAndMissingConfirmationPreserveOriginalFailureWithoutRetry() async {
        let invalid = [confirmation(project: "Other"), confirmation(project: nil),
            confirmation(title: "Other Destination"), confirmation(title: nil),
            confirmation(hasNext: false), confirmation(hasCancel: false),
            confirmation(ownForeground: false)]
        for snapshot in invalid {
            var dispatches = 0
            do {
                _ = try await FinalCutShareInvocation.performMenu(menu: { finalAttempt in
                    dispatches += 1
                    finalAttempt()
                    throw Failure.input
                }, observeCompletion: { snapshot.matches(expectedProject: "Pinned") })
                XCTFail("An unrelated or incomplete panel cannot complete the command")
            } catch Failure.input {
                XCTAssertEqual(dispatches, 1)
            } catch { XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(confirmation(project: "").matches(expectedProject: ""))
    }

    @MainActor func testSuccessfulMenuDispatchDoesNotNeedExceptionalCompletionObservation() async throws {
        var dispatches = 0
        let observed = try await FinalCutShareInvocation.performMenu(menu: { finalAttempt in
            dispatches += 1
            finalAttempt()
        }, observeCompletion: {
            XCTFail("Normal confirmation waiting remains responsible for successful input")
            return true
        })
        XCTAssertFalse(observed)
        XCTAssertEqual(dispatches, 1)
    }

    @MainActor func testCancellationAfterFinalMenuAttemptIsNeverSwallowedAsCompletion() async {
        var observations = 0
        do {
            _ = try await FinalCutShareInvocation.performMenu(menu: { finalAttempt in
                finalAttempt()
                throw CancellationError()
            }, observeCompletion: {
                observations += 1
                return true
            })
            XCTFail("Cancellation must remain cancellation")
        } catch is CancellationError {
            XCTAssertEqual(observations, 0)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    private func confirmation(project: String? = "Pinned", title: String? = "Silent Snip",
                              hasNext: Bool = true, hasCancel: Bool = true,
                              ownForeground: Bool = true) -> FinalCutShareConfirmationObservation {
        .init(projectName: project, panelTitle: title, hasNext: hasNext, hasCancel: hasCancel,
            foregroundIsHostOrHelper: ownForeground)
    }
}
