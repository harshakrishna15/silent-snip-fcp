import CutdownCore
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import XCTest
@testable import CutdownMac

final class XMLProjectApplyTests: XCTestCase {
    private var folder: URL!
    private var library: URL { folder.appendingPathComponent("Fixture.fcpbundle") }
    private var destination: URL { folder.appendingPathComponent("Result") }
    private let selection = TimelineSelection(timelineRange: .init(start: .zero, end: .init(10)))
    private let cuts = [TimeRange(start: .init(2), end: .init(3)), TimeRange(start: .init(6), end: .init(8))]

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("CutdownXMLApply-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private func fixture(location: String? = nil) -> Data {
        Data("""
        <fcpxml version="1.11"><resources><format id="f" frameDuration="1/30s"/>
        <asset id="a" name="Voice" start="0s" duration="10s" hasAudio="1"><media-rep kind="original-media" src="file:///tmp/voice.wav"/></asset>
        <effect id="e" name="Cutdown Audio" uid="\(AudioControllerSettings.effectUID)"/>
        </resources><library location="\(location ?? library.absoluteString)"><event name="Fixture" uid="original-event"><project name="Original" uid="original-project">
        <sequence format="f" duration="10s" tcStart="0s"><spine>
        <asset-clip ref="a" name="Voice" offset="0s" start="0s" duration="10s" audioRole="dialogue"><filter-audio ref="e" name="Cutdown Audio"/></asset-clip>
        </spine></sequence></project></event></library></fcpxml>
        """.utf8)
    }

    private func prepare(mode: CutdownOutputMode = .remove, data: Data? = nil) throws -> PreparedXMLProject {
        try XMLProjectApply.prepare(projectData: data ?? fixture(), selection: selection, cuts: cuts,
            settings: .defaults, mode: mode, outputName: "Edited", directory: destination)
    }

    func testCreatesSeparateEditableProjectAndRecoveryWithoutChangingInput() throws {
        let input = fixture()
        let result = try prepare(data: input)
        let original = try TimelineParser.parse(data: input)
        let output = try TimelineParser.parse(url: result.outputURL)
        let recovery = try TimelineParser.parse(url: result.recoveryURL)
        XCTAssertEqual(original.projectRange.duration, .init(10))
        XCTAssertEqual(output.projectRange.duration, .init(7))
        XCTAssertEqual(output.clips.map(\.sourceStart), [.init(0), .init(3), .init(8)])
        XCTAssertEqual(output.clips.map(\.timelineRange.duration), [.init(2), .init(3), .init(2)])
        XCTAssertTrue(output.clips.allSatisfy { $0.mediaURL == original.clips[0].mediaURL })
        for clip in output.clips {
            XCTAssertEqual(try AudioControllerSettings.read(projectData: result.output.xmlData, target: clip), .defaults)
        }
        XCTAssertNotEqual(output.projectUID, original.projectUID)
        XCTAssertNotEqual(recovery.projectUID, original.projectUID)
        XCTAssertEqual(recovery.fingerprint, original.fingerprint)
        let xml = try XMLDocument(contentsOf: result.outputURL)
        XCTAssertEqual(try xml.nodes(forXPath: "/fcpxml/import-options/option[@key='copy assets']/@value").first?.stringValue, "0")
        XCTAssertEqual(try xml.nodes(forXPath: "/fcpxml/import-options/option[@key='library location']/@value").first?.stringValue, library.absoluteString)
        XCTAssertEqual(try xml.nodes(forXPath: "//project").count, 1)
        let saved = try JSONDecoder().decode(AnalysisSettings.self, from: Data(contentsOf: destination.appendingPathComponent("Analysis-Settings.json")))
        XCTAssertEqual(saved, .defaults)
        let report = try JSONDecoder().decode(EditedProjectReport.self, from: Data(contentsOf: destination.appendingPathComponent("Edit-Report.json")))
        XCTAssertEqual(report.retainedSegments.count, 3)
    }

    func testSubmittedSettingsReplaceEmptyStateAndReportHostLoss() throws {
        let settings = try AnalysisSettings(thresholdDBFS: -31, minimumSilenceDuration: 0.75,
            beforeSpeechPadding: 0.2, afterSpeechPadding: 0.3)
        let prepared = try XMLProjectApply.prepare(projectData: fixture(), selection: selection, cuts: cuts,
            settings: settings, mode: .remove, outputName: "Edited", directory: destination)
        let xml = try XMLDocument(data: prepared.output.xmlData)
        // The native archive alone must restore settings even if host scalars disappear.
        for node in try xml.nodes(forXPath: "//filter-audio/param") { node.detach() }
        let archiveOnly = xml.xmlData
        let output = try TimelineParser.parse(data: archiveOnly)
        for clip in output.clips {
            let actual = try AudioControllerSettings.read(projectData: archiveOnly, target: clip)
            XCTAssertEqual(Float(actual.thresholdDBFS), Float(settings.thresholdDBFS))
            XCTAssertEqual(Float(actual.afterSpeechPadding), Float(settings.afterSpeechPadding))
        }
        XCTAssertEqual(try ProjectRoundTripVerification.compare(expected: prepared.output.xmlData, actual: archiveOnly).controllerSettingsPreserved, true)
        for node in try xml.nodes(forXPath: "//filter-audio/data") { node.detach() }
        let stripped = try ProjectRoundTripVerification.compare(expected: prepared.output.xmlData, actual: xml.xmlData)
        XCTAssertTrue(stripped.verified, "Audio/timeline verification stays distinct from private settings")
        XCTAssertEqual(stripped.controllerSettingsPreserved, false)
    }

    private func hostCopy(_ data: Data, uid: String = "host-result", stripped: Bool = true) throws -> Data {
        let xml = try XMLDocument(data: data)
        (try xml.nodes(forXPath: "//project/@uid")).first?.stringValue = uid
        if stripped { for node in try xml.nodes(forXPath: "//filter-audio/param | //filter-audio/data") { node.detach() } }
        return xml.xmlData
    }

    @MainActor func testVerificationRetriesWithoutReimportAndRecoversAllSettings() async throws {
        let result = try prepare()
        let request = AnalyzeRequest(id: UUID(), settings: .defaults, outputMode: .remove)
        var imports = 0
        try await result.send { _ in imports += 1 }
        let verification = try ImportedResultVerification(expected: result.output.xmlData, outputURL: result.outputURL,
            originalProjectName: "Original", request: request)
        try verification.savePending()
        do {
            _ = try await verification.verify(capture: { throw CocoaError(.fileReadUnknown) }, restore: { _, _ in XCTFail("No capture") })
            XCTFail("A failed capture must remain retryable")
        } catch {}
        XCTAssertFalse(verification.complete)
        var actual = try hostCopy(result.output.xmlData)
        var restored: [String] = []
        let report = try await verification.verify(capture: { actual }, restore: { correction, _ in
            restored.append(correction.clip.id)
            actual = try AudioControllerSettings.embedding(correction.settings, in: actual,
                selection: .init(timelineRange: correction.clip.timelineRange, sourceURL: correction.clip.mediaURL, sourceStart: correction.clip.sourceStart))
        })
        XCTAssertEqual(imports, 1)
        XCTAssertEqual(restored.count, 3)
        XCTAssertEqual(Set(restored).count, 3)
        XCTAssertTrue(report.verified)
        XCTAssertEqual(report.controllerSettingsPreserved, true)
        XCTAssertEqual(report.actualProjectUID, "host-result")
        XCTAssertEqual(try ImportedResultVerification.load(outputURL: result.outputURL).hostProjectUID, "host-result")
    }

    @MainActor func testSettingsRecoveryRefusesTheOriginalProjectName() throws {
        let result = try prepare()
        XCTAssertThrowsError(try ImportedResultVerification(expected: result.output.xmlData, outputURL: result.outputURL,
            originalProjectName: "Edited", request: AnalyzeRequest(id: UUID(), settings: .defaults, outputMode: .remove)))
    }

    @MainActor func testOlderResultCanBeAdoptedWithoutReimport() async throws {
        let result = try prepare(mode: .gaps)
        let restored = try ImportedResultVerification.load(outputURL: result.outputURL)
        XCTAssertEqual(restored.request.outputMode, .gaps)
        XCTAssertEqual(restored.originalProjectName, "Original")
        XCTAssertEqual(restored.expected, result.output.xmlData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Verification-Receipt.json").path))
        let report = try await restored.verify(capture: { try self.hostCopy(result.output.xmlData, stripped: false) },
            restore: { _, _ in XCTFail("Already retained settings need no writes") })
        XCTAssertEqual(report.controllerSettingsPreserved, true)
    }

    @MainActor func testInterruptedSettingsRecoveryResumesOnlyMissingOccurrencesAfterRestart() async throws {
        let result = try prepare()
        var actual = try hostCopy(result.output.xmlData)
        let verification = try ImportedResultVerification(expected: result.output.xmlData, outputURL: result.outputURL,
            originalProjectName: "Original", request: AnalyzeRequest(id: UUID(), settings: .defaults, outputMode: .remove))
        var restored = 0
        do {
            _ = try await verification.verify(capture: { actual }, restore: { correction, _ in
                if restored == 1 { throw CancellationError() }
                actual = try AudioControllerSettings.embedding(correction.settings, in: actual,
                    selection: .init(timelineRange: correction.clip.timelineRange))
                restored += 1
            })
            XCTFail("Interrupted restoration must not report success")
        } catch {}
        let resumed = try ImportedResultVerification.load(outputURL: result.outputURL)
        var remaining = 0
        _ = try await resumed.verify(capture: { actual }, restore: { correction, _ in
            remaining += 1
            actual = try AudioControllerSettings.embedding(correction.settings, in: actual,
                selection: .init(timelineRange: correction.clip.timelineRange))
        })
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(remaining, 2)
    }

    @MainActor func testRecoveryRejectsChangedTimelineIdentityAndUnretainedSettings() async throws {
        let result = try prepare()
        let verification = try ImportedResultVerification(expected: result.output.xmlData, outputURL: result.outputURL,
            originalProjectName: "Original", request: AnalyzeRequest(id: UUID(), settings: .defaults, outputMode: .remove))
        let stripped = try hostCopy(result.output.xmlData)
        do {
            _ = try await verification.verify(capture: { stripped }, restore: { _, _ in })
            XCTFail("Control writes alone cannot prove settings retention")
        } catch { XCTAssertTrue(error.localizedDescription.contains("did not retain")) }
        XCTAssertFalse(verification.complete)
        let clone = try hostCopy(result.output.xmlData, uid: "another-host-project", stripped: false)
        do {
            _ = try await verification.verify(capture: { clone }, restore: { _, _ in XCTFail("Wrong identity") })
            XCTFail("Same-name clone must not replace the bound result")
        } catch { XCTAssertTrue(error.localizedDescription.contains("identity changed")) }
        let rejected = try JSONDecoder().decode(ProjectRoundTripReport.self, from: Data(contentsOf: destination.appendingPathComponent("Import-Verification.json")))
        XCTAssertFalse(rejected.verified, "The saved report must also reject a different host identity")
        let changed = Data(String(decoding: stripped, as: UTF8.self).replacingOccurrences(of: "file:///tmp/voice.wav", with: "file:///tmp/other.wav").utf8)
        XCTAssertThrowsError(try ImportedSettingsRecovery.plan(expected: result.output.xmlData, actual: changed))
        try Data("tampered".utf8).write(to: result.outputURL)
        XCTAssertThrowsError(try ImportedResultVerification.load(outputURL: result.outputURL))
        do {
            _ = try await verification.verify(capture: { XCTFail("Tampering must stop before host access"); return stripped }, restore: { _, _ in })
            XCTFail("Tampered expected XML")
        } catch {}
    }

    @MainActor func testRecoveryRechecksFreshHostSnapshotAfterRestoringSettings() async throws {
        let result = try prepare()
        let stripped = try hostCopy(result.output.xmlData)
        for changeIdentity in [false, true] {
            let verification = try ImportedResultVerification(expected: result.output.xmlData, outputURL: result.outputURL,
                originalProjectName: "Original", request: AnalyzeRequest(id: UUID(), settings: .defaults, outputMode: .remove))
            var captures = 0
            var corrections = 0
            var actual = stripped
            do {
                _ = try await verification.verify(capture: {
                    captures += 1
                    if captures == 1 { return actual }
                    if changeIdentity {
                        return try self.hostCopy(actual, uid: "changed-during-recovery", stripped: false)
                    }
                    return Data(String(decoding: actual, as: UTF8.self)
                        .replacingOccurrences(of: "file:///tmp/voice.wav", with: "file:///tmp/changed.wav").utf8)
                }, restore: { correction, document in
                    XCTAssertTrue(document.clips.contains(correction.clip), "Recovery uses occurrences from the compared host snapshot")
                    corrections += 1
                    actual = try AudioControllerSettings.embedding(correction.settings, in: actual,
                        selection: .init(timelineRange: correction.clip.timelineRange))
                })
                XCTFail("Recovery must compare a fresh export, even when all settings were restored")
            } catch {
                let report = try JSONDecoder().decode(ProjectRoundTripReport.self,
                    from: Data(contentsOf: destination.appendingPathComponent("Import-Verification.json")))
                XCTAssertFalse(report.verified)
                XCTAssertTrue(report.differences.contains(changeIdentity
                    ? "imported project identity changed" : "timeline, media references, or effect settings"))
            }
            XCTAssertEqual(captures, 2)
            XCTAssertEqual(corrections, 3)
            XCTAssertFalse(verification.complete)
        }
    }

    func testGapModeGeneratesBothGapsInOneProject() throws {
        let result = try prepare(mode: .gaps)
        let output = try TimelineParser.parse(url: result.outputURL)
        XCTAssertEqual(output.projectRange.duration, .init(9))
        XCTAssertEqual(output.clips.filter { $0.kind == "gap" }.map(\.timelineRange.duration), [.init(1), .init(1)])
    }

    func testInvalidOrMissingLibraryProducesNoOutput() throws {
        for location in ["https://example.com/Test.fcpbundle", folder.absoluteString,
                         folder.appendingPathComponent("Missing.fcpbundle").absoluteString] {
            XCTAssertThrowsError(try prepare(data: fixture(location: location)))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testExistingOutputIsNeverOverwritten() throws {
        let first = try prepare()
        let bytes = try Data(contentsOf: first.outputURL)
        XCTAssertThrowsError(try prepare(mode: .gaps))
        XCTAssertEqual(try Data(contentsOf: first.outputURL), bytes)
    }

    func testBaselineAcceptsCutdownPresetMetadataButRejectsActualEdits() throws {
        let original = String(decoding: fixture(), as: UTF8.self)
        let exclusions = TimelineFingerprintExclusions(controllerEffectUIDs: [AudioControllerSettings.effectUID])
        let baseline = try TimelineParser.parse(data: Data(original.utf8), exclusions: exclusions)
        let preset = original.replacingOccurrences(of: "<filter-audio ref=\"e\"", with: "<filter-audio presetID=\"Saved Voice.aupreset\" ref=\"e\"")
        XCTAssertNoThrow(try XMLProjectApply.verifyBaseline(TimelineParser.parse(data: Data(preset.utf8), exclusions: exclusions), analyzed: baseline))
        for changed in [
            preset.replacingOccurrences(of: "uid=\"original-project\"", with: "uid=\"another-project\""),
            preset.replacingOccurrences(of: "name=\"Original\"", with: "name=\"Renamed\""),
            preset.replacingOccurrences(of: "duration=\"10s\"", with: "duration=\"9s\""),
            preset.replacingOccurrences(of: "frameDuration=\"1/30s\"", with: "frameDuration=\"1/25s\""),
            preset.replacingOccurrences(of: "file:///tmp/voice.wav", with: "file:///tmp/other.wav"),
            preset.replacingOccurrences(of: "<filter-audio presetID", with: "<filter-audio enabled=\"0\" presetID"),
            preset.replacingOccurrences(of: "<filter-audio presetID", with: "<adjust-volume amount=\"-6dB\"/><filter-audio presetID")
        ] {
            let current = try TimelineParser.parse(data: Data(changed.utf8), exclusions: exclusions)
            XCTAssertThrowsError(try XMLProjectApply.verifyBaseline(current, analyzed: baseline)) { error in
                XCTAssertTrue(error is XMLProjectBaselineError)
                XCTAssertTrue(error.localizedDescription.contains("No edited project was generated"))
                XCTAssertFalse(error.localizedDescription.contains("native edits"))
            }
        }
    }

    @MainActor func testSendsOnlyTheVerifiedArtifactOnce() async throws {
        let result = try prepare()
        var sent: [URL] = []
        try await result.send { sent.append($0) }
        XCTAssertEqual(sent, [result.outputURL])
    }

    @MainActor func testTamperingAndMissingLibraryPreventDelivery() async throws {
        let result = try prepare()
        var calls = 0
        try Data("changed".utf8).write(to: result.outputURL)
        do { try await result.send { _ in calls += 1 }; XCTFail("Changed XML must be rejected") } catch {}
        try result.output.xmlData.write(to: result.outputURL)
        try FileManager.default.removeItem(at: library)
        do { try await result.send { _ in calls += 1 }; XCTFail("Missing library must be rejected") } catch {}
        XCTAssertEqual(calls, 0)
    }

    @MainActor func testUncertainImportIsNotRetriedAndKeepsOutput() async throws {
        let result = try prepare()
        var calls = 0
        do {
            try await result.send { _ in calls += 1; throw CocoaError(.fileReadUnknown) }
            XCTFail("Delivery error must be reported")
        } catch {}
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try Data(contentsOf: result.outputURL), result.output.xmlData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.recoveryURL.path))
    }

    @MainActor func testCancellationBeforeDeliveryDoesNotImport() async throws {
        let result = try prepare()
        var calls = 0
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await result.send { _ in calls += 1 }
        }
        do { try await task.value; XCTFail("Cancelled delivery must stop") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
    }
}
