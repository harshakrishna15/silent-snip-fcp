import Foundation
import SilentSnipCore
import XCTest
#if canImport(FoundationXML)
import FoundationXML
#endif
@testable import SilentSnipMac

final class VoiceOverProjectTests: XCTestCase {
    private var folder: URL!
    private var library: URL { folder.appendingPathComponent("VoiceOver.fcpbundle") }
    private var voice: URL { folder.appendingPathComponent("Narration.wav") }
    private var neighbor: URL { folder.appendingPathComponent("Other.wav") }
    private let event = "A03E842C-BA8A-4FA9-9274-BA8241DC4457"
    private let selection = TimelineSelection(timelineRange: .init(start: .init(3), end: .init(13)))
    private let cuts = [TimeRange(start: .init(5), end: .init(6)), TimeRange(start: .init(9), end: .init(11))]

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceOver-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("voice source".utf8).write(to: voice)
        try Data("unrelated source".utf8).write(to: neighbor)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private func fixture() -> Data {
        Data("""
        <fcpxml version="1.11"><resources><format id="f" frameDuration="1/30s"/>
        <asset id="v" name="Narration" start="3600s" duration="30s" hasAudio="1"><media-rep kind="original-media" src="\(voice.absoluteString)"/></asset>
        <asset id="n" name="Other" start="0s" duration="4s" hasAudio="1"><media-rep kind="original-media" src="\(neighbor.absoluteString)"/></asset>
        <effect id="ss" name="Silent Snip Audio" uid="\(AudioControllerSettings.effectUID)"/>
        <effect id="gate" name="Noise Gate" uid="test-gate"/><effect id="limiter" name="Limiter" uid="test-limiter"/>
        </resources><library location="\(library.absoluteString)"><event name="Voice-over Event" uid="\(event)">
        <project name="Original Edit" uid="original-project"><sequence format="f" duration="17s" tcStart="7200s"><spine>
        <gap name="Lead-in" offset="7200s" start="0s" duration="3s"/>
        <asset-clip ref="v" name="Narration" offset="7203s" start="3602s" duration="10s" audioRole="dialogue">
        <adjust-volume amount="-3dB"/>
        <filter-audio ref="gate" name="Noise Gate"><param key="threshold" value="-35"/></filter-audio>
        <filter-audio ref="limiter" name="Limiter" enabled="0"><param key="gain" value="2"/></filter-audio>
        <filter-audio ref="ss" name="Silent Snip Audio"/>
        </asset-clip><asset-clip ref="n" name="Other" offset="7213s" start="0s" duration="4s" audioRole="dialogue"/>
        </spine></sequence></project></event></library></fcpxml>
        """.utf8)
    }

    private func prepare(mode: SilentSnipOutputMode = .remove) throws -> PreparedXMLProject {
        try XMLProjectApply.prepare(projectData: fixture(), selection: selection, cuts: cuts,
            settings: .defaults, mode: mode, outputName: "Narration — Cleaned — Test",
            directory: folder.appendingPathComponent("Result"), selectedClipOnly: true, useOriginalEvent: true, omitController: true)
    }

    func testSelectedRecordingBecomesSeparateProjectAtZeroWithOriginalSourceTrimsAndEffects() throws {
        let input = fixture()
        XCTAssertEqual(try ClipAudioAnalysisRoute.resolve(projectData: input, selection: selection), .finalCutRender)
        let prepared = try prepare()
        let result = try TimelineParser.parse(data: prepared.output.xmlData)
        XCTAssertEqual(result.projectRange.duration, .init(7))
        XCTAssertEqual(result.projectTimecodeStart, .zero)
        XCTAssertEqual(result.clips.count, 3)
        XCTAssertEqual(result.clips.map(\.sourceStart), [.init(3602), .init(3605), .init(3610)])
        XCTAssertEqual(result.clips.map(\.timelineRange.start), [.zero, .init(2), .init(5)])
        XCTAssertTrue(result.clips.allSatisfy { $0.mediaURL == voice && $0.hasAudio && !$0.hasVideo })
        let original = try TimelineParser.parse(data: input).selectedTarget(selection)
        let processingReference = try XMLDocument(data: input)
        for detector in try processingReference.nodes(forXPath: "//filter-audio[@ref='ss']") { detector.detach() }
        let expected = try TimelineParser.parse(data: processingReference.xmlData).selectedTarget(selection)
        XCTAssertTrue(result.clips.allSatisfy { $0.effectsFingerprint == expected.effectsFingerprint })
        XCTAssertEqual(result.clips.first?.sourceFileStart, original.sourceFileStart)
        XCTAssertNil(prepared.output.report.replacementTarget)
        XCTAssertEqual(prepared.output.report.eventUID.uuidString, event)
        let xml = try XMLDocument(data: prepared.output.xmlData)
        XCTAssertEqual(try xml.nodes(forXPath: "//spine/asset-clip/filter-audio[@ref='ss']").count, 0,
                       "Keep all sound-processing effects, while leaving the passthrough detector on the original")
        XCTAssertEqual(try xml.nodes(forXPath: "//event/@name").first?.stringValue, "Voice-over Event")
        XCTAssertEqual(try xml.nodes(forXPath: "//event/project").count, 1)
        XCTAssertEqual(try xml.nodes(forXPath: "//filter-audio[@ref='gate']/param[@key='threshold']/@value").map(\.stringValue), ["-35", "-35", "-35"])
        XCTAssertEqual(try xml.nodes(forXPath: "//filter-audio[@ref='limiter']/@enabled").map(\.stringValue), ["0", "0", "0"])
        XCTAssertEqual(try xml.nodes(forXPath: "//adjust-volume/@amount").map(\.stringValue), ["-3dB", "-3dB", "-3dB"])
        XCTAssertEqual(try xml.nodes(forXPath: "//spine/asset-clip[@name='Other']").count, 0)
        XCTAssertEqual(input, fixture())
        XCTAssertEqual(try TimelineParser.parse(url: prepared.recoveryURL).fingerprint,
                       try TimelineParser.parse(data: input).fingerprint)
    }

    func testFullProjectCopyKeepsNeighborsAndLinkedVideoWithEditableEffects() throws {
        let input = Data(String(decoding: fixture(), as: UTF8.self)
            .replacingOccurrences(of: "hasAudio=\"1\"", with: "hasAudio=\"1\" hasVideo=\"1\"").utf8)
        let prepared = try XMLProjectApply.prepare(projectData: input, selection: selection, cuts: cuts,
            settings: .defaults, mode: .remove, outputName: "Full Edit — Cleaned",
            directory: folder.appendingPathComponent("Full Result"), selectedClipOnly: false,
            useOriginalEvent: true, omitController: true)
        let result = try TimelineParser.parse(data: prepared.output.xmlData)
        XCTAssertEqual(result.projectRange.duration, .init(14))
        XCTAssertEqual(result.projectTimecodeStart, .init(7200))
        XCTAssertEqual(result.clips.first?.name, "Lead-in")
        let neighbor = try XCTUnwrap(result.clips.last)
        XCTAssertEqual(neighbor.name, "Other")
        XCTAssertEqual(neighbor.timelineRange, .init(start: .init(10), end: .init(14)))
        XCTAssertTrue(neighbor.hasVideo && neighbor.hasAudio)
        let segments = result.clips.filter { $0.name == "Narration" }
        XCTAssertEqual(segments.count, 3)
        XCTAssertTrue(segments.allSatisfy { $0.hasVideo && $0.hasAudio })
        XCTAssertEqual(segments.map(\.sourceStart), [.init(3602), .init(3605), .init(3610)])
        XCTAssertEqual(segments.map(\.timelineRange.start), [.init(3), .init(5), .init(8)])
        XCTAssertEqual(try XMLDocument(data: prepared.output.xmlData).nodes(forXPath: "//filter-audio[@ref='gate']").count, 3)
        XCTAssertEqual(try TimelineParser.parse(url: prepared.recoveryURL).fingerprint,
                       try TimelineParser.parse(data: input).fingerprint)
    }

    func testGapOutputUsesSelectedRecordingClockAndKeepsOriginalEvent() throws {
        let prepared = try prepare(mode: .gaps)
        let output = try TimelineParser.parse(data: prepared.output.xmlData)
        XCTAssertEqual(output.projectRange.duration, .init(9))
        XCTAssertEqual(output.clips.filter { $0.kind == "gap" }.map(\.timelineRange), [
            .init(start: .init(2), end: .init(3)), .init(start: .init(6), end: .init(7))])
        XCTAssertTrue(output.clips.filter(\.hasAudio).allSatisfy { $0.mediaURL == voice })
        XCTAssertEqual(prepared.output.report.retainedSegments.map(\.originalProjectRange), [
            .init(start: .init(3), end: .init(5)), .init(start: .init(6), end: .init(9)),
            .init(start: .init(11), end: .init(13))])
    }

    func testSeparateOutputCannotReplaceOriginalOrReuseItsName() throws {
        XCTAssertThrowsError(try EditedProjectWriter.write(projectData: fixture(), selection: selection,
            selectedRanges: cuts, outputName: "Original Edit", replaceOriginal: true, selectedClipOnly: true))
        XCTAssertThrowsError(try EditedProjectWriter.write(projectData: fixture(), selection: selection,
            selectedRanges: cuts, outputName: "Original Edit", selectedClipOnly: true, useOriginalEvent: true))
    }

    @MainActor func testVerificationUsesSelectedSourceEvidenceAndRejectsChangedEffectsOrDestination() async throws {
        let prepared = try prepare()
        let fullMedia = try await MediaContentSnapshot.capture([voice, neighbor])
        let selectedMedia = try fullMedia.restricting(to: [voice])
        let currentVoice = try await MediaContentSnapshot.capture([voice])
        XCTAssertEqual(selectedMedia, currentVoice)
        XCTAssertThrowsError(try fullMedia.restricting(to: [folder.appendingPathComponent("Unknown.wav")]))
        let receipt = try ImportedResultVerification(expected: prepared.output.xmlData, outputURL: prepared.outputURL,
            originalProjectName: "Original Edit", request: .init(id: UUID(), settings: .defaults, outputMode: .remove),
            sourceMedia: selectedMedia)
        try receipt.savePending()
        let loaded = try ImportedResultVerification.load(outputURL: prepared.outputURL)
        let host = try XMLDocument(data: prepared.output.xmlData)
        try host.nodes(forXPath: "//project/@uid").first?.stringValue = "host-created-result"
        let correct = host.xmlData
        for (before, after) in [("value=\"-35\"", "value=\"-20\""),
                                ("Voice-over Event", "Other Event"),
                                (event, "A03E842C-BA8A-4FA9-9274-BA8241DC4458")] {
            let wrong = Data(String(decoding: correct, as: UTF8.self).replacingOccurrences(of: before, with: after).utf8)
            do {
                _ = try await loaded.verify(capture: { wrong }, restore: { _, _ in XCTFail("Wrong output must never receive settings") })
                XCTFail("Changed effects or destination must stop verification")
            } catch {}
        }
        let report = try await loaded.verify(capture: { correct }, restore: { _, _ in XCTFail("Settings already preserved") })
        XCTAssertTrue(report.verified)
        XCTAssertEqual(report.sourceMediaVerified, true)
        XCTAssertNil(report.controllerSettingsPreserved, "The cleaned result has no detector state to recover")
    }
}
