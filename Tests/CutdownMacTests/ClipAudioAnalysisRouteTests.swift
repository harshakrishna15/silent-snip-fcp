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

    private func xml(_ children: String) -> Data {
        Data("""
        <fcpxml version="1.14"><resources>
        <format id="format" frameDuration="1/30s"/>
        <asset id="audio" start="0s" duration="6s" hasAudio="1" audioSources="1" audioChannels="2">
          <media-rep kind="original-media" src="file:///fixtures/audio.wav"/>
        </asset>
        <effect id="controller" uid="\(AudioControllerSettings.effectUID)"/>
        <effect id="limiter" uid="Limiter.Levels.audio.effectBundle"/>
        <effect id="thirdParty" uid="AudioUnit: 0x617566785445535454455354"/>
        </resources><project name="Effects"><sequence format="format" duration="6s" tcStart="0s"><spine>
        <asset-clip ref="audio" offset="0s" duration="3s" audioRole="dialogue">\(children)</asset-clip></spine></sequence></project></fcpxml>
        """.utf8)
    }
}
