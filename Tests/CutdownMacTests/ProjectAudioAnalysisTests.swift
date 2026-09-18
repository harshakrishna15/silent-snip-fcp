import CutdownCore
import Foundation
import XCTest
@testable import CutdownMac

final class ProjectAudioAnalysisTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CutdownProjectAudio-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testImmutableCaptureBytesProduceSameCutsWithoutReopeningXML() async throws {
        let fixture = try fixture()
        let expected = try await analyze(fixture)
        let context = try renderContext(fixture, document: fixture.document)
        let projectData = try Data(contentsOf: fixture.xml)
        try FileManager.default.removeItem(at: fixture.xml)
        let result = try await ProjectAudioAnalysis.analyze(projectData: projectData,
            selection: fixture.selection, dialogueAudio: fixture.audio, renderContext: context,
            settings: .defaults, jobID: UUID(), capturedMedia: nil)
        XCTAssertEqual(result.document.fingerprint, expected.document.fingerprint)
        XCTAssertEqual(result.review.selectedCuts.map(\.range), expected.review.selectedCuts.map(\.range))
        let changed = Data(String(decoding: projectData, as: UTF8.self)
            .replacingOccurrences(of: "tcStart=\"0s\"", with: "tcStart=\"1s\"").utf8)
        do {
            _ = try await ProjectAudioAnalysis.analyze(projectData: changed,
                selection: fixture.selection, dialogueAudio: fixture.audio, renderContext: context,
                settings: .defaults, jobID: UUID(), capturedMedia: nil)
            XCTFail("In-memory input still requires the captured project fingerprint")
        } catch { }
    }

    func testIsolatedRenderMapsBackToTrimmedNonzeroTimelineAndMusicRole() async throws {
        let fixture = try fixture()
        let effect = "<effect id=\"au\" uid=\"\(AudioControllerSettings.effectUID)\"/>"
        let xml = try String(contentsOf: fixture.xml)
            .replacingOccurrences(of: "</resources>", with: effect + "</resources>")
            .replacingOccurrences(of: "duration=\"3s\" tcStart=\"0s\"", with: "duration=\"6s\" tcStart=\"7200s\"")
            .replacingOccurrences(of: "<spine>", with: "<spine><gap offset=\"7200s\" start=\"0s\" duration=\"3s\"/>")
            .replacingOccurrences(of: "offset=\"0s\"", with: "offset=\"7203s\"")
            .replacingOccurrences(of: "audioRole=\"dialogue\"/>", with: "audioRole=\"music\"><filter-audio ref=\"au\"/></asset-clip>")
        try xml.write(to: fixture.xml, atomically: true, encoding: .utf8)
        let document = try TimelineParser.parse(url: fixture.xml, exclusions: .init(controllerEffectUIDs: [AudioControllerSettings.effectUID]))
        let selection = TimelineSelection(timelineRange: .init(start: .init(3), end: .init(6)))
        let target = try document.selectedTarget(selection)
        let context = try DialogueRenderContext.capturedIsolated(document: document, target: target, audioURL: fixture.audio)
        let result = try await ProjectAudioAnalysis.analyze(projectXML: fixture.xml, selection: selection,
            dialogueAudio: fixture.audio, renderContext: context)
        XCTAssertEqual(result.target.sourceFileStart, .init(1))
        XCTAssertEqual(result.audio.windows.first?.range.start, .init(3))
        XCTAssertEqual(result.review.selectedCuts.map(\.range), [.init(start: .init(41, 10), end: .init(49, 10))])
        let shortAudio = try wave(frames: 48_000, channels: 1) { _, _ in 8_192 }
        let shortContext = try DialogueRenderContext.capturedIsolated(document: document, target: target, audioURL: shortAudio)
        do {
            _ = try await ProjectAudioAnalysis.analyze(projectXML: fixture.xml, selection: selection,
                dialogueAudio: shortAudio, renderContext: shortContext)
            XCTFail("Truncated render must fail")
        } catch { }
    }

    func testTrimmedAudioOnlyClipProducesReviewedCutsAndSourceMarkers() async throws {
        let fixture = try fixture()
        let result = try await analyze(fixture)
        XCTAssertTrue(result.isAudioOnlyTarget)
        XCTAssertEqual(result.target.sourceStart, RationalTime(1))
        XCTAssertEqual(result.review.selectedCuts.map(\.range), [
            TimeRange(start: RationalTime(11, 10), end: RationalTime(19, 10))
        ])
        XCTAssertEqual(try result.review.selectedDuration, RationalTime(4, 5))
        let preview = try MarkerPreview(review: result.review, existingMarkers: result.document.markers)
        XCTAssertEqual(preview.additions.map(\.sourcePosition), [RationalTime(21, 10), RationalTime(43, 15)])
    }

    func testDialogueInSecondChannelProtectsAudioOnlyTarget() async throws {
        let fixture = try fixture(channels: 2) { frame, channel in
            (48_000..<96_000).contains(frame) && channel == 0 ? 0 : 8_192
        }
        let result = try await analyze(fixture)
        XCTAssertEqual(result.analysis.disposition, .noSilence)
        XCTAssertTrue(result.review.selectedCuts.isEmpty)
    }

    func testProcessedRenderProtectsQuietSourceAndRejectsLaterEffectChange() async throws {
        // Model a +20 dB host render: the middle second is -54 dBFS in the
        // source, but -34 dBFS after processing. Detection must use the render.
        let fixture = try fixture { frame, _ in (48_000..<96_000).contains(frame) ? 654 : 8_192 }
        let source = try wave(frames: 240_000, channels: 1) { frame, _ in
            (96_000..<144_000).contains(frame) ? 65 : 819
        }
        let original = try String(contentsOf: fixture.xml)
        let sourcePath = try XCTUnwrap(fixture.document.clips.first?.mediaURL?.absoluteString)
        let xml = original.replacingOccurrences(of: sourcePath, with: source.absoluteString)
            .replacingOccurrences(of: "audioRole=\"dialogue\"/>",
                                  with: "audioRole=\"dialogue\"><adjust-volume amount=\"20dB\"/></asset-clip>")
        try xml.write(to: fixture.xml, atomically: true, encoding: .utf8)
        let document = try TimelineParser.parse(url: fixture.xml)
        let settings = try AnalysisSettings(thresholdDBFS: -50, minimumSilenceDuration: 0.2)
        let context = try renderContext(fixture, document: document)
        let result = try await ProjectAudioAnalysis.analyze(projectXML: fixture.xml, selection: fixture.selection,
            dialogueAudio: fixture.audio, renderContext: context, settings: settings)
        XCTAssertTrue(result.review.selectedCuts.isEmpty)
        let raw = try await SourceAudioReader.read(url: source,
            range: TimeRange(start: RationalTime(1), end: RationalTime(4)), timelineStart: .zero, windowDuration: 0.01)
        let rawAnalysis = try SilenceDetector.analyze(windows: raw.windows, target: result.target.timelineRange,
            frameDuration: document.frameDuration, settings: settings)
        XCTAssertEqual(rawAnalysis.candidates.count, 1, "Source-only analysis would incorrectly cut this sound")
        try xml.replacingOccurrences(of: "20dB", with: "0dB").write(to: fixture.xml, atomically: true, encoding: .utf8)
        do {
            _ = try await ProjectAudioAnalysis.analyze(projectXML: fixture.xml, selection: fixture.selection,
                dialogueAudio: fixture.audio, renderContext: context, settings: settings)
            XCTFail("Changing processing must invalidate the rendered measurements")
        } catch ProjectAnalysisError.staleRender { }
    }

    func testGatedRenderFindsSilenceThatSourceAudioDoesNotContain() async throws {
        // Synthetic rendered samples model a gate suppressing background noise.
        // This tests render consumption, not the DSP of an installed Noise Gate.
        let fixture = try fixture { frame, _ in (48_000..<96_000).contains(frame) ? 0 : 8_192 }
        let source = try wave(frames: 240_000, channels: 1) { _, _ in 8_192 }
        let original = try String(contentsOf: fixture.xml)
        let sourcePath = try XCTUnwrap(fixture.document.clips.first?.mediaURL?.absoluteString)
        let xml = original.replacingOccurrences(of: sourcePath, with: source.absoluteString)
            .replacingOccurrences(of: "</resources>",
                with: "<effect id=\"gate\" uid=\"test-noise-gate\"/><effect id=\"controller\" uid=\"\(AudioControllerSettings.effectUID)\"/></resources>")
            .replacingOccurrences(of: "audioRole=\"dialogue\"/>",
                with: "audioRole=\"dialogue\"><filter-audio ref=\"gate\" name=\"Noise Gate\"><param name=\"Threshold\" key=\"1\" value=\"-25\"/></filter-audio><filter-audio ref=\"controller\"/></asset-clip>")
        try xml.write(to: fixture.xml, atomically: true, encoding: .utf8)
        let document = try TimelineParser.parse(url: fixture.xml)
        let target = try document.selectedTarget(fixture.selection)
        let context = try DialogueRenderContext.capturedIsolated(document: document, target: target, audioURL: fixture.audio)
        let result = try await ProjectAudioAnalysis.analyze(projectXML: fixture.xml, selection: fixture.selection,
            dialogueAudio: fixture.audio, renderContext: context)
        XCTAssertEqual(result.review.selectedCuts.map(\.range), [.init(start: .init(11, 10), end: .init(19, 10))])
        let raw = try await SourceAudioReader.read(url: source,
            range: .init(start: .init(1), end: .init(4)), timelineStart: .zero, windowDuration: 0.01)
        XCTAssertTrue(try SilenceDetector.analyze(windows: raw.windows, target: target.timelineRange,
            frameDuration: document.frameDuration, settings: AnalysisSettings()).candidates.isEmpty)
        let output = try EditedProjectWriter.write(projectData: Data(xml.utf8), selection: fixture.selection,
            selectedRanges: result.review.selectedCuts.map(\.range), outputName: "Gated cuts")
        XCTAssertEqual(try TimelineParser.parse(data: output.xmlData).clips.count, 2)
    }

    func testVideoWithAudioTargetRejectsBeforeOpeningDialogueRender() async throws {
        let fixture = try fixture()
        let xml = try String(contentsOf: fixture.xml)
            .replacingOccurrences(of: "hasAudio=\"1\"", with: "hasVideo=\"1\" hasAudio=\"1\"")
        try xml.write(to: fixture.xml, atomically: true, encoding: .utf8)
        let document = try TimelineParser.parse(url: fixture.xml)
        let context = try renderContext(fixture, document: document)
        do {
            _ = try await ProjectAudioAnalysis.analyze(projectXML: fixture.xml, selection: fixture.selection,
                dialogueAudio: directory.appendingPathComponent("not-the-render.wav"), renderContext: context)
            XCTFail("A video-with-audio target must not produce an analysis or reach audio decoding.")
        } catch TimelineError.unsupportedTarget(let reasons) {
            XCTAssertTrue(reasons.contains { $0.contains("audio-only") })
        }
    }

    func testAudioOnlyTimelineInstanceOfAVSourceRemainsSupported() async throws {
        let fixture = try fixture()
        let xml = try String(contentsOf: fixture.xml)
            .replacingOccurrences(of: "hasAudio=\"1\"", with: "hasVideo=\"1\" hasAudio=\"1\"")
            .replacingOccurrences(of: "<asset-clip ref=", with: "<asset-clip srcEnable=\"audio\" ref=")
        try xml.write(to: fixture.xml, atomically: true, encoding: .utf8)
        let document = try TimelineParser.parse(url: fixture.xml)
        let result = try await ProjectAudioAnalysis.analyze(projectXML: fixture.xml, selection: fixture.selection,
            dialogueAudio: fixture.audio, renderContext: renderContext(fixture, document: document))
        XCTAssertFalse(result.target.hasVideo)
        XCTAssertTrue(result.target.hasAudio)
        XCTAssertEqual(result.review.selectedCuts.count, 1)
    }

    func testSurroundingVideoRemainsInContextWithoutBecomingAnEditableTarget() async throws {
        let fixture = try fixture()
        let resource = """
        <asset id="broll" name="B-roll" start="0s" duration="3s" hasVideo="1" hasAudio="0">
        <media-rep kind="original-media" src="file:///fixtures/context.mov"/></asset>
        """
        let connection = """
        <asset-clip ref="broll" name="B-roll" lane="1" offset="1s" start="0s" duration="3s"/>
        """
        let xml = try String(contentsOf: fixture.xml)
            .replacingOccurrences(of: "</resources>", with: resource + "</resources>")
            .replacingOccurrences(of: "audioRole=\"dialogue\"/>", with: "audioRole=\"dialogue\">" + connection + "</asset-clip>")
        try xml.write(to: fixture.xml, atomically: true, encoding: .utf8)
        let document = try TimelineParser.parse(url: fixture.xml)
        let context = try renderContext(fixture, document: document)
        let result = try await ProjectAudioAnalysis.analyze(projectXML: fixture.xml, selection: fixture.selection,
            dialogueAudio: fixture.audio, renderContext: context)
        XCTAssertFalse(result.target.hasVideo)
        XCTAssertTrue(result.document.clips.contains { $0.name == "B-roll" && $0.hasVideo })
        XCTAssertEqual(result.review.selectedCuts.count, 1)

        let changed = xml.replacingOccurrences(of: "name=\"B-roll\" lane=\"1\" offset=\"1s\"",
                                               with: "name=\"B-roll\" lane=\"1\" offset=\"3/2s\"")
        try changed.write(to: fixture.xml, atomically: true, encoding: .utf8)
        do {
            _ = try await ProjectAudioAnalysis.analyze(projectXML: fixture.xml, selection: fixture.selection,
                dialogueAudio: fixture.audio, renderContext: context)
            XCTFail("Changes to contextual video must invalidate the captured project state.")
        } catch ProjectAnalysisError.staleRender { }
    }

    func testEntirelySilentAudioOnlyTargetHasNoApplicableCuts() async throws {
        let fixture = try fixture { _, _ in 0 }
        let result = try await analyze(fixture)
        XCTAssertEqual(result.analysis.disposition, .entirelySilent)
        XCTAssertTrue(result.review.selectedCuts.isEmpty)
    }

    func testCachedRecalculationPreservesOrResetsChoicesByRange() async throws {
        let fixture = try fixture()
        var result = try await analyze(fixture)
        try result.review.setIncluded(false, cutID: result.review.cuts[0].id)
        XCTAssertFalse(try result.recalculate(settings: AnalysisSettings(thresholdDBFS: -30)))
        XCTAssertFalse(result.review.cuts[0].included)
        XCTAssertTrue(try result.recalculate(settings: AnalysisSettings(beforeSpeechPadding: 0.2, afterSpeechPadding: 0.2)))
        XCTAssertTrue(result.review.cuts[0].included)
        XCTAssertEqual(result.review.cuts[0].range, TimeRange(start: RationalTime(6, 5), end: RationalTime(9, 5)))
    }

    func testMissingDialogueEvidenceAndStaleProjectRejectBeforeDecode() async throws {
        let fixture = try fixture()
        let doc = fixture.document
        for context in [
            try DialogueRenderContext(projectFingerprint: doc.fingerprint, projectUID: doc.projectUID,
                projectName: doc.projectName, projectRange: doc.projectRange, renderedRoles: ["music"], audioURL: fixture.audio),
            try DialogueRenderContext(projectFingerprint: "an older project", projectUID: doc.projectUID,
                projectName: doc.projectName, projectRange: doc.projectRange, renderedRoles: Set(doc.dialogueRoles), audioURL: fixture.audio)
        ] {
            do {
                _ = try await ProjectAudioAnalysis.analyze(projectXML: fixture.xml, selection: fixture.selection,
                    dialogueAudio: directory.appendingPathComponent("missing.wav"), renderContext: context)
                XCTFail("Mismatched export context must reject before decoding.")
            } catch is ProjectAnalysisError { }
        }
    }

    func testMissingPartialFrameOfAudioCannotAuthorizeEdits() async throws {
        let fixture = try fixture(renderFrames: 143_040) // 20 ms short; less than one 30 fps frame.
        do {
            _ = try await analyze(fixture)
            XCTFail("Incomplete render must not produce a reviewed edit plan.")
        } catch ProjectAnalysisError.incompleteRender { }
    }

    func testSameDurationDifferentRenderURLCannotReuseContext() async throws {
        let fixture = try fixture()
        let context = try renderContext(fixture)
        let replacement = try wave(frames: 144_000, channels: 1) { _, _ in 0 }
        do {
            _ = try await ProjectAudioAnalysis.analyze(projectXML: fixture.xml, selection: fixture.selection,
                dialogueAudio: replacement, renderContext: context)
            XCTFail("A context must not authorize a different audio artifact of the same duration.")
        } catch ProjectAnalysisError.changedRenderArtifact { }
    }

    func testSameURLWithChangedAudioBytesCannotReuseContext() async throws {
        let fixture = try fixture()
        let context = try renderContext(fixture)
        let replacement = try wave(frames: 144_000, channels: 1) { _, _ in 0 }
        try Data(contentsOf: replacement).write(to: fixture.audio)
        do {
            _ = try await ProjectAudioAnalysis.analyze(projectXML: fixture.xml, selection: fixture.selection,
                dialogueAudio: fixture.audio, renderContext: context)
            XCTFail("The content hash must detect replaced audio without relying on file duration.")
        } catch ProjectAnalysisError.changedRenderArtifact { }
    }

    func testRenderChangedAfterDecodingCannotProduceReview() async throws {
        let fixture = try fixture()
        let context = try renderContext(fixture)
        let audioURL = fixture.audio
        do {
            _ = try await ProjectAudioAnalysis.analyze(projectXML: fixture.xml, selection: fixture.selection,
                dialogueAudio: audioURL, renderContext: context, progress: { value in
                    guard value >= 1 else { return }
                    // The last PCM buffer has been decoded. Change a sample while
                    // preserving the WAV header, sample count, URL, and file size.
                    do {
                        let file = try FileHandle(forWritingTo: audioURL)
                        defer { try? file.close() }
                        try file.seek(toOffset: 44)
                        try file.write(contentsOf: Data([0, 0]))
                    } catch { XCTFail("Could not mutate completed test render: \(error)") }
                })
            XCTFail("Post-decode artifact validation must reject a changed render.")
        } catch ProjectAnalysisError.changedRenderArtifact { }
        XCTAssertEqual(Array(try Data(contentsOf: audioURL)[44..<46]), [0, 0])
    }

    func testChangedWindowDurationRequiresNewReadAndLeavesCachedReviewUntouched() async throws {
        let fixture = try fixture()
        var result = try await analyze(fixture)
        let original = result.review.cuts
        XCTAssertThrowsError(try result.recalculate(settings: AnalysisSettings(windowDuration: 0.1))) { error in
            guard case ProjectAnalysisError.changedWindowDuration = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(result.settings.windowDuration, 0.01)
        XCTAssertEqual(result.review.cuts, original)
    }

    func testKnownControllerSettingsReuseRenderButOtherAudioEffectChangesReject() async throws {
        let fixture = try fixture()
        let controllerUID = "fixture.verified.controller"
        let effects = """
        <effect id="r3" uid="\(controllerUID)"/><effect id="r4" uid="fixture.ordinary.audio-effect"/>
        """
        let filters = """
        <filter-audio ref="r3"><param name="Threshold" key="1" value="-40"/></filter-audio>
        <filter-audio ref="r4"><param name="Gain" key="1" value="-3"/></filter-audio>
        """
        let original = try String(contentsOf: fixture.xml)
            .replacingOccurrences(of: "</resources>", with: effects + "</resources>")
            .replacingOccurrences(of: "audioRole=\"dialogue\"/>", with: "audioRole=\"dialogue\">" + filters + "</asset-clip>")
        try original.write(to: fixture.xml, atomically: true, encoding: .utf8)
        let exclusions = TimelineFingerprintExclusions(controllerEffectUIDs: [controllerUID])
        let baseline = try TimelineParser.parse(url: fixture.xml, exclusions: exclusions)
        let context = try renderContext(fixture, document: baseline, controllerEffectUIDs: [controllerUID])
        let changedController = original.replacingOccurrences(of: "value=\"-40\"", with: "value=\"-30\"")
        try changedController.write(to: fixture.xml, atomically: true, encoding: .utf8)
        let result = try await ProjectAudioAnalysis.analyze(projectXML: fixture.xml, selection: fixture.selection,
            dialogueAudio: fixture.audio, renderContext: context, settings: AnalysisSettings(thresholdDBFS: -30))
        XCTAssertEqual(result.review.baselineFingerprint, baseline.fingerprint)
        XCTAssertEqual(result.settings.thresholdDBFS, -30)
        let changedAudio = changedController.replacingOccurrences(of: "value=\"-3\"", with: "value=\"-6\"")
        try changedAudio.write(to: fixture.xml, atomically: true, encoding: .utf8)
        do {
            _ = try await ProjectAudioAnalysis.analyze(projectXML: fixture.xml, selection: fixture.selection,
                dialogueAudio: fixture.audio, renderContext: context)
            XCTFail("A real audio processing change must invalidate the render.")
        } catch ProjectAnalysisError.staleRender { }
    }

    func testNativeControllerMismatchRejectsBeforeOpeningDialogueAudio() async throws {
        let fixture = try fixture()
        let uid = AudioControllerSettings.effectUID
        let effect = "<effect id=\"au\" name=\"Cutdown Audio\" uid=\"\(uid)\"/>"
        let filter = """
        <filter-audio ref="au"><data key="effectState">b3BhcXVl</data>
        <param name="Silence Threshold" key="4037165010" value="-40"/>
        <param name="Minimum Silence" key="3342540801" value="0.5"/>
        <param name="Before Speech" key="4090893112" value="0.1"/>
        <param name="After Speech" key="252981911" value="0.25"/></filter-audio>
        """
        let xml = try String(contentsOf: fixture.xml)
            .replacingOccurrences(of: "</resources>", with: effect + "</resources>")
            .replacingOccurrences(of: "audioRole=\"dialogue\"/>", with: "audioRole=\"dialogue\">" + filter + "</asset-clip>")
        try xml.write(to: fixture.xml, atomically: true, encoding: .utf8)
        let document = try TimelineParser.parse(url: fixture.xml, exclusions: .init(controllerEffectUIDs: [uid]))
        let context = try renderContext(fixture, document: document, controllerEffectUIDs: [uid])
        do {
            _ = try await ProjectAudioAnalysis.analyze(projectXML: fixture.xml, selection: fixture.selection,
                dialogueAudio: directory.appendingPathComponent("not-the-render.wav"), renderContext: context)
            XCTFail("A stale AU request must fail before attempting to read an audio artifact.")
        } catch let error as AudioControllerSettingsError {
            XCTAssertEqual(error, .settingsMismatch(["After Speech"]))
        }
    }

    func testDirectSourceTrimTimecodeAndRepeatedOccurrenceProduceEditableCuts() async throws {
        let fixture = try fixture()
        let source = try wave(frames: 240_000, channels: 2) { frame, _ in
            (96_000..<144_000).contains(frame) ? 0 : 8_192
        }
        let xml = try String(contentsOf: fixture.xml)
            .replacingOccurrences(of: fixture.document.clips[0].mediaURL!.absoluteString, with: source.absoluteString)
            .replacingOccurrences(of: "start=\"0s\" duration=\"5s\"", with: "start=\"3600s\" duration=\"5s\"")
            .replacingOccurrences(of: "start=\"1s\"", with: "start=\"3601s\"")
            .replacingOccurrences(of: "duration=\"3s\" tcStart=\"0s\"", with: "duration=\"6s\" tcStart=\"7200s\"")
            .replacingOccurrences(of: "offset=\"0s\"", with: "offset=\"7200s\"")
            .replacingOccurrences(of: "audioRole=\"dialogue\"", with: "audioRole=\"music\"")
            .replacingOccurrences(of: "</spine>", with: "<asset-clip ref=\"r2\" offset=\"7203s\" start=\"3601s\" duration=\"3s\" audioRole=\"music\"/></spine>")
        try xml.write(to: fixture.xml, atomically: true, encoding: .utf8)
        let document = try TimelineParser.parse(url: fixture.xml)
        let selection = TimelineSelection(timelineRange: TimeRange(start: RationalTime(3), end: RationalTime(6)))
        let context = try DialogueRenderContext(projectFingerprint: document.fingerprint,
            projectUID: document.projectUID, projectName: document.projectName, projectRange: document.projectRange,
            renderedRoles: [], audioURL: source, sourceRange: TimeRange(start: RationalTime(1), end: RationalTime(4)))
        let result = try await AudioProjectProcessor.process(projectXML: fixture.xml, selection: selection,
            dialogueAudio: source, renderContext: context, outputDirectory: directory.appendingPathComponent("cuts"),
            outputName: "Source cuts")
        XCTAssertEqual(result.analyzed.audio.windows.count, 300)
        XCTAssertEqual(result.analyzed.target.sourceFileStart, RationalTime(1))
        XCTAssertEqual(result.analyzed.review.selectedCuts.map(\.range), [
            TimeRange(start: RationalTime(41, 10), end: RationalTime(49, 10))])
        XCTAssertEqual(result.artifacts?.report.analysisScope, "selected-source-audio")
        XCTAssertEqual(result.artifacts?.report.assertedDialogueRoles, [])
        let edited = try TimelineParser.parse(url: XCTUnwrap(result.artifacts?.editedXML))
        XCTAssertEqual(edited.clips.count, 3)
        XCTAssertEqual(edited.clips[0].timelineRange, document.clips[0].timelineRange)
        XCTAssertEqual(edited.clips[0].sourceStart, document.clips[0].sourceStart)
        XCTAssertEqual(edited.projectRange.duration, RationalTime(26, 5))
    }

    func testDirectSourceUsesLoudestChannelAndRejectsIncompleteTrim() async throws {
        let source = try wave(frames: 96_000, channels: 2) { _, channel in channel == 0 ? 0 : 8_192 }
        let audio = try await SourceAudioReader.read(url: source,
            range: TimeRange(start: RationalTime(1, 2), end: RationalTime(3, 2)),
            timelineStart: RationalTime(10), windowDuration: 0.01)
        XCTAssertEqual(audio.windows.count, 100)
        let analysis = try SilenceDetector.analyze(windows: audio.windows,
            target: TimeRange(start: RationalTime(10), end: RationalTime(11)),
            frameDuration: RationalTime(1, 30), settings: .defaults)
        XCTAssertEqual(analysis.disposition, .noSilence)
        do {
            _ = try await SourceAudioReader.read(url: source, range: TimeRange(start: .zero, end: RationalTime(3)),
                timelineStart: .zero, windowDuration: 0.01)
            XCTFail("Truncated source must fail")
        } catch SourceAudioError.incompleteAudio {}
    }

    func testDirectSourceFractionalSampleBoundsKeepEntireSilenceUnavailable() async throws {
        let source = try wave(frames: 96_000, channels: 1) { _, _ in 0 }
        let range = TimeRange(start: RationalTime(1, 7), end: RationalTime(8, 7))
        let audio = try await SourceAudioReader.read(url: source, range: range,
            timelineStart: RationalTime(1001, 30000), windowDuration: 0.01)
        let target = TimeRange(start: RationalTime(1001, 30000), end: RationalTime(31001, 30000))
        let analysis = try SilenceDetector.analyze(windows: audio.windows, target: target,
            frameDuration: RationalTime(1001, 30000), settings: .defaults)
        XCTAssertEqual(analysis.disposition, .entirelySilent)
        XCTAssertTrue(analysis.candidates.isEmpty)
    }

    private struct Fixture {
        let xml: URL
        let audio: URL
        let document: TimelineDocument
        let selection = TimelineSelection(timelineRange: TimeRange(start: .zero, end: RationalTime(3)))
    }

    private func analyze(_ fixture: Fixture) async throws -> AnalyzedAudioProject {
        return try await ProjectAudioAnalysis.analyze(projectXML: fixture.xml, selection: fixture.selection,
            dialogueAudio: fixture.audio, renderContext: renderContext(fixture))
    }

    private func renderContext(_ fixture: Fixture, document: TimelineDocument? = nil,
                               controllerEffectUIDs: Set<String> = []) throws -> DialogueRenderContext {
        let doc = document ?? fixture.document
        return try DialogueRenderContext(projectFingerprint: doc.fingerprint, projectUID: doc.projectUID,
            projectName: doc.projectName, projectRange: doc.projectRange, renderedRoles: Set(doc.dialogueRoles),
            audioURL: fixture.audio, controllerEffectUIDs: controllerEffectUIDs)
    }

    private func fixture(channels: Int = 1, renderFrames: Int = 144_000,
                         sample: (Int, Int) -> Int16 = { frame, _ in
        (48_000..<96_000).contains(frame) ? 0 : 8_192
    }) throws -> Fixture {
        let source = try wave(frames: 240_000, channels: channels) { _, _ in 8_192 }
        let render = try wave(frames: renderFrames, channels: channels, sample: sample)
        let xml = directory.appendingPathComponent("Project.fcpxml")
        try Data("""
        <fcpxml version="1.14"><resources>
        <format id="r1" frameDuration="1/30s" width="1920" height="1080"/>
        <asset id="r2" name="Voice" start="0s" duration="5s" hasAudio="1" audioSources="1" audioChannels="\(channels)">
        <media-rep kind="original-media" src="\(source.absoluteString)"/></asset></resources>
        <library><event><project name="Audio-only" uid="audio-project"><sequence format="r1" duration="3s" tcStart="0s">
        <spine><asset-clip ref="r2" name="Voice" offset="0s" start="1s" duration="3s" audioRole="dialogue"/></spine>
        </sequence></project></event></library></fcpxml>
        """.utf8).write(to: xml)
        return Fixture(xml: xml, audio: render, document: try TimelineParser.parse(url: xml))
    }

    private func wave(frames: Int, channels: Int, sample: (Int, Int) -> Int16) throws -> URL {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        let bytes = frames * channels * 2
        text("RIFF"); integer(UInt32(36 + bytes)); text("WAVE")
        text("fmt "); integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(channels))
        integer(UInt32(48_000)); integer(UInt32(48_000 * channels * 2))
        integer(UInt16(channels * 2)); integer(UInt16(16))
        text("data"); integer(UInt32(bytes))
        for frame in 0..<frames { for channel in 0..<channels { integer(sample(frame, channel)) } }
        let url = directory.appendingPathComponent("\(UUID()).wav")
        try data.write(to: url)
        return url
    }
}
