import CutdownCore
import Foundation
import XCTest
@testable import CutdownMac

final class ClipAudioAnalysisRouteTests: XCTestCase {
    private let selection = TimelineSelection(timelineRange: TimeRange(start: .zero, end: RationalTime(3)))

    func testOnlyUnprocessedClipUsesSourceAudio() throws {
        for children in ["", "<marker start=\"1s\" value=\"Note\"/>",
                         "<filter-audio ref=\"controller\" name=\"Cutdown Audio\"/>"] {
            XCTAssertEqual(try ClipAudioAnalysisRoute.resolve(projectData: xml(children), selection: selection), .source)
        }
        for children in [
            "<adjust-volume amount=\"7.64317dB\"/>",
            "<adjust-volume amount=\"0dB\"><param name=\"amount\"><keyframeAnimation><keyframe time=\"1s\" value=\"12dB\"/></keyframeAnimation></param></adjust-volume>",
            "<adjust-panner mode=\"stereo\" amount=\"50\"/>",
            "<filter-audio ref=\"limiter\"/>",
            "<filter-audio ref=\"thirdParty\"><data key=\"effectState\">opaque</data></filter-audio>",
            "<filter-audio ref=\"limiter\" name=\"Cutdown Audio\"/>",
            "<audio-channel-source srcCh=\"1\" role=\"dialogue\"/>",
            "<adjust-loudness amount=\"50\"/>",
            "<filter-audio ref=\"controller\"/><filter-audio ref=\"limiter\"/>"
        ] {
            XCTAssertEqual(try ClipAudioAnalysisRoute.resolve(projectData: xml(children), selection: selection),
                           .finalCutRender, children)
        }
    }

    func testNonoverlappingAudioAndSilentVideoDoNotContaminateRender() throws {
        let data = xml("", following: "<asset-clip ref=\"audio\" offset=\"3s\" duration=\"3s\" audioRole=\"dialogue\"/>")
        let doc = try TimelineParser.parse(data: data)
        XCTAssertNoThrow(try ClipAudioAnalysisRoute.validateRenderIsolation(document: doc,
            target: doc.selectedTarget(selection, requireExistingMedia: false)))
        let video = try TimelineParser.parse(data: xml("<asset-clip ref=\"video\" lane=\"1\" offset=\"0s\" duration=\"3s\"/>"))
        XCTAssertNoThrow(try ClipAudioAnalysisRoute.validateRenderIsolation(document: video,
            target: video.selectedTarget(selection, requireExistingMedia: false)))
    }

    func testOtherAudioAndUnknownContainersNeverMasqueradeAsSelectedClip() throws {
        for children in [
            "<asset-clip ref=\"audio\" lane=\"-1\" offset=\"1s\" duration=\"1s\" audioRole=\"dialogue\"/>",
            "<asset-clip ref=\"audio\" lane=\"-1\" offset=\"1s\" duration=\"1s\" audioRole=\"music\"/>",
            "<clip lane=\"1\" offset=\"1s\" duration=\"1s\"/>"
        ] {
            let doc = try TimelineParser.parse(data: xml(children))
            XCTAssertThrowsError(try ClipAudioAnalysisRoute.validateRenderIsolation(document: doc,
                target: doc.selectedTarget(selection, requireExistingMedia: false)))
        }
    }

    private func xml(_ children: String, following: String = "") -> Data {
        Data("""
        <fcpxml version="1.14"><resources>
        <format id="format" frameDuration="1/30s"/>
        <asset id="audio" start="0s" duration="6s" hasAudio="1" audioSources="1" audioChannels="2">
          <media-rep kind="original-media" src="file:///fixtures/audio.wav"/>
        </asset>
        <asset id="video" start="0s" duration="6s" hasVideo="1" hasAudio="0">
          <media-rep kind="original-media" src="file:///fixtures/video.mov"/>
        </asset>
        <effect id="controller" uid="\(AudioControllerSettings.effectUID)"/>
        <effect id="limiter" uid="Limiter.Levels.audio.effectBundle"/>
        <effect id="thirdParty" uid="AudioUnit: 0x617566785445535454455354"/>
        </resources><project name="Effects"><sequence format="format" duration="6s" tcStart="0s"><spine>
        <asset-clip ref="audio" offset="0s" duration="3s" audioRole="dialogue">\(children)</asset-clip>
        \(following)</spine></sequence></project></fcpxml>
        """.utf8)
    }
}
