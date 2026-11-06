import ApplicationServices
import Foundation
import XCTest
@testable import SilentSnipMac

final class WorkflowReviewAXLookupsTests: XCTestCase {
    private let view = UUID()
    private let gesture = UUID()
    private var marker: String { "silentsnip.workflow.review.\(view.uuidString)" }
    private var action: String { "silentsnip.workflow.apply.requested.\(gesture.uuidString)" }

    private final class Tree {
        var values: [Int: [String: Any]] = [0: [kAXRoleAttribute: kAXWindowRole],
            10: [kAXRoleAttribute: kAXWindowRole], 11: [kAXRoleAttribute: kAXGroupRole],
            20: [kAXRoleAttribute: kAXWindowRole], 21: [kAXRoleAttribute: kAXGroupRole]]
        var edges = [10: [11], 20: [21]]
        var reads: [Int: Int] = [:]
        var childReads: [Int: Int] = [:]

        func read(_ node: Int, _ names: [String]) -> [String: Any] {
            reads[node, default: 0] += 1
            return values[node, default: [:]].filter { names.contains($0.key) }
        }
        func children(_ node: Int) -> [Int] {
            childReads[node, default: 0] += 1
            return edges[node] ?? []
        }
        func cache() -> WorkflowReviewAXLookups<Int> {
            WorkflowReviewAXLookups(read: read, children: children, equals: ==)
        }
        func button(_ node: Int, identifier: String, enabled: Bool? = nil) {
            values[node] = [kAXRoleAttribute: kAXButtonRole, kAXIdentifierAttribute: identifier]
            if let enabled { values[node]?[kAXEnabledAttribute] = NSNumber(value: enabled) }
        }
        var totalReads: Int { reads.values.reduce(0, +) + childReads.values.reduce(0, +) }
    }

    private func fixture() -> (Tree, WorkflowReviewAXLookups<Int>) {
        let tree = Tree()
        tree.button(12, identifier: marker)
        tree.button(13, identifier: action, enabled: false)
        tree.edges[11] = [12, 13]
        return (tree, tree.cache())
    }

    func testOnlyExactPinnedProjectWindowIsExcludedBeforeAnyTreeRead() {
        let (tree, cache) = fixture()
        // Even a misleading copied marker cannot turn the proven workspace
        // into the independently floating Workflow window.
        tree.button(1, identifier: marker)
        tree.edges[0] = [1]
        XCTAssertEqual(cache.matchingWindows([0, 10, 0, 10], excluding: 0, markerIdentifier: marker), [10])
        XCTAssertNil(tree.reads[0]); XCTAssertNil(tree.childReads[0]); XCTAssertNil(tree.reads[1])
        XCTAssertEqual(cache.statistics.mainWindowSkips, 1)
        // A different reference with the same role is still searched.
        tree.button(22, identifier: marker); tree.edges[21] = [22]
        XCTAssertEqual(cache.matchingWindows([0, 10, 20], excluding: 0, markerIdentifier: marker), [10, 20])
    }

    func testPositiveRoutesSaveReadsWithoutCachingTheEnabledGestureState() throws {
        let (tree, cache) = fixture()
        for node in 100..<400 { tree.values[node] = [kAXRoleAttribute: kAXGroupRole] }
        tree.edges[10] = Array(100..<400) + [11]
        XCTAssertEqual(cache.matchingWindows([10], excluding: 0, markerIdentifier: marker), [10])
        let firstAction = try XCTUnwrap(cache.action(in: 10, identifier: action))
        XCTAssertFalse(try XCTUnwrap((firstAction.values[kAXEnabledAttribute] as? NSNumber)?.boolValue))
        let initialReads = tree.totalReads
        tree.reads.removeAll(); tree.childReads.removeAll()
        tree.values[13]?[kAXEnabledAttribute] = NSNumber(value: true)
        XCTAssertEqual(cache.matchingWindows([10], excluding: 0, markerIdentifier: marker), [10])
        let changedAction = try XCTUnwrap(cache.action(in: 10, identifier: action))
        XCTAssertFalse(WorkflowReviewGesture.pending(identifier: changedAction.values[kAXIdentifierAttribute] as? String,
            enabled: (changedAction.values[kAXEnabledAttribute] as? NSNumber)?.boolValue, gesture: gesture, action: "apply"))
        XCTAssertLessThan(tree.totalReads, initialReads / 10)
        XCTAssertEqual(cache.statistics.cacheHits, 2)
        tree.values[13]?[kAXEnabledAttribute] = nil
        XCTAssertNil(cache.action(in: 10, identifier: action)?.values[kAXEnabledAttribute])
    }

    func testReadableDetachedMarkerAndActionAreReplacedThroughFreshParentEdges() throws {
        let (tree, cache) = fixture()
        XCTAssertEqual(cache.matchingWindows([10], excluding: 0, markerIdentifier: marker), [10])
        XCTAssertEqual(cache.action(in: 10, identifier: action)?.element, 13)
        // Old native handles continue answering attributes after their parent
        // is rebuilt. They must never authorize the replacement view.
        tree.values[14] = [kAXRoleAttribute: kAXGroupRole]
        tree.button(15, identifier: marker); tree.button(16, identifier: action, enabled: true)
        tree.edges[10] = [14]; tree.edges[14] = [15, 16]
        XCTAssertEqual(cache.matchingWindows([10], excluding: 0, markerIdentifier: marker), [10])
        XCTAssertEqual(cache.action(in: 10, identifier: action)?.element, 16)
        XCTAssertEqual(cache.statistics.invalidations, 2)
        tree.edges[14] = []
        XCTAssertTrue(cache.matchingWindows([10], excluding: 0, markerIdentifier: marker).isEmpty)
        XCTAssertNil(cache.action(in: 10, identifier: action))
    }

    func testPreviouslyUnmatchedAndNewWindowsStillParticipateInDuplicateDetection() {
        let (tree, cache) = fixture()
        XCTAssertEqual(cache.matchingWindows([10, 20], excluding: 0, markerIdentifier: marker), [10])
        tree.button(22, identifier: marker); tree.edges[21] = [22]
        let duplicates = cache.matchingWindows([10, 10, 20], excluding: 0, markerIdentifier: marker)
        XCTAssertEqual(duplicates, [10, 20])
        XCTAssertNotNil(WorkflowAnalyzeObservation(matchingWindows: duplicates.count, focusedMatches: true,
            hostIsActive: true, buttonFound: true, pendingIDMatches: true, buttonEnabled: false).failureReason)
        tree.values[30] = [kAXRoleAttribute: kAXWindowRole]
        tree.button(31, identifier: marker); tree.edges[30] = [31]
        XCTAssertEqual(cache.matchingWindows([10, 20, 30], excluding: 0, markerIdentifier: marker), [10, 20, 30])
    }

    func testChangingViewAndGestureCannotReuseOldRoutes() {
        let (tree, cache) = fixture()
        XCTAssertEqual(cache.matchingWindows([10], excluding: 0, markerIdentifier: marker), [10])
        XCTAssertNotNil(cache.action(in: 10, identifier: action))
        let newMarker = "silentsnip.workflow.review.\(UUID().uuidString)"
        XCTAssertTrue(cache.matchingWindows([10], excluding: 0, markerIdentifier: newMarker).isEmpty)
        XCTAssertNil(cache.action(in: 10, identifier: action))
        tree.values[12]?[kAXIdentifierAttribute] = newMarker
        XCTAssertEqual(cache.matchingWindows([10], excluding: 0, markerIdentifier: newMarker), [10])
        let newAction = "silentsnip.workflow.apply.requested.\(UUID().uuidString)"
        XCTAssertNil(cache.action(in: 10, identifier: newAction))
        tree.values[13]?[kAXIdentifierAttribute] = newAction
        XCTAssertEqual(cache.action(in: 10, identifier: newAction)?.element, 13)
        XCTAssertNil(cache.action(in: 10, identifier: action))
    }

    func testCancellationDuringEnumerationCannotReportPartialUniqueWindow() {
        let (tree, cache) = fixture()
        tree.button(22, identifier: marker); tree.edges[21] = [22]
        XCTAssertEqual(cache.matchingWindows([10, 20], excluding: 0, markerIdentifier: marker), [10, 20])
        var checks = 0
        XCTAssertTrue(cache.matchingWindows([10, 20], excluding: 0, markerIdentifier: marker,
            shouldContinue: { checks += 1; return checks < 7 }).isEmpty)
    }

    func testCachedViewBecomingSheetOrFilePanelIsRejected() {
        let (tree, cache) = fixture()
        XCTAssertEqual(cache.matchingWindows([10], excluding: 0, markerIdentifier: marker), [10])
        tree.values[10]?[kAXRoleAttribute] = kAXSheetRole
        XCTAssertTrue(cache.matchingWindows([10], excluding: 0, markerIdentifier: marker).isEmpty)
        tree.values[10]?[kAXRoleAttribute] = kAXWindowRole
        for identifier in ["save-panel", "open-panel", "GoToWindow"] {
            tree.values[10]?[kAXIdentifierAttribute] = identifier
            XCTAssertTrue(cache.matchingWindows([10], excluding: 0, markerIdentifier: marker).isEmpty)
        }
    }

    func testWorkflowSearchRetainsItsExistingThreeThousandNodeLimit() {
        let (tree, cache) = fixture()
        for node in 100..<800 { tree.values[node] = [kAXRoleAttribute: kAXGroupRole] }
        tree.edges[10] = Array(100..<800) + [11]
        XCTAssertEqual(cache.matchingWindows([10], excluding: 0, markerIdentifier: marker), [10])
        XCTAssertGreaterThan(cache.statistics.visitedNodes, 600)
    }
}
