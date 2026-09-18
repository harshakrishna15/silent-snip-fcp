import XCTest
@testable import CutdownCore

final class TimelineTests: XCTestCase {
    func testExtremeFadesProtectWholeClipWithoutOverflow() throws {
        let xml = """
        <fcpxml version="1.14"><resources><format id="f" frameDuration="1/30s"/>
        <asset id="a" start="0s" duration="3s" hasAudio="1"><media-rep kind="original-media" src="file:///tmp/a.wav"/></asset></resources>
        <library><event><project name="Overflow" uid="test"><sequence format="f" duration="3s" tcStart="0s"><spine>
        <gap offset="0s" duration="1s"/><asset-clip ref="a" offset="1s" start="0s" duration="1s" audioRole="dialogue">
        <adjust-volume amount="0dB"><fadeIn duration="9223372036854775807s"/><fadeOut duration="9223372036854775807s"/></adjust-volume>
        </asset-clip><gap offset="2s" duration="1s"/></spine></sequence></project></event></library></fcpxml>
        """
        let doc = try parse(xml)
        let target = try doc.selectedTarget(.init(timelineRange: range(1, 2)), requireExistingMedia: false)
        XCTAssertEqual(try doc.protectedRanges(for: target).map(\.range), [range(1, 2), range(1, 2)])
        let plan = try ReviewPlan(jobID: UUID(), document: doc, target: target,
            analysis: SilenceAnalysisResult(candidates: [.init(start: .init(1), end: .init(3, 2))], disposition: .cuts))
        XCTAssertTrue(plan.selectedCuts.isEmpty)
    }

    private func fixture() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "timeline-context", withExtension: "fcpxml", subdirectory: "Fixtures"))
        return try String(contentsOf: url)
    }
    private func audioOnlyFixture() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "audio-only-timeline", withExtension: "fcpxml", subdirectory: "Fixtures"))
        return try String(contentsOf: url)
    }
    private func nativeAudioFixture() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "final-cut-12-3-native-audio", withExtension: "fcpxml", subdirectory: "Fixtures"))
        return try String(contentsOf: url)
    }
    private func parse(_ xml: String, exclusions: TimelineFingerprintExclusions = .init()) throws -> TimelineDocument {
        try TimelineParser.parse(data: Data(xml.utf8), exclusions: exclusions)
    }
    private func range(_ start: Int64, _ end: Int64) -> TimeRange {
        TimeRange(start: RationalTime(start), end: RationalTime(end))
    }

    func testProjectTimecodeAndSourceTimecodeAreIndependent() throws {
        let doc = try parse(fixture())
        XCTAssertEqual(doc.projectTimecodeStart, RationalTime(3600))
        XCTAssertEqual(doc.projectRange, range(0, 20))
        XCTAssertEqual(doc.frameDuration, RationalTime(1001, 30000))
        let target = try doc.selectedTarget(.init(timelineRange: range(0, 10)), requireExistingMedia: false)
        XCTAssertEqual(target.sourceStart, RationalTime(105))
        XCTAssertEqual(target.assetStart, RationalTime(100))
        XCTAssertEqual(target.sourceFileStart, RationalTime(5))
        XCTAssertEqual(doc.clips.first(where: { $0.name == "Title" })?.timelineRange, range(2, 6))
        XCTAssertEqual(doc.clips.first(where: { $0.name == "Connected speech" })?.timelineRange, range(4, 6))
    }

    func testExactOccurrenceSelectionWithRepeatedSourceAndName() throws {
        let doc = try parse(fixture())
        let target = try doc.selectedTarget(.init(timelineRange: range(10, 20), sourceURL: URL(string: "file:///fixtures/voice.wav")), requireExistingMedia: false)
        XCTAssertEqual(target.sourceStart, RationalTime(130))
        XCTAssertEqual(target.id, "spine/1")
        XCTAssertThrowsError(try doc.selectedTarget(.init(timelineRange: range(10, 20), sourceStart: RationalTime(105)), requireExistingMedia: false))
        XCTAssertThrowsError(try doc.selectedTarget(.init(timelineRange: range(1, 11)), requireExistingMedia: false))
        XCTAssertThrowsError(try doc.selectedTarget(.init(timelineRange: range(0, 10))))
    }

    func testConnectedDialogueProtectsButMusicAndTitlesDoNot() throws {
        let doc = try parse(fixture())
        let target = try doc.selectedTarget(.init(timelineRange: range(0, 10)), requireExistingMedia: false)
        XCTAssertEqual(doc.dialogueRoles, ["Dialogue.Voice", "dialogue"])
        let protected = try doc.protectedRanges(for: target)
        XCTAssertEqual(protected.count, 1)
        XCTAssertEqual(protected[0].range, range(4, 6))
        XCTAssertTrue(protected[0].reason.contains("Connected speech"))
    }

    func testDisabledComponentsDoNotCountAsDialogue() throws {
        let xml = try fixture().replacingOccurrences(of: "audioRole=\"Dialogue.Voice\"/>", with: "audioRole=\"Dialogue.Voice\"><audio-channel-source srcCh=\"1\" role=\"dialogue.disabled\" active=\"0\"/></asset-clip>")
        let doc = try parse(xml)
        XCTAssertEqual(doc.dialogueRoles, ["dialogue"])
        let target = try doc.selectedTarget(.init(timelineRange: range(0, 10)), requireExistingMedia: false)
        XCTAssertTrue(try doc.protectedRanges(for: target).isEmpty)
    }

    func testRetimeDisabledVideoAndSplitEditTargetsAreRejected() throws {
        let base = try fixture()
        for change in [
            base.replacingOccurrences(of: "<title ref=", with: "<timeMap/><title ref="),
            base.replacingOccurrences(of: "start=\"105s\" duration=\"10s\" audioRole", with: "start=\"105s\" duration=\"10s\" srcEnable=\"video\" audioRole"),
            base.replacingOccurrences(of: "start=\"105s\" duration=\"10s\" audioRole", with: "start=\"105s\" duration=\"10s\" audioStart=\"106s\" audioRole"),
            base.replacingOccurrences(of: "start=\"105s\" duration=\"10s\" audioRole", with: "start=\"105s\" duration=\"10s\" enabled=\"0\" audioRole")
        ] {
            let doc = try parse(change)
            XCTAssertThrowsError(try doc.selectedTarget(.init(timelineRange: range(0, 10)), requireExistingMedia: false))
        }
    }

    func testTransitionsAreProtected() throws {
        let xml = try fixture().replacingOccurrences(of: "<asset-clip ref=\"r2\" name=\"Recording\" offset=\"3610s\"", with: "<transition name=\"Dissolve\" offset=\"3609s\" duration=\"2s\"/><asset-clip ref=\"r2\" name=\"Recording\" offset=\"3610s\"")
        let doc = try parse(xml)
        let target = try doc.selectedTarget(.init(timelineRange: range(0, 10)), requireExistingMedia: false)
        XCTAssertTrue(try doc.protectedRanges(for: target).contains(.init(range: range(9, 10), reason: "Transition: Dissolve")))
    }

    func testMarkerOwnershipIsExactAndIncludesNotesStatusAndTiming() throws {
        let xml = try fixture()
        let original = try parse(xml)
        let marker = try XCTUnwrap(original.markers.first)
        XCTAssertEqual(marker.parentClipID, "spine/0")
        XCTAssertEqual(marker.timelinePosition, RationalTime(1))
        XCTAssertEqual(marker.sourcePosition, RationalTime(106))
        XCTAssertEqual(marker.note, "job:fixture")
        let exclusions = TimelineFingerprintExclusions(ownedMarkers: [marker.identity])
        let withoutMarker = xml.replacingOccurrences(of: "<marker start=\"106s\" duration=\"1001/30000s\" value=\"Cutdown Candidate 1\" note=\"job:fixture\" completed=\"0\"/>", with: "")
        XCTAssertEqual(try parse(xml, exclusions: exclusions).fingerprint, try parse(withoutMarker).fingerprint)
        XCTAssertNotEqual(original.fingerprint, try parse(withoutMarker).fingerprint)
        for changed in [
            xml.replacingOccurrences(of: "note=\"job:fixture\"", with: "note=\"user edited\""),
            xml.replacingOccurrences(of: "completed=\"0\"", with: "completed=\"1\""),
            xml.replacingOccurrences(of: "<marker start=\"106s\"", with: "<marker start=\"107s\"")
        ] {
            XCTAssertNotEqual(try parse(changed, exclusions: exclusions).fingerprint, try parse(withoutMarker).fingerprint)
        }
    }

    func testOnlyExplicitControllerUIDParametersAreExcluded() throws {
        let xml = try fixture()
        let thresholdChanged = xml.replacingOccurrences(of: "value=\"-40\"", with: "value=\"-30\"")
        XCTAssertNotEqual(try parse(xml).fingerprint, try parse(thresholdChanged).fingerprint)
        let exclusions = TimelineFingerprintExclusions(controllerEffectUIDs: ["test.cutdown.controller"])
        XCTAssertEqual(try parse(xml, exclusions: exclusions).fingerprint, try parse(thresholdChanged, exclusions: exclusions).fingerprint)
        let otherEffectChanged = xml.replacingOccurrences(of: "value=\"0.5\"", with: "value=\"0.8\"")
        XCTAssertNotEqual(try parse(xml, exclusions: exclusions).fingerprint, try parse(otherEffectChanged, exclusions: exclusions).fingerprint)
        let disabledController = xml.replacingOccurrences(of: "<filter-audio ref=\"r6\"", with: "<filter-audio enabled=\"0\" ref=\"r6\"")
        XCTAssertNotEqual(try parse(xml, exclusions: exclusions).fingerprint, try parse(disabledController, exclusions: exclusions).fingerprint)
    }

    func testFingerprintIgnoresExporterFormattingButPreservesUserContent() throws {
        let xml = try fixture()
        let equivalent = xml.replacingOccurrences(of: "2026-09-15 00:00:00 +0000", with: "2026-09-16 00:00:00 +0000")
            .replacingOccurrences(of: "r2", with: "r22").replacingOccurrences(of: "105s", with: "210/2s")
        XCTAssertEqual(try parse(xml).fingerprint, try parse(equivalent).fingerprint)
        let changed = xml.replacingOccurrences(of: "name=\"Title\"", with: "name=\"Changed title\"")
        XCTAssertNotEqual(try parse(xml).fingerprint, try parse(changed).fingerprint)
    }

    func testInvalidRationalsAndOverflowThrowWithoutTrapping() throws {
        let xml = try fixture()
        for invalid in ["1/0s", "1/-2s", "1/2/3s", "nans", "1.5s", "9223372036854775808s"] {
            XCTAssertThrowsError(try parse(xml.replacingOccurrences(of: "3600s", with: invalid)))
        }
        let overflow = xml.replacingOccurrences(of: "offset=\"3600s\"", with: "offset=\"9223372036854775807s\"")
            .replacingOccurrences(of: "tcStart=\"3600s\"", with: "tcStart=\"-1s\"")
        XCTAssertThrowsError(try parse(overflow))
    }

    func testOutOfRangeTimecodeAndExternalEntitiesAreRejected() throws {
        let xml = try fixture()
        XCTAssertThrowsError(try parse(xml.replacingOccurrences(of: "offset=\"3600s\"", with: "offset=\"0s\"")))
        let entity = xml.replacingOccurrences(of: "<!DOCTYPE fcpxml>", with: "<!DOCTYPE fcpxml [<!ENTITY secret SYSTEM \"file:///etc/passwd\">]>")
        XCTAssertThrowsError(try parse(entity))
        let internalEntity = xml.replacingOccurrences(of: "<!DOCTYPE fcpxml>", with: "<!DOCTYPE fcpxml [<!ENTITY name \"expanded\">]>")
        XCTAssertThrowsError(try parse(internalEntity))
        let externalDTD = xml.replacingOccurrences(of: "<!DOCTYPE fcpxml>", with: "<!DOCTYPE fcpxml SYSTEM \"https://example.invalid/fcpxml.dtd\">")
        XCTAssertThrowsError(try parse(externalDTD))
    }

    func testSourceArithmeticInvalidLanesAndNegativeResourceDurationReject() throws {
        let xml = try fixture()
        let overflow = xml.replacingOccurrences(of: "start=\"100s\"", with: "start=\"-9223372036854775808s\"")
        XCTAssertThrowsError(try parse(overflow))
        XCTAssertThrowsError(try parse(xml.replacingOccurrences(of: "lane=\"1\"", with: "lane=\"invalid\"")))
        XCTAssertThrowsError(try parse(xml.replacingOccurrences(of: "duration=\"100s\"", with: "duration=\"-100s\"")))
    }

    func testSecondaryStorylinePositionsUseTheParentSourceOrigin() throws {
        let xml = try fixture().replacingOccurrences(of: "<title ref=\"r5\" name=\"Title\" lane=\"1\" offset=\"107s\" start=\"0s\" duration=\"4s\"/>", with: """
        <spine lane="1" offset="107s">
          <asset-clip ref="r4" name="Secondary dialogue" offset="1s" start="0s" duration="2s" audioRole="dialogue.secondary"/>
        </spine>
        """)
        let doc = try parse(xml)
        let nested = try XCTUnwrap(doc.clips.first(where: { $0.name == "Secondary dialogue" }))
        XCTAssertEqual(nested.timelineRange, range(3, 5))
        XCTAssertFalse(nested.isPrimaryStoryline)
        let target = try doc.selectedTarget(.init(timelineRange: range(0, 10)), requireExistingMedia: false)
        XCTAssertTrue(try doc.protectedRanges(for: target).contains(where: { $0.range == range(3, 5) }))
    }

    func testUnresolvedConnectedRetimeProtectsItsWholeOverlap() throws {
        let xml = try fixture().replacingOccurrences(of: "audioRole=\"music\"/>", with: """
        audioRole="music"><timeMap/><audio ref="r4" offset="0s" start="0s" duration="2s" role="dialogue.hidden"/></asset-clip>
        """)
        let doc = try parse(xml)
        let unresolved = try XCTUnwrap(doc.clips.first(where: { $0.name == "Music bed" }))
        XCTAssertTrue(unresolved.hasUnresolvedTiming)
        XCTAssertFalse(doc.clips.contains(where: { $0.dialogueRoles.contains("dialogue.hidden") }))
        let target = try doc.selectedTarget(.init(timelineRange: range(0, 10)), requireExistingMedia: false)
        XCTAssertTrue(try doc.protectedRanges(for: target).contains(where: { $0.range == range(0, 10) && $0.reason.contains("cannot be mapped") }))
    }

    func testAuditionUsesActiveItemDurationAndIgnoresAlternativeDialogue() throws {
        let xml = try fixture().replacingOccurrences(of: "<title ref=\"r5\" name=\"Title\" lane=\"1\" offset=\"107s\" start=\"0s\" duration=\"4s\"/>", with: """
        <audition lane="1" offset="107s">
          <asset-clip ref="r3" name="Active music" offset="0s" start="0s" duration="4s" audioRole="music"/>
          <asset-clip ref="r4" name="Alternative dialogue" offset="0s" start="0s" duration="8s" audioRole="dialogue.alternative"/>
        </audition>
        """)
        let doc = try parse(xml)
        XCTAssertEqual(doc.clips.first(where: { $0.kind == "audition" })?.timelineRange, range(2, 6))
        XCTAssertFalse(doc.dialogueRoles.contains("dialogue.alternative"))
        XCTAssertFalse(doc.clips.contains(where: { $0.name == "Alternative dialogue" }))
    }

    func testUnownedSameNamedMarkerStillChangesFingerprint() throws {
        let xml = try fixture()
        let marker = try XCTUnwrap(parse(xml).markers.first)
        let exclusions = TimelineFingerprintExclusions(ownedMarkers: [marker.identity])
        let duplicate = xml.replacingOccurrences(of: "<filter-audio ref=\"r6\"", with: "<marker start=\"108s\" duration=\"1001/30000s\" value=\"Cutdown Candidate 1\" note=\"my own marker\"/><filter-audio ref=\"r6\"")
        XCTAssertNotEqual(try parse(xml, exclusions: exclusions).fingerprint, try parse(duplicate, exclusions: exclusions).fingerprint)
    }

    func testMarkersMayOmitDurationAndTitleStyleReferencesAreLocal() throws {
        let xml = try fixture().replacingOccurrences(of: "duration=\"1001/30000s\" value=", with: "value=")
            .replacingOccurrences(of: "duration=\"4s\"/>", with: """
            duration="4s"><text><text-style ref="ts1">Hello</text-style></text><text-style-def id="ts1"><text-style font="Helvetica"/></text-style-def></title>
            """)
        let doc = try parse(xml)
        XCTAssertEqual(doc.markers.first?.duration, .zero)
        let changedDefinition = xml.replacingOccurrences(of: "id=\"ts1\"", with: "id=\"ts2\"")
        XCTAssertNotEqual(doc.fingerprint, try parse(changedDefinition).fingerprint)
        let changedText = xml.replacingOccurrences(of: ">Hello<", with: ">Changed<")
        XCTAssertNotEqual(doc.fingerprint, try parse(changedText).fingerprint)
    }

    func testResourceCyclesMissingReferencesAndExcessiveDepthReject() throws {
        let xml = try fixture()
        let cyclic = xml.replacingOccurrences(of: "uid=\"test.title\"", with: "uid=\"test.title\" ref=\"r5\"")
        XCTAssertThrowsError(try parse(cyclic))
        let missing = xml.replacingOccurrences(of: "<filter-audio ref=\"r7\"", with: "<filter-audio ref=\"missing\"")
        XCTAssertThrowsError(try parse(missing))
        let resources = (0..<300).map { index in
            "<effect id=\"chain\(index)\" ref=\"\(index == 299 ? "r7" : "chain\(index + 1)")\"/>"
        }.joined()
        let deep = xml.replacingOccurrences(of: "</resources>", with: resources + "</resources>")
            .replacingOccurrences(of: "<filter-audio ref=\"r7\"", with: "<filter-audio ref=\"chain0\"")
        XCTAssertThrowsError(try parse(deep))
    }

    func testBundleAndMultipleProjectHandling() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("fcpxmld")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try fixture().write(to: directory.appendingPathComponent("Info.fcpxml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try TimelineParser.parse(url: directory).projectName, "Timeline context")
        let multiple = try fixture().replacingOccurrences(of: "</event>", with: "<project name=\"Other\"><sequence format=\"r1\"><spine/></sequence></project></event>")
        XCTAssertThrowsError(try parse(multiple))
    }

    func testNativeVideoExportRemainsReadableContextButCannotBeTheTarget() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "final-cut-12-3-basic", withExtension: "fcpxml", subdirectory: "Fixtures"))
        let doc = try TimelineParser.parse(url: url)
        XCTAssertEqual(doc.version, "1.14")
        XCTAssertEqual(doc.projectName, "Cutdown Basic")
        XCTAssertEqual(doc.projectTimecodeStart, .zero)
        XCTAssertEqual(doc.projectRange, range(0, 10))
        XCTAssertEqual(doc.frameDuration, RationalTime(1, 30))
        // Final Cut omitted the asset-clip's default start=0s on export and
        // represented the asset frame duration as 512/15360s in a new format.
        let video = try XCTUnwrap(doc.clips.first)
        XCTAssertEqual(video.name, "Recording")
        XCTAssertEqual(video.sourceStart, .zero)
        XCTAssertEqual(video.sourceFileStart, .zero)
        XCTAssertEqual(video.dialogueRoles, ["dialogue"])
        XCTAssertTrue(video.hasVideo && video.hasAudio)
        XCTAssertThrowsError(try doc.selectedTarget(.init(timelineRange: range(0, 10)), requireExistingMedia: false)) {
            XCTAssertEqual($0 as? TimelineError, .unsupportedTarget([
                "Cutdown supports audio-only timeline clips; video clips with audio are not supported"
            ]))
        }
        XCTAssertEqual(doc.markers.count, 1)
        XCTAssertEqual(doc.markers[0].timelinePosition, RationalTime(4))
        XCTAssertEqual(doc.markers[0].sourcePosition, RationalTime(4))
        XCTAssertEqual(doc.markers[0].value, "User marker — keep")
    }

    func testFinalCut123ExportFingerprintIgnoresBookmarksAndResourceRenumbering() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "final-cut-12-3-basic", withExtension: "fcpxml", subdirectory: "Fixtures"))
        let xml = try String(contentsOf: url)
        let equivalent = xml.replacingOccurrences(of: "c2FuaXRpemVk", with: "bmV3LWJvb2ttYXJr")
            .replacingOccurrences(of: "r3", with: "r30")
            .replacingOccurrences(of: "512/15360s", with: "1/30s")
            .replacingOccurrences(of: "modDate=\"2026-09-14 20:06:28 -0700\"", with: "modDate=\"2026-09-15 20:06:28 -0700\"")
        XCTAssertEqual(try parse(xml).fingerprint, try parse(equivalent).fingerprint)
        let relinked = xml.replacingOccurrences(of: "sig=\"11111111111111111111111111111111\"", with: "sig=\"44444444444444444444444444444444\"")
        XCTAssertNotEqual(try parse(xml).fingerprint, try parse(relinked).fingerprint)
    }

    func testAudioOnlyTrimmedRepeatedSourcesAndMarkersUseExactInstancePositions() throws {
        let doc = try parse(audioOnlyFixture())
        XCTAssertEqual(doc.projectTimecodeStart, RationalTime(3600))
        XCTAssertEqual(doc.projectRange, range(0, 16))
        let first = try doc.selectedTarget(.init(timelineRange: range(0, 8)), requireExistingMedia: false)
        let second = try doc.selectedTarget(.init(timelineRange: range(8, 16), sourceURL: URL(string: "file:///fixtures/voice.m4a"), sourceStart: RationalTime(135)), requireExistingMedia: false)
        XCTAssertTrue(first.hasAudio)
        XCTAssertFalse(first.hasVideo)
        XCTAssertTrue(first.isPrimaryStoryline)
        XCTAssertTrue(first.unsupportedReasons.isEmpty)
        XCTAssertEqual(first.sourceFileStart, RationalTime(5))
        XCTAssertEqual(second.sourceFileStart, RationalTime(35))
        XCTAssertEqual(first.name, second.name)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(doc.markers.map(\.timelinePosition), [RationalTime(1), RationalTime(9)])
        XCTAssertEqual(doc.markers.map(\.sourcePosition), [RationalTime(106), RationalTime(136)])
        XCTAssertThrowsError(try doc.selectedTarget(.init(timelineRange: range(8, 16), sourceStart: RationalTime(105)), requireExistingMedia: false))
        XCTAssertThrowsError(try doc.selectedTarget(.init(timelineRange: range(0, 8))))
    }

    func testAudioOnlyAssetsAndAudioOnlyInsertionOfVideoKeepAudioEnabled() throws {
        let xml = try audioOnlyFixture()
        let explicitNoVideo = xml.replacingOccurrences(of: "duration=\"120s\" hasAudio=\"1\"", with: "duration=\"120s\" hasVideo=\"0\" hasAudio=\"1\"")
        let audioOnlyInsertion = try fixture()
            .replacingOccurrences(of: "name=\"Voice recording\" start=\"100s\" duration=\"100s\" hasAudio=\"1\"", with: "name=\"Voice recording\" start=\"100s\" duration=\"100s\" hasVideo=\"1\" hasAudio=\"1\"")
            .replacingOccurrences(of: "start=\"105s\" duration=\"10s\" audioRole", with: "start=\"105s\" duration=\"10s\" srcEnable=\"audio\" audioRole")
        let standalone = try parse(explicitNoVideo).selectedTarget(.init(timelineRange: range(0, 8)), requireExistingMedia: false)
        let fromVideo = try parse(audioOnlyInsertion).selectedTarget(.init(timelineRange: range(0, 10)), requireExistingMedia: false)
        for target in [standalone, fromVideo] {
            XCTAssertTrue(target.hasAudio)
            XCTAssertFalse(target.hasVideo)
            XCTAssertTrue(target.unsupportedReasons.isEmpty)
        }
    }

    func testAudioTargetStillAccountsForConnectedVideoDialogueAndVideoChanges() throws {
        let resource = """
        <asset id="camera" name="Other speaker camera" start="0s" duration="10s" hasVideo="1" hasAudio="1" format="r1">
          <media-rep kind="original-media" src="file:///fixtures/context-camera.mov"/>
        </asset>
        <effect id="cameraEffect" name="Camera color" uid="context.camera.color"/>
        """
        let clip = """
        <asset-clip ref="camera" name="Other speaker camera" lane="2" offset="107s" start="0s" duration="2s" audioRole="dialogue.camera">
          <filter-video ref="cameraEffect"><param name="Amount" key="1" value="0.25"/></filter-video>
        </asset-clip>
        """
        let xml = try fixture().replacingOccurrences(of: "</resources>", with: resource + "</resources>")
            .replacingOccurrences(of: "<title ref=", with: clip + "<title ref=")
        let doc = try parse(xml)
        let target = try doc.selectedTarget(.init(timelineRange: range(0, 10)), requireExistingMedia: false)
        XCTAssertFalse(target.hasVideo)
        XCTAssertTrue(doc.dialogueRoles.contains("dialogue.camera"))
        XCTAssertTrue(try doc.protectedRanges(for: target).contains {
            $0.range == range(2, 4) && $0.reason.contains("Other speaker camera")
        })
        // Even a mistakenly allowlisted video effect remains part of project
        // state. Only Cutdown's audio-controller controls can be excluded.
        let exclusions = TimelineFingerprintExclusions(controllerEffectUIDs: ["context.camera.color"])
        let changed = xml.replacingOccurrences(of: "value=\"0.25\"", with: "value=\"0.75\"")
        XCTAssertNotEqual(try parse(xml, exclusions: exclusions).fingerprint,
                          try parse(changed, exclusions: exclusions).fingerprint)
    }

    func testAudioOnlyTargetRejectsDisabledOrUnavailableAudio() throws {
        let xml = try audioOnlyFixture()
        let firstAttributes = "start=\"105s\" duration=\"8s\" audioRole"
        let variants = [
            xml.replacingOccurrences(of: firstAttributes, with: "start=\"105s\" duration=\"8s\" srcEnable=\"video\" audioRole"),
            xml.replacingOccurrences(of: firstAttributes, with: "start=\"105s\" duration=\"8s\" enabled=\"0\" audioRole"),
            xml.replacingOccurrences(of: "duration=\"120s\" hasAudio=\"1\"", with: "duration=\"120s\" hasAudio=\"0\""),
            xml.replacingOccurrences(of: "value=\"User voice marker\"/>", with: "value=\"User voice marker\"/><audio-channel-source srcCh=\"1, 2\" role=\"dialogue.voice\" active=\"0\"/>")
        ]
        for variant in variants {
            let doc = try parse(variant)
            XCTAssertThrowsError(try doc.selectedTarget(.init(timelineRange: range(0, 8)), requireExistingMedia: false)) { error in
                guard case TimelineError.unsupportedTarget(let reasons) = error else { return XCTFail("Unexpected rejection: \(error)") }
                XCTAssertTrue(reasons.contains("enabled source audio is required"))
            }
        }
    }

    func testAudioOnlyTargetKeepsConnectedRetimeSplitEditAndAmbiguityGuards() throws {
        let xml = try audioOnlyFixture()
        let firstAttributes = "start=\"105s\" duration=\"8s\" audioRole"
        let variants = [
            xml.replacingOccurrences(of: firstAttributes, with: "start=\"105s\" duration=\"8s\" lane=\"1\" audioRole"),
            xml.replacingOccurrences(of: firstAttributes, with: "start=\"105s\" duration=\"8s\" audioStart=\"106s\" audioRole"),
            xml.replacingOccurrences(of: firstAttributes, with: "start=\"105s\" duration=\"8s\" audioDuration=\"7s\" audioRole"),
            xml.replacingOccurrences(of: "<asset-clip ref=\"r3\"", with: "<timeMap/><asset-clip ref=\"r3\"")
        ]
        for variant in variants {
            let doc = try parse(variant)
            XCTAssertThrowsError(try doc.selectedTarget(.init(timelineRange: range(0, 8)), requireExistingMedia: false))
        }
        let ambiguous = xml.replacingOccurrences(of: "offset=\"3608s\" start=\"135s\"", with: "offset=\"3600s\" start=\"105s\"")
        XCTAssertThrowsError(try parse(ambiguous).selectedTarget(.init(timelineRange: range(0, 8)), requireExistingMedia: false)) { error in
            XCTAssertEqual(error as? TimelineError, .ambiguousTarget)
        }
    }

    func testAudioOnlyTimelineDialogueProtectsTargetWhileMusicAndTitlesDoNot() throws {
        let doc = try parse(audioOnlyFixture())
        let target = try doc.selectedTarget(.init(timelineRange: range(0, 8)), requireExistingMedia: false)
        XCTAssertEqual(doc.dialogueRoles, ["dialogue.other", "dialogue.voice"])
        let protected = try doc.protectedRanges(for: target)
        XCTAssertEqual(protected.count, 1)
        XCTAssertEqual(protected[0].range, range(2, 3))
        XCTAssertTrue(protected[0].reason.contains("Other speaker"))
        let second = try doc.selectedTarget(.init(timelineRange: range(8, 16)), requireExistingMedia: false)
        XCTAssertTrue(try doc.protectedRanges(for: second).isEmpty)
    }

    func testAudioOnlyCompoundAndMulticamTargetsRemainUnsupported() throws {
        let original = try audioOnlyFixture()
        for kind in ["ref-clip", "mc-clip"] {
            let source = "<asset-clip ref=\"r2\" offset=\"0s\" start=\"105s\" duration=\"8s\" audioRole=\"dialogue.voice\"/>"
            let content = kind == "ref-clip"
                ? "<sequence format=\"r1\" duration=\"8s\" tcStart=\"0s\"><spine>\(source)</spine></sequence>"
                : "<multicam format=\"r1\" duration=\"8s\" tcStart=\"0s\"><mc-angle angleID=\"voice\">\(source)</mc-angle></multicam>"
            let nested = "<media id=\"r6\" name=\"Nested voice\">\(content)</media>"
            let target = "<\(kind) ref=\"r6\" name=\"Nested voice\" offset=\"3616s\" start=\"0s\" duration=\"8s\"/>"
            let xml = original.replacingOccurrences(of: "sequence format=\"r1\" duration=\"16s\"", with: "sequence format=\"r1\" duration=\"24s\"")
                .replacingOccurrences(of: "</spine>", with: target + "</spine>")
                .replacingOccurrences(of: "</resources>", with: nested + "</resources>")
            let doc = try parse(xml)
            XCTAssertThrowsError(try doc.selectedTarget(.init(timelineRange: range(16, 24)), requireExistingMedia: false)) { error in
                guard case TimelineError.unsupportedTarget(let reasons) = error else { return XCTFail("Unexpected rejection: \(error)") }
                XCTAssertTrue(reasons.contains("only a direct asset clip in the primary storyline is supported"))
            }
        }
    }

    func testAudioOnlyReviewMapsPreviewToTrimmedSourceAndEntireSilenceMakesNoCuts() throws {
        let doc = try parse(audioOnlyFixture())
        let target = try doc.selectedTarget(.init(timelineRange: range(0, 8)), requireExistingMedia: false)
        let candidate = TimeRange(start: RationalTime(6, 5), end: RationalTime(9, 5))
        let analysis = try SilenceAnalysisResult(candidates: [candidate], disposition: .cuts)
        let review = try ReviewPlan(jobID: UUID(), document: doc, target: target, analysis: analysis)
        let markers = try MarkerPreview(review: review, existingMarkers: doc.markers)
        XCTAssertEqual(markers.additions.map(\.timelinePosition), [RationalTime(6, 5), RationalTime(44, 25)])
        XCTAssertEqual(markers.additions.map(\.sourcePosition), [RationalTime(531, 5), RationalTime(2669, 25)])
        let silence = try SilenceDetector.analyze(windows: [AudioLevelWindow(range: target.timelineRange, channelRMS: [0, 0])],
            target: target.timelineRange, frameDuration: doc.frameDuration)
        XCTAssertEqual(silence.disposition, .entirelySilent)
        let silentReview = try ReviewPlan(jobID: UUID(), document: doc, target: target, analysis: silence)
        XCTAssertTrue(silentReview.selectedCuts.isEmpty)
        XCTAssertTrue(try MarkerPreview(review: silentReview, existingMarkers: doc.markers).additions.isEmpty)
    }

    func testAudioControllerExclusionRequiresExplicitUIDAndPreservesOtherAudioEffects() throws {
        let resources = """
        <effect id="r6" name="Cutdown Audio" uid="fixture.verified.audio-controller"/>
        <effect id="r7" name="Cutdown Audio" uid="fixture.other.audio-effect"/>
        """
        let originalMarker = "<marker start=\"106s\" duration=\"1/25s\" value=\"User voice marker\"/>"
        let audioEffects = """
        <filter-audio ref="r6" name="Cutdown Audio"><param name="Threshold" key="1" value="-40"/></filter-audio>
        <filter-audio ref="r7" name="Cutdown Audio"><param name="Gain" key="1" value="-3"/></filter-audio>
        """
        let xml = try audioOnlyFixture().replacingOccurrences(of: "</resources>", with: resources + "</resources>")
            .replacingOccurrences(of: originalMarker, with: originalMarker + audioEffects)
        let changedControls = xml.replacingOccurrences(of: "value=\"-40\"", with: "value=\"-30\"")
        XCTAssertNotEqual(try parse(xml).fingerprint, try parse(changedControls).fingerprint)
        let exclusions = TimelineFingerprintExclusions(controllerEffectUIDs: ["fixture.verified.audio-controller"])
        XCTAssertEqual(try parse(xml, exclusions: exclusions).fingerprint, try parse(changedControls, exclusions: exclusions).fingerprint)
        let changedOther = xml.replacingOccurrences(of: "value=\"-3\"", with: "value=\"-6\"")
        XCTAssertNotEqual(try parse(xml, exclusions: exclusions).fingerprint, try parse(changedOther, exclusions: exclusions).fingerprint)
        let disabled = xml.replacingOccurrences(of: "<filter-audio ref=\"r6\"", with: "<filter-audio enabled=\"0\" ref=\"r6\"")
        XCTAssertNotEqual(try parse(xml, exclusions: exclusions).fingerprint, try parse(disabled, exclusions: exclusions).fingerprint)
        let removed = xml.replacingOccurrences(of: audioEffects, with: "")
        XCTAssertNotEqual(try parse(xml, exclusions: exclusions).fingerprint, try parse(removed, exclusions: exclusions).fingerprint)
    }

    func testNativeFinalCut123AudioExportUsesSupportedDirectAudioAssetClip() throws {
        let doc = try parse(nativeAudioFixture())
        XCTAssertEqual(doc.projectName, "Cutdown Audio Native")
        XCTAssertEqual(doc.projectRange, range(0, 10))
        XCTAssertEqual(doc.frameDuration, RationalTime(1, 30))
        let target = try doc.selectedTarget(.init(timelineRange: range(0, 10)), requireExistingMedia: false)
        XCTAssertEqual(target.kind, "asset-clip")
        XCTAssertEqual(target.name, "Recording")
        XCTAssertEqual(target.sourceStart, .zero)
        XCTAssertFalse(target.hasVideo)
        XCTAssertTrue(target.hasAudio)
        XCTAssertTrue(target.unsupportedReasons.isEmpty)
        XCTAssertEqual(doc.dialogueRoles, ["dialogue"])
    }

    func testVerifiedNativeAudioControllerArchiveIsExcludedOnlyWithItsExactAllowlistEntry() throws {
        let xml = try nativeAudioFixture()
        let changedArchive = xml.replacingOccurrences(of: "<data key=\"effectState\">.*?</data>",
            with: "<data key=\"effectState\">Y2hhbmdlZC1jb250cm9scw==</data>", options: .regularExpression)
        XCTAssertNotEqual(try parse(xml).fingerprint, try parse(changedArchive).fingerprint)
        let uid = "AudioUnit: 0x617566786374646e4374646e"
        let exclusions = TimelineFingerprintExclusions(controllerEffectUIDs: [uid])
        XCTAssertEqual(try parse(xml, exclusions: exclusions).fingerprint, try parse(changedArchive, exclusions: exclusions).fingerprint)
        let changedControls = changedArchive.replacingOccurrences(of: "value=\"-32\"", with: "value=\"-28\"")
        XCTAssertEqual(try parse(xml, exclusions: exclusions).fingerprint, try parse(changedControls, exclusions: exclusions).fingerprint)
        let disabled = changedControls.replacingOccurrences(of: "<filter-audio ref=\"r4\"", with: "<filter-audio enabled=\"0\" ref=\"r4\"")
        XCTAssertNotEqual(try parse(xml, exclusions: exclusions).fingerprint, try parse(disabled, exclusions: exclusions).fingerprint)
        let removed = xml.replacingOccurrences(of: "(?s)<filter-audio ref=\"r4\".*?</filter-audio>", with: "", options: .regularExpression)
        XCTAssertNotEqual(try parse(xml, exclusions: exclusions).fingerprint, try parse(removed, exclusions: exclusions).fingerprint)
    }

    func testCutdownPresetReferenceDoesNotInvalidateAnOtherwiseIdenticalReview() throws {
        let xml = try nativeAudioFixture()
        let withPreset = xml.replacingOccurrences(of: "<filter-audio ref=\"r4\"",
            with: "<filter-audio presetID=\"[0]Local Voice.aupreset\" ref=\"r4\"")
        let uid = "AudioUnit: 0x617566786374646e4374646e"
        let exclusions = TimelineFingerprintExclusions(controllerEffectUIDs: [uid])
        XCTAssertNotEqual(try parse(xml).fingerprint, try parse(withPreset).fingerprint,
            "Full XML preservation must still include the preset reference")
        XCTAssertEqual(try parse(xml, exclusions: exclusions).fingerprint,
                       try parse(withPreset, exclusions: exclusions).fingerprint)
        let other = xml.replacingOccurrences(of: uid, with: "AudioUnit: other.effect")
        let otherPreset = withPreset.replacingOccurrences(of: uid, with: "AudioUnit: other.effect")
        XCTAssertNotEqual(try parse(other, exclusions: exclusions).fingerprint,
                          try parse(otherPreset, exclusions: exclusions).fingerprint)
        let otherAllowlist = TimelineFingerprintExclusions(controllerEffectUIDs: ["AudioUnit: other.effect"])
        XCTAssertNotEqual(try parse(other, exclusions: otherAllowlist).fingerprint,
                          try parse(otherPreset, exclusions: otherAllowlist).fingerprint,
                          "A different effect's preset can change its sound")
        let disabled = withPreset.replacingOccurrences(of: "presetID=", with: "enabled=\"0\" presetID=")
        XCTAssertNotEqual(try parse(xml, exclusions: exclusions).fingerprint,
                          try parse(disabled, exclusions: exclusions).fingerprint)
    }

    func testControllerArchiveExclusionPreservesUnknownDataAndOtherAudioUnits() throws {
        let xml = try nativeAudioFixture()
        let uid = "AudioUnit: 0x617566786374646e4374646e"
        let exclusions = TimelineFingerprintExclusions(controllerEffectUIDs: [uid])
        let otherData = xml.replacingOccurrences(of: "</filter-audio>", with: "<data key=\"otherState\">YWJj</data></filter-audio>")
        let changedOtherData = otherData.replacingOccurrences(of: ">YWJj<", with: ">ZGVm<")
        XCTAssertNotEqual(try parse(otherData, exclusions: exclusions).fingerprint, try parse(changedOtherData, exclusions: exclusions).fingerprint)
        let otherController = xml.replacingOccurrences(of: uid, with: "fixture.other.controller")
        let changedOtherController = otherController.replacingOccurrences(of: "<data key=\"effectState\">.*?</data>",
            with: "<data key=\"effectState\">Y2hhbmdlZA==</data>", options: .regularExpression)
        let otherAllowlist = TimelineFingerprintExclusions(controllerEffectUIDs: ["fixture.other.controller"])
        XCTAssertNotEqual(try parse(otherController, exclusions: otherAllowlist).fingerprint,
                          try parse(changedOtherController, exclusions: otherAllowlist).fingerprint)
    }

    func testNativeAudioDeletionRetainsTheComplementOfAnalyzedCutsAndEveryAUInstance() throws {
        let before = try parse(nativeAudioFixture())
        let original = try before.selectedTarget(.init(timelineRange: before.projectRange), requireExistingMedia: false)
        let afterURL = try XCTUnwrap(Bundle.module.url(forResource: "final-cut-12-3-native-audio-after-cuts", withExtension: "fcpxml", subdirectory: "Fixtures"))
        let after = try TimelineParser.parse(url: afterURL)

        // The generated WAV has quiet intervals 2–3.5s and 5–7s. Derive the
        // proposed cuts from these measurements and the native published settings,
        // independently of the exported result's clip start/duration attributes.
        let windows: [AudioLevelWindow] = (0..<1_000).map { index in
            let quiet = (200..<350).contains(index) || (500..<700).contains(index)
            let time = TimeRange(start: RationalTime(Int64(index), 100), end: RationalTime(Int64(index + 1), 100))
            return AudioLevelWindow(range: time, channelRMS: quiet ? [0, 0] : [0.25, 0.25])
        }
        let settings = try AnalysisSettings(thresholdDBFS: -32, minimumSilenceDuration: 0.75,
            beforeSpeechPadding: 0.125, afterSpeechPadding: 0.25)
        let analysis = try SilenceDetector.analyze(windows: windows, target: original.timelineRange,
            frameDuration: before.frameDuration, settings: settings)
        XCTAssertEqual(analysis.candidates.count, 2)

        var cursor = original.timelineRange.start
        var retained: [TimeRange] = []
        for cut in analysis.candidates {
            if cursor < cut.start { retained.append(TimeRange(start: cursor, end: cut.start)) }
            cursor = cut.end
        }
        if cursor < original.timelineRange.end {
            retained.append(TimeRange(start: cursor, end: original.timelineRange.end))
        }
        let expectedSource = try retained.map { range in
            TimeRange(start: try original.sourceStart.adding(range.start.subtracting(original.timelineRange.start)),
                      end: try original.sourceStart.adding(range.end.subtracting(original.timelineRange.start)))
        }
        let actualClips = after.clips.filter(\.isPrimaryStoryline).sorted { $0.timelineRange.start < $1.timelineRange.start }
        let actualSource = try actualClips.map { clip in
            TimeRange(start: clip.sourceStart, end: try clip.sourceStart.adding(clip.timelineRange.checkedDuration()))
        }
        XCTAssertEqual(actualSource, expectedSource)
        XCTAssertEqual(actualClips.count, retained.count)
        XCTAssertEqual(after.projectRange.duration, try before.projectRange.duration.subtracting(analysis.removedDuration))
        XCTAssertEqual(after.projectRange.duration, RationalTime(73, 10)) // Observed 00:00:07:09 at 30 fps.

        var nextOffset = RationalTime.zero
        for clip in actualClips {
            XCTAssertEqual(clip.timelineRange.start, nextOffset, "Native deletion must ripple without gaps.")
            nextOffset = clip.timelineRange.end
            XCTAssertEqual(clip.mediaURL, original.mediaURL)
            XCTAssertEqual(clip.assetStart, original.assetStart)
            XCTAssertEqual(clip.dialogueRoles, original.dialogueRoles)
            XCTAssertTrue(clip.hasAudio && !clip.hasVideo && clip.enabled)
            XCTAssertTrue(clip.unsupportedReasons.isEmpty)
            // Compare unexcluded signatures: every resulting segment retains the
            // actual AU instance, four explicit controls and its archived state.
            XCTAssertEqual(clip.effectsFingerprint, original.effectsFingerprint)
        }
        XCTAssertEqual(nextOffset, after.projectRange.end)
    }
}
