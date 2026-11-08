import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import SilentSnipCore
import XCTest
@testable import SilentSnipMac

/// Serialization and pre-import rejection tests. Synthetic state bytes do not
/// establish compatibility with a vendor's DSP or native Final Cut behavior.
final class EditableEffectReconstructionTests: XCTestCase {
    private let gateUID = "AudioUnit: 0x61756678000000b3454d4147"
    private let limiterUID = "Limiter.Levels.audio.effectBundle"
    private let selection = TimelineSelection(timelineRange: .init(start: .zero, end: .init(8)))
    private let cut = TimeRange(start: .init(2), end: .init(3))

    func testBareLimiterAndPresetOnlyGateCannotCreateEditableResults() throws {
        for (uid, filter) in [
            (limiterUID, "<filter-audio ref=\"fx\" name=\"Limiter\"/>"),
            (gateUID, "<filter-audio ref=\"fx\" name=\"Noise Gate\" presetID=\"[0]Blue Yeti Home Toy Room .aupreset\"/>")
        ] {
            let input = fixture(uid: uid, filters: filter)
            // Equal, incomplete XML is not evidence of native state fidelity.
            XCTAssertTrue(try ProjectRoundTripVerification.compare(expected: input, actual: input).verified)
            assertRejected(input, effectName: uid == limiterUID ? "Limiter" : "Noise Gate")
        }
    }

    func testOuterWrapperControlsAndOpaqueDataDoNotProveAdvancedLimiterState() throws {
        let archive = try state()
        for content in ["", "<param name=\"Amount\" key=\"amount\" value=\"0\"/>", archive,
                        archive + "<param name=\"Amount\" key=\"amount\" value=\"7\"/>"] {
            for enabled in ["1", "0"] {
                assertRejected(fixture(uid: limiterUID,
                    filters: "<filter-audio ref=\"fx\" name=\"Limiter\" enabled=\"\(enabled)\">\(content)</filter-audio>"),
                    effectName: "Limiter")
            }
        }
    }

    func testDirectAudioUnitArchivesAreNotNativeReconstructionProof() throws {
        for content in ["", "<param key=\"threshold\" value=\"-30\"/>",
                        "<data key=\"effectState\">YWJj</data>",
                        "<data key=\"effectState\">AQ!ID</data>",
                        "<data key=\"effectState\"/>",
                        try state(packet: Data()), try state(),
                        try state() + "<param key=\"threshold\" value=\"-31.5\"/>"] {
            for enabled in ["1", "0"] {
                assertRejected(fixture(uid: gateUID,
                    filters: "<filter-audio ref=\"fx\" name=\"Noise Gate\" enabled=\"\(enabled)\">\(content)</filter-audio>"),
                    effectName: "Noise Gate")
            }
        }
    }

    func testSyntheticXMLArchivePreservesExactBytesWithoutClaimingNativeCompleteness() throws {
        let contents = try state() + "<param key=\"threshold\" value=\"-31.5\"/>"
        let input = fixture(uid: "fixture.synthetic-effect",
            filters: "<filter-audio ref=\"fx\" name=\"Noise Gate\" presetID=\"Saved.aupreset\">\(contents)</filter-audio>")
        assertRejected(input, effectName: "Noise Gate")
        let result = try EditedProjectWriter.serializationExpectation(projectData: input, selection: selection,
            selectedRanges: [cut], outputName: "Serialization Only")
        let xml = try XMLDocument(data: result.xmlData)
        let states = try xml.nodes(forXPath: "//project/sequence/spine/asset-clip/filter-audio/data")
        let original = try XMLDocument(data: input).nodes(forXPath: "//filter-audio/data").first?.stringValue
        XCTAssertEqual(states.map(\.stringValue), [original, original])
        XCTAssertEqual(try xml.nodes(forXPath: "//filter-audio/param/@value").map(\.stringValue), ["-31.5", "-31.5"])
        XCTAssertEqual(try TimelineParser.parse(data: result.xmlData).clips.map(\.mediaURL),
            [URL(string: "file:///fixtures/Original.wav"), URL(string: "file:///fixtures/Original.wav")])
        XCTAssertNil(result.report.losslessAudio)
    }

    func testKnownControllerIsExemptButAnAudioEffectWithItsNameIsNot() throws {
        XCTAssertNoThrow(try write(fixture(uid: AudioControllerSettings.effectUID,
            filters: "<filter-audio ref=\"fx\" name=\"Silent Snip Audio\"/>")))
        assertRejected(fixture(uid: gateUID,
            filters: "<filter-audio ref=\"fx\" name=\"Silent Snip Audio\"/>"), effectName: "Silent Snip Audio")
        // Unknown formats receive the same native-state requirement; display
        // names and generic resource identifiers cannot create an exemption.
        for uid in ["fixture.generic-effect", "vendor.example.CustomPlugin.v3", "Unrecognized Effect"] {
            assertRejected(fixture(uid: uid,
                filters: "<filter-audio ref=\"fx\" name=\"Silent Snip Audio\" enabled=\"0\"><param key=\"amount\" value=\"3\"/></filter-audio>"),
                effectName: "Silent Snip Audio")
        }
    }

    func testMissingEffectResourceOrIdentityFailsClosed() throws {
        let input = fixture(uid: "vendor.Unknown", filters: "<filter-audio ref=\"fx\" name=\"Unknown\"/>")
        for alteration in ["missing-resource", "missing-uid", "blank-uid"] {
            let xml = try XMLDocument(data: input)
            let resource = try XCTUnwrap(xml.nodes(forXPath: "/fcpxml/resources/effect").first as? XMLElement)
            switch alteration {
            case "missing-resource": resource.detach()
            case "missing-uid": resource.removeAttribute(forName: "uid")
            default: resource.attribute(forName: "uid")?.stringValue = " "
            }
            XCTAssertThrowsError(try EditableEffectReconstruction.validate(projectData: xml.xmlData), alteration)
            XCTAssertThrowsError(try write(xml.xmlData), alteration)
        }
    }

    func testFinalRetainedTimelineChecksComponentsConnectionsAndUncutNeighbors() throws {
        assertRejected(fixture(uid: limiterUID,
            filters: "<audio-channel-source srcCh=\"1\"><filter-audio ref=\"fx\" name=\"Limiter\"/></audio-channel-source>"),
            effectName: "Limiter")
        assertRejected(fixture(uid: limiterUID, filters: "", neighbor: true), effectName: "Limiter")
        XCTAssertNoThrow(try write(fixture(uid: limiterUID, filters: "", neighbor: true), selectedClipOnly: true),
            "A discarded neighbor does not need to be reconstructed")
        let connected = "<asset-clip ref=\"a\" name=\"Music Bed\" lane=\"-1\" offset=\"0s\" start=\"0s\" duration=\"8s\" audioRole=\"music\"><filter-audio ref=\"fx\" name=\"Limiter\"/></asset-clip>"
        assertRejected(fixture(uid: limiterUID, filters: connected), effectName: "Limiter")
    }

    func testPrepareRejectsBeforeWritingAnImportableResult() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IncompleteFX-" + UUID().uuidString)
        let library = folder.appendingPathComponent("Fixture.fcpbundle")
        let resultFolder = folder.appendingPathComponent("Result")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = fixture(uid: limiterUID, filters: "<filter-audio ref=\"fx\" name=\"Limiter\"/>", library: library)
        let origin = try WorkflowReviewOrigin(view: UUID(), gesture: UUID(), libraryURL: library,
            projectUID: "original-project", projectName: "Original")
        XCTAssertThrowsError(try XMLProjectApply.prepare(projectData: input, selection: selection, cuts: [cut],
            settings: .defaults, mode: .remove, outputName: "Cleaned", directory: resultFolder,
            useOriginalEvent: true, omitController: true, workflowOrigin: origin))
        XCTAssertFalse(FileManager.default.fileExists(atPath: resultFolder.path),
            "Incomplete effect state must fail before producing files that can be imported")
    }

    private func assertRejected(_ input: Data, effectName: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try write(input), file: file, line: line) { error in
            guard case .unsupported = error as? EditedProjectWriterError else {
                return XCTFail("Expected incomplete-state rejection, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(error.localizedDescription.contains("‘\(effectName)’"), file: file, line: line)
            XCTAssertTrue(error.localizedDescription.contains("original settings"), file: file, line: line)
            XCTAssertTrue(error.localizedDescription.contains("no cleaned project was sent"), file: file, line: line)
        }
    }

    private func write(_ input: Data, selectedClipOnly: Bool = false) throws -> EditedProjectOutput {
        try EditedProjectWriter.write(projectData: input, selection: selection,
            selectedRanges: [cut], outputName: "Cleaned", selectedClipOnly: selectedClipOnly)
    }

    private func state(packet: Data = Data([1, 2, 3, 4])) throws -> String {
        // Matching AU identity plus nonempty bytes is still no native proof.
        let contents: NSDictionary = ["type": 0x61756678, "subtype": 0x000000b3, "manufacturer": 0x454d4147,
            "version": 1, "data": packet]
        let encoder = NSKeyedArchiver(requiringSecureCoding: true)
        encoder.encode(contents, forKey: "effectState")
        encoder.finishEncoding()
        return "<data key=\"effectState\">\(encoder.encodedData.base64EncodedString())</data>"
    }

    private func fixture(uid: String, filters: String, neighbor: Bool = false,
                         library: URL = URL(string: "file:///fixtures/Cutdown%20Integration.fcpbundle")!) -> Data {
        Data("""
        <fcpxml version="1.14"><resources><format id="f" frameDuration="1/30s"/>
        <asset id="a" name="Original Audio" start="0s" duration="20s" hasAudio="1"><media-rep kind="original-media" src="file:///fixtures/Original.wav"/></asset>
        <effect id="fx" name="Audio Effect" uid="\(uid)"/>
        </resources><library location="\(library.absoluteString)"><event name="Fixture" uid="BBBB0000-0000-4000-8000-000000000001"><project name="Original" uid="original-project">
        <sequence format="f" duration="\(neighbor ? 12 : 8)s" tcStart="0s"><spine>
        <asset-clip ref="a" name="Voice" offset="0s" start="0s" duration="8s" audioRole="dialogue">\(filters)</asset-clip>
        \(neighbor ? "<asset-clip ref=\"a\" name=\"Later Clip\" offset=\"8s\" start=\"10s\" duration=\"4s\" audioRole=\"dialogue\"><filter-audio ref=\"fx\" name=\"Limiter\"/></asset-clip>" : "")
        </spine></sequence></project></event></library></fcpxml>
        """.utf8)
    }
}
