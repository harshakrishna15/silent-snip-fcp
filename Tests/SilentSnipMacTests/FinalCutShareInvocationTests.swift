import XCTest
@testable import SilentSnipMac

final class FinalCutShareInvocationTests: XCTestCase {
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
}
