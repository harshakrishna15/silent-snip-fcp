import ApplicationServices
import XCTest
@testable import SilentSnipMac

final class ClosedShareAXCommandTests: XCTestCase {
    private typealias Command = ClosedShareAXCommand<Int>
    private func tree() -> [Int: Command.Node] {
        [0: .init(role: kAXMenuBarRole, title: nil, enabled: nil, children: [1]),
         1: .init(role: kAXMenuBarItemRole, title: "File", enabled: true, children: [2]),
         2: .init(role: kAXMenuRole, title: nil, enabled: nil, children: [3]),
         3: .init(role: kAXMenuItemRole, title: "Share", enabled: true, children: [4]),
         4: .init(role: kAXMenuRole, title: nil, enabled: nil, children: [5]),
         5: .init(role: kAXMenuItemRole, title: "Silent Snip…", enabled: true, children: [])]
    }
    private func resolve(_ nodes: [Int: Command.Node], bar: Int = 0, actions: [String] = [kAXPickAction]) throws -> Command {
        try Command.resolve(menuBar: bar, read: { try XCTUnwrap(nodes[$0]) }, actions: { _ in actions }, shouldContinue: { true })
    }

    func testUniqueClosedHierarchyRetainsEveryIdentityAndOnlyAdvertisedAction() throws {
        let result = try resolve(tree())
        XCTAssertEqual(result.hierarchy, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(result.item, 5)
        XCTAssertEqual(result.action, kAXPickAction)
        XCTAssertEqual(try resolve(tree(), actions: [kAXPickAction, kAXPressAction]).action, kAXPressAction)
        XCTAssertThrowsError(try resolve(tree(), actions: []))
        XCTAssertThrowsError(try resolve(tree(), actions: ["AXShowMenu"]))
    }

    func testProductionRequiresPressEvenWhenPickIsAdvertised() throws {
        let nodes = tree()
        func production(actions: [String]) throws -> Command {
            try Command.resolve(menuBar: 0, read: { try XCTUnwrap(nodes[$0]) },
                actions: { _ in actions }, pressOnly: true, shouldContinue: { true })
        }
        XCTAssertThrowsError(try production(actions: [kAXPickAction]))
        XCTAssertEqual(try production(actions: [kAXPickAction, kAXPressAction]).action, kAXPressAction)
    }

    func testProductionRejectsAnUnreadableSiblingRatherThanAssumingUniqueCommand() throws {
        for title: String? in [nil, "Silent Snip…"] {
            var nodes = tree()
            nodes[4] = .init(role: kAXMenuRole, title: nil, enabled: nil, children: [5, 6])
            nodes[6] = .init(role: kAXMenuItemRole, title: title, enabled: nil, children: [])
            XCTAssertThrowsError(try Command.resolve(menuBar: 0, read: { try XCTUnwrap(nodes[$0]) },
                actions: { _ in [kAXPressAction] }, pressOnly: true, shouldContinue: { true }))
        }
    }

    func testUnknownOrDisabledStateAtEveryRequiredItemRejectsBeforeInput() {
        for id in [1, 3, 5] {
            for enabled: Bool? in [false, nil] {
                var nodes = tree(); let node = nodes[id]!
                nodes[id] = .init(role: node.role, title: node.title, enabled: enabled, children: node.children)
                XCTAssertThrowsError(try resolve(nodes))
            }
        }
    }

    func testDuplicateFileShareTargetAndSubmenuAreRejected() {
        for (parentID, originalID) in [(0, 1), (2, 3), (4, 5), (1, 2)] {
            var nodes = tree(); let parent = nodes[parentID]!
            nodes[9] = nodes[originalID]
            nodes[parentID] = .init(role: parent.role, title: parent.title, enabled: parent.enabled,
                children: parent.children + [9])
            XCTAssertThrowsError(try resolve(nodes))
        }
    }

    func testChangedAncestorOrMenuBarIdentityInvalidatesOtherwiseIdenticalLeaf() throws {
        let retained = try resolve(tree())
        var parentChanged = tree()
        parentChanged[7] = parentChanged[2]
        parentChanged[1] = .init(role: kAXMenuBarItemRole, title: "File", enabled: true, children: [7])
        XCTAssertFalse(retained.isSame(as: try resolve(parentChanged), equals: ==))
        var rootChanged = tree(); rootChanged[10] = rootChanged[0]
        XCTAssertFalse(retained.isSame(as: try resolve(rootChanged, bar: 10), equals: ==))
    }

    func testChangedAdvertisedActionsCannotReuseTheFirstChoice() throws {
        let retained = try resolve(tree(), actions: [kAXPickAction])
        XCTAssertFalse(retained.isSame(as: try resolve(tree(), actions: [kAXPressAction]), equals: ==))
        XCTAssertFalse(retained.isSame(as: try resolve(tree(), actions: [kAXPickAction, "AXShowMenu"]), equals: ==))
        XCTAssertTrue(retained.isSame(as: try resolve(tree()), equals: ==))
    }

    func testMissingWrongRoleOrInterruptedHierarchyDoesNotGuessAnAction() {
        var nodes = tree()
        nodes[3] = .init(role: kAXButtonRole, title: "Share", enabled: true, children: [4])
        XCTAssertThrowsError(try resolve(nodes))
        nodes = tree(); nodes[4] = .init(role: kAXMenuRole, title: nil, enabled: nil, children: [])
        XCTAssertThrowsError(try resolve(nodes))
        XCTAssertThrowsError(try Command.resolve(menuBar: 0, read: { try XCTUnwrap(self.tree()[$0]) },
            actions: { _ in [kAXPickAction] }, shouldContinue: { false }))
    }

    func testOversizedChildSubmenuAndActionListsAreRejected() {
        var nodes = tree()
        nodes[0] = .init(role: kAXMenuBarRole, title: nil, enabled: nil, children: Array(repeating: 1, count: 257))
        XCTAssertThrowsError(try resolve(nodes))
        nodes = tree()
        nodes[1] = .init(role: kAXMenuBarItemRole, title: "File", enabled: true, children: Array(repeating: 2, count: 17))
        XCTAssertThrowsError(try resolve(nodes))
        XCTAssertThrowsError(try resolve(tree(), actions: Array(repeating: kAXPressAction, count: 33)))
        XCTAssertThrowsError(try resolve(tree(), actions: [kAXPressAction, String(repeating: "x", count: 129)]))
    }

    @MainActor func testCancellationDuringResolutionRemainsCancellationAndCannotChooseAction() async {
        let nodes = tree()
        let task = Task { @MainActor in
            _ = try Command.resolve(menuBar: 0, read: { id in
                if id == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                return try XCTUnwrap(nodes[id])
            }, actions: { _ in XCTFail("Cancelled resolution must not read or choose a final action"); return [kAXPressAction] },
                shouldContinue: { !Task.isCancelled })
            return true
        }
        do { _ = try await task.value; XCTFail("Resolution must stop") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
