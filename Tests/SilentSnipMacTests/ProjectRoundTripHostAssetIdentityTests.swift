import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import XCTest
@testable import SilentSnipMac

final class ProjectRoundTripHostAssetIdentityTests: XCTestCase {
    private let assigned = "EC67787317D7E36EAF4A9C3302315849"
    private let other = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    func testOnlyNewAudioAssetIdentityAndNativeIngestMetadataAreAdopted() throws {
        let expected = fixture(native: false)
        let actual = fixture(native: true)
        let first = try ProjectRoundTripVerification.compare(expected: expected, actual: actual, allowHostAssignedIdentity: true)
        XCTAssertTrue(first.verified)
        XCTAssertEqual(first.hostAssignedAudioAssetUIDs, ["file:///tmp/Processed-Audio.wav": assigned])
        let bound = try ProjectRoundTripVerification.compare(expected: expected, actual: actual,
            allowHostAssignedIdentity: true, expectedHostProjectUID: first.actualProjectUID,
            expectedHostAudioAssetUIDs: first.hostAssignedAudioAssetUIDs)
        XCTAssertTrue(bound.verified)
        let changed = fixture(native: true, uid: other)
        XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: expected, actual: changed,
            allowHostAssignedIdentity: true, expectedHostProjectUID: first.actualProjectUID,
            expectedHostAudioAssetUIDs: first.hostAssignedAudioAssetUIDs).verified,
            "Once assigned, the imported audio asset identity remains bound")
    }

    func testExistingUIDAndMismatchedAssignedSignatureRemainStrict() throws {
        let expected = fixture(native: false, uid: other)
        XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: expected,
            actual: fixture(native: true), allowHostAssignedIdentity: true).verified)
        let wrongSignature = String(decoding: fixture(native: true), as: UTF8.self)
            .replacingOccurrences(of: "sig=\"\(assigned)\"", with: "sig=\"\(other)\"")
        XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: fixture(native: false),
            actual: Data(wrongSignature.utf8), allowHostAssignedIdentity: true).verified)
    }

    func testNativeReuseOfAnOlderRenderAtAnotherPathIsNotAnIdentityNormalization() throws {
        // Sanitized native case: Final Cut reused a previously imported asset
        // for a byte-identical copied WAV, retaining its old URL and asset UID.
        // Exact PCM alone must not authorize a different durable dependency.
        let expected = Data(String(decoding: fixture(native: false), as: UTF8.self)
            .replacingOccurrences(of: "file:///tmp/Processed-Audio.wav", with: "file:///tmp/Result-v2/Processed-Audio.wav").utf8)
        let actual = Data(String(decoding: fixture(native: true), as: UTF8.self)
            .replacingOccurrences(of: "file:///tmp/Processed-Audio.wav", with: "file:///tmp/Result-v1/Processed-Audio.wav").utf8)
        let report = try ProjectRoundTripVerification.compare(expected: expected, actual: actual, allowHostAssignedIdentity: true)
        XCTAssertFalse(report.verified)
        XCTAssertNil(report.hostAssignedAudioAssetUIDs,
            "A host-assigned UID may bind only the exact expected media URL")
    }

    func testAudioMediaMetadataAndProcessingAreNeverHiddenByIdentityAdoption() throws {
        let expected = fixture(native: false)
        let actual = fixture(native: true)
        let changes = [
            ("//media-rep/@src", "file:///tmp/Substituted.wav"),
            ("//asset/@audioChannels", "1"),
            ("//asset/@audioRate", "44100"),
            ("//asset/@duration", "11s"),
            ("//asset/@hasVideo", "1")
        ]
        for (path, value) in changes {
            let xml = try XMLDocument(data: actual)
            if let attribute = try xml.nodes(forXPath: path).first { attribute.stringValue = value }
            else if path == "//asset/@hasVideo", let asset = try xml.nodes(forXPath: "//asset").first as? XMLElement {
                asset.addAttribute(XMLNode.attribute(withName: "hasVideo", stringValue: value) as! XMLNode)
            }
            XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: expected, actual: xml.xmlData,
                allowHostAssignedIdentity: true).verified, path)
        }
        let xml = try XMLDocument(data: actual)
        let clip = try XCTUnwrap(xml.nodes(forXPath: "//asset-clip").first as? XMLElement)
        clip.addChild(try XMLElement(xmlString: "<adjust-volume amount='-3dB'/>"))
        XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: expected, actual: xml.xmlData,
            allowHostAssignedIdentity: true).verified)
        for child in clip.children ?? [] { child.detach() }
        let metadata = try XCTUnwrap(xml.nodes(forXPath: "//asset/metadata").first as? XMLElement)
        metadata.addChild(try XMLElement(xmlString: "<md key='unknown-processing' value='changed'/>"))
        XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: expected, actual: xml.xmlData,
            allowHostAssignedIdentity: true).verified)
    }

    private func fixture(native: Bool, uid: String? = nil) -> Data {
        let hostUID = uid ?? (native ? assigned : nil)
        let identity = hostUID.map { " uid=\"\($0)\"" } ?? ""
        let signature = native ? " sig=\"\(hostUID!)\"" : ""
        let metadata = native ? "<metadata><md key='com.apple.proapps.mio.ingestDate' value='2026-11-02 22:32:34 -0800'/></metadata>" : ""
        return Data("""
        <fcpxml version="1.14"><resources><format id="f" frameDuration="1/30s"/>
          <asset id="a" name="Original sound"\(identity) start="0s" duration="10s" hasAudio="1"\(native ? "" : " hasVideo=\"0\"") audioSources="1" audioChannels="2" audioRate="48000"><media-rep kind="original-media"\(signature) src="file:///tmp/Processed-Audio.wav"/>\(metadata)</asset>
        </resources><project name="Cleaned" uid="\(native ? "host-project" : "generated-project")"><sequence format="f" duration="10s" tcStart="0s"><spine>
          <asset-clip ref="a" name="Original sound" offset="0s" start="0s" duration="10s" audioRole="dialogue"\(native ? "" : " srcEnable=\"audio\"")/>
        </spine></sequence></project></fcpxml>
        """.utf8)
    }
}
