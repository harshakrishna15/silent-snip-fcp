import ApplicationServices
import XCTest
@testable import SilentSnipMac

final class FinalCutMenuPathTests: XCTestCase {
    private final class Host {
        typealias Route = FinalCutMenuPath<Int>
        var nodes: [Int: [String: Any]] = [
            0: [kAXRoleAttribute: kAXMenuBarRole, kAXChildrenAttribute: [1, 9]],
            1: [kAXRoleAttribute: kAXMenuBarItemRole, kAXTitleAttribute: "File", kAXEnabledAttribute: true, kAXChildrenAttribute: [2]],
            2: [kAXRoleAttribute: kAXMenuRole, kAXChildrenAttribute: [3]],
            3: [kAXRoleAttribute: kAXMenuItemRole, kAXTitleAttribute: "Share", kAXEnabledAttribute: true, kAXChildrenAttribute: [4]],
            4: [kAXRoleAttribute: kAXMenuRole, kAXChildrenAttribute: [5, 6]],
            5: [kAXRoleAttribute: kAXMenuItemRole, kAXTitleAttribute: "Silent Snip…", kAXEnabledAttribute: true, kAXChildrenAttribute: [Int]()],
            6: [kAXRoleAttribute: kAXMenuItemRole, kAXTitleAttribute: "Other Destination…", kAXEnabledAttribute: true, kAXChildrenAttribute: [Int]()],
            9: [kAXRoleAttribute: kAXMenuBarItemRole, kAXTitleAttribute: "Edit", kAXEnabledAttribute: true, kAXChildrenAttribute: [Int]()]
        ]
        var unowned: Set<Int> = []
        var advertised: [String]? = [kAXPressAction, kAXPickAction]
        var requests: [(Int, [String])] = []
        var actionRequests = [Int]()
        lazy var route = Route(titles: ["File", "Share", "Silent Snip…"], read: { [unowned self] id, names in
            self.requests.append((id, names))
            return names.reduce(into: [:]) { if let value = self.nodes[id]?[$1] { $0[$1] = value } }
        }, owned: { [unowned self] in !self.unowned.contains($0) }, actions: { [unowned self] id in
            self.actionRequests.append(id)
            return self.advertised
        }, equals: ==)
        func command() -> Route.Item? { route.command(in: 0, shouldContinue: { true }) }
        func input(_ index: Int = 2, container: Int = 4) -> Route.Item? {
            route.input(in: 0, index: index, container: container, shouldContinue: { true })
        }
    }

    func testMissingShortcutStillSharesOneDiscoveryWithOrdinaryMenuInputs() throws {
        let host = Host()
        let command = try XCTUnwrap(host.command())
        XCTAssertEqual(command.element, 5)
        XCTAssertNil(command.values[kAXMenuItemCmdVirtualKeyAttribute])
        XCTAssertEqual(host.input(0, container: 0)?.element, 1)
        XCTAssertEqual(host.input(1, container: 2)?.element, 3)
        XCTAssertEqual(host.input()?.element, 5)
        XCTAssertEqual(host.route.counters["menuPath.searches"], 1)
        XCTAssertEqual(host.actionRequests, [1, 3, 5])
        XCTAssertTrue(host.requests.contains { id, names in
            id == 5 && names.contains(kAXEnabledAttribute) && names.contains(kAXMenuItemCmdVirtualKeyAttribute)
                && names.contains(kAXMenuItemCmdModifiersAttribute) && names.contains(kAXMenuItemCmdCharAttribute)
                && names.contains(kAXMenuItemCmdGlyphAttribute)
        }, "Shortcut metadata must be batched, not fetched one scalar at a time")
        XCTAssertFalse(host.requests.contains { $0.1.count == 1 && $0.1.contains(kAXEnabledAttribute) })
    }

    func testShortcutAndEnabledValuesAreAlwaysFresh() throws {
        let host = Host()
        host.nodes[5]?[kAXMenuItemCmdVirtualKeyAttribute] = 17
        host.nodes[5]?[kAXMenuItemCmdModifiersAttribute] = 0
        host.nodes[5]?[kAXMenuItemCmdCharAttribute] = "t"
        XCTAssertEqual(try XCTUnwrap(host.command()).values[kAXMenuItemCmdVirtualKeyAttribute] as? Int, 17)
        host.nodes[5]?[kAXMenuItemCmdVirtualKeyAttribute] = 18
        XCTAssertEqual(try XCTUnwrap(host.command()).values[kAXMenuItemCmdVirtualKeyAttribute] as? Int, 18)
        host.nodes[5]?[kAXEnabledAttribute] = false
        XCTAssertEqual(try XCTUnwrap(host.command()).values[kAXEnabledAttribute] as? Bool, false)
        XCTAssertNil(host.input())
        XCTAssertTrue(host.actionRequests.isEmpty)
    }

    func testRenamedSiblingMakesCommandAmbiguousWithoutChangingChildIdentities() throws {
        let host = Host()
        _ = try XCTUnwrap(host.command())
        host.nodes[6]?[kAXTitleAttribute] = "Silent Snip…"
        XCTAssertNil(host.input())
        XCTAssertTrue(host.actionRequests.isEmpty)
        XCTAssertEqual(host.route.counters["menuPath.invalidations"], 1)
    }

    func testUnreadableSiblingCannotProveCommandUnique() throws {
        for attribute in [kAXTitleAttribute, kAXRoleAttribute] {
            let host = Host(); _ = try XCTUnwrap(host.command())
            host.nodes[6]?.removeValue(forKey: attribute)
            XCTAssertNil(host.input())
            XCTAssertTrue(host.actionRequests.isEmpty)
        }
        let host = Host(); _ = try XCTUnwrap(host.command()); host.unowned.insert(6)
        XCTAssertNil(host.input())
        XCTAssertTrue(host.actionRequests.isEmpty)
    }

    func testDetachedRenamedDisabledOrUnreadableAncestorCannotAuthorizeInput() throws {
        let mutations: [(Host) -> Void] = [
            { $0.nodes[0]?[kAXChildrenAttribute] = [9] },
            { $0.nodes[1]?[kAXChildrenAttribute] = [Int]() },
            { $0.nodes[2]?.removeValue(forKey: kAXChildrenAttribute) },
            { $0.nodes[3]?[kAXTitleAttribute] = "Different Command" },
            { $0.nodes[3]?[kAXEnabledAttribute] = false },
            { $0.nodes[3]?.removeValue(forKey: kAXEnabledAttribute) },
            { $0.nodes[4]?[kAXRoleAttribute] = kAXGroupRole },
            { $0.nodes[5]?.removeValue(forKey: kAXEnabledAttribute) },
            { $0.nodes[5]?[kAXRoleAttribute] = kAXButtonRole }
        ]
        for mutate in mutations {
            let host = Host(); _ = try XCTUnwrap(host.command()); mutate(host)
            XCTAssertNil(host.input())
            XCTAssertTrue(host.actionRequests.isEmpty)
        }
    }

    func testEveryMountedObjectMustBelongToPinnedHost() throws {
        for id in [0, 1, 2, 3, 4, 5] {
            let host = Host(); _ = try XCTUnwrap(host.command()); host.unowned.insert(id)
            XCTAssertNil(host.input())
            XCTAssertTrue(host.actionRequests.isEmpty)
        }
    }

    func testInputUsesOnlyCurrentlyAdvertisedBoundedActions() throws {
        let host = Host(); _ = try XCTUnwrap(host.command())
        host.advertised = [kAXPickAction]
        XCTAssertEqual(host.input()?.actions, [kAXPickAction])
        for actions: [String]? in [nil, [], ["AXShowMenu"], Array(repeating: kAXPressAction, count: 33),
                                  [kAXPressAction, String(repeating: "x", count: 129)]] {
            host.advertised = actions
            XCTAssertNil(host.input())
        }
    }

    func testMissingCommandIsNotNegativelyCached() throws {
        let host = Host(); host.nodes[4]?[kAXChildrenAttribute] = [6]
        XCTAssertNil(host.command())
        host.nodes[4]?[kAXChildrenAttribute] = [5, 6]
        XCTAssertEqual(try XCTUnwrap(host.command()).element, 5)
        XCTAssertEqual(host.route.counters["menuPath.searches"], 2)
    }

    func testOrdinaryRouteCanOpenSubmenusNotMaterializedForClosedShortcutDiscovery() throws {
        let host = Host()
        host.nodes[1]?[kAXChildrenAttribute] = [Int]()
        host.nodes[3]?[kAXChildrenAttribute] = [Int]()
        XCTAssertNil(host.command())
        XCTAssertEqual(host.input(0, container: 0)?.element, 1)
        // Native File opens, then native Share opens. Each newly observed
        // prefix is uniquely resolved without repeating any input.
        host.nodes[1]?[kAXChildrenAttribute] = [2]
        XCTAssertEqual(host.input(1, container: 2)?.element, 3)
        host.nodes[3]?[kAXChildrenAttribute] = [4]
        XCTAssertEqual(try XCTUnwrap(host.input()).element, 5)
        XCTAssertEqual(host.actionRequests, [1, 3, 5])
    }

    func testAmbiguousHierarchyMissingChildrenAndOversizedMenusReject() {
        let mutations: [(Host) -> Void] = [
            { $0.nodes[9] = $0.nodes[1] },
            { $0.nodes[2]?[kAXChildrenAttribute] = [3, 3] },
            { $0.nodes[1]?.removeValue(forKey: kAXChildrenAttribute) },
            { $0.nodes[0]?[kAXChildrenAttribute] = Array(repeating: 1, count: 257) },
            { $0.nodes[1]?[kAXChildrenAttribute] = Array(repeating: 2, count: 17) }
        ]
        for mutate in mutations {
            let host = Host(); mutate(host)
            XCTAssertNil(host.command())
            XCTAssertTrue(host.actionRequests.isEmpty)
        }
    }

    func testDifferentRootOrContainerCannotReuseMountedInput() throws {
        let host = Host(); _ = try XCTUnwrap(host.command()); host.nodes[10] = host.nodes[0]
        XCTAssertNil(host.route.input(in: 10, index: 2, container: 4, shouldContinue: { true }))
        XCTAssertTrue(host.actionRequests.isEmpty)
        _ = try XCTUnwrap(host.command())
        XCTAssertNil(host.input(container: 2))
        XCTAssertTrue(host.actionRequests.isEmpty)
    }

    func testStoppedObservationDoesNotReadOrChooseAnAction() throws {
        let host = Host()
        XCTAssertNil(host.route.command(in: 0, shouldContinue: { false }))
        XCTAssertTrue(host.requests.isEmpty)
        _ = try XCTUnwrap(host.command())
        XCTAssertNil(host.route.input(in: 0, index: 2, container: 4, shouldContinue: { false }))
        XCTAssertTrue(host.actionRequests.isEmpty)
        XCTAssertEqual(host.input()?.element, 5)
    }
}
