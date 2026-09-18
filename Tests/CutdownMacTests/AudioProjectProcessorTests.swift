import CutdownCore
import Foundation
import XCTest
@testable import CutdownMac

final class AudioProjectProcessorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CutdownProcessor-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testPCMAnalysisCreatesEditableRetainedSourceSegmentsAndReportWithoutChangingInputs() async throws {
        let fixture = try fixture()
        let originalXML = try Data(contentsOf: fixture.xml)
        let originalMedia = try Data(contentsOf: fixture.source)
        let originalRender = try Data(contentsOf: fixture.audio)
        let result = try await process(fixture)
        let artifacts = try XCTUnwrap(result.artifacts)
        XCTAssertEqual(result.analyzed.review.selectedCuts.map(\.range), [range(11, 19, denominator: 10)])
        let edited = try TimelineParser.parse(url: artifacts.editedXML)
        XCTAssertEqual(edited.projectRange.duration, RationalTime(11, 5))
        XCTAssertEqual(edited.clips.map(\.sourceStart), [RationalTime(1), RationalTime(29, 10)])
        XCTAssertEqual(edited.clips.map(\.timelineRange), [range(0, 11, denominator: 10), range(11, 22, denominator: 10)])
        XCTAssertTrue(edited.clips.allSatisfy { $0.mediaURL == fixture.source })
        XCTAssertEqual(try Data(contentsOf: artifacts.beforeXML), originalXML)
        XCTAssertEqual(try Data(contentsOf: fixture.xml), originalXML)
        XCTAssertEqual(try Data(contentsOf: fixture.source), originalMedia)
        XCTAssertEqual(try Data(contentsOf: fixture.audio), originalRender)
        let report = try JSONDecoder().decode(AudioProjectProcessingReport.self, from: Data(contentsOf: artifacts.reportURL))
        XCTAssertEqual(report.operation, "offline-edited-project")
        XCTAssertFalse(report.classifiesBreaths)
        XCTAssertEqual(report.editedProject.removedDuration, RationalTime(4, 5))
        XCTAssertEqual(report.measurementWindowCount, 300)
        XCTAssertEqual(report.dialogueAudioSHA256, fixture.context.audioSHA256)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: artifacts.directory.path).sorted(),
                       ["Before-Cutdown.fcpxml", "Cutdown.fcpxml", "Edit-Report.json"])
    }

    func testNoSilenceEntireSilenceAndEmptySelectionCreateNoOutputDirectory() async throws {
        for signal in [Signal.continuous, .silent, .pause] {
            let fixture = try fixture(signal: signal)
            let selected: [TimeRange]? = signal == .pause ? [] : nil
            let result = try await process(fixture, selectedRanges: selected)
            XCTAssertNil(result.artifacts)
            XCTAssertTrue(result.analyzed.review.selectedCuts.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(result.analyzed.analysis.disposition, signal == .continuous ? .noSilence : signal == .silent ? .entirelySilent : .cuts)
        }
    }

    func testExplicitSelectionMustMatchDistinctEligibleCandidates() async throws {
        let fixture = try fixture()
        let eligible = range(11, 19, denominator: 10)
        for selected in [[range(1, 2)], [eligible, eligible], [range(0, 3)]] {
            do {
                _ = try await process(fixture, selectedRanges: selected)
                XCTFail("An arbitrary or repeated range must not authorize an output.")
            } catch AudioProjectProcessingError.invalidSelection { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        let result = try await process(fixture, selectedRanges: [eligible])
        XCTAssertEqual(result.artifacts?.report.editedProject.selectedRanges, [eligible])
    }

    func testExistingOutputIsRejectedAndPreserved() async throws {
        let fixture = try fixture()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let sentinel = output.appendingPathComponent("keep.txt")
        try Data("existing result".utf8).write(to: sentinel)
        do {
            _ = try await process(fixture)
            XCTFail("An existing result directory must not be overwritten.")
        } catch AudioProjectProcessingError.outputExists { }
        XCTAssertEqual(try String(contentsOf: sentinel), "existing result")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["keep.txt"])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".staging") })
    }

    func testXMLChangedDuringPCMReadCannotProduceOutput() async throws {
        let fixture = try fixture()
        let xmlURL = fixture.xml
        do {
            _ = try await process(fixture, progress: { progress in
                guard progress >= 1 else { return }
                do {
                    let changed = try String(contentsOf: xmlURL).replacingOccurrences(of: "name=\"Processor Audio\"", with: "name=\"Changed\"")
                    try changed.write(to: xmlURL, atomically: true, encoding: .utf8)
                } catch { XCTFail("Failed to mutate the test XML: \(error)") }
            })
            XCTFail("Project changes must reject the output, even with unchanged render bytes.")
        } catch AudioProjectProcessingError.changedProject { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testSourceMediaRemovedAfterDecodeCannotProduceOutput() async throws {
        let fixture = try fixture()
        let source = fixture.source
        do {
            _ = try await process(fixture, progress: { progress in
                guard progress >= 1 else { return }
                try? FileManager.default.removeItem(at: source)
            })
            XCTFail("The output must still have readable source media.")
        } catch TimelineError.missingMedia { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testRenderChangedAfterDecodeCannotProduceOutput() async throws {
        let fixture = try fixture()
        let audio = fixture.audio
        do {
            _ = try await process(fixture, progress: { progress in
                guard progress >= 1 else { return }
                do {
                    let handle = try FileHandle(forWritingTo: audio)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: 44)
                    try handle.write(contentsOf: Data([0, 0]))
                } catch { XCTFail("Failed to mutate the render: \(error)") }
            })
            XCTFail("Changed render samples cannot authorize an edited output.")
        } catch ProjectAnalysisError.changedRenderArtifact { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCancellationAtDecodeBoundaryCannotPublishFiles() async throws {
        let fixture = try fixture()
        let processing = Task {
            try await process(fixture, progress: { progress in
                if progress >= 1 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        do {
            _ = try await processing.value
            XCTFail("A cancelled process cannot publish artifacts.")
        } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testProtectedDialogueCandidatesDoNotCreateAnEditedProject() async throws {
        let fixture = try fixture(connectedDialogue: true)
        let result = try await process(fixture)
        XCTAssertEqual(result.analyzed.analysis.disposition, .cuts)
        XCTAssertEqual(result.analyzed.review.cuts.count, 1)
        XCTAssertFalse(try XCTUnwrap(result.analyzed.review.cuts.first).isEligible)
        XCTAssertNil(result.artifacts)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testInvalidDestinationLibraryRejectsWithoutFiles() async throws {
        let fixture = try fixture()
        do {
            _ = try await AudioProjectProcessor.process(projectXML: fixture.xml, selection: fixture.selection,
                dialogueAudio: fixture.audio, renderContext: fixture.context, outputDirectory: output,
                outputName: "Cutdown Test", destinationLibrary: directory.appendingPathComponent("Missing.fcpbundle"))
            XCTFail("A missing Final Cut destination must reject before creating output.")
        } catch AudioProjectProcessingError.invalidDestinationLibrary { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    private var output: URL { directory.appendingPathComponent("Result", isDirectory: true) }

    private func process(_ fixture: Fixture, selectedRanges: [TimeRange]? = nil,
                         progress: @Sendable (Double) -> Void = { _ in }) async throws -> AudioProjectProcessingResult {
        try await AudioProjectProcessor.process(projectXML: fixture.xml, selection: fixture.selection,
            dialogueAudio: fixture.audio, renderContext: fixture.context, outputDirectory: output,
            outputName: "Cutdown Test", selectedRanges: selectedRanges, progress: progress)
    }

    private struct Fixture {
        let xml: URL
        let audio: URL
        let source: URL
        let context: DialogueRenderContext
        let selection = TimelineSelection(timelineRange: TimeRange(start: .zero, end: RationalTime(3)))
    }

    private enum Signal { case pause, continuous, silent }

    private func fixture(signal: Signal = .pause, connectedDialogue: Bool = false) throws -> Fixture {
        let source = directory.appendingPathComponent("Source-\(UUID()).wav")
        let audio = directory.appendingPathComponent("Render-\(UUID()).wav")
        try wave(seconds: 5) { frame in
            signal == .silent || (signal == .pause && (96_000..<144_000).contains(frame)) ? 0 : 8_192
        }.write(to: source)
        try wave(seconds: 3) { frame in
            signal == .silent || (signal == .pause && (48_000..<96_000).contains(frame)) ? 0 : 8_192
        }.write(to: audio)
        let xml = directory.appendingPathComponent("Project-\(UUID()).fcpxml")
        let connection = connectedDialogue
            ? "<asset-clip ref=\"a\" name=\"Connected dialogue\" lane=\"-1\" offset=\"2s\" start=\"0s\" duration=\"1s\" audioRole=\"dialogue\"/>" : ""
        try Data("""
        <fcpxml version="1.14"><resources>
        <format id="f" frameDuration="1/30s" width="1920" height="1080"/>
        <asset id="a" name="Voice" start="0s" duration="5s" hasAudio="1" audioSources="1" audioChannels="1">
        <media-rep kind="original-media" src="\(source.absoluteString)"/></asset></resources>
        <library><event name="Test"><project name="Processor Audio" uid="processor-audio-test">
        <sequence format="f" duration="3s" tcStart="0s"><spine>
        <asset-clip ref="a" name="Voice" offset="0s" start="1s" duration="3s" audioRole="dialogue">\(connection)</asset-clip>
        </spine></sequence></project></event></library></fcpxml>
        """.utf8).write(to: xml)
        let document = try TimelineParser.parse(url: xml)
        let context = try DialogueRenderContext(projectFingerprint: document.fingerprint, projectUID: document.projectUID,
            projectName: document.projectName, projectRange: document.projectRange,
            renderedRoles: Set(document.dialogueRoles), audioURL: audio)
        return Fixture(xml: xml, audio: audio, source: source, context: context)
    }

    private func range(_ start: Int64, _ end: Int64, denominator: Int64 = 1) -> TimeRange {
        TimeRange(start: RationalTime(start, denominator), end: RationalTime(end, denominator))
    }

    private func wave(seconds: Int, sample: (Int) -> Int16) throws -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        let frames = seconds * 48_000
        text("RIFF"); integer(UInt32(36 + frames * 2)); text("WAVE")
        text("fmt "); integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1))
        integer(UInt32(48_000)); integer(UInt32(96_000)); integer(UInt16(2)); integer(UInt16(16))
        text("data"); integer(UInt32(frames * 2))
        for frame in 0..<frames { integer(sample(frame)) }
        return data
    }
}
