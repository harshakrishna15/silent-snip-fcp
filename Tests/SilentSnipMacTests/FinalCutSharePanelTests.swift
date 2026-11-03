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
        let labels = ["1 file", ".wav", "Audio Track - 1", "All Dialogue", "Roles as:"]
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

    func testSeparateFilesSelectsOnlyWholeNonDialogueOutputs() {
        func layout(_ roles: [[String]], preset: String = "Audio Only as Separate Files (edited)") -> Panel {
            var controls = [control(0, kAXStaticTextRole, title: "\(roles.count) file"),
                control(1, kAXPopUpButtonRole, value: preset, description: "Roles formats and presets")]
            for (index, fileRoles) in roles.enumerated() {
                controls += [control(10 + index * 20, kAXStaticTextRole, title: ".wav"),
                    control(11 + index * 20, kAXButtonRole, title: "Remove audio track/file"),
                    control(12 + index * 20, kAXPopUpButtonRole, value: "Stereo", description: "Audio Channels")]
                for (roleIndex, role) in fileRoles.enumerated() {
                    controls += [control(13 + index * 20 + roleIndex * 2, kAXButtonRole, title: "Remove", description: "Remove role"),
                        control(14 + index * 20 + roleIndex * 2, kAXStaticTextRole, title: role)]
                }
            }
            return Panel(controls: controls)
        }
        let mixed = layout([["All Dialogue"], ["All Music"], ["All Effects"]])
        XCTAssertFalse(mixed.verifiesDialogueWAV)
        XCTAssertEqual(mixed.unwantedAudioFile?.element, 31)
        let cleaned = layout([["All Dialogue"]])
        XCTAssertTrue(cleaned.verifiesDialogueWAV)
        XCTAssertNil(cleaned.unwantedAudioFile)
        let custom = layout([["All Dialogue"], ["All Room Tone"]])
        XCTAssertFalse(custom.verifiesDialogueWAV)
        XCTAssertEqual(custom.unwantedAudioFile?.element, 31,
            "Remove the complete custom-role export file while preserving the one pure Dialogue file")
        for bad in [layout([["All Dialogue", "All Music"]]), layout([["All Dialogue", "Ambience"]]),
                    layout([["All Dialogue"], ["All Dialogue"]]), layout([["All Dialogue"], ["Unknown"]]),
                    layout([["All Dialogue", "All Room Tone"]]),
                    layout([["All Dialogue"], ["Room Tone.Clean"]]),
                    layout([["All Dialogue"], ["All Dialogue.Voice"]]),
                    layout([["All Dialogue"], ["All"]]),
                    layout([["All Dialogue"]], preset: "Custom")] {
            XCTAssertFalse(bad.verifiesDialogueWAV)
            XCTAssertNil(bad.unwantedAudioFile)
        }
        var unknownMix = ["1 file", ".wav", "Audio Track - 1", "All Dialogue", "Ambience", "Roles as:"]
            .enumerated().map { control($0.offset, kAXStaticTextRole, title: $0.element) }
        unknownMix.append(control(100, kAXPopUpButtonRole, value: "WAV", description: "Roles formats and presets"))
        XCTAssertFalse(Panel(controls: unknownMix).verifiesDialogueWAV)
    }

    func testFullProjectMixRequiresEveryRoleInOneStereoWAV() {
        let expected: Set<String> = ["dialogue.Voice", "music.Bed"]
        XCTAssertTrue(fullMix(roles: ["All Dialogue", "All Music"]).verifiesFullProjectMixWAV(expectedRoles: expected))
        XCTAssertFalse(fullMix(roles: ["All Dialogue"]).verifiesFullProjectMixWAV(expectedRoles: expected),
            "The WAV popup updates before the full native role track has settled")
        XCTAssertFalse(fullMix(roles: ["All Dialogue", "All Music", "All Effects"]).verifiesFullProjectMixWAV(expectedRoles: expected))
        XCTAssertFalse(fullMix(roles: ["All Dialogue", "All Music"]).verifiesFullProjectMixWAV(expectedRoles: []))
    }

    func testFullProjectMixRetainsCustomGroupsAndSubrolesWithoutNormalizingDistinctGroupsTogether() {
        let expected: Set<String> = ["dialogue.One", "dialogue.Two", "Custom Voice.Overdub"]
        XCTAssertTrue(fullMix(roles: ["All Dialogue", "All Custom Voice"]).verifiesFullProjectMixWAV(expectedRoles: expected))
        XCTAssertFalse(fullMix(roles: ["All Dialogue"]).verifiesFullProjectMixWAV(expectedRoles: expected),
            "Custom roles must not disappear from a full mix")
        XCTAssertFalse(fullMix(roles: ["All AB"]).verifiesFullProjectMixWAV(expectedRoles: ["A B.One", "AB.Two"]),
            "Whitespace normalization must not merge distinct custom role groups")
    }

    func testFullProjectMixRejectsMissingOrAmbiguousStereoAndStaleSeparateFiles() {
        let expected: Set<String> = ["dialogue", "music"]
        XCTAssertFalse(fullMix(roles: ["All Dialogue", "All Music"], layout: nil).verifiesFullProjectMixWAV(expectedRoles: expected))
        XCTAssertFalse(fullMix(roles: ["All Dialogue", "All Music"], layout: "Mono").verifiesFullProjectMixWAV(expectedRoles: expected))
        XCTAssertFalse(fullMix(roles: ["All Dialogue", "All Music"], preset: "Audio Only as Separate Files").verifiesFullProjectMixWAV(expectedRoles: expected))
        let valid = fullMix(roles: ["All Dialogue", "All Music"])
        for extra in [control(100, kAXStaticTextRole, value: "Stereo (L R)", description: "audio channel layout"),
                      control(101, kAXStaticTextRole, title: ".wav"),
                      control(102, kAXStaticTextRole, title: "Audio Track - 2"),
                      control(103, kAXStaticTextRole, title: "2 files"),
                      control(104, kAXPopUpButtonRole, value: "WAV", description: "Roles formats and presets")] {
            XCTAssertFalse(Panel(controls: valid.controls + [extra]).verifiesFullProjectMixWAV(expectedRoles: expected))
        }
        XCTAssertFalse(fullMix(roles: ["All Dialogue", "All Music", "All Music"]).verifiesFullProjectMixWAV(expectedRoles: expected))
    }

    private func fullMix(roles: [String], layout: String? = "Stereo (L R)", preset: String = "WAV") -> Panel {
        let labels = [".wav", "1 file", "audio track-1"] + roles + ["Roles as:"]
        var controls = labels.enumerated().map { control($0.offset, kAXStaticTextRole, title: $0.element) }
        controls.append(control(90, kAXPopUpButtonRole, value: preset, description: "Roles formats and presets"))
        if let layout {
            controls.append(control(91, kAXStaticTextRole, value: layout, description: "audio channel layout"))
        }
        return Panel(controls: controls)
    }

    func testBoundsAndDeadlineRejectIncompleteSnapshots() {
        for (maxNodes, maxDepth, keepReading) in [(2, 16, true), (500, 1, true), (500, 16, false)] {
            XCTAssertThrowsError(try Panel.capture(root: 0, read: { id in
                (self.control(id, kAXGroupRole), id < 2 ? [id + 1] : [])
            }, shouldContinue: { keepReading }, maxNodes: maxNodes, maxDepth: maxDepth))
        }
    }
}
