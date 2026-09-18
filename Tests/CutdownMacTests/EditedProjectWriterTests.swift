import CutdownCore
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import XCTest
@testable import CutdownMac

final class EditedProjectWriterTests: XCTestCase {
    private let projectUID = UUID(uuidString: "AAAA0000-0000-4000-8000-000000000001")!
    private let eventUID = UUID(uuidString: "BBBB0000-0000-4000-8000-000000000001")!

    func testKeyframesKeepSourceCoordinatesAndFadesStayAtOuterEdges() throws {
        let animation = "<keyframeAnimation><keyframe time=\"100s\" value=\"-6\"/><keyframe time=\"105s\" value=\"0\" curve=\"smooth\"/><keyframe time=\"110s\" value=\"-3\"/></keyframeAnimation>"
        let data = fixture(spine: "<asset-clip ref=\"a\" offset=\"0s\" start=\"100s\" duration=\"10s\" audioRole=\"dialogue\"><adjust-volume><param name=\"amount\"><fadeIn duration=\"1s\" type=\"easeIn\"/><fadeOut duration=\"1s\" type=\"easeOut\"/>\(animation)</param></adjust-volume></asset-clip>")
        for gaps in [[:], [range(2, 3): RationalTime(1), range(6, 8): RationalTime(1)]] {
            let result = try EditedProjectWriter.write(projectData: data, selection: .init(timelineRange: range(0, 10)),
                selectedRanges: [range(2, 3), range(6, 8)], outputName: "Animated", replacementGaps: gaps)
            let output = try XMLDocument(data: result.xmlData)
            let clips = try output.nodes(forXPath: "//spine/asset-clip")
            XCTAssertEqual(clips.count, 3)
            for (index, clip) in clips.enumerated() {
                XCTAssertEqual(try clip.nodes(forXPath: ".//keyframe/@time").map(\.stringValue), ["100s", "105s", "110s"])
                XCTAssertEqual(try clip.nodes(forXPath: ".//fadeIn").count, index == 0 ? 1 : 0)
                XCTAssertEqual(try clip.nodes(forXPath: ".//fadeOut").count, index == 2 ? 1 : 0)
            }
            XCTAssertTrue(try ProjectRoundTripVerification.compare(expected: result.xmlData, actual: result.xmlData).verified)
            let changed = Data(String(decoding: result.xmlData, as: UTF8.self).replacingOccurrences(of: "type=\"easeIn\"", with: "type=\"linear\"").utf8)
            XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: result.xmlData, actual: changed).verified)
        }
        XCTAssertThrowsError(try write(data, selection: range(0, 10), cuts: [range(0, 1)]))
        let document = try TimelineParser.parse(data: data)
        XCTAssertEqual(try document.protectedRanges(for: document.clips[0]).map(\.range), [range(0, 1), range(9, 10)])
    }

    func testNativeAudioOutputMatchesIndependentFinalCutSourceIntervalsAndEffects() throws {
        let before = try nativeFixture("final-cut-12-3-native-audio")
        let after = try TimelineParser.parse(data: nativeFixture("final-cut-12-3-native-audio-after-cuts"))
        let result = try write(before, selection: range(0, 10), cuts: [
            .init(start: .init(34, 15), end: .init(101, 30)),
            .init(start: .init(79, 15), end: .init(103, 15))
        ])
        let generated = try TimelineParser.parse(data: result.xmlData)
        XCTAssertEqual(generated.clips.map(\.timelineRange), after.clips.map(\.timelineRange))
        XCTAssertEqual(generated.clips.map(\.sourceStart), after.clips.map(\.sourceStart))
        XCTAssertEqual(generated.clips.map(\.effectsFingerprint), after.clips.map(\.effectsFingerprint))
        XCTAssertEqual(generated.clips.map(\.mediaURL), after.clips.map(\.mediaURL))
        XCTAssertEqual(result.report.removedDuration, RationalTime(27, 10))
        XCTAssertEqual(result.report.resultProjectDuration, RationalTime(73, 10))
        XCTAssertEqual(generated.projectUID, projectUID.uuidString)
        XCTAssertEqual(generated.projectName, "Edited & Reviewed")
        XCTAssertEqual(try TimelineParser.parse(data: before).projectName, "Cutdown Audio Native")
        let source = try XMLDocument(data: before)
        let output = try XMLDocument(data: result.xmlData)
        XCTAssertEqual(try text(source, "/fcpxml/resources/asset/media-rep/bookmark"),
                       try text(output, "/fcpxml/resources/asset/media-rep/bookmark"))
        XCTAssertEqual(try output.nodes(forXPath: "//project").count, 1)
        XCTAssertEqual(try output.nodes(forXPath: "//event").count, 1)
        XCTAssertEqual(try text(output, "//event/@name"), "Cutdown Results")
        XCTAssertEqual(try text(output, "//event/@uid"), eventUID.uuidString)
        XCTAssertTrue(try output.nodes(forXPath: "//project/@modDate").isEmpty)
    }

    func testTrimmedRepeatedSourceAndNonzeroTimecodeMoveOnlyExactTargetAndFollowingItems() throws {
        let data = fixture(spine: """
        <asset-clip ref="a" offset="3600s" start="100s" duration="4s" audioRole="dialogue"/>
        <asset-clip ref="a" offset="3604s" start="110s" duration="8s" audioRole="dialogue">
          <adjust-volume amount="-6dB"/>
          <filter-audio ref="au"><data key="effectState">YWJj</data><param name="gain" value="1"/></filter-audio>
        </asset-clip>
        <asset-clip ref="a" offset="3612s" start="125s" duration="4s" audioRole="dialogue">
          <asset-clip ref="music" lane="-1" offset="126s" duration="2s" audioRole="music"/>
          <marker start="126s" value="Later marker"/>
        </asset-clip>
        """, duration: "16s", tcStart: "3600s")
        let result = try write(data, selection: range(4, 12), cuts: [range(6, 7), range(9, 10)])
        let output = try TimelineParser.parse(data: result.xmlData)
        let clips = output.clips.filter(\.isPrimaryStoryline)
        XCTAssertEqual(clips.map(\.sourceStart), [100, 110, 113, 116, 125].map { RationalTime($0) })
        XCTAssertEqual(clips.map(\.timelineRange), [range(0, 4), range(4, 6), range(6, 8), range(8, 10), range(10, 14)])
        XCTAssertEqual(result.report.retainedSegments.map(\.mediaFileRange), [range(10, 12), range(13, 15), range(16, 18)])
        XCTAssertEqual(output.clips.first(where: { !$0.isPrimaryStoryline })?.timelineRange, range(11, 13))
        XCTAssertEqual(output.markers.map(\.timelinePosition), [RationalTime(11)])
        let xml = try XMLDocument(data: result.xmlData)
        XCTAssertEqual(try text(xml, "//spine/asset-clip[5]/@offset"), "3610s")
        XCTAssertEqual(try text(xml, "//spine/asset-clip[5]/asset-clip/@offset"), "126s")
    }

    func testFractionalFramesLeadingTrailingCutsAndAdjacentCutsStayExact() throws {
        let frame = RationalTime(1001, 30000)
        let data = fixture(spine: "<asset-clip ref=\"a\" offset=\"0s\" start=\"100s\" duration=\"1001/100s\" audioRole=\"dialogue\"/>",
                           duration: "1001/100s", frame: "1001/30000s")
        let selected = TimeRange(start: .zero, end: frame * 300)
        let cuts: [TimeRange] = [.init(start: frame * 250, end: frame * 300),
                                .init(start: .zero, end: frame * 10),
                                .init(start: frame * 100, end: frame * 110),
                                .init(start: frame * 110, end: frame * 120)]
        let result = try write(data, selection: selected, cuts: cuts)
        XCTAssertEqual(result.report.removedDuration, frame * 80)
        XCTAssertEqual(result.report.resultProjectDuration, frame * 220)
        XCTAssertEqual(result.report.retainedSegments.map(\.sourceRange), [
            .init(start: RationalTime(100) + frame * 10, end: RationalTime(100) + frame * 100),
            .init(start: RationalTime(100) + frame * 120, end: RationalTime(100) + frame * 250)
        ])
        XCTAssertEqual(result.report.selectedRanges.first?.start, .zero)
    }

    func testAnnotationsArePreservedOnlyOnRetainedSourceWithoutDuplication() throws {
        let data = fixture(spine: """
        <asset-clip ref="a" offset="0s" start="100s" duration="10s" audioRole="dialogue">
          <marker start="100s" duration="1/30s" value="First" note="User" completed="0"/>
          <marker start="102s" duration="1/30s" value="Removed"/>
          <marker start="104s" duration="1/30s" value="Retained boundary"/>
          <chapter-marker start="108s" value="Chapter"/>
          <keyword start="101s" duration="7s" value="Interview"/>
          <rating value="favorite"/>
        </asset-clip>
        """)
        let result = try write(data, selection: range(0, 10), cuts: [range(2, 4)])
        let output = try TimelineParser.parse(data: result.xmlData)
        XCTAssertEqual(output.markers.map(\.value), ["First", "Retained boundary", "Chapter"])
        XCTAssertEqual(output.markers.map(\.timelinePosition), [0, 2, 6].map { RationalTime($0) })
        XCTAssertEqual(output.markers.first?.note, "User")
        XCTAssertEqual(output.markers.first?.completed, "0")
        XCTAssertEqual(result.report.removedPointMarkerCount, 1)
        let xml = try XMLDocument(data: result.xmlData)
        XCTAssertEqual(try xml.nodes(forXPath: "//keyword/@start").map(\.stringValue), ["101s", "104s"])
        XCTAssertEqual(try xml.nodes(forXPath: "//keyword/@duration").map(\.stringValue), ["1s", "4s"])
        XCTAssertEqual(try xml.nodes(forXPath: "//rating/@duration").map(\.stringValue), ["2s", "6s"])
    }

    func testImportOptionsUseExistingMediaAndExplicitLibraryWithoutReplacingOriginalEvent() throws {
        let destination = URL(fileURLWithPath: "/fixtures/Cutdown Integration.fcpbundle")
        let data = fixture(spine: simpleTarget)
        let result = try EditedProjectWriter.write(projectData: data, selection: .init(timelineRange: range(0, 10)),
            selectedRanges: [range(2, 3)], outputName: "New", projectUID: projectUID, eventUID: eventUID,
            destinationLibrary: destination)
        let xml = try XMLDocument(data: result.xmlData)
        XCTAssertEqual(try text(xml, "//import-options/option[@key='copy assets']/@value"), "0")
        XCTAssertEqual(try text(xml, "//import-options/option[@key='suppress warnings']/@value"), "0")
        XCTAssertEqual(try text(xml, "//import-options/option[@key='library location']/@value"), destination.absoluteString)
        XCTAssertEqual(try text(xml, "//library/@location"), destination.absoluteString)
        XCTAssertEqual(try text(xml, "//library/@colorProcessing"), "wide-hdr")
        XCTAssertEqual(try text(xml, "//asset[@id='a']/media-rep/@src"), "file:///fixtures/voice.wav")
        XCTAssertEqual(try xml.nodes(forXPath: "//smart-collection").count, 0)
    }

    func testIdenticalInputsAndExplicitIdentitiesProduceDeterministicOutput() throws {
        let data = fixture(spine: simpleTarget)
        let first = try write(data, selection: range(0, 10), cuts: [range(2, 3)])
        let second = try write(data, selection: range(0, 10), cuts: [range(2, 3)])
        XCTAssertEqual(first.xmlData, second.xmlData)
        XCTAssertEqual(first.report.retainedSegments, second.report.retainedSegments)
    }

    func testRejectsOutsideUnalignedEmptyOverlappingAndWholeClipCuts() throws {
        let data = fixture(spine: simpleTarget)
        for cuts in [[], [range(0, 0)], [range(-1, 1)], [range(9, 11)],
                     [.init(start: .init(1, 100), end: .init(1))],
                     [range(2, 4), range(3, 5)], [range(0, 10)], [range(0, 3), range(3, 10)]] {
            XCTAssertThrowsError(try write(data, selection: range(0, 10), cuts: cuts), "\(cuts)")
        }
    }

    func testRejectsVideoTargetButPreservesSurroundingVideoUnchanged() throws {
        let video = "<asset-clip ref=\"video\" offset=\"10s\" duration=\"2s\" audioRole=\"dialogue\"/>"
        let data = fixture(spine: simpleTarget + video, duration: "12s")
        XCTAssertThrowsError(try write(data, selection: range(10, 12), cuts: [range(10, 11)]))
        let result = try write(data, selection: range(0, 10), cuts: [range(2, 3)])
        let output = try TimelineParser.parse(data: result.xmlData)
        XCTAssertEqual(output.clips.last?.timelineRange, range(9, 11))
        XCTAssertEqual(output.clips.last?.hasVideo, true)
    }

    func testRejectsTargetConnectionsTransitionsTimedAutomationAndComponentTrims() throws {
        let invalidContents = [
            "<asset-clip ref=\"music\" lane=\"-1\" offset=\"100s\" duration=\"1s\" audioRole=\"music\"/>",
            "<adjust-volume><param name=\"gain\"><keyframeAnimation/></param></adjust-volume>",
            "<audio-channel-source srcCh=\"1\" start=\"100s\" duration=\"10s\"/>",
            "<audio-channel-source srcCh=\"1\"><mute start=\"101s\" duration=\"1s\"/></audio-channel-source>",
            "<timeMap><timept time=\"0s\" value=\"0s\"/></timeMap>",
            "<filter-video ref=\"au\"/>"
        ]
        for content in invalidContents {
            let data = fixture(spine: "<asset-clip ref=\"a\" offset=\"0s\" start=\"100s\" duration=\"10s\" audioRole=\"dialogue\">\(content)</asset-clip>")
            XCTAssertThrowsError(try write(data, selection: range(0, 10), cuts: [range(2, 3)]), content)
        }
        let transition = fixture(spine: simpleTarget + "<transition offset=\"9s\" duration=\"1s\"/>")
        XCTAssertThrowsError(try write(transition, selection: range(0, 10), cuts: [range(2, 3)]))
    }

    func testEarlierConnectedItemAcrossEditIsRejected() throws {
        let data = fixture(spine: """
        <gap offset="0s" start="0s" duration="1s">
          <asset-clip ref="music" lane="-1" offset="0s" duration="10s" audioRole="music"/>
        </gap>
        <asset-clip ref="a" offset="1s" start="100s" duration="10s" audioRole="dialogue"/>
        """, duration: "11s")
        XCTAssertThrowsError(try write(data, selection: range(1, 11), cuts: [range(2, 3)])) {
            XCTAssertTrue($0.localizedDescription.contains("crosses a selected cut"))
        }
    }

    func testRejectsReusedIdentityMalformedXMLAndRemoteDestination() throws {
        let data = fixture(spine: simpleTarget)
        XCTAssertThrowsError(try EditedProjectWriter.write(projectData: data, selection: .init(timelineRange: range(0, 10)),
            selectedRanges: [range(2, 3)], outputName: "New",
            projectUID: UUID(uuidString: "CCCC0000-0000-4000-8000-000000000001")!))
        XCTAssertThrowsError(try EditedProjectWriter.write(projectData: data, selection: .init(timelineRange: range(0, 10)),
            selectedRanges: [range(2, 3)], outputName: "New", destinationLibrary: URL(string: "https://example.com/library.fcpbundle")!))
        XCTAssertThrowsError(try write(Data("<!DOCTYPE fcpxml SYSTEM 'file:///tmp/untrusted'>".utf8),
                                       selection: range(0, 10), cuts: [range(2, 3)]))
    }

    func testOutputValidatesAgainstInstalledFinalCutDTDWhenAvailable() throws {
        let dtd = URL(fileURLWithPath: "/Applications/Final Cut Pro.app/Contents/Frameworks/Interchange.framework/Versions/A/Resources/FCPXMLv1_14.dtd")
        guard FileManager.default.fileExists(atPath: dtd.path) else { throw XCTSkip("Final Cut's DTD is not installed") }
        let result = try write(nativeFixture("final-cut-12-3-native-audio"), selection: range(0, 10), cuts: [range(2, 3)])
        let input = Pipe()
        let errors = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xmllint")
        process.arguments = ["--noout", "--nonet", "--dtdvalid", dtd.absoluteString, "-"]
        process.standardInput = input
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: result.xmlData)
        try input.fileHandleForWriting.close()
        let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: diagnostics, as: UTF8.self))
    }

    private var simpleTarget: String {
        "<asset-clip ref=\"a\" offset=\"0s\" start=\"100s\" duration=\"10s\" audioRole=\"dialogue\"/>"
    }

    private func write(_ data: Data, selection: TimeRange, cuts: [TimeRange]) throws -> EditedProjectOutput {
        try EditedProjectWriter.write(projectData: data, selection: .init(timelineRange: selection), selectedRanges: cuts,
                                      outputName: "Edited & Reviewed", projectUID: projectUID, eventUID: eventUID)
    }

    private func range(_ start: Int64, _ end: Int64) -> TimeRange {
        .init(start: RationalTime(start), end: RationalTime(end))
    }

    private func text(_ xml: XMLDocument, _ path: String) throws -> String? {
        try xml.nodes(forXPath: path).first?.stringValue
    }

    private func nativeFixture(_ name: String) throws -> Data {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CutdownCoreTests/Fixtures")
        return try Data(contentsOf: folder.appendingPathComponent(name + ".fcpxml"))
    }

    private func fixture(spine: String, duration: String = "10s", tcStart: String = "0s", frame: String = "1/30s") -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.14">
          <import-options><option key="copy assets" value="1"/></import-options>
          <resources>
            <format id="f" frameDuration="\(frame)" width="1920" height="1080"/>
            <asset id="a" name="Voice" start="100s" duration="100s" hasAudio="1" audioChannels="2" audioRate="48000">
              <media-rep kind="original-media" src="file:///fixtures/voice.wav"><bookmark>YWJj</bookmark></media-rep>
            </asset>
            <asset id="music" name="Music" start="0s" duration="100s" hasAudio="1" audioChannels="2" audioRate="48000">
              <media-rep kind="original-media" src="file:///fixtures/music.wav"/>
            </asset>
            <asset id="video" name="Video" start="0s" duration="100s" hasAudio="1" hasVideo="1" format="f">
              <media-rep kind="original-media" src="file:///fixtures/context.mov"/>
            </asset>
            <effect id="au" name="Audio effect" uid="AudioUnit: test-static-effect"/>
          </resources>
          <library colorProcessing="wide-hdr" location="file:///fixtures/Original.fcpbundle/">
            <event name="Original event" uid="DDDD0000-0000-4000-8000-000000000001">
              <project name="Original" uid="CCCC0000-0000-4000-8000-000000000001">
                <sequence format="f" duration="\(duration)" tcStart="\(tcStart)" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
                  <spine>\(spine)</spine>
                </sequence>
              </project>
            </event>
            <smart-collection name="Old collections"><match-clip rule="is" type="project"/></smart-collection>
          </library>
        </fcpxml>
        """.utf8)
    }
}
