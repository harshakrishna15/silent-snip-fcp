import XCTest
@testable import SilentSnipMac

final class FinalCutActivationReadinessTests: XCTestCase {
    private typealias State = FinalCutActivationReadiness.ApplicationState

    func testAlreadyFocusedRequiresTwoFreshApplicationChecksAroundOneWindowRead() {
        var applicationReads = 0, windowReads = 0
        XCTAssertTrue(FinalCutActivationReadiness.alreadyFocused(hostPID: 101, mainWindow: 7,
            readApplication: { applicationReads += 1; return State(active: true, foregroundPID: 101) },
            readWindows: { windowReads += 1; return (7, 7) }, equals: ==))
        XCTAssertEqual(applicationReads, 2)
        XCTAssertEqual(windowReads, 1)
    }

    func testForeignHelperOrUnavailableForegroundCannotUsePinnedWindowSnapshot() {
        for foreground: Int32? in [202, nil] {
            var windowsRead = false
            XCTAssertFalse(FinalCutActivationReadiness.alreadyFocused(hostPID: 101, mainWindow: 7,
                readApplication: { State(active: true, foregroundPID: foreground) },
                readWindows: { windowsRead = true; return (7, 7) }, equals: ==))
            XCTAssertFalse(windowsRead)
        }
        XCTAssertFalse(FinalCutActivationReadiness.alreadyFocused(hostPID: 0, mainWindow: 7,
            readApplication: { State(active: true, foregroundPID: 0) }, readWindows: { (7, 7) }, equals: ==))
    }

    func testBothFocusedAndMainWindowsMustBeTheExactPinnedWorkspace() {
        let observations: [(Int?, Int?)] = [(8, 7), (7, 8), (nil, 7), (7, nil)]
        for windows in observations {
            XCTAssertFalse(FinalCutActivationReadiness.alreadyFocused(hostPID: 101, mainWindow: 7,
                readApplication: { State(active: true, foregroundPID: 101) },
                readWindows: { windows }, equals: ==))
        }
    }

    func testStaleFrontmostAndWindowValuesCannotOverrideInactiveApplication() {
        XCTAssertFalse(FinalCutActivationReadiness.alreadyFocused(hostPID: 101, mainWindow: 7,
            readApplication: { State(active: false, foregroundPID: 101) }, readWindows: { (7, 7) }, equals: ==))
    }

    func testApplicationSwitchDuringAXReadRejectsThePreviouslyReadyState() {
        var state = State(active: true, foregroundPID: 101)
        XCTAssertFalse(FinalCutActivationReadiness.alreadyFocused(hostPID: 101, mainWindow: 7,
            readApplication: { state }, readWindows: {
                state = State(active: false, foregroundPID: 202)
                return (7, 7)
            }, equals: ==))
    }

    func testEveryActivationDecisionRereadsApplicationAndWindowOwnership() {
        var state = State(active: true, foregroundPID: 101)
        var windows: (Int?, Int?) = (7, 7)
        func ready() -> Bool {
            FinalCutActivationReadiness.alreadyFocused(hostPID: 101, mainWindow: 7,
                readApplication: { state }, readWindows: { windows }, equals: ==)
        }
        XCTAssertTrue(ready())
        windows = (8, 7)
        XCTAssertFalse(ready(), "A formerly focused workspace must not remain cached")
        windows = (7, 7)
        state = State(active: false, foregroundPID: 202)
        XCTAssertFalse(ready())
        state = State(active: true, foregroundPID: 101)
        XCTAssertTrue(ready())
    }
}
