import XCTest
@testable import CutdownMac

final class FinalCutDialogueExportTests: XCTestCase {
    func testAudioFormatLabelAcceptsObservedCombinedFieldsOnly() {
        XCTAssertTrue(FinalCutDialogueExport.matchesSettingsLabel("Audio Format:", expected: "Audio Format:"))
        XCTAssertTrue(FinalCutDialogueExport.matchesSettingsLabel(
            "Video Codec: None  Resolution: None\nColor Space: None Audio Format:", expected: "Audio Format:"))
        XCTAssertTrue(FinalCutDialogueExport.matchesSettingsLabel("Export File Format:", expected: "Export File Format:"))
        XCTAssertTrue(FinalCutDialogueExport.matchesSettingsLabel("Format:", expected: "Export File Format:"))
        for label in ["Audio Format:", "Previous Format:", "Format: Audio Only", "Video Codec:"] {
            XCTAssertFalse(FinalCutDialogueExport.matchesSettingsLabel(label, expected: "Export File Format:"))
        }
        for label in ["Previous Audio Format:", "Video Codec: H.264 Resolution: None Color Space: None Audio Format:",
                      "Audio Format: WAV", "Export File Format:", "Format:"] {
            XCTAssertFalse(FinalCutDialogueExport.matchesSettingsLabel(label, expected: "Audio Format:"))
        }
    }
}
