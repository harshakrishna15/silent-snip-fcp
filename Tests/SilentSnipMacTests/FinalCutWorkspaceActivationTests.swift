import XCTest
@testable import SilentSnipMac

final class FinalCutWorkspaceActivationTests: XCTestCase {
    private struct OwnershipChanged: Error {}
    private struct RaiseFailed: Error {}

    func testSuccessfulFocusAttributesSkipRaiseLookupAndAction() throws {
        var attributes = 0
        XCTAssertFalse(try FinalCutWorkspaceActivation.pin(setAttributes: { attributes += 1 }, isFocused: { true },
            supportsRaise: { XCTFail("The ready workspace needs no extra action lookup"); return true },
            authorizeRaise: { XCTFail("No Raise should be authorized") }, raise: { XCTFail("No Raise should be sent") }))
        XCTAssertEqual(attributes, 1)
    }

    func testIgnoredAttributesUseExactlyOneAdvertisedRaiseAfterFreshAuthorization() throws {
        var events: [String] = []
        XCTAssertTrue(try FinalCutWorkspaceActivation.pin(setAttributes: { events.append("attributes") },
            isFocused: { events.append("observe"); return false }, supportsRaise: { events.append("advertised"); return true },
            authorizeRaise: { events.append("authorize") }, raise: { events.append("raise") }))
        XCTAssertEqual(events, ["attributes", "observe", "advertised", "authorize", "raise"])
    }

    func testUnadvertisedRaiseLeavesOnlyReadOnlyFocusSettlingToCaller() throws {
        var attributes = 0
        XCTAssertFalse(try FinalCutWorkspaceActivation.pin(setAttributes: { attributes += 1 }, isFocused: { false },
            supportsRaise: { false }, authorizeRaise: { XCTFail("An unsupported action cannot be authorized") },
            raise: { XCTFail("An unsupported action cannot be attempted") }))
        XCTAssertEqual(attributes, 1)
    }

    func testChangedForegroundProjectOrOpenDialogPreventsRaise() {
        var actions = 0
        XCTAssertThrowsError(try FinalCutWorkspaceActivation.pin(setAttributes: {}, isFocused: { false }, supportsRaise: { true },
            authorizeRaise: { throw OwnershipChanged() }, raise: { actions += 1 }))
        XCTAssertEqual(actions, 0)
    }

    func testAnUncertainRaiseIsNeverReplayed() {
        var attributes = 0, actions = 0
        XCTAssertThrowsError(try FinalCutWorkspaceActivation.pin(setAttributes: { attributes += 1 }, isFocused: { false }, supportsRaise: { true },
            authorizeRaise: {}, raise: { actions += 1; throw RaiseFailed() }))
        XCTAssertEqual(attributes, 1)
        XCTAssertEqual(actions, 1)
    }
}
