import ApplicationServices
import XCTest
@testable import SilentSnipMac

final class FinalCutSharePanelTests: XCTestCase {
    private typealias Panel = FinalCutSharePanel<Int>
    private func control(_ id: Int, _ role: String, title: String? = nil, value: String? = nil,
                         description: String? = nil, selected: Bool = false) -> Panel.Control {
        .init(element: id, role: role, title: title, value: value, description: description, selected: selected)
    }

    func testOneReadPerNodeRetainsHostOrderAndBothCurrentFormats() throws {
        let controls = [control(0, kAXSheetRole), control(1, kAXGroupRole),
            control(2, kAXStaticTextRole, value: "Format:"), control(3, kAXPopUpButtonRole, value: "Audio Only"),
            control(4, kAXStaticTextRole, title: "Audio Format:"), control(5, kAXPopUpButtonRole, value: "WAV")]
        let children = [0: [1], 1: [2, 3, 4, 5]]
        var reads: [Int: Int] = [:]
        let panel = try Panel.capture(root: 0, read: { id in
            reads[id, default: 0] += 1
            return (controls[id], children[id] ?? [])
        }, shouldContinue: { true })
        XCTAssertEqual(reads.count, 6)
        XCTAssertTrue(reads.values.allSatisfy { $0 == 1 }, "Each node supplies its fields and children in one read")
        XCTAssertEqual(panel.controls.map(\.element), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(panel.popup(after: "Export File Format:")?.element, 3)
        XCTAssertEqual(panel.popup(after: "Audio Format:")?.value, "WAV")
    }

    func testDuplicateLabelsAndAdjacentPopupsAreRejected() {
        let label = control(0, kAXStaticTextRole, title: "Audio Format:")
        let popup = control(1, kAXPopUpButtonRole, value: "WAV")
        XCTAssertNil(Panel(controls: [label, popup, label, popup]).popup(after: "Audio Format:"))
        XCTAssertNil(Panel(controls: [label, popup, popup]).popup(after: "Audio Format:"))
        XCTAssertNil(Panel(controls: [label, control(2, kAXStaticTextRole, title: "Video Codec:"), popup])
            .popup(after: "Audio Format:"), "Never cross into another field")
    }

    func testRebuiltPanelResolvesReplacementInsteadOfDetachedPopup() {
        let label = control(0, kAXStaticTextRole, title: "Audio Format:")
        let before = Panel(controls: [label, control(1, kAXPopUpButtonRole, value: "AAC")])
        let after = Panel(controls: [label, control(2, kAXPopUpButtonRole, value: "WAV")])
        XCTAssertEqual(before.popup(after: "Audio Format:")?.element, 1)
        XCTAssertEqual(after.popup(after: "Audio Format:")?.element, 2)
        XCTAssertEqual(after.popup(after: "Audio Format:")?.value, "WAV")
    }

    func testTabSelectionAndMenuLookupRequireUniqueExactControls() {
        let tab = control(1, kAXRadioButtonRole, title: "Settings", selected: true)
        XCTAssertTrue(Panel(controls: [tab]).tab("Settings")?.selected == true)
        XCTAssertNil(Panel(controls: [tab, tab]).tab("Settings"))
        XCTAssertNil(Panel(controls: [control(2, kAXStaticTextRole, title: "Settings")]).tab("Settings"))
        let item = control(3, kAXMenuItemRole, title: "Audio Only")
        XCTAssertEqual(Panel(controls: [item]).menuItem("audio only")?.element, 3)
        XCTAssertNil(Panel(controls: [item, item]).menuItem("Audio Only"))
        XCTAssertNil(Panel(controls: [control(4, kAXMenuItemRole, title: "Video and Audio")]).menuItem("Audio Only"))
    }

    func testDialogueVerificationRejectsWrongMixAndAmbiguousPreset() {
        let labels = ["All Dialogue", "1 file", ".wav", "Audio Track - 1"]
            .enumerated().map { control($0.offset, kAXStaticTextRole, title: $0.element) }
        let preset = control(4, kAXPopUpButtonRole, value: "WAV", description: "Roles formats and presets")
        XCTAssertTrue(Panel(controls: labels + [preset]).verifiesDialogueWAV)
        for extra in [control(5, kAXStaticTextRole, title: "All Music"),
                      control(6, kAXStaticTextRole, title: "All Dialogue"),
                      control(7, kAXStaticTextRole, title: "Audio Track - 2"), preset] {
            XCTAssertFalse(Panel(controls: labels + [preset, extra]).verifiesDialogueWAV)
        }
        for value in ["AAC", "", "AIFF"] {
            XCTAssertFalse(Panel(controls: labels + [control(4, kAXPopUpButtonRole, value: value,
                description: "Roles formats and presets")]).verifiesDialogueWAV)
        }
        XCTAssertFalse(Panel(controls: Array(labels.dropLast()) + [preset]).verifiesDialogueWAV)
    }

    func testBoundsAndDeadlineRejectIncompleteSnapshots() {
        for (maxNodes, maxDepth, keepReading) in [(2, 16, true), (500, 1, true), (500, 16, false)] {
            XCTAssertThrowsError(try Panel.capture(root: 0, read: { id in
                (self.control(id, kAXGroupRole), id < 2 ? [id + 1] : [])
            }, shouldContinue: { keepReading }, maxNodes: maxNodes, maxDepth: maxDepth))
        }
    }
}
