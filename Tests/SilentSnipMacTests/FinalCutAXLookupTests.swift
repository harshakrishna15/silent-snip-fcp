import ApplicationServices
import XCTest
@testable import SilentSnipMac

final class FinalCutAXLookupTests: XCTestCase {
    private final class Tree {
        var values: [Int: [String: Any]] = [0: [kAXRoleAttribute: kAXWindowRole],
            1: [kAXRoleAttribute: kAXGroupRole],
            2: [kAXRoleAttribute: kAXPopUpButtonRole, kAXIdentifierAttribute: "project", kAXTitleAttribute: "Original"]]
        var edges = [0: [1], 1: [2]]
        var reads = 0
        var childReads = 0
        func read(_ node: Int, _ names: [String]) -> [String: Any] {
            reads += 1
            return values[node, default: [:]].filter { names.contains($0.key) }
        }
        func children(_ node: Int) -> [Int] { childReads += 1; return edges[node] ?? [] }
        func lookup() -> FinalCutAXLookup<Int> {
            FinalCutAXLookup(root: 0, query: .init(identifier: "project", containersOnly: true,
                additionalAttributes: [kAXTitleAttribute]), read: read, children: children, equals: ==)
        }
    }

    func testRepeatedChecksReuseMountedPathButAlwaysReadFreshTitle() throws {
        let lookup = treeLookupFixture()
        let initial = try XCTUnwrap(lookup.0.resolve())
        XCTAssertEqual(initial.element, 2)
        let firstReads = lookup.1.reads + lookup.1.childReads
        lookup.1.reads = 0; lookup.1.childReads = 0
        lookup.1.values[2]?[kAXTitleAttribute] = "Different project"
        XCTAssertEqual(lookup.0.resolve()?.values[kAXTitleAttribute] as? String, "Different project")
        let repeatedReads = lookup.1.reads + lookup.1.childReads
        XCTAssertLessThan(repeatedReads, firstReads / 10)
        print("AX fixture host reads: initial discovery=\(firstReads), validated repeated lookup=\(repeatedReads). Synthetic tree; not a live Final Cut latency measurement.")
        XCTAssertEqual(lookup.0.statistics.searches, 1)
        XCTAssertEqual(lookup.0.statistics.cacheHits, 1)
    }

    private func treeLookupFixture() -> (FinalCutAXLookup<Int>, Tree) {
        let tree = Tree()
        for index in 3..<203 { tree.values[index] = [kAXRoleAttribute: kAXGroupRole] }
        tree.edges[0] = Array(3..<203) + [1]
        return (tree.lookup(), tree)
    }

    func testReadableButDetachedOldControlIsNeverReused() {
        let tree = Tree(), lookup = tree.lookup()
        XCTAssertEqual(lookup.resolve()?.element, 2)
        tree.values[3] = [kAXRoleAttribute: kAXPopUpButtonRole, kAXIdentifierAttribute: "project", kAXTitleAttribute: "Replacement"]
        tree.edges[1] = [3] // Old handle remains readable, but is no longer mounted.
        XCTAssertEqual(lookup.resolve()?.element, 3)
        XCTAssertEqual(lookup.statistics.invalidations, 1)
        XCTAssertEqual(lookup.statistics.searches, 2)
    }

    func testRebuiltParentInvalidatesEntireOldPath() {
        let tree = Tree(), lookup = tree.lookup()
        XCTAssertEqual(lookup.resolve()?.element, 2)
        tree.values[4] = [kAXRoleAttribute: kAXGroupRole]
        tree.values[5] = tree.values[2]
        tree.edges[0] = [4]; tree.edges[4] = [5]
        XCTAssertEqual(lookup.resolve()?.path, [0, 4, 5])
        XCTAssertEqual(lookup.statistics.invalidations, 1)
    }

    func testControlMovedUnderInspectorCannotUseCachedRoute() {
        let tree = Tree(), lookup = tree.lookup()
        XCTAssertNotNil(lookup.resolve())
        tree.values[1]?[kAXIdentifierAttribute] = "VideoInspector"
        XCTAssertNil(lookup.resolve())
        XCTAssertEqual(lookup.statistics.cacheHits, 0)
    }

    func testMissingAttributesAndChangedIdentifierCannotAuthorizeCachedControl() {
        let tree = Tree(), lookup = tree.lookup()
        XCTAssertNotNil(lookup.resolve())
        tree.values[2]?[kAXTitleAttribute] = nil
        XCTAssertNil(lookup.resolve()?.values[kAXTitleAttribute])
        XCTAssertEqual(lookup.statistics.cacheHits, 0)
        XCTAssertEqual(lookup.statistics.searches, 2)
        tree.values[2]?[kAXIdentifierAttribute] = "other"
        XCTAssertNil(lookup.resolve())
    }

    func testUnreadableAncestorFallsBackAndMissingControlIsNotRetained() {
        let tree = Tree(), lookup = tree.lookup()
        XCTAssertNotNil(lookup.resolve())
        tree.edges[0] = nil
        XCTAssertNil(lookup.resolve())
        tree.edges[0] = [1]
        XCTAssertEqual(lookup.resolve()?.element, 2)
        XCTAssertEqual(lookup.statistics.searches, 3)
    }

    func testCancellationStopsCachedValidationWithoutSearchingOrReading() {
        let tree = Tree(), lookup = tree.lookup()
        XCTAssertNotNil(lookup.resolve())
        let before = tree.reads + tree.childReads
        XCTAssertNil(lookup.resolve(shouldContinue: { false }))
        XCTAssertEqual(tree.reads + tree.childReads, before)
        XCTAssertEqual(lookup.statistics.searches, 1)
    }

    func testSearchKeepsDepthNodeDeadlineAndCycleBounds() {
        let tree = Tree()
        let query = FinalCutAXQuery(identifier: "project", containersOnly: true)
        func search(depth: Int = 24, nodes: Int = 600, keepGoing: () -> Bool = { true }) -> FinalCutAXMatch<Int>? {
            FinalCutAXSearch.find(root: 0, query: query, maxDepth: depth, maxNodes: nodes,
                read: tree.read, children: tree.children, equals: ==, shouldContinue: keepGoing)
        }
        XCTAssertNil(search(depth: 1)); XCTAssertNil(search(nodes: 2))
        XCTAssertEqual(search(depth: 2, nodes: 3)?.element, 2)
        let before = tree.reads
        XCTAssertNil(search(keepGoing: { false })); XCTAssertEqual(tree.reads, before)
        tree.edges[1] = [0]
        XCTAssertNil(search()); XCTAssertLessThan(tree.reads - before, 4)
    }

    func testSearchMatchesAllRequestedFieldsAndNeverTraversesClipContents() {
        let tree = Tree()
        tree.values[2]?[kAXDescriptionAttribute] = "Expected"
        let query = FinalCutAXQuery(role: kAXPopUpButtonRole, identifier: "project", title: "Original",
            description: "Expected", containersOnly: true)
        func search() -> FinalCutAXMatch<Int>? {
            FinalCutAXSearch.find(root: 0, query: query, read: tree.read, children: tree.children,
                equals: ==, shouldContinue: { true })
        }
        XCTAssertEqual(search()?.element, 2)
        tree.values[1]?[kAXRoleAttribute] = kAXLayoutItemRole
        XCTAssertNil(search())
        tree.values[1]?[kAXRoleAttribute] = kAXGroupRole
        tree.values[2]?[kAXTitleAttribute] = "Wrong"
        XCTAssertNil(search())
    }

    func testBatchSnapshotPreservesMissingPositionsAndLiveBooleanValues() {
        var singles = 0
        let values = FinalCutAXAttributes.values(names: ["role", "missing", "selected"],
            batch: { ["AXLayoutItem", NSNull(), NSNumber(value: false)] }, single: { _ in singles += 1; return "wrong" })
        XCTAssertEqual(values["role"] as? String, "AXLayoutItem")
        XCTAssertNil(values["missing"])
        XCTAssertEqual((values["selected"] as? NSNumber)?.boolValue, false)
        XCTAssertEqual(singles, 0)
    }

    func testUnsupportedBatchAndMalformedResponseUseIndividualReadFallback() {
        for batch: [Any]? in [nil, []] {
            var singles: [String] = []
            let values = FinalCutAXAttributes.values(names: ["role", "title"], batch: { batch }, single: {
                singles.append($0); return $0 == "title" ? "Original" : "AXButton"
            })
            XCTAssertEqual(values["title"] as? String, "Original")
            XCTAssertEqual(singles, ["role", "title"])
        }
    }

    func testAttributeErrorsAreMissingAndUnsupportedAttributesHaveCompatibilityFallback() throws {
        for expected in [AXError.attributeUnsupported, .notImplemented, .noValue, .invalidUIElement, .cannotComplete] {
            var error = expected
            let value = try XCTUnwrap(AXValueCreate(.axError, &error))
            var singles = 0
            let values = FinalCutAXAttributes.values(names: ["title"], batch: { [value] }, single: { _ in
                singles += 1; return "Fallback"
            })
            let supportsFallback = expected != .noValue && expected != .invalidUIElement
            XCTAssertEqual(singles, supportsFallback ? 1 : 0)
            XCTAssertEqual(values["title"] as? String, supportsFallback ? "Fallback" : nil)
        }
    }

    @MainActor func testCaptureDetailsDoNotDoubleCountStagesAndSurviveFailure() throws {
        var clock = 100.0
        let timing = AnalysisTiming(request: UUID(), clock: { clock })
        timing.begin("capture")
        timing.measure("capture.activation") { clock += 2 }
        enum Failure: Error { case stopped }
        XCTAssertThrowsError(try timing.measure("capture.xmlExchange") { clock += 3; throw Failure.stopped })
        timing.recordCounters(["capture.projectLookup.cacheHits": 5])
        let report = timing.report(outcome: "failed")
        XCTAssertEqual(report.totalSeconds, 5)
        XCTAssertEqual(report.stages["capture"], 5)
        XCTAssertEqual(report.details["capture.activation"], 2)
        XCTAssertEqual(report.details["capture.xmlExchange"], 3)
        XCTAssertEqual(report.counters["capture.projectLookup.cacheHits"], 5)
        XCTAssertNoThrow(try JSONEncoder().encode(report))
    }

    @MainActor func testAsyncCaptureTimingKeepsFailedExchangeAndRepeatedDetails() async {
        var clock = 0.0
        let timing = AnalysisTiming(request: UUID(), clock: { clock })
        enum Failure: Error { case stopped }
        do {
            try await timing.measure("exchange") {
                await Task.yield(); clock += 3; throw Failure.stopped
            }
            XCTFail("Expected failure")
        } catch {}
        await timing.measure("exchange") { await Task.yield(); clock += 2 }
        XCTAssertEqual(timing.report(outcome: "failed").details["exchange"], 5)
    }
}
