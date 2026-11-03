import Foundation
import SilentSnipCore
import XCTest
@testable import SilentSnipMac

final class FinalCutAudioMixScopeTests: XCTestCase {
    func testWholeProjectMixRejectsSelectedRangeAndMissingRoleEvidence() {
        XCTAssertTrue(FinalCutAudioMixScope.dialogue.permitsSelectionRange(true))
        XCTAssertTrue(FinalCutAudioMixScope.fullProjectMix(expectedRoles: ["dialogue", "music"]).permitsSelectionRange(false))
        XCTAssertFalse(FinalCutAudioMixScope.fullProjectMix(expectedRoles: ["dialogue", "music"]).permitsSelectionRange(true))
        XCTAssertFalse(FinalCutAudioMixScope.fullProjectMix(expectedRoles: []).permitsSelectionRange(false))
    }

    func testIncludesConnectedMusicCustomRoleAndEveryDeclaredComponentGroup() throws {
        let xml = fixture("""
        <asset-clip ref="a" name="Voice" offset="0s" start="0s" duration="10s" audioRole="dialogue.Original">
          <audio-channel-source srcCh="1" role="dialogue.Active"/>
          <audio-channel-source srcCh="2" role="effects.Disabled" active="0"/>
          <asset-clip ref="a" name="Music" lane="-1" offset="0s" start="0s" duration="10s" audioRole="music.Bed"/>
          <asset-clip ref="a" name="Custom" lane="-2" offset="0s" start="0s" duration="10s" audioRole="Custom Voice.Overdub"/>
        </asset-clip>
        """)
        XCTAssertEqual(try FinalCutAudioMixScope.expectedRoles(projectData: xml),
            ["dialogue.Original", "dialogue.Active", "effects.Disabled", "music.Bed", "Custom Voice.Overdub"])
    }

    func testDeclaredInactiveAndVideoOnlyAudioGroupsRemainInNativeRoleCoverage() throws {
        let xml = fixture("""
        <asset-clip ref="a" name="Voice" offset="0s" start="0s" duration="10s" audioRole="dialogue">
          <filter-audio ref="gate" enabled="0"/>
          <asset-clip ref="a" lane="-1" offset="0s" start="0s" duration="10s" audioRole="music" enabled="0">
            <asset-clip ref="a" lane="-2" offset="0s" start="0s" duration="10s" audioRole="Custom.Disabled"/>
          </asset-clip>
          <asset-clip ref="a" lane="-3" offset="0s" start="0s" duration="10s" audioRole="effects" srcEnable="video"/>
          <asset-clip ref="a" lane="-4" offset="0s" start="0s" duration="10s" audioRole="music">
            <audio-role-source role="music" enabled="0"/>
          </asset-clip>
        </asset-clip>
        """)
        XCTAssertEqual(try FinalCutAudioMixScope.expectedRoles(projectData: xml),
            ["dialogue", "music", "Custom.Disabled", "effects"],
            "Native WAV Roles retain declared inactive groups; bypassing DSP does not remove them either")
    }

    func testEnabledAudioComponentsCanInheritExactClipAudioRole() throws {
        let xml = fixture("""
        <asset-clip ref="a" offset="0s" start="0s" duration="10s" audioRole="Ambience.Room">
          <audio-channel-source srcCh="1, 2"/>
        </asset-clip>
        """)
        XCTAssertEqual(try FinalCutAudioMixScope.expectedRoles(projectData: xml), ["Ambience.Room"])
    }

    func testMissingRolesInvalidFlagsAndUnresolvedRoutingStop() throws {
        let clips = [
            "<asset-clip ref='a' offset='0s' start='0s' duration='10s'/>",
            "<asset-clip ref='a' offset='0s' start='0s' duration='10s' audioRole='dialogue' enabled='maybe'/>",
            "<asset-clip ref='a' offset='0s' start='0s' duration='10s' audioRole='dialogue' srcEnable='mystery'/>",
            "<asset-clip ref='a' offset='0s' start='0s' duration='10s' audioRole='dialogue'><audio-channel-source srcCh='1' active='maybe'/></asset-clip>",
            "<clip offset='0s' start='0s' duration='10s'><audio ref='a' offset='0s' start='0s' duration='10s' role='music'/></clip>",
            "<asset-clip ref='a' offset='0s' start='0s' duration='10s' audioRole='dialogue'><timeMap><timept time='0s' value='0s'/><timept time='10s' value='5s'/></timeMap></asset-clip>"
        ]
        for clip in clips {
            XCTAssertThrowsError(try FinalCutAudioMixScope.expectedRoles(projectData: fixture(clip)), clip)
        }
    }

    private func fixture(_ spine: String) -> Data {
        Data("""
        <fcpxml version="1.11"><resources><format id="f" frameDuration="1/30s"/>
          <asset id="a" name="Source" start="0s" duration="10s" hasVideo="1" hasAudio="1"><media-rep kind="original-media" src="file:///tmp/Generated.wav"/></asset>
          <effect id="gate" uid="native-gate"/>
        </resources><project name="Fixture" uid="fixture-project"><sequence format="f" duration="10s" tcStart="0s"><spine>\(spine)</spine></sequence></project></fcpxml>
        """.utf8)
    }
}
