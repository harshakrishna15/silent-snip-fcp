import Foundation
import XCTest
@testable import SilentSnipMac

@MainActor final class FinalCutOwnedInputFocusTests: XCTestCase {
    private struct FocusFailure: Error {}
    private struct RestoreFailure: Error {}

    func testReadyHostNeedsNoActivationAndStillRequiresStrictFocus() async throws {
        var assertions = 0
        try await FinalCutOwnedInputFocus.prepare(ownsForeground: { false }, restore: {
            XCTFail("A ready host must not receive another activation")
        }, assertFocused: { assertions += 1 })
        XCTAssertEqual(assertions, 1)
    }

    func testOwnHelperIsRestoredBeforeTheStrictAssertion() async throws {
        var helperIsForeground = true
        var events: [String] = []
        try await FinalCutOwnedInputFocus.prepare(ownsForeground: { helperIsForeground }, restore: {
            events.append("restore")
            await Task.yield()
            helperIsForeground = false
        }, assertFocused: {
            events.append("assert")
            XCTAssertFalse(helperIsForeground)
        })
        XCTAssertEqual(events, ["restore", "assert"])
    }

    func testForeignForegroundIsNeverActivatedOverAndItsFocusFailureEscapes() async throws {
        var restorations = 0, assertions = 0
        do {
            try await FinalCutOwnedInputFocus.prepare(ownsForeground: { false }, restore: {
                restorations += 1
            }, assertFocused: {
                assertions += 1
                throw FocusFailure()
            })
            XCTFail("A foreign app cannot authorize host input")
        } catch is FocusFailure { }
        XCTAssertEqual(restorations, 0)
        XCTAssertEqual(assertions, 1)
    }

    func testFailedRestorationPropagatesWithoutAuthorizingInput() async throws {
        do {
            try await FinalCutOwnedInputFocus.prepare(ownsForeground: { true }, restore: {
                throw RestoreFailure()
            }, assertFocused: {
                XCTFail("A failed restore cannot reach a successful focus authorization")
            })
            XCTFail("The original restore error must escape")
        } catch is RestoreFailure { }
    }

    func testHelperStillForegroundCannotPassAfterRestoreReturns() async throws {
        var restorations = 0, assertions = 0
        do {
            try await FinalCutOwnedInputFocus.prepare(ownsForeground: { true }, restore: {
                restorations += 1
            }, assertFocused: {
                assertions += 1
                throw FocusFailure()
            })
            XCTFail("Returning from restore is not proof that the host owns focus")
        } catch is FocusFailure { }
        XCTAssertEqual(restorations, 1)
        XCTAssertEqual(assertions, 1)
    }

    func testRestorationCancellationPropagatesWithoutAnotherAction() async throws {
        var restorations = 0
        do {
            try await FinalCutOwnedInputFocus.prepare(ownsForeground: { true }, restore: {
                restorations += 1
                throw CancellationError()
            }, assertFocused: {
                XCTFail("Cancelled restoration cannot authorize input")
            })
            XCTFail("Cancellation must escape unchanged")
        } catch is CancellationError { }
        XCTAssertEqual(restorations, 1)
    }

    func testAlreadyCancelledTaskDoesNotRestoreOrAssert() async throws {
        let work = Task { @MainActor in
            try await FinalCutOwnedInputFocus.prepare(ownsForeground: {
                XCTFail("An already cancelled task must stop before observing ownership")
                return true
            }, restore: {
                XCTFail("An already cancelled task must not activate the host")
            }, assertFocused: {
                XCTFail("An already cancelled task cannot authorize input")
            })
        }
        work.cancel()
        do {
            try await work.value
            XCTFail("Task cancellation must escape")
        } catch is CancellationError { }
    }
}
