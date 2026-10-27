import XCTest
@testable import SilentSnipMac

final class FinalCutHelperLifetimeTests: XCTestCase {
    func testManualLaunchWithoutFinalCutAllowsSetup() {
        var lifetime = FinalCutHelperLifetime()
        XCTAssertEqual(lifetime.update(hostIsRunning: false, isBusy: false), .wait)
        XCTAssertEqual(lifetime.update(hostIsRunning: false, isBusy: true), .wait)
        XCTAssertFalse(lifetime.isStopping)
    }

    func testIdleHelperQuitsAfterObservedHostExits() {
        var lifetime = FinalCutHelperLifetime()
        XCTAssertEqual(lifetime.update(hostIsRunning: true, isBusy: false), .wait)
        XCTAssertEqual(lifetime.update(hostIsRunning: false, isBusy: false), .quit)
        XCTAssertTrue(lifetime.isStopping)
    }

    func testHostRemainsAliveWhenOnlyItsWindowCloses() {
        var lifetime = FinalCutHelperLifetime()
        for busy in [false, true, false] {
            XCTAssertEqual(lifetime.update(hostIsRunning: true, isBusy: busy), .wait)
            XCTAssertFalse(lifetime.isStopping)
        }
    }

    func testHostExitCancelsOnceAndWaitsForCleanup() {
        var lifetime = FinalCutHelperLifetime()
        XCTAssertEqual(lifetime.update(hostIsRunning: true, isBusy: true), .wait)
        XCTAssertEqual(lifetime.update(hostIsRunning: false, isBusy: true), .cancelWork)
        XCTAssertEqual(lifetime.update(hostIsRunning: false, isBusy: true), .wait)
        XCTAssertEqual(lifetime.update(hostIsRunning: false, isBusy: false), .quit)
    }

    func testQuickHostRelaunchDoesNotReviveCancelledHelperWork() {
        var lifetime = FinalCutHelperLifetime()
        XCTAssertEqual(lifetime.update(hostIsRunning: true, isBusy: true), .wait)
        XCTAssertEqual(lifetime.update(hostIsRunning: false, isBusy: true), .cancelWork)
        XCTAssertEqual(lifetime.update(hostIsRunning: true, isBusy: true), .wait)
        XCTAssertEqual(lifetime.update(hostIsRunning: true, isBusy: false), .quit)
    }
}
