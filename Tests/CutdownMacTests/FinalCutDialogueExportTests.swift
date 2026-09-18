import CutdownCore
import Foundation
import XCTest
@testable import CutdownMac

final class FinalCutDialogueExportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CutdownDialogueExportTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testAudioFormatLabelAcceptsObservedCombinedFieldsOnly() {
        XCTAssertTrue(FinalCutDialogueExport.matchesSettingsLabel("Audio Format:", expected: "Audio Format:"))
        XCTAssertTrue(FinalCutDialogueExport.matchesSettingsLabel(
            "Video Codec: None  Resolution: None\nColor Space: None Audio Format:", expected: "Audio Format:"))
        XCTAssertTrue(FinalCutDialogueExport.matchesSettingsLabel("Export File Format:", expected: "Export File Format:"))
        XCTAssertTrue(FinalCutDialogueExport.matchesSettingsLabel("Format:", expected: "Export File Format:"))
        for label in ["Audio Format:", "Previous Format:", "Format: Audio Only", "Video Codec:"] {
            XCTAssertFalse(FinalCutDialogueExport.matchesSettingsLabel(label, expected: "Export File Format:"))
        }
        for label in ["Previous Audio Format:", "Video Codec: H.264 Resolution: None Color Space: None Audio Format:",
                      "Audio Format: WAV", "Export File Format:", "Format:"] {
            XCTAssertFalse(FinalCutDialogueExport.matchesSettingsLabel(label, expected: "Audio Format:"))
        }
    }

    func testEmptyDirectoryCleanupNeverRemovesUnownedOrPendingFiles() throws {
        let pending = directory.appendingPathComponent("writing.wav")
        let original = directory.appendingPathComponent("original.fcpxml")
        try Data([0, 1, 2]).write(to: pending)
        try Data("<fcpxml/>".utf8).write(to: original)
        try LegacyDialogueExport.removeEmptyJobDirectory(at: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        try FileManager.default.removeItem(at: pending)
        try LegacyDialogueExport.removeEmptyJobDirectory(at: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        try FileManager.default.removeItem(at: original)
        try LegacyDialogueExport.removeEmptyJobDirectory(at: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNoThrow(try LegacyDialogueExport.removeEmptyJobDirectory(at: directory))
    }

    func testEmptyDirectoryCleanupDoesNotFollowSymlinks() throws {
        let target = directory.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try LegacyDialogueExport.removeEmptyJobDirectory(at: link))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testPendingTokenPreservesDestinationBeforeWAVExists() throws {
        let token = directory.appendingPathComponent("Export-\(UUID()).pending")
        try Data().write(to: token, options: .withoutOverwriting)
        try LegacyDialogueExport.removeEmptyJobDirectory(at: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        let wav = directory.appendingPathComponent("queued.wav")
        try wave(frames: 1).write(to: wav)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
    }

    func testDialogueAndSubrolesAreAcceptedForTheVerifiedSingleRoleFlow() throws {
        for role in ["dialogue", "dialogue.dialogue-1", "Dialogue"] {
            let (document, url) = try project(role: role)
            XCTAssertNoThrow(try LegacyDialogueExport.validateDialogueOnlyProject(document, xmlURL: url))
        }
    }

    func testMusicAndEffectsNeverFallBackToTheWholeAudioMix() throws {
        for role in ["music", "effects", "music.bed"] {
            let (document, url) = try project(connectedRole: role)
            XCTAssertThrowsError(try LegacyDialogueExport.validateDialogueOnlyProject(document, xmlURL: url)) { error in
                guard case LegacyDialogueExport.ExportError.mixedAudioRoles = error else {
                    return XCTFail("Expected explicit mixed-role rejection, received \(error).")
                }
            }
        }
    }

    func testMixedComponentsInsideOneClipCannotHideBehindDialogueRole() throws {
        let components = """
        <audio-channel-source srcCh="1" role="dialogue"/>
        <audio-channel-source srcCh="2" role="music"/>
        """
        let (document, url) = try project(components: components)
        XCTAssertThrowsError(try LegacyDialogueExport.validateDialogueOnlyProject(document, xmlURL: url))
    }

    func testAbsentDialogueIsNotTreatedAsSilence() throws {
        let (document, url) = try project(role: "music")
        XCTAssertThrowsError(try LegacyDialogueExport.validateDialogueOnlyProject(document, xmlURL: url)) { error in
            guard case LegacyDialogueExport.ExportError.noDialogue = error else {
                return XCTFail("Expected no-dialogue rejection, received \(error).")
            }
        }
    }

    func testCompletedPCMAllowsOnlySampleBoundaryRounding() async throws {
        let url = directory.appendingPathComponent("completed.wav")
        try wave(frames: 47_999).write(to: url)
        try await LegacyDialogueExport.waitForCompletedPCM(at: url, expected: RationalTime(1), timeout: 3,
            cancellationEnabled: true)
        try wave(frames: 48_000 - 1_600).write(to: url)
        await assertIncomplete(url, expected: RationalTime(1), timeout: 1.5)
    }

    func testHeaderWithoutSamplesAndTruncatedPCMDoNotComplete() async throws {
        let url = directory.appendingPathComponent("unfinished.wav")
        let full = wave(frames: 48_000)
        try full.prefix(44).write(to: url)
        await assertIncomplete(url, expected: RationalTime(1), timeout: 1.5)
        try full.dropLast(48_000).write(to: url)
        await assertIncomplete(url, expected: RationalTime(1), timeout: 1.5)
    }

    func testCompletionWaitsForTheActualFinalFile() async throws {
        let url = directory.appendingPathComponent("writing.wav")
        let full = wave(frames: 48_000)
        try full.prefix(44).write(to: url)
        let writer = Task {
            try await Task.sleep(nanoseconds: 300_000_000)
            try full.write(to: url, options: .atomic)
        }
        try await LegacyDialogueExport.waitForCompletedPCM(at: url, expected: RationalTime(1), timeout: 4,
            cancellationEnabled: true)
        try await writer.value
        XCTAssertEqual(try Data(contentsOf: url), full)
    }

    func testInvalidExpectedDurationsAndCancellationFailPromptly() async throws {
        let url = directory.appendingPathComponent("absent.wav")
        for duration in [RationalTime.zero, RationalTime(-1)] {
            await assertIncomplete(url, expected: duration, timeout: 60)
        }
        await assertIncomplete(url, expected: RationalTime(1), timeout: 0)
        let wait = Task {
            try await LegacyDialogueExport.waitForCompletedPCM(at: url, expected: RationalTime(1), timeout: 60,
                cancellationEnabled: true)
        }
        wait.cancel()
        do { try await wait.value; XCTFail("Cancellation must end the wait.") }
        catch is CancellationError { }
    }

    private func assertIncomplete(_ url: URL, expected: RationalTime, timeout: TimeInterval,
                                  file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await LegacyDialogueExport.waitForCompletedPCM(at: url, expected: expected, timeout: timeout,
                cancellationEnabled: true)
            XCTFail("Incomplete PCM must not establish a completed Dialogue export.", file: file, line: line)
        } catch {
            guard case LegacyDialogueExport.ExportError.incompleteExport = error else {
                return XCTFail("Unexpected error: \(error).", file: file, line: line)
            }
        }
    }

    private func project(role: String = "dialogue", connectedRole: String? = nil,
                         components: String = "") throws -> (TimelineDocument, URL) {
        let connection = connectedRole.map {
            "<asset-clip ref=\"r2\" lane=\"-1\" offset=\"0s\" start=\"0s\" duration=\"10s\" audioRole=\"\($0)\"/>"
        } ?? ""
        let xml = """
        <fcpxml version="1.14"><resources>
          <format id="r1" frameDuration="1/30s"/>
          <asset id="r2" start="0s" duration="10s" hasAudio="1" audioSources="1" audioChannels="2" audioRate="48000">
            <media-rep kind="original-media" src="file:///fixtures/original.wav"/>
          </asset>
        </resources><project name="Export guard"><sequence format="r1" duration="10s" tcStart="0s"><spine>
          <asset-clip ref="r2" offset="0s" start="0s" duration="10s" audioRole="\(role)">
            \(components)\(connection)
          </asset-clip>
        </spine></sequence></project></fcpxml>
        """
        let data = Data(xml.utf8)
        let url = directory.appendingPathComponent("Project-\(UUID()).fcpxml")
        try data.write(to: url)
        return (try TimelineParser.parse(data: data), url)
    }

    /// Mono PCM16 at 48 kHz, with a correctly sized header and audible samples.
    private func wave(frames: Int) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        text("RIFF"); number(UInt32(36 + frames * 2)); text("WAVE")
        text("fmt "); number(UInt32(16)); number(UInt16(1)); number(UInt16(1))
        number(UInt32(48_000)); number(UInt32(96_000)); number(UInt16(2)); number(UInt16(16))
        text("data"); number(UInt32(frames * 2))
        for _ in 0..<frames { number(Int16(8_192)) }
        return data
    }
}
