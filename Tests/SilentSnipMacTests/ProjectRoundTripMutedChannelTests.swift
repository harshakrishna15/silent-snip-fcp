import Foundation
import XCTest
@testable import SilentSnipMac

final class ProjectRoundTripMutedChannelTests: XCTestCase {
    private let separate = "<audio-channel-source srcCh='1' enabled='0' role='dialogue'/><audio-channel-source srcCh='2' enabled='0' role='dialogue'/>"
    private let grouped = "<audio-channel-source srcCh='1, 2' enabled='0' role='dialogue.dialogue-1'/>"

    func testCompletelyMutedAVChannelGroupsIgnoreOnlyDefaultRoleAndGroupingSyntax() throws {
        XCTAssertTrue(try ProjectRoundTripVerification.compare(expected: fixture(separate), actual: fixture(grouped)).verified)
        XCTAssertTrue(try ProjectRoundTripVerification.compare(expected: fixture(grouped), actual: fixture(separate)).verified)
    }

    func testReenabledMissingDuplicateOrOutOfRangeSourceChannelsCannotNormalize() throws {
        for components in [
            "<audio-channel-source srcCh='1, 2' enabled='1' role='dialogue.dialogue-1'/>",
            "<audio-channel-source srcCh='1' enabled='0' role='dialogue.dialogue-1'/>",
            "<audio-channel-source srcCh='1, 1, 2' enabled='0' role='dialogue.dialogue-1'/>",
            "<audio-channel-source srcCh='1, 2, 3' enabled='0' role='dialogue.dialogue-1'/>",
            "<audio-channel-source srcCh='1, 2' role='dialogue.dialogue-1'/>",
            "<audio-channel-source srcCh='1, 2,' enabled='0' role='dialogue.dialogue-1'/>"
        ] {
            XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: fixture(separate), actual: fixture(components)).verified,
                "Every source channel must be explicitly disabled exactly once: \(components)")
        }
    }

    func testPartialMutingDoesNotMakeRemainingRoleStateNonrendering() throws {
        let expected = "<audio-channel-source srcCh='1' enabled='0' role='dialogue'/>"
        let actual = "<audio-channel-source srcCh='1' enabled='0' role='dialogue.dialogue-1'/>"
        XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: fixture(expected), actual: fixture(actual)).verified)
    }

    func testPurePCMUnknownComponentStateAndDSPRemainStrict() throws {
        XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: fixture(separate, video: false), actual: fixture(grouped, video: false)).verified,
            "The newly rendered audio asset never receives the muted-AV exception")
        let withActive = grouped.replacingOccurrences(of: "enabled='0'", with: "enabled='0' active='0'")
        XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: fixture(separate), actual: fixture(withActive)).verified)
        let withDSP = grouped.replacingOccurrences(of: "/>", with: "><adjust-volume amount='-3dB'/></audio-channel-source>")
        XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: fixture(separate), actual: fixture(withDSP)).verified)
        XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: fixture(separate),
            actual: fixture(grouped + "<adjust-volume amount='-3dB'/>")).verified,
            "Processing outside the disabled component nodes stays in the complete fingerprint")
    }

    func testSourceMediaAndChannelMetadataRemainStrictUnderCompleteMuting() throws {
        let expected = fixture(separate)
        let changedMedia = String(decoding: fixture(grouped), as: UTF8.self)
            .replacingOccurrences(of: "Original.mov", with: "Different.mov")
        XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: expected, actual: Data(changedMedia.utf8)).verified)
        let changedCount = String(decoding: fixture(grouped), as: UTF8.self)
            .replacingOccurrences(of: "audioChannels=\"2\"", with: "audioChannels=\"1\"")
        XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: expected, actual: Data(changedCount.utf8)).verified)
    }

    private func fixture(_ components: String, video: Bool = true) -> Data {
        Data("""
        <fcpxml version="1.14"><resources><format id="f" frameDuration="1/30s"/>
          <asset id="a" name="Original" uid="existing-original-asset" start="0s" duration="10s" hasVideo="\(video ? 1 : 0)" hasAudio="1" audioSources="1" audioChannels="2" audioRate="48000"><media-rep kind="original-media" src="file:///tmp/Original.mov"/></asset>
        </resources><project name="Frozen" uid="same-project"><sequence format="f" duration="10s" tcStart="0s"><spine>
          <asset-clip ref="a" name="Camera" offset="0s" start="0s" duration="10s" audioRole="dialogue">\(components)</asset-clip>
        </spine></sequence></project></fcpxml>
        """.utf8)
    }
}
