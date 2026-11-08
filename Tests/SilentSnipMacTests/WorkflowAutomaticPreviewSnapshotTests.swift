import ApplicationServices
import XCTest
@testable import SilentSnipMac

final class WorkflowAutomaticPreviewSnapshotTests: XCTestCase {
    private final class Node {
        var role: String?
        var id: String?
        var value: String?
        var children: [Node]?
        init(_ role: String?, id: String? = nil, value: String? = nil, children: [Node]? = nil) {
            self.role = role; self.id = id; self.value = value; self.children = children
        }
        func read(_ names: [String]) -> [String: Any] {
            var result: [String: Any] = [:]
            for name in names {
                if name == kAXRoleAttribute { result[name] = role }
                if name == kAXIdentifierAttribute { result[name] = id }
                if name == kAXValueAttribute { result[name] = value }
                if name == kAXChildrenAttribute { result[name] = children }
            }
            return result
        }
    }
    private let settings = ReviewWireSettings(threshold: -40, minimum: 0.5, before: 0.1, after: 0.2)
    private func fixture(_ edit: UUID) -> Node {
        let fields = ["-40", "0.5", "0.1", "0.2"].enumerated().map {
            Node(kAXTextFieldRole, id: "silentsnip.workflow.setting.\($0.offset)", value: $0.element)
        }
        return Node(kAXGroupRole, id: WorkflowAutomaticPreviewSnapshot.marker(edit: edit),
            children: fields + [Node(kAXPopUpButtonRole, id: "silentsnip.workflow.output", value: "Remove Silence")])
    }
    private func matches(_ group: Node, edit: UUID, output: SilentSnipOutputMode = .remove,
                         read: ((Node, [String]) -> [String: Any])? = nil,
                         shouldContinue: () -> Bool = { true }) -> Bool {
        WorkflowAutomaticPreviewSnapshot.matches(group: group, edit: edit, settings: settings, output: output,
            read: read ?? { $0.read($1) }, equals: { $0 === $1 }, shouldContinue: shouldContinue)
    }

    func testExactNativeValuesAndBothOutputTitlesMatch() {
        let edit = UUID(), group = fixture(edit)
        XCTAssertTrue(matches(group, edit: edit))
        group.children?.last?.value = "Replace with 1-Second Gaps"
        XCTAssertTrue(matches(group, edit: edit, output: .gaps))
        XCTAssertFalse(matches(group, edit: edit, output: .remove))
    }
    func testOldOrMissingMarkerCannotAuthorizeDisplayedValues() {
        let edit = UUID(), group = fixture(edit)
        XCTAssertFalse(matches(group, edit: UUID()))
        group.id = nil
        XCTAssertFalse(matches(group, edit: edit))
    }
    func testEverySettingAndOutputMustEqualThePendingRequest() {
        for index in 0..<5 {
            let edit = UUID(), group = fixture(edit)
            group.children?[index].value = index == 4 ? "Replace with Gap" : "0.123"
            XCTAssertFalse(matches(group, edit: edit))
        }
    }
    func testIncompleteOrNonFiniteEditorValuesCannotAuthorize() {
        for value in ["", "-", "0.5x", "NaN", "Infinity", "0,5"] {
            let edit = UUID(), group = fixture(edit)
            group.children?[1].value = value
            XCTAssertFalse(matches(group, edit: edit), value)
        }
    }
    func testDuplicateMissingOrWrongRoleControlsAreRejected() {
        let edit = UUID()
        let duplicated = fixture(edit)
        duplicated.children?.append(Node(kAXTextFieldRole, id: "silentsnip.workflow.setting.0", value: "-40"))
        XCTAssertFalse(matches(duplicated, edit: edit))
        let missing = fixture(edit); missing.children?.removeFirst()
        XCTAssertFalse(matches(missing, edit: edit))
        let wrongRole = fixture(edit); wrongRole.children?.first?.role = kAXStaticTextRole
        XCTAssertFalse(matches(wrongRole, edit: edit))
    }
    func testNestedContainerNeedsCompleteChildrenObservation() {
        let edit = UUID(), group = fixture(edit)
        let fields = group.children
        group.children = [Node(kAXGroupRole, children: fields)]
        XCTAssertTrue(matches(group, edit: edit))
        group.children?.first?.children = nil
        XCTAssertFalse(matches(group, edit: edit))
    }
    func testDetachedFieldCannotBeAuthorizedFromEarlierDiscovery() {
        let edit = UUID(), group = fixture(edit)
        var detached = false
        XCTAssertFalse(matches(group, edit: edit, read: { node, names in
            if node === group, names == [kAXChildrenAttribute], !detached {
                detached = true
                group.children?.removeFirst()
            }
            return node.read(names)
        }))
        XCTAssertTrue(detached)
    }
    func testChangedFieldValueBeforeFreshReadIsRejected() {
        let edit = UUID(), group = fixture(edit)
        let field = group.children![1]
        XCTAssertFalse(matches(group, edit: edit, read: { node, names in
            if node === field, names == [kAXRoleAttribute, kAXIdentifierAttribute, kAXValueAttribute] { node.value = "0.7" }
            return node.read(names)
        }))
    }
    func testNewDraftMarkerDuringObservationRejectsOlderSnapshot() {
        let edit = UUID(), group = fixture(edit)
        XCTAssertFalse(matches(group, edit: edit, read: { node, names in
            if node === group, names == [kAXRoleAttribute, kAXIdentifierAttribute] { node.id = WorkflowAutomaticPreviewSnapshot.marker(edit: UUID()) }
            return node.read(names)
        }))
    }
    func testCycleBoundsAndStoppedObservationCannotAuthorize() {
        let edit = UUID(), group = fixture(edit)
        XCTAssertFalse(matches(group, edit: edit, shouldContinue: { false }))
        group.children?.append(group)
        XCTAssertFalse(matches(group, edit: edit))
        let bounded = fixture(edit)
        bounded.children = (0..<65).map { _ in Node(kAXStaticTextRole) }
        XCTAssertFalse(matches(bounded, edit: edit))
    }
}
