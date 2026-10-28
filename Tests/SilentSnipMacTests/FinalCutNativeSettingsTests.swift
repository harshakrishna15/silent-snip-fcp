import XCTest
import SilentSnipCore
@testable import SilentSnipMac

final class FinalCutNativeSettingsTests: XCTestCase {
    private func node(_ role: String, _ description: String? = nil, value: String? = nil, enabled: Bool? = true) -> AccessibilityNode {
        .init(role: role, identifier: nil, title: nil, description: description, value: value,
              selected: nil, enabled: enabled, children: [])
    }
    private var controls: [AccessibilityNode] {
        [node("AXCheckBox", "silent snip audio check box", value: "1"),
         node("AXStaticText", value: "Silent Snip Audio"),
         node("AXDisclosureTriangle", "toggle parameters", value: "0")]
            + FinalCutNativeSettings.descriptions.map { node("AXSlider", $0) }
            + [node("AXCheckBox", "other effect check box", value: "1"),
               node("AXSlider", "silence threshold slider")]
    }

    func testNativeRecoveryIsConfinedToOneEnabledControllerBlock() {
        XCTAssertEqual(FinalCutNativeSettings.sliderIndices(in: controls), [3, 4, 5, 6])
        XCTAssertEqual(FinalCutNativeSettings.disclosureIndex(in: controls), 2)
        var disabled = controls
        disabled[0] = node("AXCheckBox", "silent snip audio check box", value: "0")
        XCTAssertNil(FinalCutNativeSettings.sliderIndices(in: disabled))
        XCTAssertNil(FinalCutNativeSettings.disclosureIndex(in: disabled))
        XCTAssertNil(FinalCutNativeSettings.sliderIndices(in: controls + Array(controls.prefix(7))))
        XCTAssertNil(FinalCutNativeSettings.disclosureIndex(in: controls + Array(controls.prefix(7))))
    }

    func testNativeBinaryStatesAcceptIntegerAndFloatingRepresentations() {
        for value in [NSNumber(value: 0), NSNumber(value: 0.0), NSNumber(value: false)] {
            XCTAssertEqual(FinalCutNativeSettings.binaryValue(value), "0")
        }
        for value in [NSNumber(value: 1), NSNumber(value: 1.0), NSNumber(value: true)] {
            XCTAssertEqual(FinalCutNativeSettings.binaryValue(value), "1")
        }
        for value in [NSNumber(value: -1), NSNumber(value: 2), NSNumber(value: Double.nan)] {
            XCTAssertNil(FinalCutNativeSettings.binaryValue(value))
        }
        XCTAssertNil(FinalCutNativeSettings.binaryValue(nil))
        XCTAssertEqual(FinalCutNativeSettings.binaryValue("0.0"), "0")
        XCTAssertEqual(FinalCutNativeSettings.binaryValue("1"), "1")
        XCTAssertNil(FinalCutNativeSettings.binaryValue("on"))
        XCTAssertNil(FinalCutNativeSettings.binaryValue("1 trailing"))
    }

    func testEffectVisibilityToggleDoesNotHideItsNativeParameters() {
        var native = controls
        native.insert(.init(role: "AXCheckBox", identifier: nil, title: "Hide", description: nil, value: "1",
                            selected: nil, enabled: true, children: []), at: 2)
        XCTAssertEqual(FinalCutNativeSettings.disclosureIndex(in: native), 3)
        XCTAssertEqual(FinalCutNativeSettings.sliderIndices(in: native), [4, 5, 6, 7])
        native.insert(node("AXCheckBox", "unidentified effect", value: "1"), at: 4)
        XCTAssertNil(FinalCutNativeSettings.sliderIndices(in: native), "Unknown checkboxes still terminate the owned block")
    }

    func testMissingDisabledExtraAndMisidentifiedNativeParametersReject() {
        var missing = controls; missing.remove(at: 4)
        var disabled = controls; disabled[4] = node("AXSlider", "minimum silence slider", enabled: false)
        var wrong = controls; wrong[4] = node("AXSlider", "unrelated threshold slider")
        var extra = controls; extra.insert(node("AXSlider", "unknown slider"), at: 7)
        for variant in [missing, disabled, wrong, extra] {
            XCTAssertNil(FinalCutNativeSettings.sliderIndices(in: variant))
        }
    }

    func testPreciseRecoveryRequiresFourUniqueEnabledFieldsAndSlidersInTheOwnedBlock() {
        var native = controls
        native.insert(contentsOf: FinalCutNativeSettings.fieldDescriptions.map { node("AXTextField", $0) }, at: 7)
        XCTAssertEqual(FinalCutNativeSettings.fieldIndices(in: native), [7, 8, 9, 10])
        var disabled = native; disabled[8] = node("AXTextField", "minimum silence scrubber", enabled: false)
        var unknown = native; unknown[8] = node("AXTextField", "unrelated scrubber")
        var missing = native; missing.remove(at: 9)
        var noSliders = native; noSliders.remove(at: 3)
        var extra = native; extra.insert(node("AXTextField", "extra scrubber"), at: 7)
        var unreadable = native; unreadable[8] = node("AXTextField", "minimum silence scrubber", enabled: nil)
        for variant in [disabled, unknown, missing, noSliders, extra, unreadable] {
            XCTAssertNil(FinalCutNativeSettings.fieldIndices(in: variant))
        }
    }
}
