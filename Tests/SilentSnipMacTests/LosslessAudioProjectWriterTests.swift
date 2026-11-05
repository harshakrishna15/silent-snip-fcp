import Foundation
import SilentSnipCore
#if canImport(FoundationXML)
import FoundationXML
#endif
import XCTest
@testable import SilentSnipMac

final class LosslessAudioProjectWriterTests: XCTestCase {
    private let selection = TimelineSelection(timelineRange: .init(start: RationalTime(2), end: RationalTime(8)))
    private let cuts = [TimeRange(start: RationalTime(3), end: RationalTime(4))]

    func testFullMixPreservesEveryRetainedSampleMappingAndMutesConnectedProcessing() throws {
        let audio = try pcm(seconds: 10, start: 0, scope: .projectMix)
        let originalBytes = try Data(contentsOf: audio.url)
        let output = try write(fixture(camera: false, music: true), audio: audio)
        let document = try TimelineParser.parse(data: output.xmlData)
        let audible = document.clips.filter { $0.enabled && $0.hasAudio }
        XCTAssertEqual(audible.count, 2) // continuous spans; no split at old primary boundaries
        XCTAssertTrue(audible.allSatisfy { $0.mediaURL == audio.url && !$0.hasVideo })
        XCTAssertTrue(audible.allSatisfy { $0.isPrimaryStoryline && $0.lane == 0 && $0.parentID == nil },
                      "The kept sound must occupy the primary storyline, rather than connect below gap anchors")
        XCTAssertEqual(audible.map(\.timelineRange), [range(0, 3), range(3, 9)])
        XCTAssertEqual(audible.map(\.sourceStart), [RationalTime(0), RationalTime(4)])
        XCTAssertEqual(audible.map { $0.timelineRange.duration }, [RationalTime(3), RationalTime(6)])
        XCTAssertEqual(output.report.losslessAudio, audio)
        let tree = try XMLDocument(data: output.xmlData)
        XCTAssertTrue(try tree.nodes(forXPath: "//project/sequence/spine//filter-audio").isEmpty)
        XCTAssertTrue(try tree.nodes(forXPath: "//project/sequence/spine//adjust-volume").isEmpty)
        XCTAssertTrue(document.clips.filter { $0.mediaURL?.path == "/fixtures/music.wav" }.allSatisfy { !$0.hasAudio })
        XCTAssertEqual(try Data(contentsOf: audio.url), originalBytes)
        try audio.validate()
    }

    func testAudioOnlyFullMixPreservesMarkersAndMutedConnectedMusicOnThePrimarySound() throws {
        let input = fixture(camera: false, music: true)
        let original = try TimelineParser.parse(data: input)
        let audio = try pcm(seconds: 10, start: 0, scope: .projectMix)
        let output = try write(input, audio: audio)
        let document = try TimelineParser.parse(data: output.xmlData)
        let audible = document.clips.filter { $0.enabled && $0.hasAudio }
        XCTAssertTrue(audible.allSatisfy { $0.isPrimaryStoryline && $0.parentID == nil })
        XCTAssertEqual(document.projectTimecodeStart, RationalTime(3600))
        XCTAssertEqual(document.frameDuration, original.frameDuration)
        XCTAssertEqual(document.projectRange, range(0, 9))

        let music = document.clips.filter { $0.mediaURL?.path == "/fixtures/music.wav" }
        XCTAssertEqual(music.map(\.timelineRange), [range(2, 3), range(3, 7)])
        XCTAssertEqual(music.map(\.sourceStart), [RationalTime(0), RationalTime(2)])
        XCTAssertTrue(music.allSatisfy { !$0.isPrimaryStoryline && !$0.enabled && !$0.hasAudio && $0.lane == -1 })
        let marker = try XCTUnwrap(document.markers.first { $0.value == "Keep me" })
        XCTAssertEqual(document.markers.filter { $0.value == "Keep me" }.count, 1)
        XCTAssertEqual(marker.timelinePosition, RationalTime(9, 4))

        let tree = try XMLDocument(data: output.xmlData)
        XCTAssertTrue(try tree.nodes(forXPath: "//project/sequence/spine/gap").isEmpty,
                      "Original silent lead-in/out belongs to the captured mix, not empty primary anchors")
        XCTAssertEqual(try TimelineParser.parse(data: input).fingerprint, original.fingerprint)
    }

    func testAudioOnlyFullMixPutsPacingGapBetweenPrimarySoundSegments() throws {
        let audio = try pcm(seconds: 10, start: 0, scope: .projectMix)
        let gap = RationalTime(1, 2)
        let output = try EditedProjectWriter.write(projectData: fixture(camera: false, music: true),
            selection: selection, selectedRanges: cuts, outputName: "Primary sound with pause",
            replacementGaps: [cuts[0]: gap], losslessAudio: audio)
        let document = try TimelineParser.parse(data: output.xmlData)
        let primary = document.clips.filter(\.isPrimaryStoryline)
        let audible = document.clips.filter { $0.enabled && $0.hasAudio }
        let silentGap = TimeRange(start: RationalTime(3), end: RationalTime(7, 2))
        XCTAssertEqual(primary.map(\.kind), ["asset-clip", "gap", "asset-clip"])
        XCTAssertEqual(primary.map(\.timelineRange), [range(0, 3), silentGap,
                       .init(start: RationalTime(7, 2), end: RationalTime(19, 2))])
        XCTAssertEqual(audible.map(\.sourceStart), [RationalTime(0), RationalTime(4)])
        XCTAssertTrue(audible.allSatisfy { $0.isPrimaryStoryline && $0.parentID == nil && $0.mediaURL == audio.url })
        XCTAssertTrue(audible.allSatisfy { $0.timelineRange.intersection(silentGap) == nil })
        XCTAssertEqual(document.projectRange.end, RationalTime(19, 2))
        XCTAssertEqual(output.report.insertedGapDuration, gap)

        let music = document.clips.filter { $0.mediaURL?.path == "/fixtures/music.wav" }
        XCTAssertEqual(music.map(\.timelineRange), [range(2, 3),
                       .init(start: RationalTime(7, 2), end: RationalTime(15, 2))])
        XCTAssertEqual(music.map(\.sourceStart), [RationalTime(0), RationalTime(2)])
        XCTAssertTrue(music.allSatisfy { !$0.enabled && !$0.hasAudio })
    }

    func testFullMixPreservesConnectedVideoAttachedToAnAudioOnlySource() throws {
        for enabled in [true, false] {
            let input = Data(String(decoding: fixture(camera: false, music: true, connectedVideo: true), as: UTF8.self)
                .replacingOccurrences(of: "name=\"Context\" lane=\"1\"",
                                      with: "name=\"Context\" lane=\"1\" enabled=\"\(enabled ? 1 : 0)\"").utf8)
            let original = try TimelineParser.parse(data: input)
            let originalVideo = try XCTUnwrap(original.clips.first { $0.mediaURL?.path == "/fixtures/context.mov" })
            let audio = try pcm(seconds: 10, start: 0, scope: .projectMix)
            let output = try write(input, audio: audio)
            let document = try TimelineParser.parse(data: output.xmlData)
            let video = try XCTUnwrap(document.clips.first { $0.mediaURL == originalVideo.mediaURL })
            XCTAssertEqual(document.clips.filter { $0.mediaURL == originalVideo.mediaURL }.count, 1)
            XCTAssertEqual(video.timelineRange, originalVideo.timelineRange)
            XCTAssertEqual(video.sourceStart, originalVideo.sourceStart)
            XCTAssertEqual(video.lane, originalVideo.lane)
            XCTAssertEqual(video.enabled, originalVideo.enabled)
            XCTAssertEqual(video.effectsFingerprint, originalVideo.effectsFingerprint)
            XCTAssertTrue(video.hasVideo)
            XCTAssertFalse(video.hasAudio)
            XCTAssertTrue(document.clips.filter { $0.enabled && $0.hasAudio }
                .allSatisfy { $0.mediaURL == audio.url && !$0.isPrimaryStoryline },
                "Visible or disabled video must retain the existing visual layout and connected mix")
        }
    }

    func testHostDemotionOfPrimaryPCMToConnectedAudioFailsStrictRoundTripVerification() throws {
        let audio = try pcm(seconds: 10, start: 0, scope: .projectMix)
        let output = try write(fixture(camera: false, music: true), audio: audio)
        let expected = try TimelineParser.parse(data: output.xmlData)
        let expectedSound = expected.clips.filter { $0.enabled && $0.hasAudio }
        XCTAssertEqual(expectedSound.count, 2)
        XCTAssertTrue(expectedSound.allSatisfy(\.isPrimaryStoryline))
        XCTAssertTrue(try ProjectRoundTripVerification.compare(expected: output.xmlData,
            actual: output.xmlData, allowHostAssignedIdentity: true).verified)

        let xml = try XMLDocument(data: output.xmlData)
        let spine = try XCTUnwrap(xml.nodes(forXPath: "//project/sequence/spine").first as? XMLElement)
        let primarySound = spine.elements(forName: "asset-clip").filter {
            $0.attribute(forName: "ref")?.stringValue == expectedSound.first?.assetID
        }
        XCTAssertEqual(primarySound.count, expectedSound.count)
        for clip in primarySound {
            let position = clip.index
            let sourceStart = try XCTUnwrap(clip.attribute(forName: "start")?.stringValue)
            let gap = XMLElement(name: "gap")
            for (key, value) in ["name": "Demoted sound anchor",
                                 "offset": try XCTUnwrap(clip.attribute(forName: "offset")?.stringValue),
                                 "start": sourceStart,
                                 "duration": try XCTUnwrap(clip.attribute(forName: "duration")?.stringValue)] {
                gap.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode)
            }
            clip.detach()
            clip.attribute(forName: "offset")?.stringValue = sourceStart
            if let lane = clip.attribute(forName: "lane") { lane.stringValue = "-1" }
            else { clip.addAttribute(XMLNode.attribute(withName: "lane", stringValue: "-1") as! XMLNode) }
            gap.addChild(clip)
            spine.insertChild(gap, at: position)
        }
        let actual = try TimelineParser.parse(data: xml.xmlData)
        let actualSound = actual.clips.filter { $0.enabled && $0.hasAudio }
        XCTAssertEqual(actualSound.map(\.timelineRange), expectedSound.map(\.timelineRange))
        XCTAssertEqual(actualSound.map(\.sourceStart), expectedSound.map(\.sourceStart))
        XCTAssertEqual(actualSound.map(\.mediaURL), expectedSound.map(\.mediaURL))
        XCTAssertTrue(actualSound.allSatisfy { !$0.isPrimaryStoryline && $0.lane == -1 })
        let report = try ProjectRoundTripVerification.compare(expected: output.xmlData,
            actual: xml.xmlData, allowHostAssignedIdentity: true)
        XCTAssertFalse(report.verified, "Identical sound is insufficient when the host changes the requested storyline placement")
        XCTAssertNotEqual(report.expectedFingerprint, report.actualFingerprint)
        let reportURL = audio.url.deletingLastPathComponent().appendingPathComponent("Demoted-Import-Verification.json")
        XCTAssertThrowsError(try ProjectRoundTripVerification.verify(expected: output.xmlData,
            actual: xml.xmlData, reportURL: reportURL, allowHostAssignedIdentity: true)) { error in
            guard case EditedProjectWriterError.verificationFailed = error else {
                return XCTFail("Expected strict imported-topology rejection, received \(error)")
            }
        }
        let saved = try JSONDecoder().decode(ProjectRoundTripReport.self, from: Data(contentsOf: reportURL))
        XCTAssertFalse(saved.verified)
    }

    func testAudioOnlyFullMixOrdersMutedRolesFromDifferentOriginalParentsByLane() throws {
        let input = Data(String(decoding: fixture(camera: false, music: true), as: UTF8.self)
            .replacingOccurrences(of: "name=\"Music\" lane=\"-1\"", with: "name=\"Music\" lane=\"-2\"")
            .replacingOccurrences(of: "<effect id=\"fx\"", with: """
            <asset id="room" name="Room Tone" start="0s" duration="10s" hasAudio="1" audioSources="1" audioChannels="2"><media-rep kind="original-media" src="file:///fixtures/room.wav"/></asset>
            <effect id="fx"
            """)
            .replacingOccurrences(of: "<gap name=\"Lead in\" offset=\"3600s\" start=\"3600s\" duration=\"2s\"/>", with: """
            <gap name="Lead in" offset="3600s" start="3600s" duration="2s"><asset-clip ref="room" name="Room Tone" lane="-1" offset="3600s" start="0s" duration="3/2s" audioRole="effects.roomtone"><filter-audio ref="fx"/></asset-clip></gap>
            """).utf8)
        let audio = try pcm(seconds: 10, start: 0, scope: .projectMix)
        let output = try write(input, audio: audio)
        let document = try TimelineParser.parse(data: output.xmlData)
        let sound = document.clips.filter { $0.enabled && $0.hasAudio }
        XCTAssertEqual(sound.map(\.timelineRange), [range(0, 3), range(3, 9)])
        XCTAssertTrue(sound.allSatisfy { $0.isPrimaryStoryline && $0.mediaURL == audio.url })
        let music = document.clips.filter { $0.mediaURL?.path == "/fixtures/music.wav" }
        XCTAssertEqual(music.map(\.timelineRange), [range(2, 3), range(3, 7)])
        XCTAssertEqual(music.map(\.sourceStart), [RationalTime(0), RationalTime(2)])
        XCTAssertTrue(music.allSatisfy { !$0.enabled && !$0.hasAudio && $0.lane == -2 })
        let room = try XCTUnwrap(document.clips.first { $0.mediaURL?.path == "/fixtures/room.wav" })
        XCTAssertEqual(room.timelineRange, .init(start: .zero, end: RationalTime(3, 2)))
        XCTAssertEqual(room.sourceStart, .zero)
        XCTAssertEqual(room.lane, -1)
        XCTAssertFalse(room.enabled)
        XCTAssertFalse(room.hasAudio)
        let xml = try XMLDocument(data: output.xmlData)
        let firstPrimary = try XCTUnwrap(xml.nodes(forXPath: "//project/sequence/spine/asset-clip").first as? XMLElement)
        XCTAssertEqual(firstPrimary.elements(forName: "asset-clip").compactMap {
            Int($0.attribute(forName: "lane")?.stringValue ?? "")
        }, [-2, -1], "Merging old parent children must preserve Final Cut's native lane order")
    }

    func testAudioOnlyFullMixMergesClipNotesAndDeduplicatesIdenticalMetadata() throws {
        let audio = try pcm(seconds: 10, start: 0, scope: .projectMix)
        let output = try write(fixtureWithMergedClipNotes(voiceMetadataValue: "same"), audio: audio)
        let xml = try XMLDocument(data: output.xmlData)
        let first = try XCTUnwrap(xml.nodes(forXPath: "//project/sequence/spine/asset-clip").first as? XMLElement)
        let note = try XCTUnwrap(first.elements(forName: "note").first?.stringValue)
        XCTAssertEqual(first.elements(forName: "note").count, 1)
        XCTAssertTrue(note.contains("Lead-in note"))
        XCTAssertTrue(note.contains("Voice note"))
        let metadata = try XCTUnwrap(first.elements(forName: "metadata").first)
        let shared = metadata.elements(forName: "md").filter {
            $0.attribute(forName: "key")?.stringValue == "com.silentsnip.test.shared"
        }
        XCTAssertEqual(shared.count, 1, "Equivalent entries from merged source clips must not become duplicate keys")
        XCTAssertEqual(shared.first?.attribute(forName: "value")?.stringValue, "same")
        let children = (first.children ?? []).compactMap { $0 as? XMLElement }
        XCTAssertEqual(children.first?.name, "note")
        XCTAssertEqual(children.last?.name, "metadata")
        XCTAssertTrue(try ProjectRoundTripVerification.compare(expected: output.xmlData, actual: output.xmlData).verified)
    }

    func testAudioOnlyFullMixRejectsConflictingMetadataInsteadOfDiscardingIt() throws {
        let audio = try pcm(seconds: 10, start: 0, scope: .projectMix)
        XCTAssertThrowsError(try write(fixtureWithMergedClipNotes(voiceMetadataValue: "different"), audio: audio)) { error in
            guard case EditedProjectWriterError.unsupported(let reason) = error else {
                return XCTFail("Expected an explicit metadata conflict, received \(error)")
            }
            XCTAssertTrue(reason.contains("incompatible metadata"))
            XCTAssertTrue(reason.contains("com.silentsnip.test.shared"))
            XCTAssertTrue(reason.contains("not discarded"))
        }
        try audio.validate()
    }

    func testAudioOnlyFullMixPreservesZeroDurationKeywordAndRatingAtFinalEndpoint() throws {
        let input = Data(String(decoding: fixture(camera: false), as: UTF8.self)
            .replacingOccurrences(of: "<gap name=\"Lead out\" offset=\"3608s\" start=\"3600s\" duration=\"2s\"/>", with: """
            <gap name="Lead out" offset="3608s" start="3600s" duration="2s"><keyword start="3602s" duration="0s" value="At end"/><rating start="3602s" duration="0s" value="favorite" note="At end"/></gap>
            """).utf8)
        let audio = try pcm(seconds: 10, start: 0, scope: .projectMix)
        let output = try write(input, audio: audio)
        let document = try TimelineParser.parse(data: output.xmlData)
        XCTAssertEqual(document.projectRange.end, RationalTime(9))
        let xml = try XMLDocument(data: output.xmlData)
        for (name, value) in [("keyword", "At end"), ("rating", "favorite")] {
            let nodes = try xml.nodes(forXPath: "//project/sequence/spine/asset-clip/\(name)")
            XCTAssertEqual(nodes.count, 1, "A zero-length \(name) at the project end must survive")
            let annotation = try XCTUnwrap(nodes.first as? XMLElement)
            XCTAssertEqual(annotation.attribute(forName: "value")?.stringValue, value)
            XCTAssertEqual(try RationalTime.parse(try XCTUnwrap(annotation.attribute(forName: "duration")?.stringValue)), .zero)
            let parent = try XCTUnwrap(annotation.parent as? XMLElement)
            let offset = try RationalTime.parse(try XCTUnwrap(parent.attribute(forName: "offset")?.stringValue))
            let sourceStart = try RationalTime.parse(try XCTUnwrap(parent.attribute(forName: "start")?.stringValue))
            let localStart = try RationalTime.parse(try XCTUnwrap(annotation.attribute(forName: "start")?.stringValue))
            let timelinePosition = try offset.subtracting(document.projectTimecodeStart)
                .adding(localStart.subtracting(sourceStart))
            XCTAssertEqual(timelinePosition, document.projectRange.end)
        }
    }

    func testAudioOnlyFullMixKeepsFractionalPhysicalTailAsAnExactGapWithoutExtendingPCM() throws {
        let frame = RationalTime(1001, 30_000)
        let end = try frame.multiplied(by: RationalTime(1796))
        let cut = TimeRange(start: try frame.multiplied(by: RationalTime(15)),
                            end: try frame.multiplied(by: RationalTime(20)))
        let input = Data("""
        <fcpxml version="1.14"><resources>
        <format id="f" frameDuration="1001/30000s"/>
        <asset id="a" start="0s" duration="120s" hasAudio="1" audioSources="1" audioChannels="2"><media-rep kind="original-media" src="file:///fixtures/voice.wav"/></asset>
        </resources><library><event><project name="Fractional audio" uid="AAAA0000-0000-4000-8000-000000000001"><sequence format="f" duration="\(time(end))" tcStart="3600s" audioLayout="stereo" audioRate="48k"><spine>
        <asset-clip ref="a" offset="3600s" start="0s" duration="\(time(end))" audioRole="dialogue"/>
        </spine></sequence></project></event></library></fcpxml>
        """.utf8)
        let audio = try pcm(frames: 2_876_473, timelineRange: .init(start: .zero, end: end), scope: .projectMix)
        let output = try EditedProjectWriter.write(projectData: input,
            selection: .init(timelineRange: .init(start: .zero, end: end)), selectedRanges: [cut],
            outputName: "Fractional primary sound", losslessAudio: audio)
        let document = try TimelineParser.parse(data: output.xmlData)
        let rendered = document.clips.filter { $0.mediaURL == audio.url }
        XCTAssertEqual(rendered.count, 2)
        XCTAssertTrue(rendered.allSatisfy { $0.isPrimaryStoryline && $0.parentID == nil && $0.lane == 0 })
        let last = try XCTUnwrap(rendered.last)
        XCTAssertEqual(try last.sourceStart.adding(last.timelineRange.checkedDuration()), RationalTime(2_876_473, 48_000))
        let totalPCM = try rendered.reduce(RationalTime.zero) { try $0.adding($1.timelineRange.checkedDuration()) }
        XCTAssertEqual(totalPCM, RationalTime(2_868_465, 48_000))
        let gap = try XCTUnwrap(document.clips.first { $0.isPrimaryStoryline && $0.kind == "gap" })
        XCTAssertEqual(document.clips.filter { $0.isPrimaryStoryline && $0.kind == "gap" }.count, 1)
        XCTAssertEqual(gap.timelineRange.start, last.timelineRange.end)
        XCTAssertEqual(gap.timelineRange.end, document.projectRange.end)
        XCTAssertEqual(try gap.timelineRange.checkedDuration(), RationalTime(1, 80_000))
        XCTAssertTrue(try gap.timelineRange.checkedDuration() < RationalTime(1, audio.sampleRate))
        XCTAssertEqual(document.projectRange.end, try end.subtracting(cut.checkedDuration()))
        XCTAssertEqual(document.projectTimecodeStart, RationalTime(3600))
        XCTAssertEqual(document.frameDuration, frame)
        try audio.validate()
    }

    func testFullMixRetainsCameraVideoTransformsAndExistingConnectedVideo() throws {
        let input = fixture(camera: true, music: true, connectedVideo: true)
        let original = try TimelineParser.parse(data: input)
        let audio = try pcm(seconds: 10, start: 0, scope: .projectMix)
        let output = try write(input, audio: audio)
        let document = try TimelineParser.parse(data: output.xmlData)
        let camera = document.clips.filter { $0.isPrimaryStoryline && $0.hasVideo }
        XCTAssertEqual(camera.map(\.sourceStart), [RationalTime(105), RationalTime(107)])
        XCTAssertEqual(camera.map(\.timelineRange), [range(2, 3), range(3, 7)])
        XCTAssertTrue(camera.allSatisfy { !$0.hasAudio && $0.mediaURL?.path == "/fixtures/voice.mov" })
        XCTAssertEqual(document.clips.filter { $0.mediaURL?.path == "/fixtures/context.mov" }.map(\.timelineRange),
                       original.clips.filter { $0.mediaURL?.path == "/fixtures/context.mov" }.map(\.timelineRange))
        let tree = try XMLDocument(data: output.xmlData)
        XCTAssertEqual(try tree.nodes(forXPath: "//project/sequence/spine/asset-clip/adjust-transform/@position").compactMap(\.stringValue),
                       ["0.2 0.3", "0.2 0.3"])
        XCTAssertEqual(try tree.nodes(forXPath: "//project/sequence/spine/asset-clip/audio-channel-source[@enabled='0']/@srcCh").compactMap(\.stringValue),
                       ["1", "2", "1", "2"])
        // Dropping srcEnable, as the native host did, must not unmute raw AV.
        let withoutFlags = String(decoding: output.xmlData, as: UTF8.self)
            .replacingOccurrences(of: " srcEnable=\"video\"", with: "")
        XCTAssertTrue(try TimelineParser.parse(data: Data(withoutFlags.utf8)).clips
            .filter { $0.enabled && $0.hasAudio }.allSatisfy { $0.mediaURL == audio.url })
        let audible = document.clips.filter { $0.enabled && $0.hasAudio }
        XCTAssertTrue(audible.allSatisfy { $0.mediaURL == audio.url })
        XCTAssertEqual(audible.filter { $0.timelineRange == range(3, 9) }.count, 1)
        // Existing music has lane -1. The PCM layer must use a different lane.
        let targetChildren = document.clips.filter { !$0.isPrimaryStoryline && $0.timelineRange == range(3, 9) && $0.hasAudio }
        XCTAssertEqual(targetChildren.map(\.lane), [-2])
        XCTAssertEqual(try TimelineParser.parse(data: input).fingerprint, original.fingerprint)
    }

    func testFullMixKeepsInsertedPacingGapsSilentAndMapsFollowingAudioToOriginalClock() throws {
        let audio = try pcm(seconds: 10, start: 0, scope: .projectMix)
        let gap = RationalTime(1, 2)
        let output = try EditedProjectWriter.write(projectData: fixture(camera: true), selection: selection,
            selectedRanges: cuts, outputName: "Baked result", replacementGaps: [cuts[0]: gap], losslessAudio: audio)
        let document = try TimelineParser.parse(data: output.xmlData)
        let silentGap = TimeRange(start: RationalTime(3), end: RationalTime(7, 2))
        XCTAssertTrue(document.clips.filter { $0.enabled && $0.hasAudio }.allSatisfy {
            $0.timelineRange.intersection(silentGap) == nil
        })
        let resumed = try XCTUnwrap(document.clips.first { $0.enabled && $0.hasAudio && $0.timelineRange.start == RationalTime(7, 2) })
        XCTAssertEqual(resumed.sourceStart, RationalTime(4))
        XCTAssertEqual(document.projectRange.end, RationalTime(19, 2))
    }

    func testSelectedTargetMappingHandlesNonzeroRawSourceAndPreservesAttachedVideoPosition() throws {
        let input = fixture(camera: false, connectedVideo: true)
        let audio = try pcm(seconds: 6, start: 2, scope: .selectedTarget)
        let output = try write(input, audio: audio)
        let document = try TimelineParser.parse(data: output.xmlData)
        let target = document.clips.filter { $0.isPrimaryStoryline && $0.mediaURL == audio.url }
        XCTAssertEqual(target.map(\.sourceStart), [RationalTime(0), RationalTime(2)])
        XCTAssertEqual(target.map(\.timelineRange), [range(2, 3), range(3, 7)])
        let video = try XCTUnwrap(document.clips.first { $0.mediaURL?.path == "/fixtures/context.mov" })
        XCTAssertEqual(video.timelineRange, .init(start: RationalTime(5, 2), end: RationalTime(11, 4)))
        let marker = try XCTUnwrap(document.markers.first { $0.value == "Keep me" })
        XCTAssertEqual(marker.timelinePosition, RationalTime(9, 4))
        XCTAssertEqual(marker.sourcePosition, RationalTime(1, 4))
        let tree = try XMLDocument(data: output.xmlData)
        XCTAssertTrue(try tree.nodes(forXPath: "//project/sequence/spine/asset-clip/filter-audio").isEmpty)
    }

    func testSelectedTargetAVKeepsOriginalVideoAndAddsOnlyOneRenderedAudioLayer() throws {
        let audio = try pcm(seconds: 6, start: 2, scope: .selectedTarget)
        let output = try write(fixture(camera: true, music: true), audio: audio)
        let document = try TimelineParser.parse(data: output.xmlData)
        let camera = document.clips.filter { $0.isPrimaryStoryline && $0.hasVideo }
        XCTAssertEqual(camera.map(\.sourceStart), [RationalTime(105), RationalTime(107)])
        XCTAssertTrue(camera.allSatisfy { !$0.hasAudio })
        let rendered = document.clips.filter { $0.mediaURL == audio.url }
        XCTAssertEqual(rendered.count, 2)
        XCTAssertEqual(rendered.map(\.timelineRange), [range(2, 3), range(3, 7)])
        XCTAssertEqual(rendered.map(\.sourceStart), [RationalTime(0), RationalTime(2)])
        XCTAssertTrue(document.clips.contains { $0.mediaURL?.path == "/fixtures/music.wav" && $0.hasAudio })
    }

    func testFullMixRetainsDisabledVideoAsInvisibleWhileMixStillPlaysAcrossIt() throws {
        let input = Data(String(decoding: fixture(camera: true), as: UTF8.self).replacingOccurrences(of: "<gap name=\"Lead in\" offset=\"3600s\" start=\"3600s\" duration=\"2s\"/>",
            with: "<asset-clip ref=\"context\" name=\"Disabled camera\" enabled=\"0\" offset=\"3600s\" start=\"0s\" duration=\"2s\"/>").utf8)
        let audio = try pcm(seconds: 10, start: 0, scope: .projectMix)
        let output = try write(input, audio: audio)
        let document = try TimelineParser.parse(data: output.xmlData)
        let disabled = try XCTUnwrap(document.clips.first { $0.name == "Disabled camera" && $0.hasVideo })
        XCTAssertFalse(disabled.enabled)
        XCTAssertEqual(disabled.timelineRange, range(0, 2))
        XCTAssertTrue(document.clips.contains { $0.mediaURL == audio.url && $0.hasAudio && $0.enabled && $0.timelineRange == range(0, 3) })
    }

    func testFullMixRefusesPartialProjectCoverageAndChangedPCM() throws {
        let partial = try pcm(seconds: 6, start: 2, scope: .projectMix)
        XCTAssertThrowsError(try write(fixture(camera: true), audio: partial))
        let audio = try pcm(seconds: 10, start: 0, scope: .projectMix)
        let stream = try FileHandle(forWritingTo: audio.url)
        try stream.seek(toOffset: 44)
        try stream.write(contentsOf: Data([1, 0, 0, 0]))
        try stream.close()
        XCTAssertThrowsError(try write(fixture(camera: true), audio: audio))
    }

    func testFullMixOutputUsesExactNativePCMRateAndLayoutWithoutChangingSourceProject() throws {
        let input = Data(String(decoding: fixture(camera: true), as: UTF8.self)
            .replacingOccurrences(of: "audioLayout=\"stereo\" audioRate=\"48k\"", with: "audioLayout=\"mono\" audioRate=\"44.1k\"").utf8)
        let audio = try pcm(seconds: 10, start: 0, scope: .projectMix)
        let output = try write(input, audio: audio)
        let after = try XMLDocument(data: output.xmlData)
        XCTAssertEqual(try after.nodes(forXPath: "//project/sequence/@audioLayout").first?.stringValue, "stereo")
        XCTAssertEqual(try after.nodes(forXPath: "//project/sequence/@audioRate").first?.stringValue, "48k")
        let original = try XMLDocument(data: input)
        XCTAssertEqual(try original.nodes(forXPath: "//project/sequence/@audioLayout").first?.stringValue, "mono")
        XCTAssertEqual(try original.nodes(forXPath: "//project/sequence/@audioRate").first?.stringValue, "44.1k")
    }

    func testFullMixRefusesToGuessMissingCameraAudioChannelMetadata() throws {
        let input = Data(String(decoding: fixture(camera: true), as: UTF8.self)
            .replacingOccurrences(of: "audioChannels=\"2\"", with: "").utf8)
        let audio = try pcm(seconds: 10, start: 0, scope: .projectMix)
        XCTAssertThrowsError(try write(input, audio: audio)) { error in
            guard case EditedProjectWriterError.unsupported(let reason) = error else {
                return XCTFail("Expected unavailable channel metadata, received \(error)")
            }
            XCTAssertTrue(reason.contains("audio channel count"))
        }
    }

    func testFractionalVideoBoundariesDoNotSplitPCMAndOnlyPhysicalFinalTailIsClamped() throws {
        let frame = RationalTime(1001, 30_000)
        let end = try frame.multiplied(by: RationalTime(1796))
        let lead = try frame.multiplied(by: RationalTime(3)) // 4804.8 samples: never an audio cut.
        let cut = TimeRange(start: try frame.multiplied(by: RationalTime(15)),
                            end: try frame.multiplied(by: RationalTime(20)))
        let input = Data("""
        <fcpxml version="1.14"><resources>
        <format id="f" frameDuration="1001/30000s"/>
        <asset id="camera" start="0s" duration="120s" hasVideo="1" hasAudio="1" audioSources="1" audioChannels="2"><media-rep kind="original-media" src="file:///fixtures/camera.mov"/></asset>
        </resources><library><event><project name="Fractional" uid="AAAA0000-0000-4000-8000-000000000001"><sequence format="f" duration="\(time(end))" tcStart="3600s" audioLayout="stereo" audioRate="48k"><spine>
        <asset-clip ref="camera" offset="3600s" start="0s" duration="\(time(lead))"><audio-channel-source srcCh="1" enabled="0" role="dialogue"/><audio-channel-source srcCh="2" enabled="0" role="dialogue"/></asset-clip>
        <asset-clip ref="camera" offset="\(time(try RationalTime(3600).adding(lead)))" start="0s" duration="\(time(try end.subtracting(lead)))" audioRole="dialogue"/>
        </spine></sequence></project></event></library></fcpxml>
        """.utf8)
        let audio = try pcm(frames: 2_876_473, timelineRange: .init(start: .zero, end: end), scope: .projectMix)
        let output = try EditedProjectWriter.write(projectData: input,
            selection: .init(timelineRange: .init(start: lead, end: end)), selectedRanges: [cut],
            outputName: "Fractional preserved", losslessAudio: audio)
        let document = try TimelineParser.parse(data: output.xmlData)
        let rendered = document.clips.filter { $0.mediaURL == audio.url }
        XCTAssertEqual(rendered.count, 2)
        XCTAssertEqual(rendered[0].timelineRange.end, cut.start)
        XCTAssertTrue(rendered[0].timelineRange.end > lead) // connected PCM bridges the visual boundary
        let last = try XCTUnwrap(rendered.last)
        XCTAssertEqual(try last.sourceStart.adding(last.timelineRange.duration),
                       RationalTime(2_876_473, 48_000))
        XCTAssertEqual(document.projectRange.end, try end.subtracting(cut.checkedDuration()))
        let physical = last.timelineRange.end
        let tail = try document.projectRange.end.subtracting(physical)
        XCTAssertTrue(tail > .zero && tail < RationalTime(1, 48_000))
        let total = try rendered.reduce(RationalTime.zero) { try $0.adding($1.timelineRange.checkedDuration()) }
        XCTAssertEqual(total, RationalTime(2_868_465, 48_000)) // exactly 8008 physical samples removed
        let fractionalCut = TimeRange(start: try frame.multiplied(by: RationalTime(16)), end: cut.end)
        XCTAssertThrowsError(try EditedProjectWriter.write(projectData: input,
            selection: .init(timelineRange: .init(start: lead, end: end)), selectedRanges: [fractionalCut],
            outputName: "Reject fractional audio sample", losslessAudio: audio))
    }

    func testPacingGapCannotShiftAlignedSourcePCMToAFractionalResultSample() throws {
        let frame = RationalTime(1001, 30_000)
        let end = try frame.multiplied(by: RationalTime(600))
        let cut = TimeRange(start: try frame.multiplied(by: RationalTime(100)),
                            end: try frame.multiplied(by: RationalTime(200)))
        let input = Data("""
        <fcpxml version="1.14"><resources><format id="f" frameDuration="1001/30000s"/>
        <asset id="a" start="0s" duration="30s" hasAudio="1" audioSources="1" audioChannels="2" audioRate="44100"><media-rep kind="original-media" src="file:///fixtures/rate.wav"/></asset>
        </resources><library><event><project name="44.1 kHz" uid="AAAA0000-0000-4000-8000-000000000001"><sequence format="f" duration="\(time(end))" audioLayout="stereo" audioRate="44.1k"><spine>
        <asset-clip ref="a" offset="0s" start="0s" duration="\(time(end))" audioRole="dialogue"/>
        </spine></sequence></project></event></library></fcpxml>
        """.utf8)
        let audio = try pcm(frames: 882_882, timelineRange: .init(start: .zero, end: end),
                            scope: .projectMix, sampleRate: 44_100)
        // Both 100-frame cuts are exact samples; Remove Silence remains valid.
        _ = try EditedProjectWriter.write(projectData: input,
            selection: .init(timelineRange: .init(start: .zero, end: end)), selectedRanges: [cut],
            outputName: "Aligned removal", losslessAudio: audio)
        // The existing one-second pacing policy uses 30 video frames here.
        // 30 * 1001/30000 * 44100 = 44144.1 samples: never round its phase.
        let gap = try frame.multiplied(by: RationalTime(30))
        XCTAssertThrowsError(try EditedProjectWriter.write(projectData: input,
            selection: .init(timelineRange: .init(start: .zero, end: end)), selectedRanges: [cut],
            outputName: "Reject shifted sound", replacementGaps: [cut: gap], losslessAudio: audio)) { error in
            guard case EditedProjectWriterError.unsupported(let reason) = error else {
                return XCTFail("Expected an explicit sample-phase rejection, received \(error)")
            }
            XCTAssertTrue(reason.contains("between native PCM samples"))
        }
    }

    func testNilProvenanceRetainsExistingEditableOutputExactly() throws {
        let input = fixture(camera: true, music: true)
        let project = UUID(), event = UUID()
        let original = try EditedProjectWriter.write(projectData: input, selection: selection,
            selectedRanges: cuts, outputName: "Editable", projectUID: project, eventUID: event)
        let explicitNil = try EditedProjectWriter.write(projectData: input, selection: selection,
            selectedRanges: cuts, outputName: "Editable", projectUID: project, eventUID: event, losslessAudio: nil)
        XCTAssertEqual(original.xmlData, explicitNil.xmlData)
        XCTAssertNil(explicitNil.report.losslessAudio)
    }

    func testAudioOnlyPrimaryRebuildRefusesToDiscardAnUnhandledMarkerOnAnUntouchedGap() throws {
        let input = Data(String(decoding: fixture(camera: false), as: UTF8.self)
            .replacingOccurrences(of: "<gap name=\"Lead in\" offset=\"3600s\" start=\"3600s\" duration=\"2s\"/>",
                with: "<gap name=\"Lead in\" offset=\"3600s\" start=\"3600s\" duration=\"2s\"><hidden-clip-marker/></gap>").utf8)
        let audio = try pcm(seconds: 10, start: 0, scope: .projectMix)
        XCTAssertThrowsError(try write(input, audio: audio)) { error in
            guard case EditedProjectWriterError.unsupported(let reason) = error else {
                return XCTFail("Expected explicit preservation refusal, received \(error)")
            }
            XCTAssertTrue(reason.contains("hidden-clip-marker"))
            XCTAssertTrue(reason.contains("cannot be preserved"))
        }
    }

    func testAudioOnlyPrimarySoundUsesCapturedChannelRoutingWithoutApplyingItAgain() throws {
        let input = Data(String(decoding: fixture(camera: false, music: true), as: UTF8.self)
            .replacingOccurrences(of: "<marker start=\"421/4s\" value=\"Keep me\"/><filter-audio ref=\"fx\">",
                with: "<marker start=\"421/4s\" value=\"Keep me\"/><audio-channel-source srcCh=\"1\" enabled=\"1\" role=\"dialogue.voice\"/><filter-audio ref=\"fx\">").utf8)
        let original = try TimelineParser.parse(data: input)
        XCTAssertTrue(try original.selectedTarget(selection, requireExistingMedia: false).hasAudio)
        let audio = try pcm(seconds: 10, start: 0, scope: .projectMix)
        let output = try write(input, audio: audio)
        let result = try TimelineParser.parse(data: output.xmlData)
        let audible = result.clips.filter { $0.enabled && $0.hasAudio }
        XCTAssertEqual(audible.map(\.timelineRange), [range(0, 3), range(3, 9)])
        XCTAssertEqual(audible.map(\.sourceStart), [RationalTime(0), RationalTime(4)])
        XCTAssertTrue(audible.allSatisfy { $0.isPrimaryStoryline && $0.mediaURL == audio.url })
        let xml = try XMLDocument(data: output.xmlData)
        XCTAssertTrue(try xml.nodes(forXPath: "//project/sequence/spine/asset-clip/audio-channel-source").isEmpty)
        XCTAssertEqual(try TimelineParser.parse(data: input).fingerprint, original.fingerprint)
    }

    private func write(_ input: Data, audio: LosslessRenderedAudio) throws -> EditedProjectOutput {
        try EditedProjectWriter.write(projectData: input, selection: selection,
            selectedRanges: cuts, outputName: "Baked result", losslessAudio: audio)
    }

    private func fixtureWithMergedClipNotes(voiceMetadataValue: String) -> Data {
        Data(String(decoding: fixture(camera: false), as: UTF8.self)
            .replacingOccurrences(of: "<gap name=\"Lead in\" offset=\"3600s\" start=\"3600s\" duration=\"2s\"/>", with: """
            <gap name="Lead in" offset="3600s" start="3600s" duration="2s"><note>Lead-in note</note><metadata><md key="com.silentsnip.test.shared" value="same"/></metadata></gap>
            """)
            .replacingOccurrences(of: "audioRole=\"dialogue.voice\"><adjust-volume", with: "audioRole=\"dialogue.voice\"><note>Voice note</note><adjust-volume")
            .replacingOccurrences(of: "</filter-audio></asset-clip>", with: "</filter-audio><metadata><md key=\"com.silentsnip.test.shared\" value=\"\(voiceMetadataValue)\"/></metadata></asset-clip>").utf8)
    }

    private func fixture(camera: Bool, music: Bool = false, connectedVideo: Bool = false) -> Data {
        let children = (music ? "<asset-clip ref=\"music\" name=\"Music\" lane=\"-1\" offset=\"105s\" start=\"0s\" duration=\"6s\" audioRole=\"music\"><filter-audio ref=\"fx\"/></asset-clip>" : "")
            + (connectedVideo ? "<asset-clip ref=\"context\" name=\"Context\" lane=\"1\" offset=\"211/2s\" start=\"0s\" duration=\"1/4s\" srcEnable=\"video\"><adjust-transform position=\"0.4 0.5\"/></asset-clip>" : "")
        return Data("""
        <fcpxml version="1.14"><resources>
        <format id="f" frameDuration="1/30s" width="640" height="360"/>
        <asset id="voice" name="Voice" start="100s" duration="30s" hasAudio="1" audioSources="1" audioChannels="2" hasVideo="\(camera ? 1 : 0)" format="f"><media-rep kind="original-media" src="file:///fixtures/voice.\(camera ? "mov" : "wav")"/></asset>
        <asset id="music" name="Music" start="0s" duration="30s" hasAudio="1" audioSources="1" audioChannels="2"><media-rep kind="original-media" src="file:///fixtures/music.wav"/></asset>
        <asset id="context" name="Context" start="0s" duration="10s" hasAudio="1" audioSources="1" audioChannels="2" hasVideo="1" format="f"><media-rep kind="original-media" src="file:///fixtures/context.mov"/></asset>
        <effect id="fx" uid="fixture.stateful.audio" name="Stateful DSP"/>
        </resources><library><event name="Original" uid="BBBB0000-0000-4000-8000-000000000001"><project name="Original project" uid="AAAA0000-0000-4000-8000-000000000001">
        <sequence format="f" duration="10s" tcStart="3600s" audioLayout="stereo" audioRate="48k"><spine>
        <gap name="Lead in" offset="3600s" start="3600s" duration="2s"/>
        <asset-clip ref="voice" name="Voice" offset="3602s" start="105s" duration="6s" audioRole="dialogue.voice"><adjust-volume amount="-3dB"/>\(camera ? "<adjust-transform position=\"0.2 0.3\"/>" : "")\(children)<marker start="421/4s" value="Keep me"/><filter-audio ref="fx"><data key="effectState">YWJj</data></filter-audio></asset-clip>
        <gap name="Lead out" offset="3608s" start="3600s" duration="2s"/>
        </spine></sequence></project></event></library></fcpxml>
        """.utf8)
    }

    private func pcm(seconds: Int64, start: Int64, scope: LosslessRenderedAudio.Scope) throws -> LosslessRenderedAudio {
        try pcm(frames: seconds * 48_000,
            timelineRange: .init(start: RationalTime(start), end: RationalTime(start + seconds)), scope: scope)
    }

    private func pcm(frames: Int64, timelineRange: TimeRange,
                     scope: LosslessRenderedAudio.Scope, sampleRate: Int64 = 48_000) throws -> LosslessRenderedAudio {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Processed-Audio.wav")
        let byteCount = UInt32(frames * 4)
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(byteCount + 36)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16)); append(UInt16(1)); append(UInt16(2))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 4)); append(UInt16(4)); append(UInt16(16))
        data.append(contentsOf: "data".utf8); append(byteCount)
        data.append(Data(repeating: 0, count: Int(byteCount)))
        try data.write(to: url)
        return try LosslessRenderedAudio(url: url, sha256: MediaContentSnapshot.contentHash(at: url),
            sampleRate: sampleRate, channelCount: 2, frameCount: frames,
            timelineRange: timelineRange, scope: scope)
    }
    private func range(_ start: Int64, _ end: Int64) -> TimeRange { .init(start: RationalTime(start), end: RationalTime(end)) }
    private func time(_ value: RationalTime) -> String { "\(value.numerator)/\(value.denominator)s" }
}
