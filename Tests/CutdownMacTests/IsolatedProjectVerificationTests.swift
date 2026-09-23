import CutdownCore
import Foundation
import XCTest
@testable import CutdownMac

final class IsolatedProjectVerificationTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Test.fcpbundle"), withIntermediateDirectories: true)
        try Data([0]).write(to: directory.appendingPathComponent("Voice.wav"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func fixture() -> Data {
        Data("""
        <fcpxml version="1.11"><resources><format id="f" frameDuration="1/30s"/>
        <asset id="a" start="3600s" duration="20s" hasAudio="1"><media-rep kind="original-media" src="\(directory.appendingPathComponent("Voice.wav").absoluteString)"/></asset>
        <effect id="c" uid="\(AudioControllerSettings.effectUID)"/><effect id="e" uid="test-limiter"/></resources>
        <library location="\(directory.appendingPathComponent("Test.fcpbundle").absoluteString)"><event name="Original" uid="9BB8C00A-93BC-4613-8018-9517EEDBC983"><project name="Original" uid="original">
        <sequence format="f" duration="8s" tcStart="7200s"><spine><gap offset="7200s" start="0s" duration="3s"/>
        <asset-clip ref="a" name="Voice" offset="7203s" start="3602s" duration="5s" audioRole="music">
        <adjust-volume amount="6dB"/><audio-channel-source srcCh="1, 2" role="effects"/>
        <asset-clip ref="a" name="Neighbor" lane="-1" offset="3603s" start="3600s" duration="1s" audioRole="dialogue"/>
        <filter-audio ref="e"><param key="limit" value="-1"/></filter-audio><filter-audio ref="c"/>
        </asset-clip></spine></sequence></project></event></library></fcpxml>
        """.utf8)
    }
    func testGateLimiterRenderUsesHostStableComponentSubroleWithoutRelaxingVerification() throws {
        // Regression from the user's saved render: Final Cut expands a bare
        // component role to dialogue.dialogue-1. All DSP entries stay identical.
        let source = String(decoding: fixture(), as: UTF8.self)
            .replacingOccurrences(of: "</resources>", with: "<effect id=\"gate\" uid=\"AudioUnit: 0x61756678000000b3454d4147\"/></resources>")
            .replacingOccurrences(of: "<filter-audio ref=\"e\"", with: "<filter-audio ref=\"gate\" presetID=\"Saved gate.aupreset\"/><filter-audio ref=\"e\"")
        let isolated = try IsolatedAudioProject.make(projectData: Data(source.utf8),
            selection: .init(timelineRange: .init(start: .init(3), end: .init(8))))
        let uid = try XCTUnwrap(TimelineParser.parse(data: isolated.data).projectUID)
        let expected = String(decoding: isolated.data, as: UTF8.self)
        let delivered = expected.replacingOccurrences(of: "role=\"dialogue\"", with: "role=\"dialogue.dialogue-1\"")
            .replacingOccurrences(of: "uid=\"\(uid)\"", with: "uid=\"host-imported\"")
        XCTAssertTrue(try ProjectRoundTripVerification.compare(expected: isolated.data, actual: Data(delivered.utf8), allowHostAssignedIdentity: true).verified)
        let legacy = Data(expected.replacingOccurrences(of: "role=\"dialogue.dialogue-1\"", with: "role=\"dialogue\"").utf8)
        XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: legacy, actual: Data(delivered.utf8), allowHostAssignedIdentity: true).verified)
        for (before, after) in [("Saved gate.aupreset", "Changed gate.aupreset"), ("value=\"-1\"", "value=\"-6\""),
                                ("dialogue.dialogue-1", "music.music-1")] {
            XCTAssertTrue(delivered.contains(before))
            XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: isolated.data,
                actual: Data(delivered.replacingOccurrences(of: before, with: after).utf8), allowHostAssignedIdentity: true).verified)
        }
    }

    func testCleanupRequiresOwnedVerifiedProjectAndRestoredOriginal() throws {
        let isolated = try IsolatedAudioProject.make(projectData: fixture(), selection: .init(timelineRange: .init(start: .init(3), end: .init(8))))
        let delivered = Data(String(decoding: isolated.data, as: UTF8.self)
            .replacingOccurrences(of: "uid=\"\(isolated.destination.originalProjectUID)\"", with: "uid=\"\(UUID().uuidString)\"").utf8)
        XCTAssertNoThrow(try AnalysisProjectCleanup.validate(isolated: isolated, delivered: delivered, currentProject: "Original"))
        XCTAssertThrowsError(try AnalysisProjectCleanup.validate(isolated: isolated, delivered: delivered, currentProject: isolated.name))
        XCTAssertThrowsError(try AnalysisProjectCleanup.validate(isolated: isolated, delivered: delivered, currentProject: "Other"))
        XCTAssertThrowsError(try AnalysisProjectCleanup.validate(isolated: isolated, delivered: fixture(), currentProject: "Original"))
        let changed = Data(String(decoding: delivered, as: UTF8.self).replacingOccurrences(of: "6dB", with: "0dB").utf8)
        XCTAssertThrowsError(try AnalysisProjectCleanup.validate(isolated: isolated, delivered: changed, currentProject: "Original"))
        let wrongEvent = Data(String(decoding: delivered, as: UTF8.self)
            .replacingOccurrences(of: "name=\"Original\" uid=\"9BB8C00A-93BC-4613-8018-9517EEDBC983\"",
                with: "name=\"Other\" uid=\"9BB8C00A-93BC-4613-8018-9517EEDBC983\"").utf8)
        XCTAssertThrowsError(try AnalysisProjectCleanup.validate(isolated: isolated, delivered: wrongEvent, currentProject: "Original"))
    }

    func testIsolationPreservesSourceTrimProcessingAndChannelsWithoutNeighbors() throws {
        let data = fixture()
        let result = try IsolatedAudioProject.make(projectData: data, selection: .init(timelineRange: .init(start: .init(3), end: .init(8))))
        let document = try TimelineParser.parse(data: result.data)
        XCTAssertEqual(document.clips.count, 1)
        XCTAssertEqual(document.clips[0].sourceFileStart, .init(2))
        XCTAssertEqual(document.clips[0].timelineRange, .init(start: .zero, end: .init(5)))
        XCTAssertEqual(document.clips[0].mediaURL, directory.appendingPathComponent("Voice.wav"))
        XCTAssertNotEqual(document.projectUID, "original")
        XCTAssertEqual(result.destination.eventName, "Original")
        XCTAssertEqual(result.destination.eventUID, result.sourceProject.eventUID)
        XCTAssertEqual(result.destination.libraryURL, result.sourceProject.libraryURL)
        let xml = String(decoding: result.data, as: UTF8.self)
        XCTAssertFalse(xml.contains("<event name=\"Cutdown Analysis\""))
        XCTAssertTrue(xml.contains("6dB")); XCTAssertTrue(xml.contains("srcCh=\"1, 2\""))
        XCTAssertTrue(xml.contains("value=\"-1\"")); XCTAssertTrue(xml.contains("role=\"dialogue.dialogue-1\""))
        XCTAssertFalse(xml.contains("name=\"Neighbor\"")); XCTAssertFalse(xml.contains("<filter-audio ref=\"c\""))
        XCTAssertEqual(data, fixture())
    }
    func testRoundTripRejectsProcessingTimingMediaAndIdentityChanges() throws {
        let source = String(decoding: fixture(), as: UTF8.self)
        XCTAssertTrue(try ProjectRoundTripVerification.compare(expected: fixture(), actual: fixture()).verified)
        for (before, after) in [("6dB", "0dB"), ("value=\"-1\"", "value=\"-6\""), ("3602s", "3601s"),
                                ("Voice.wav", "Other.wav"), ("uid=\"original\"", "uid=\"other\""),
                                ("duration=\"8s\"", "duration=\"9s\"")] {
            let changed = Data(source.replacingOccurrences(of: before, with: after).utf8)
            let url = directory.appendingPathComponent("Report.json")
            XCTAssertThrowsError(try ProjectRoundTripVerification.verify(expected: fixture(), actual: changed, reportURL: url))
            XCTAssertFalse(try JSONDecoder().decode(ProjectRoundTripReport.self, from: Data(contentsOf: url)).verified)
        }
    }
    func testImportedHostIdentityIsBoundWithoutIgnoringProjectContents() throws {
        let source = String(decoding: fixture(), as: UTF8.self)
        let imported = Data(source.replacingOccurrences(of: "uid=\"original\"", with: "uid=\"host-generated\"").utf8)
        XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: fixture(), actual: imported).verified)
        XCTAssertTrue(try ProjectRoundTripVerification.compare(expected: fixture(), actual: imported, allowHostAssignedIdentity: true).verified)
        let wrongEffects = Data(String(decoding: imported, as: UTF8.self).replacingOccurrences(of: "6dB", with: "0dB").utf8)
        XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: fixture(), actual: wrongEffects, allowHostAssignedIdentity: true).verified)
        let missingIdentity = Data(source.replacingOccurrences(of: "uid=\"original\"", with: "").utf8)
        XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: fixture(), actual: missingIdentity, allowHostAssignedIdentity: true).verified)
    }

    func testRoundTripAllowsEquivalentRationalTimesAndControllerPresetMetadata() throws {
        let source = String(decoding: fixture(), as: UTF8.self)
        let changed = source.replacingOccurrences(of: "duration=\"5s\"", with: "duration=\"150/30s\"")
            .replacingOccurrences(of: "<filter-audio ref=\"c\"", with: "<filter-audio presetID=\"saved\" ref=\"c\"")
        XCTAssertTrue(try ProjectRoundTripVerification.compare(expected: fixture(), actual: Data(changed.utf8)).verified)
    }

    func testRenderDeliveryCanVerifyIsolationWithoutEarlierXMLExport() throws {
        let isolated = try IsolatedAudioProject.make(projectData: fixture(),
            selection: .init(timelineRange: .init(start: .init(3), end: .init(8))))
        let uid = try XCTUnwrap(TimelineParser.parse(data: isolated.data).projectUID)
        let delivered = String(decoding: isolated.data, as: UTF8.self)
            .replacingOccurrences(of: "uid=\"\(uid)\"", with: "uid=\"host-render-project\"")
        let report = directory.appendingPathComponent("Render-Verification.json")
        XCTAssertNoThrow(try ProjectRoundTripVerification.verify(expected: isolated.data,
            actual: Data(delivered.utf8), reportURL: report, allowHostAssignedIdentity: true))
        XCTAssertEqual(try JSONDecoder().decode(ProjectRoundTripReport.self,
            from: Data(contentsOf: report)).actualProjectUID, "host-render-project")

        // Binding the new host UUID must not mask a wrong mix, dropped effect,
        // changed source trim, or wrong project in the combined XML/audio Share.
        for (before, after) in [("6dB", "0dB"), ("value=\"-1\"", "value=\"-6\""),
                                ("3602s", "3601s"), ("Voice.wav", "Other.wav"),
                                (isolated.name, "Other project"), ("audioRole=\"dialogue\"", "audioRole=\"music\""),
                                ("uid=\"host-render-project\"", "")] {
            XCTAssertTrue(delivered.contains(before), "Mutation must change the fixture")
            XCTAssertThrowsError(try ProjectRoundTripVerification.verify(expected: isolated.data,
                actual: Data(delivered.replacingOccurrences(of: before, with: after).utf8),
                reportURL: report, allowHostAssignedIdentity: true))
        }
    }
}
