import CutdownCore
import CoreGraphics
import XCTest
@testable import CutdownMac

final class FinalCutProjectCaptureTests: XCTestCase {
    func testPreviewAnchorsToExactHostWindowDespiteTransparentCoveringSurfaces() {
        let frame = CGRect(x: 0, y: 20, width: 1000, height: 800)
        let project = FinalCutPreviewSurface(pid: 10, frame: frame, layer: 0, alpha: 1, number: 123)
        let transparent = FinalCutPreviewSurface(pid: 11, frame: frame, layer: 3, alpha: 1, number: 456)
        XCTAssertEqual(FinalCutPreviewSurface.projectWindowNumber(in: [transparent, project], projectPID: 10, projectFrame: frame), 123)
        XCTAssertNil(FinalCutPreviewSurface.projectWindowNumber(in: [project, project], projectPID: 10, projectFrame: frame))
        XCTAssertNil(FinalCutPreviewSurface.projectWindowNumber(in: [transparent], projectPID: 10, projectFrame: frame))
    }

    func testRangeShortcutUsesAdvertisedPhysicalKeyAndAXModifiers() throws {
        let plain = try XCTUnwrap(FinalCutMenuShortcut(virtualKey: 34, modifiers: 8, character: "i", glyph: nil, enabled: true))
        XCTAssertEqual(plain.keyCode, 34)
        XCTAssertEqual(plain.flags, [])
        let command = try XCTUnwrap(FinalCutMenuShortcut(virtualKey: 31, modifiers: 0, character: "o", glyph: nil, enabled: true))
        XCTAssertEqual(command.flags, .maskCommand)
        let modified = try XCTUnwrap(FinalCutMenuShortcut(virtualKey: 12, modifiers: 7, character: "q", glyph: nil, enabled: true))
        XCTAssertEqual(modified.keyCode, 12, "Use the host's assigned key, not a hard-coded default")
        XCTAssertEqual(modified.flags, [.maskCommand, .maskShift, .maskAlternate, .maskControl])
        let noCommand = try XCTUnwrap(FinalCutMenuShortcut(virtualKey: 12, modifiers: 15, character: "q", glyph: nil, enabled: true))
        XCTAssertEqual(noCommand.flags, [.maskShift, .maskAlternate, .maskControl])
    }

    func testRangeShortcutRejectsUnavailableOrUnusableAssignments() {
        for enabled: Bool? in [false, nil] {
            XCTAssertNil(FinalCutMenuShortcut(virtualKey: 34, modifiers: 8, character: "i", glyph: nil, enabled: enabled))
        }
        for key: Int? in [nil, -1, 128, Int.max] {
            XCTAssertNil(FinalCutMenuShortcut(virtualKey: key, modifiers: 8, character: "i", glyph: nil, enabled: true))
        }
        for modifiers: Int? in [nil, -1, 16, Int.max] {
            XCTAssertNil(FinalCutMenuShortcut(virtualKey: 34, modifiers: modifiers, character: "i", glyph: nil, enabled: true))
        }
        for character: String? in [nil, ""] {
            XCTAssertNil(FinalCutMenuShortcut(virtualKey: 0, modifiers: 0, character: character, glyph: 0, enabled: true))
        }
    }

    func testRangeShortcutSupportsGlyphAssignmentAndZeroKeyCode() throws {
        let glyph = try XCTUnwrap(FinalCutMenuShortcut(virtualKey: 123, modifiers: 9, character: nil, glyph: 28, enabled: true))
        XCTAssertEqual(glyph.keyCode, 123)
        XCTAssertEqual(glyph.flags, .maskShift)
        let a = try XCTUnwrap(FinalCutMenuShortcut(virtualKey: 0, modifiers: 8, character: "a", glyph: nil, enabled: true))
        XCTAssertEqual(a.keyCode, 0, "Zero is a valid physical key code, not missing metadata")
    }

    func testPreviewClipsToScrollViewportBesideDockedBrowser() {
        let clip = CGRect(x: -300, y: 600, width: 2000, height: 200)
        let layout = CGRect(x: 0, y: 500, width: 1600, height: 400)
        let browserOpen = CGRect(x: 0, y: 500, width: 1100, height: 400)
        XCTAssertEqual(FinalCutPreviewGeometry.visibleFrame(clip: clip, timeline: layout, scrollViewports: [browserOpen]), CGRect(x: 0, y: 600, width: 1100, height: 200))
        XCTAssertEqual(FinalCutPreviewGeometry.visibleFrame(clip: clip, timeline: layout, scrollViewports: [layout]), CGRect(x: 0, y: 600, width: 1600, height: 200))
        XCTAssertNil(FinalCutPreviewGeometry.visibleFrame(clip: clip, timeline: layout, scrollViewports: []))
        XCTAssertNil(FinalCutPreviewGeometry.visibleFrame(clip: clip, timeline: layout, scrollViewports: [CGRect(x: 0, y: 0, width: 500, height: 100)]))
    }

    func testPreviewFollowsVisibleProjectAndMasksCoveringWindowsWithoutForegroundRequirement() {
        let frame = CGRect(x: 0, y: 20, width: 1000, height: 800)
        let cover = CGRect(x: 0, y: 20, width: 500, height: 800)
        let project = FinalCutPreviewSurface(pid: 10, frame: frame, layer: 0, alpha: 1)
        let windows = [FinalCutPreviewSurface(pid: 99, frame: frame, layer: 1000, alpha: 1),
            FinalCutPreviewSurface(pid: 20, frame: frame, layer: 3, alpha: 1),
            FinalCutPreviewSurface(pid: 30, frame: cover, layer: 0, alpha: 1), project,
            FinalCutPreviewSurface(pid: 40, frame: frame, layer: 0, alpha: 1)]
        XCTAssertEqual(FinalCutPreviewSurface.occlusions(in: windows, projectPID: 10, projectFrame: frame, helperPID: 20), [cover])
        XCTAssertNil(FinalCutPreviewSurface.occlusions(in: Array(windows.prefix(2)), projectPID: 10, projectFrame: frame, helperPID: 20))
        XCTAssertNil(FinalCutPreviewSurface.occlusions(in: [project, project], projectPID: 10, projectFrame: frame, helperPID: 20))
        XCTAssertEqual(FinalCutPreviewSurface.occlusions(in: [project], projectPID: 10, projectFrame: frame, helperPID: 20), [])
    }

    func testOtherEffectEditorsDoNotHidePreviewButModalDialogsStillDo() {
        for _ in ["Noise Gate", "Limiter", "Third-party Audio Unit", "Cutdown"] {
            XCTAssertFalse(FinalCutWindowPolicy.blocksPreview(role: "AXWindow", subrole: "AXDialog", modal: false, containsCutdownReview: false))
        }
        XCTAssertTrue(FinalCutWindowPolicy.blocksPreview(role: "AXWindow", subrole: "AXDialog", modal: true, containsCutdownReview: true))
        XCTAssertTrue(FinalCutWindowPolicy.blocksPreview(role: "AXSheet", subrole: nil, modal: false, containsCutdownReview: true))
        XCTAssertTrue(FinalCutWindowPolicy.blocksPreview(role: "AXWindow", subrole: "AXDialog", modal: nil, containsCutdownReview: false))
        XCTAssertFalse(FinalCutWindowPolicy.blocksPreview(role: "AXWindow", subrole: "AXDialog", modal: nil, containsCutdownReview: true))
    }

    func testControlActionUsesOnlyAnAdvertisedActivationAction() {
        XCTAssertEqual(FinalCutControlAction.preferred(from: ["AXCancel", "AXPick"]), "AXPick")
        XCTAssertEqual(FinalCutControlAction.preferred(from: ["AXPress"]), "AXPress")
        XCTAssertEqual(FinalCutControlAction.preferred(from: ["AXPick", "AXPress"]), "AXPress")
        XCTAssertNil(FinalCutControlAction.preferred(from: ["AXCancel", "AXShowMenu"]))
        XCTAssertNil(FinalCutControlAction.preferred(from: []))
    }

    func testMenuActivationRequiresOpenSelectedEnabledItem() {
        XCTAssertTrue(FinalCutControlAction.confirmsPickedMenuItem(action: "AXPick", menuOpen: true, itemSelected: true, itemEnabled: true))
        XCTAssertTrue(FinalCutControlAction.confirmsPickedMenuItem(action: "AXPress", menuOpen: true, itemSelected: true, itemEnabled: true))
        XCTAssertFalse(FinalCutControlAction.confirmsPickedMenuItem(action: "AXPress", menuOpen: false, itemSelected: true, itemEnabled: true))
        XCTAssertFalse(FinalCutControlAction.confirmsPickedMenuItem(action: "AXPick", menuOpen: false, itemSelected: true, itemEnabled: true))
        XCTAssertFalse(FinalCutControlAction.confirmsPickedMenuItem(action: "AXPick", menuOpen: true, itemSelected: false, itemEnabled: true))
        XCTAssertFalse(FinalCutControlAction.confirmsPickedMenuItem(action: "AXPick", menuOpen: true, itemSelected: true, itemEnabled: false))
    }

    func testDuplicateRootSheetsRetainTheirDeepestAncestorChain() {
        let edges = ["main": ["save"], "save": ["goTo"], "goTo": ["nested"]]
        let paths = FinalCutSheetTraversal.paths(roots: ["main", "save", "goTo"], equals: ==,
            children: { edges[$0] ?? [] })
        XCTAssertEqual(paths.first { $0.element == "save" }?.lineage, ["main", "save"])
        XCTAssertEqual(paths.first { $0.element == "goTo" }?.lineage, ["main", "save", "goTo"])
        XCTAssertEqual(paths.first { $0.element == "nested" }?.lineage, ["main", "save", "goTo", "nested"])
        let focusedMain = paths.filter { $0.lineage.contains("main") }.max { $0.lineage.count < $1.lineage.count }
        XCTAssertEqual(focusedMain?.element, "nested")
    }

    func testSheetTraversalBoundsCyclesDepthAndRepeatedChildren() {
        let cycle = FinalCutSheetTraversal.paths(roots: ["main"], equals: ==,
            children: { $0 == "main" ? ["save", "save"] : ["main"] })
        XCTAssertEqual(cycle.map(\.element), ["main", "save"])
        let deep = FinalCutSheetTraversal.paths(roots: [0], equals: ==, children: { [$0 + 1] })
        XCTAssertEqual(deep.map(\.element), [0, 1, 2, 3, 4])
        XCTAssertEqual(deep.last?.lineage.count, 5)
    }

    func testReviewRestorationFindsOnlyCutdownsEditorAmongFlatEffects() {
        let controls = [
            node(role: "AXCheckBox", description: "other effect check box"),
            node(role: "AXStaticText", value: "Other Effect"),
            node(role: "AXButton", description: "Show effect editor"),
            node(role: "AXCheckBox", description: "cutdown audio check box"),
            node(role: "AXStaticText", value: "Cutdown Audio"),
            node(role: "AXButton", description: "cutdown audio parameter menu"),
            node(role: "AXButton", description: "Show effect editor"),
            node(role: "AXCheckBox", description: "later effect check box"),
            node(role: "AXButton", description: "Show effect editor")
        ]
        XCTAssertEqual(FinalCutReviewInspector.editorIndex(in: controls), 6)
        XCTAssertNil(FinalCutReviewInspector.editorIndex(in: Array(controls.prefix(3))))
        XCTAssertNil(FinalCutReviewInspector.editorIndex(in: controls + Array(controls[3...6])))
    }

    func testReviewRestorationRejectsMissingDisabledOrAmbiguousEditors() {
        let heading = [node(role: "AXCheckBox", description: "cutdown audio check box"),
                       node(role: "AXStaticText", value: "Cutdown Audio")]
        let editor = node(role: "AXButton", description: "Show effect editor")
        XCTAssertNil(FinalCutReviewInspector.editorIndex(in: heading))
        XCTAssertNil(FinalCutReviewInspector.editorIndex(in: [heading[0], editor]))
        XCTAssertNil(FinalCutReviewInspector.editorIndex(in: heading + [editor, editor]))
        XCTAssertNil(FinalCutReviewInspector.editorIndex(in: heading + [node(role: "AXButton", description: "Show effect editor", enabled: false)]))
        XCTAssertNil(FinalCutReviewInspector.editorIndex(in: heading + [node(role: "AXCheckBox", description: "other effect check box"), editor]))
    }

    func testCutdownReviewPanelDoesNotBlockButRealDialogsDo() {
        XCTAssertFalse(FinalCutWindowPolicy.isBlockingDialog(subrole: "AXDialog", modal: false, containsCutdownReview: true))
        XCTAssertFalse(FinalCutWindowPolicy.isBlockingDialog(subrole: "AXDialog", modal: nil, containsCutdownReview: true))
        XCTAssertTrue(FinalCutWindowPolicy.isBlockingDialog(subrole: "AXDialog", modal: true, containsCutdownReview: true))
        XCTAssertTrue(FinalCutWindowPolicy.isBlockingDialog(subrole: "AXDialog", modal: false, containsCutdownReview: false))
        XCTAssertTrue(FinalCutWindowPolicy.isBlockingDialog(subrole: "AXDialog", modal: nil, containsCutdownReview: false))
        XCTAssertTrue(FinalCutWindowPolicy.isBlockingDialog(subrole: "AXStandardWindow", modal: true, containsCutdownReview: false))
        XCTAssertFalse(FinalCutWindowPolicy.isBlockingDialog(subrole: "AXStandardWindow", modal: false, containsCutdownReview: false))
        XCTAssertTrue(FinalCutWindowPolicy.isBlockingDialog(role: "AXSheet", subrole: nil, modal: nil, containsCutdownReview: false))
        XCTAssertTrue(FinalCutWindowPolicy.isBlockingDialog(role: "AXSheet", subrole: nil, modal: false, containsCutdownReview: true))
    }

    func testNDFAndFractionalFrameTimecodesStayExact() throws {
        XCTAssertEqual(try FinalCutTimecode.time("01:02:03:12", frameDuration: RationalTime(1, 25)), RationalTime(93087, 25))
        XCTAssertEqual(try FinalCutTimecode.time("00:01:00:00", frameDuration: RationalTime(1001, 30000)), RationalTime(3003, 50))
        XCTAssertEqual(try FinalCutTimecode.format(RationalTime(3003, 50), frameDuration: RationalTime(1001, 30000)), "00:01:00:00")
    }

    func testDropFrameLabelsSkipOnlyRequiredFrameNumbers() throws {
        let rate = RationalTime(1001, 30000)
        XCTAssertEqual(try FinalCutTimecode.time("00:01:00;02", frameDuration: rate), RationalTime(3003, 50))
        XCTAssertEqual(try FinalCutTimecode.time("00:10:00;00", frameDuration: rate), RationalTime(2999997, 5000))
        XCTAssertEqual(try FinalCutTimecode.time("01:00:00;00", frameDuration: rate), RationalTime(8999991, 2500))
        for label in ["00:00:00;00", "00:00:59;29", "00:01:00;02", "00:09:59;29", "00:10:00;00", "01:00:00;00", "23:59:59;29"] {
            XCTAssertEqual(try FinalCutTimecode.format(FinalCutTimecode.time(label, frameDuration: rate), frameDuration: rate, dropFrame: true), label)
        }
        let sixty = RationalTime(1001, 60000)
        XCTAssertEqual(try FinalCutTimecode.format(FinalCutTimecode.time("00:01:00;04", frameDuration: sixty), frameDuration: sixty, dropFrame: true), "00:01:00;04")
        for invalid in ["00:01:00;00", "00:01:00;01", "00:61:00:00", "00:00:60:00", "00:00:00:30", "1:02:03:04", "00:00:00.12", "-1:00:00:00", "999999999999999:00:00:00"] {
            XCTAssertThrowsError(try FinalCutTimecode.time(invalid, frameDuration: rate), invalid)
        }
        XCTAssertThrowsError(try FinalCutTimecode.time("00:01:00;02", frameDuration: RationalTime(1, 30)))
        XCTAssertThrowsError(try FinalCutTimecode.format(RationalTime(1, 100), frameDuration: rate))
        XCTAssertThrowsError(try FinalCutTimecode.format(RationalTime(Int64.max), frameDuration: rate))
    }

    func testSelectedTrimmedRepeatedOccurrenceUsesExactEdgesAndSourceIdentity() throws {
        let document = try fixture()
        let snapshot = try selection(start: "00:00:08:00", end: "00:00:16:00")
        let (selected, target) = try snapshot.resolve(in: document, requireExistingMedia: false)
        XCTAssertEqual(target.id, "spine/1")
        XCTAssertEqual(selected.timelineRange, TimeRange(start: RationalTime(8), end: RationalTime(16)))
        XCTAssertEqual(selected.sourceStart, RationalTime(1))
        XCTAssertEqual(selected.sourceURL, URL(fileURLWithPath: "/tmp/CutdownCaptureFixture.wav"))
    }

    func testNonzeroProjectTimecodeResolvesToProjectSeconds() throws {
        let document = try fixture(tcStart: 3600)
        let snapshot = try selection(start: "01:00:08:00", end: "01:00:16:00")
        XCTAssertEqual(try snapshot.resolve(in: document, requireExistingMedia: false).1.id, "spine/1")
        XCTAssertThrowsError(try selection(start: "00:00:08:00", end: "00:00:16:00").resolve(in: document, requireExistingMedia: false))
    }

    func testXMLRejectsVideoTargetEvenWhenAccessibilityCallsItAnAudioClip() throws {
        let document = try fixture(videoTarget: true)
        let snapshot = try selection(start: "00:00:08:00", end: "00:00:16:00")
        XCTAssertThrowsError(try snapshot.resolve(in: document, requireExistingMedia: false)) { error in
            guard case TimelineError.unsupportedTarget(let reasons) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reasons.contains { $0.contains("audio-only") })
        }
    }

    func testPartialSelectionChangedNameAndProjectAreRejected() throws {
        let document = try fixture()
        XCTAssertThrowsError(try selection(start: "00:00:08:00", end: "00:00:12:00").resolve(in: document, requireExistingMedia: false))
        XCTAssertThrowsError(try selection(start: "00:00:08:00", end: "00:00:16:00", name: "Different source").resolve(in: document, requireExistingMedia: false))
        XCTAssertThrowsError(try selection(start: "00:00:08:00", end: "00:00:16:00", project: "Another project").resolve(in: document, requireExistingMedia: false))
    }

    func testConnectedClipWithIdenticalNameAndBoundsIsAmbiguous() throws {
        let document = try fixture(connectedDuplicate: true)
        XCTAssertThrowsError(try selection(start: "00:00:00:00", end: "00:00:08:00").resolve(in: document, requireExistingMedia: false))
    }

    func testSnapshotRequiresOneDirectWholeClipWithUniqueHandles() throws {
        let one = clip()
        XCTAssertThrowsError(try FinalCutSelectionSnapshot(projectName: "Capture", timeline: node(role: "AXLayoutArea", description: "Project Timeline")))
        XCTAssertThrowsError(try FinalCutSelectionSnapshot(projectName: "Capture", timeline: node(role: "AXLayoutArea", description: "Project Timeline", children: [one, one])))
        XCTAssertThrowsError(try FinalCutSelectionSnapshot(projectName: "Capture", timeline: node(role: "AXLayoutArea", description: "Project Timeline", children: [node(role: "AXGroup", children: [one])])) )
        let bad = node(role: "AXLayoutItem", value: "00:00:08:00", selected: true, children: [node(role: "AXHandle", description: "Leading Edge", value: "00:00:00:00")])
        XCTAssertThrowsError(try FinalCutSelectionSnapshot(projectName: "Capture", timeline: node(role: "AXLayoutArea", description: "Project Timeline", children: [bad])))
        XCTAssertThrowsError(try FinalCutSelectionSnapshot(projectName: "Capture", timeline: node(role: "AXLayoutArea", description: "Browser", children: [one])))
    }

    private func selection(start: String, end: String, name: String = "Recording", project: String = "Capture") throws -> FinalCutSelectionSnapshot {
        try FinalCutSelectionSnapshot(projectName: project, timeline: node(role: "AXLayoutArea", description: "Project Timeline", children: [clip(start: start, end: end, name: name)]))
    }
    private func clip(start: String = "00:00:00:00", end: String = "00:00:08:00", name: String = "Recording") -> AccessibilityNode {
        node(role: "AXLayoutItem", description: "Audio-Clip:\(name)", value: "00:00:08:00", selected: true, children: [
            node(role: "AXHandle", description: "Leading Edge", value: start),
            node(role: "AXHandle", description: "Trailing Edge", value: end),
            node(role: "AXTextField", description: "Title", value: name)
        ])
    }
    private func node(role: String, description: String? = nil, value: String? = nil, selected: Bool? = nil, enabled: Bool = true, children: [AccessibilityNode] = []) -> AccessibilityNode {
        AccessibilityNode(role: role, identifier: nil, title: nil, description: description, value: value, selected: selected, enabled: enabled, children: children)
    }

    private func fixture(tcStart: Int = 0, connectedDuplicate: Bool = false, videoTarget: Bool = false) throws -> TimelineDocument {
        let nested = connectedDuplicate ? "<asset-clip ref=\"r2\" name=\"Recording\" lane=\"1\" offset=\"1s\" start=\"1s\" duration=\"8s\" audioRole=\"dialogue\"/>" : ""
        return try TimelineParser.parse(data: Data("""
        <fcpxml version="1.14"><resources>
          <format id="r1" frameDuration="1/30s"/>
          <asset id="r2" name="Recording" start="0s" duration="10s" hasVideo="\(videoTarget ? 1 : 0)" hasAudio="1" audioSources="1" audioChannels="2"><media-rep kind="original-media" src="file:///tmp/CutdownCaptureFixture.wav"/></asset>
        </resources><library><event name="Disposable"><project name="Capture" uid="fixture"><sequence format="r1" duration="16s" tcStart="\(tcStart)s" tcFormat="NDF"><spine>
          <asset-clip ref="r2" name="Recording" offset="\(tcStart)s" start="1s" duration="8s" audioRole="dialogue">\(nested)</asset-clip>
          <asset-clip ref="r2" name="Recording" offset="\(tcStart + 8)s" start="1s" duration="8s" audioRole="dialogue"/>
        </spine></sequence></project></event></library></fcpxml>
        """.utf8))
    }
}
