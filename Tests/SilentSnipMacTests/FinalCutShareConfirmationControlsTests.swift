import ApplicationServices
import XCTest
@testable import SilentSnipMac

final class FinalCutShareConfirmationControlsTests: XCTestCase {
    private func button(_ title: String = "Next…", enabled: Bool = true) -> [String: Any] {
        [kAXRoleAttribute: kAXButtonRole, kAXTitleAttribute: title, kAXEnabledAttribute: NSNumber(value: enabled)]
    }

    func testConfirmationReusesMountedPathButAlwaysReadsCurrentEnabledState() {
        var fields: [Int: [String: Any]] = [0: [kAXRoleAttribute: kAXSheetRole], 1: button()]
        let lookup = FinalCutShareConfirmationControls<Int>(read: { id, _ in fields[id] ?? [:] },
            children: { $0 == 0 ? [1] : [] }, equals: ==)
        XCTAssertEqual(lookup.next(in: 0, shouldContinue: { true }), 1)
        fields[1]?[kAXEnabledAttribute] = NSNumber(value: false)
        XCTAssertNil(lookup.next(in: 0, shouldContinue: { true }), "A previous enabled observation is never reused")
        fields[1]?[kAXEnabledAttribute] = NSNumber(value: true)
        XCTAssertEqual(lookup.next(in: 0, shouldContinue: { true }), 1)
        XCTAssertEqual(lookup.counters["confirmation.searches"], 1)
        XCTAssertEqual(lookup.counters["confirmation.pathChecks"], 2)
    }

    func testDetachedControlAndReplacedPanelCannotReceiveConfirmation() {
        let fields: [Int: [String: Any]] = [0: [kAXRoleAttribute: kAXSheetRole],
            1: button(), 2: button(), 3: [kAXRoleAttribute: kAXSheetRole]]
        var children = [0: [1], 3: [2]]
        let lookup = FinalCutShareConfirmationControls<Int>(read: { id, _ in fields[id] ?? [:] },
            children: { children[$0] ?? [] }, equals: ==)
        XCTAssertEqual(lookup.next(in: 0, shouldContinue: { true }), 1)
        children[0] = []
        XCTAssertNil(lookup.next(in: 0, shouldContinue: { true }))
        XCTAssertEqual(lookup.next(in: 3, shouldContinue: { true }), 2)
        XCTAssertEqual(lookup.counters["confirmation.invalidations"], 1)
    }

    func testUnavailableControlIsNotNegativeCachedAndChangedTitleIsRejected() {
        var fields: [Int: [String: Any]] = [0: [kAXRoleAttribute: kAXSheetRole]]
        var children: [Int: [Int]] = [0: []]
        let lookup = FinalCutShareConfirmationControls<Int>(read: { id, _ in fields[id] ?? [:] },
            children: { children[$0] ?? [] }, equals: ==)
        XCTAssertNil(lookup.next(in: 0, shouldContinue: { true }))
        fields[1] = button(); children[0] = [1]
        XCTAssertEqual(lookup.next(in: 0, shouldContinue: { true }), 1)
        fields[1] = button("Cancel")
        XCTAssertNil(lookup.next(in: 0, shouldContinue: { true }))
        XCTAssertNil(lookup.next(in: 0, shouldContinue: { false }))
    }
}
