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
                      control(104, kAXPopUpButtonRole, value: "WAV", description: "Roles formats and presets")] {
            XCTAssertFalse(Panel(controls: valid.controls + [extra]).verifiesFullProjectMixWAV(expectedRoles: expected),
                "Duplicate WAV/track/layout/preset controls after Roles as: must remain forbidden")
        }
        let boundary = valid.controls.firstIndex { $0.title == "Roles as:" }!
        for extra in [control(101, kAXStaticTextRole, title: ".wav"),
                      control(102, kAXStaticTextRole, title: "Audio Track - 2"),
                      control(103, kAXStaticTextRole, title: "2 files")] {
            var controls = valid.controls
            controls.insert(extra, at: boundary)
            XCTAssertFalse(Panel(controls: controls).verifiesFullProjectMixWAV(expectedRoles: expected),
                "Additional audio outputs above Roles as: remain forbidden")
        }
        XCTAssertFalse(fullMix(roles: ["All Dialogue", "All Music", "All Music"]).verifiesFullProjectMixWAV(expectedRoles: expected))
    }

    func testFullProjectMixSeparatesAudioOutputCountFromWAVAndXMLDeliveryFooter() {
        let roles: Set<String> = ["dialogue"]
        let valid = fullMix(roles: ["All Dialogue"])
        let footer = [control(105, kAXStaticTextRole, title: "48kHz"),
                      control(106, kAXStaticTextRole, title: "00:01:00.000"),
                      control(107, kAXStaticTextRole, title: "2 files"),
                      control(108, kAXStaticTextRole, title: "17.3 MB"),
                      control(109, kAXStaticTextRole, title: "Silent Snip")]
        XCTAssertTrue(Panel(controls: valid.controls + footer).verifiesFullProjectMixWAV(expectedRoles: roles),
            "The native footer includes the project XML attachment alongside the one WAV")
        var wrongHeader = valid.controls
        let count = wrongHeader.firstIndex { $0.title == "1 file" }!
        wrongHeader[count] = control(110, kAXStaticTextRole, title: "2 files")
        XCTAssertFalse(Panel(controls: wrongHeader + footer).verifiesFullProjectMixWAV(expectedRoles: roles))
    }

    func testFullProjectMixAcceptsOnlyTheObservedNativeStaticKindWAVFooter() throws {
        // Sanitized controls from the native three-role failure diagnostic.
        // No project names, source paths, request IDs, or other private values.
        let controls = [
            control(0, kAXWindowRole, title: "Silent Snip"),
            control(1, kAXImageRole, description: "PE Share WindowBackground"),
            control(2, kAXTabGroupRole),
            control(3, kAXRadioButtonRole, title: "Info", value: "0"),
            control(4, kAXRadioButtonRole, title: "Settings", value: "0"),
            control(5, kAXRadioButtonRole, title: "Roles", value: "1"),
            control(6, kAXScrollAreaRole),
            control(7, kAXImageRole, description: "FC Glyphs Share Audio File"),
            control(8, kAXStaticTextRole, value: ".wav"),
            control(9, kAXStaticTextRole, value: "1 file"),
            control(10, kAXStaticTextRole, value: "audio track-1"),
            control(11, kAXImageRole, description: "FC Glyphs Share Audio Track"),
            control(12, kAXStaticTextRole, value: "All Dialogue"),
            control(13, kAXStaticTextRole, value: "All Music"),
            control(14, kAXStaticTextRole, value: "All Room Tone"),
            control(15, kAXStaticTextRole, value: "Roles as:"),
            control(16, kAXPopUpButtonRole, value: "WAV", description: "Roles formats and presets"),
            control(17, kAXScrollBarRole, value: "1"),
            control(18, kAXStaticTextRole, value: "Silent Snip"),
            control(19, kAXButtonRole, title: "Next…"),
            control(20, kAXButtonRole, title: "Cancel"),
            control(21, kAXImageRole, description: ""),
            control(22, kAXStaticTextRole, value: "Stereo (L R)", description: "audio channel layout"),
            control(23, kAXImageRole, description: "PE Share InfoBar TextSeparator"),
            control(24, kAXStaticTextRole, value: "48 kHz", description: "audio sample rate"),
            control(25, kAXStaticTextRole, value: "00:01:00.000", description: "duration"),
            control(26, kAXStaticTextRole, value: ".wav", description: "kind"),
            control(27, kAXStaticTextRole, value: "17.3 MB est.", description: "estimated file size"),
            control(28, kAXStaticTextRole, value: "Silent Snip")
        ]
        let roles: Set<String> = ["dialogue", "music", "Room Tone"]
        XCTAssertTrue(Panel(controls: controls).verifiesFullProjectMixWAV(expectedRoles: roles))
        XCTAssertTrue(Panel(controls: controls + [control(100, kAXStaticTextRole, value: "2 files")])
            .verifiesFullProjectMixWAV(expectedRoles: roles), "WAV+XML attachment summary remains outside the audio count")

        for extra in [control(101, kAXStaticTextRole, value: ".wav"),
                      control(102, kAXStaticTextRole, value: ".wav", description: "kind"),
                      control(103, kAXButtonRole, value: ".wav", description: "kind"),
                      control(104, kAXStaticTextRole, value: "audio track-2"),
                      control(105, kAXButtonRole, value: "audio track-2")] {
            XCTAssertFalse(Panel(controls: controls + [extra]).verifiesFullProjectMixWAV(expectedRoles: roles),
                "No additional WAV/track output can be hidden by the known footer")
        }
        for description in [nil, "Kind", "file kind", "audio channel layout"] as [String?] {
            var altered = controls
            altered[26] = control(26, kAXStaticTextRole, value: ".wav", description: description)
            XCTAssertFalse(Panel(controls: altered).verifiesFullProjectMixWAV(expectedRoles: roles),
                "Only the exact observed AX description qualifies as a second WAV footer")
        }
        var duplicateHeader = controls
        duplicateHeader.insert(control(106, kAXStaticTextRole, value: ".wav", description: "kind"), at: 9)
        XCTAssertFalse(Panel(controls: duplicateHeader).verifiesFullProjectMixWAV(expectedRoles: roles),
            "A second header WAV cannot qualify as the footer")
        var missingHeader = controls
        missingHeader.remove(at: 8)
        XCTAssertFalse(Panel(controls: missingHeader).verifiesFullProjectMixWAV(expectedRoles: roles),
            "The footer cannot substitute for the required header WAV")
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
