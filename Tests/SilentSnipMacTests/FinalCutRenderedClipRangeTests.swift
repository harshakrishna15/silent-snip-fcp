import XCTest
@testable import SilentSnipMac

final class FinalCutRenderedClipRangeTests: XCTestCase {
    private func node(_ role: String, _ description: String, _ value: String, selected: Bool = false,
                      children: [AccessibilityNode] = []) -> AccessibilityNode {
        .init(role: role, identifier: nil, title: nil, description: description, value: value,
              selected: selected, enabled: true, children: children)
    }
    func testRenderedRangeBindsBothEdgesAndDurationOfTheSelectedOccurrence() throws {
        let handles = [node("AXHandle", "Leading Edge", "01:00:02:00"), node("AXHandle", "Trailing Edge", "01:00:18:10"),
                       node("AXTextField", "Title", "Interview")]
        let clip = node("AXLayoutItem", "AV-Clip:Interview", "00:00:16:10", selected: true, children: handles)
        let selection = try FinalCutSelectionSnapshot(projectName: "Edit", timeline: node("AXLayoutArea", "Project Timeline", "", children: [clip]))
        func timeline(start: String = "01:00:02:00", end: String = "01:00:18:10", duration: String = "00:00:16:10") -> AccessibilityNode {
            node("AXLayoutArea", "Project Timeline", "", children: [clip,
                node("AXLayoutItem", "Range Selection", duration, children: [node("AXHandle", "Range Start", start), node("AXHandle", "Range End", end)])])
        }
        let expected = FinalCutRenderedClipRange(selection: selection)
        XCTAssertEqual(FinalCutRenderedClipRange(timeline: timeline()), expected)
        XCTAssertNotEqual(FinalCutRenderedClipRange(timeline: timeline(start: "01:00:03:00")), expected)
        XCTAssertNotEqual(FinalCutRenderedClipRange(timeline: timeline(end: "01:00:17:10")), expected)
        XCTAssertNotEqual(FinalCutRenderedClipRange(timeline: timeline(duration: "00:00:15:10")), expected)
        XCTAssertNil(FinalCutRenderedClipRange(timeline: node("AXLayoutArea", "Project Timeline", "", children: [clip])))
        let duplicate = timeline().children.last!
        XCTAssertNil(FinalCutRenderedClipRange(timeline: node("AXLayoutArea", "Project Timeline", "", children: [duplicate, duplicate])))
        let invalid = node("AXLayoutItem", "Range Selection", "00:00:16:10", children: [node("AXHandle", "Range Start", "01:00:02:00")])
        XCTAssertNil(FinalCutRenderedClipRange(timeline: node("AXLayoutArea", "Project Timeline", "", children: [invalid])))
    }
}
