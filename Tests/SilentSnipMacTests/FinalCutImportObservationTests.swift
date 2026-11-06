import ApplicationServices
import XCTest
@testable import SilentSnipMac

final class FinalCutImportObservationTests: XCTestCase {
    private typealias Observation = FinalCutImportObservation<Int>

    func testOneBatchPerNodeFindsProjectWithoutEnteringFieldEditors() throws {
        let fields: [Int: Observation.Control] = [
            0: .init(element: 0, role: kAXScrollAreaRole, title: nil, value: nil, description: "organizer"),
            1: .init(element: 1, role: kAXGroupRole, title: nil, value: nil, description: nil),
            2: .init(element: 2, role: kAXTextFieldRole, title: nil, value: "Generated Result", description: nil),
            3: .init(element: 3, role: kAXImageRole, title: "Generated Result", value: nil, description: nil)]
        let children = [0: [1], 1: [2, 3], 2: [99]]
        var reads: [Int: Int] = [:]
        let result = try Observation.capture(root: 0, read: { id in
            reads[id, default: 0] += 1
            return (try XCTUnwrap(fields[id]), children[id] ?? [])
        }, shouldContinue: { true })
        XCTAssertEqual(reads, [0: 1, 1: 1, 2: 1, 3: 1])
        XCTAssertTrue(result.containsProject(named: "Generated Result"))
        XCTAssertFalse(result.containsProject(named: "Generated"), "Project names remain exact")
    }

    func testDialogAuthorizationUsesCompleteSnapshotIncludingUnexpectedButtons() throws {
        let warning = "Your XML was imported with the following warnings. Some metadata changed."
        var controls = [
            Observation.Control(element: 0, role: kAXSheetRole, title: "Import XML", value: nil, description: nil),
            .init(element: 1, role: kAXStaticTextRole, title: nil, value: warning, description: nil),
            .init(element: 2, role: kAXStaticTextRole, title: nil, value: "Silent Snip.fcpxml", description: nil),
            .init(element: 3, role: kAXButtonRole, title: "OK", value: nil, description: nil)]
        XCTAssertTrue(Observation(controls: controls).dialog.isCompletedWarning(for: "Silent Snip.fcpxml"))
        controls.append(.init(element: 4, role: kAXButtonRole, title: "Replace", value: nil, description: nil))
        XCTAssertFalse(Observation(controls: controls).dialog.isCompletedWarning(for: "Silent Snip.fcpxml"))
        XCTAssertEqual(Observation(controls: controls).buttons.map(\.element), [3, 4])
    }

    func testBoundsAndInterruptedSnapshotCannotReturnPartialAuthorization() {
        let root = Observation.Control(element: 0, role: kAXGroupRole, title: nil, value: nil, description: nil)
        XCTAssertThrowsError(try Observation.capture(root: 0, read: { _ in (root, [1, 2]) },
            shouldContinue: { true }, maxNodes: 2))
        XCTAssertThrowsError(try Observation.capture(root: 0, read: { _ in (root, [1]) },
            shouldContinue: { true }, maxDepth: 0))
        XCTAssertThrowsError(try Observation.capture(root: 0, read: { _ in (root, []) }, shouldContinue: { false }))
    }

    func testExactImportedTimelineSkipsAllBrowserDiscovery() {
        var reads = 0
        let lookup = FinalCutImportBrowserLookups(root: 0, read: { _, _ in reads += 1; return [:] },
            children: { _ in reads += 1; return [] }, equals: ==)
        for _ in 0..<5 {
            XCTAssertNil(lookup.resolve(currentProject: "Generated Result", importedProject: "Generated Result", shouldContinue: { true }))
        }
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(lookup.counters["browser.exactTimelineSkips"], 5)
    }

    func testMountedBrowserRouteReusesThenFindsReplacement() {
        var fields: [Int: [String: Any]] = [
            0: [kAXRoleAttribute: kAXWindowRole], 1: [kAXRoleAttribute: kAXGroupRole],
            2: [kAXRoleAttribute: kAXScrollAreaRole, kAXDescriptionAttribute: "organizer"],
            3: [kAXRoleAttribute: kAXScrollAreaRole, kAXDescriptionAttribute: "organizer"]]
        var children = [0: [1], 1: [2]]
        let lookup = FinalCutImportBrowserLookups(root: 0, read: { id, _ in fields[id] ?? [:] },
            children: { children[$0] ?? [] }, equals: ==)
        XCTAssertEqual(lookup.resolve(currentProject: "Original", importedProject: "Result", shouldContinue: { true }), 2)
        XCTAssertEqual(lookup.resolve(currentProject: "Original", importedProject: "Result", shouldContinue: { true }), 2)
        children[1] = [3]
        XCTAssertEqual(lookup.resolve(currentProject: "Original", importedProject: "Result", shouldContinue: { true }), 3)
        fields[3]?[kAXDescriptionAttribute] = "Unrelated browser"
        XCTAssertNil(lookup.resolve(currentProject: "Original", importedProject: "Result", shouldContinue: { true }))
        XCTAssertEqual(lookup.counters["browser.cacheHits"], 1)
        XCTAssertEqual(lookup.counters["browser.invalidations"], 2)
    }

    func testAlternativeLayoutIsPreferredButMissingBrowserIsNeverNegativeCached() {
        var fields: [Int: [String: Any]] = [0: [kAXRoleAttribute: kAXWindowRole]]
        var children: [Int: [Int]] = [0: []]
        let lookup = FinalCutImportBrowserLookups(root: 0, read: { id, _ in fields[id] ?? [:] },
            children: { children[$0] ?? [] }, equals: ==)
        XCTAssertNil(lookup.resolve(currentProject: "Original", importedProject: "Result", shouldContinue: { true }))
        fields[1] = [kAXRoleAttribute: kAXScrollAreaRole, kAXDescriptionAttribute: "Organizer filmlist scroll view"]
        children[0] = [1]
        XCTAssertEqual(lookup.resolve(currentProject: "Original", importedProject: "Result", shouldContinue: { true }), 1)
        let searches = lookup.counters["browser.searches"]
        XCTAssertEqual(lookup.resolve(currentProject: "Original", importedProject: "Result", shouldContinue: { true }), 1)
        XCTAssertEqual(lookup.counters["browser.searches"], searches)
        children[0] = []
        XCTAssertNil(lookup.resolve(currentProject: "Original", importedProject: "Result", shouldContinue: { true }))
    }

    func testInterruptedBrowserDiscoveryIsUnknownAndDoesNotBecomeAMissingBrowser() {
        let fields: [Int: [String: Any]] = [0: [kAXRoleAttribute: kAXWindowRole],
            1: [kAXRoleAttribute: kAXScrollAreaRole, kAXDescriptionAttribute: "organizer"]]
        let lookup = FinalCutImportBrowserLookups(root: 0, read: { id, _ in fields[id] ?? [:] },
            children: { $0 == 0 ? [1] : [] }, equals: ==)
        XCTAssertNil(lookup.resolve(currentProject: "Original", importedProject: "Result", shouldContinue: { false }))
        XCTAssertFalse(lookup.lastResolutionComplete, "An incomplete search must not authorize browser reveal")
        XCTAssertEqual(lookup.resolve(currentProject: "Original", importedProject: "Result", shouldContinue: { true }), 1)
        XCTAssertTrue(lookup.lastResolutionComplete)
    }
}
