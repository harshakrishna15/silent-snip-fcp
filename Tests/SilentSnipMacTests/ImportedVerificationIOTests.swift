import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import SilentSnipCore
import XCTest
@testable import SilentSnipMac

final class ImportedVerificationIOTests: XCTestCase {
    private var folder: URL!
    private var source: URL { folder.appendingPathComponent("Voice.wav") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SilentSnipVerificationIO-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Fixture.fcpbundle"), withIntermediateDirectories: true)
        try Data("unchanged source audio".utf8).write(to: source)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private func prepare() throws -> PreparedXMLProject {
        let xml = Data("""
        <fcpxml version="1.11"><resources><format id="f" frameDuration="1/30s"/>
        <asset id="a" name="Voice" start="0s" duration="10s" hasAudio="1"><media-rep kind="original-media" src="\(source.absoluteString)"/></asset>
        <effect id="e" name="Silent Snip Audio" uid="\(AudioControllerSettings.effectUID)"/>
        </resources><library location="\(folder.appendingPathComponent("Fixture.fcpbundle").absoluteString)"><event name="Fixture" uid="fixture-event"><project name="Original" uid="original-project">
        <sequence format="f" duration="10s" tcStart="0s"><spine>
        <asset-clip ref="a" name="Voice" offset="0s" start="0s" duration="10s" audioRole="dialogue"><filter-audio ref="e"/></asset-clip>
        </spine></sequence></project></event></library></fcpxml>
        """.utf8)
        return try XMLProjectApply.prepare(projectData: xml,
            selection: .init(timelineRange: .init(start: .zero, end: .init(10))),
            cuts: [.init(start: .init(2), end: .init(3))], settings: .defaults, mode: .remove,
            outputName: "Edited", directory: folder.appendingPathComponent("Result"))
    }

    private func hostCopy(_ data: Data, strippingSettings: Bool = false) throws -> Data {
        let xml = try XMLDocument(data: data)
        if let uid = try xml.nodes(forXPath: "//project/@uid").first { uid.stringValue = "host-project" }
        if strippingSettings {
            for node in try xml.nodes(forXPath: "//filter-audio/param | //filter-audio/data") { node.detach() }
        }
        return xml.xmlData
    }

    @MainActor private func makeVerification(_ result: PreparedXMLProject) async throws -> ImportedResultVerification {
        let media = try await MediaContentSnapshot.capture([source])
        return try ImportedResultVerification(expected: result.output.xmlData, outputURL: result.outputURL,
            originalProjectName: "Original", request: .init(id: UUID(), settings: .defaults, outputMode: .remove),
            sourceMedia: media)
    }

    @MainActor func testUnchangedImportUsesOneFullValidationAcrossCaptureAndNoRecovery() async throws {
        let result = try prepare()
        let verification = try await makeVerification(result)
        let events = Events()
        let actual = try hostCopy(result.output.xmlData)
        let report = try await verification.verify(capture: {
            events.append("capture")
            return actual
        }, restore: { _, _ in
            XCTFail("Matching imported settings require no native writes")
        }, validateMedia: { media in
            events.append("validation")
            try await media.validate()
        })
        XCTAssertTrue(report.verified)
        XCTAssertEqual(report.sourceMediaVerified, true)
        XCTAssertEqual(events.values.filter { $0 == "validation" }.count, 1,
            "The same read-only host capture phase must not rescan every source twice")
    }

    @MainActor func testHistoricalDigestMismatchRejectsReadOnlyCaptureWithoutRecovery() async throws {
        let result = try prepare()
        let actual = try hostCopy(result.output.xmlData, strippingSettings: true)
        let snapshot = try await MediaContentSnapshot.capture([source])
        var receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        let differentHashes = snapshot.hashes.mapValues { _ in String(repeating: "0", count: 64) }
        receipt["hashes"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(differentHashes))
        let historical = try JSONDecoder().decode(MediaContentSnapshot.self,
            from: JSONSerialization.data(withJSONObject: receipt))
        let verification = try ImportedResultVerification(expected: result.output.xmlData, outputURL: result.outputURL,
            originalProjectName: "Original", request: .init(id: UUID(), settings: .defaults, outputMode: .remove),
            sourceMedia: historical)
        var captures = 0
        do {
            _ = try await verification.verify(capture: {
                captures += 1
                return actual
            }, restore: { _, _ in
                XCTFail("A historical digest mismatch must block settings recovery")
            })
            XCTFail("Matching references and stamps cannot replace the historical digest")
        } catch ProjectAnalysisError.changedRenderArtifact { }
        XCTAssertEqual(captures, 1)
        let directory = result.outputURL.deletingLastPathComponent()
        let report = try JSONDecoder().decode(ProjectRoundTripReport.self,
            from: Data(contentsOf: directory.appendingPathComponent("Import-Verification.json")))
        XCTAssertFalse(report.verified)
        XCTAssertEqual(report.sourceMediaVerified, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Verification-Receipt.json").path))

        do {
            _ = try await verification.verify(capture: {
                XCTFail("A supplied validator must still follow the historical preflight")
                return actual
            }, restore: { _, _ in XCTFail("The mismatched digest must prevent recovery") },
               validateMedia: { _ in XCTFail("The supplied validator cannot replace historical evidence") })
            XCTFail("The historical preflight must fail before capture")
        } catch ProjectAnalysisError.changedRenderArtifact { }
    }

    @MainActor func testCaptureMutationAfterConcurrentValidationEvenWhenBytesAreRestoredFails() async throws {
        let result = try prepare()
        let verification = try await makeVerification(result)
        let actual = try hostCopy(result.output.xmlData)
        let source = self.source
        let original = try Data(contentsOf: source)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let phase = ValidationCompletion()
        do {
            _ = try await verification.verify(capture: {
                // Deterministically finish the overlapping hash first, then
                // mutate during the still-active native XML capture phase.
                guard try await phase.wait() else {
                    XCTFail("Full source validation must overlap native capture rather than wait for it")
                    throw CocoaError(.fileReadUnknown)
                }
                try Data("changed source bytes".utf8).write(to: source)
                try original.write(to: source)
                try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: source.path)
                return actual
            }, restore: { _, _ in
                XCTFail("A source mutation must stop before native recovery writes")
            }, validateMedia: { media in
                try await media.validate()
                await phase.finish()
            })
            XCTFail("Restoring bytes and mtime must not hide a capture-time source mutation")
        } catch { }
        let report = try JSONDecoder().decode(ProjectRoundTripReport.self,
            from: Data(contentsOf: result.outputURL.deletingLastPathComponent().appendingPathComponent("Import-Verification.json")))
        XCTAssertFalse(report.verified)
        XCTAssertEqual(report.sourceMediaVerified, false)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    @MainActor func testRecoveryJoinsCaptureValidationBeforeWritesAndFullyValidatesAfterRecovery() async throws {
        let result = try prepare()
        let verification = try await makeVerification(result)
        let events = Events()
        var actual = try hostCopy(result.output.xmlData, strippingSettings: true)
        var captures = 0
        let report = try await verification.verify(capture: {
            captures += 1
            events.append("capture\(captures)")
            return actual
        }, restore: { correction, _ in
            XCTAssertTrue(events.values.contains("validated1"), "Recovery must await the content check spanning its initial capture")
            events.append("restore")
            actual = try AudioControllerSettings.embedding(correction.settings, in: actual,
                selection: .init(timelineRange: correction.clip.timelineRange))
        }, validateMedia: { media in
            let number = events.values.filter { $0.hasPrefix("validated") }.count + 1
            try await media.validate()
            events.append("validated\(number)")
        })
        XCTAssertTrue(report.verified)
        XCTAssertEqual(report.controllerSettingsPreserved, true)
        XCTAssertEqual(captures, 2)
        XCTAssertEqual(events.values.filter { $0.hasPrefix("validated") }, ["validated1", "validated2"])
        XCTAssertEqual(events.values.last, "validated2", "The final full-content check follows the recovered host export")
    }

    @MainActor func testTimingDetailsPreserveConcurrentValidationAndSuccessfulReport() async throws {
        let result = try prepare()
        let verification = try await makeVerification(result)
        let actual = try hostCopy(result.output.xmlData)
        let clock = TimingClock()
        let timing = AnalysisTiming(request: verification.request.id, clock: { clock.now })
        timing.begin("importAndVerification")
        let validation = ValidationCompletion()
        var captures = 0
        let report = try await verification.verify(capture: {
            captures += 1
            clock.advance(3)
            guard try await validation.wait() else {
                XCTFail("Timing must preserve concurrent source validation rather than serialize it after capture")
                throw CocoaError(.fileReadUnknown)
            }
            return actual
        }, restore: { _, _ in
            XCTFail("Instrumentation cannot introduce a recovery write")
        }, validateMedia: { media in
            try await media.validate()
            clock.advance(2)
            await validation.finish()
        }, timing: timing)

        XCTAssertTrue(report.verified)
        XCTAssertEqual(report.sourceMediaVerified, true)
        XCTAssertEqual(captures, 1)
        let recorded = timing.report(outcome: "verified")
        XCTAssertEqual(recorded.totalSeconds, 5)
        XCTAssertEqual(recorded.stages, ["importAndVerification": 5],
            "Fine-grained observations must not replace or split the caller's critical-path stage")
        XCTAssertGreaterThanOrEqual(recorded.details["verification.capture"] ?? -1, 3)
        XCTAssertGreaterThanOrEqual(recorded.details["verification.mediaValidation"] ?? -1, 2)
        for name in ["savedResultRead", "expectedParse", "sourceGuardSetup", "sourceSnapshot",
                     "sourceGuard", "destination", "actualParse", "comparison", "reportWrite",
                     "receipt", "recoveryPlan", "finalGuard"] {
            XCTAssertNotNil(recorded.details["verification." + name], name)
        }
        XCTAssertEqual(recorded.counters["verification.readOnlyPhases"], 1)
        XCTAssertEqual(recorded.counters["verification.captureCalls"], 1)
        XCTAssertEqual(recorded.counters["verification.mediaValidationPasses"], 1)
        XCTAssertNil(recorded.counters["verification.recoveryWrites"])
        XCTAssertNil(recorded.counters["verification.ctimeRestarts"])
    }

    @MainActor func testTimingRecordsFailedCaptureWithoutRetryOrRecovery() async throws {
        struct CaptureFailure: Error {}
        let result = try prepare()
        let verification = try await makeVerification(result)
        let clock = TimingClock()
        let timing = AnalysisTiming(request: verification.request.id, clock: { clock.now })
        var captures = 0
        do {
            _ = try await verification.verify(capture: {
                captures += 1
                clock.advance(4)
                throw CaptureFailure()
            }, restore: { _, _ in
                XCTFail("A failed native capture cannot authorize recovery")
            }, timing: timing)
            XCTFail("The original capture failure must escape")
        } catch is CaptureFailure { }
        let recorded = timing.report(outcome: "failed")
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(recorded.details["verification.capture"], 4,
            "Failed intervals remain visible rather than disappearing from timing")
        XCTAssertEqual(recorded.counters["verification.captureCalls"], 1)
        XCTAssertNil(recorded.counters["verification.recoveryWrites"])
        XCTAssertNil(recorded.counters["verification.ctimeRestarts"])
        let reportURL = result.outputURL.deletingLastPathComponent().appendingPathComponent("Import-Verification.json")
        let report = try JSONDecoder().decode(ProjectRoundTripReport.self, from: Data(contentsOf: reportURL))
        XCTAssertFalse(report.verified)
        XCTAssertEqual(report.sourceMediaVerified, false)
    }

    @MainActor func testTimingSeparatesRecoveryWorkAndRetainsPostRecoveryValidation() async throws {
        let result = try prepare()
        let verification = try await makeVerification(result)
        let clock = TimingClock()
        let timing = AnalysisTiming(request: verification.request.id, clock: { clock.now })
        var actual = try hostCopy(result.output.xmlData, strippingSettings: true)
        var captures = 0, restores = 0
        let report = try await verification.verify(capture: {
            captures += 1
            clock.advance(2)
            return actual
        }, restore: { correction, _ in
            restores += 1
            clock.advance(1)
            actual = try AudioControllerSettings.embedding(correction.settings, in: actual,
                selection: .init(timelineRange: correction.clip.timelineRange))
        }, validateMedia: { media in
            try await media.validate()
            clock.advance(3)
        }, timing: timing)
        XCTAssertTrue(report.verified)
        XCTAssertEqual(report.controllerSettingsPreserved, true)
        XCTAssertEqual(report.sourceMediaVerified, true)
        XCTAssertEqual(captures, 2)
        XCTAssertGreaterThan(restores, 0)
        let recorded = timing.report(outcome: "verified")
        XCTAssertEqual(recorded.counters["verification.captureCalls"], 2)
        XCTAssertEqual(recorded.counters["verification.recoveryWrites"], restores)
        XCTAssertEqual(recorded.counters["verification.mediaValidationPasses"], 2)
        XCTAssertGreaterThanOrEqual(recorded.details["verification.recoveryWrite"] ?? -1, Double(restores))
        XCTAssertEqual(recorded.details["verification.recoveryCapture"], 2)
        XCTAssertEqual(recorded.details["verification.recoveryValidation"], 3)
    }

    @MainActor func testTimingRecordsCancelledCaptureWithoutAnotherAttempt() async throws {
        let result = try prepare()
        let verification = try await makeVerification(result)
        let clock = TimingClock()
        let timing = AnalysisTiming(request: verification.request.id, clock: { clock.now })
        var captures = 0
        do {
            _ = try await verification.verify(capture: {
                captures += 1
                clock.advance(1)
                throw CancellationError()
            }, restore: { _, _ in
                XCTFail("Cancellation cannot authorize a recovery write")
            }, timing: timing)
            XCTFail("Cancellation must escape unchanged")
        } catch is CancellationError { }
        let recorded = timing.report(outcome: "cancelled")
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(recorded.details["verification.capture"], 1)
        XCTAssertEqual(recorded.counters["verification.captureCalls"], 1)
        XCTAssertNil(recorded.counters["verification.recoveryWrites"])
        XCTAssertNil(recorded.counters["verification.ctimeRestarts"])
    }

    private final class TimingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0.0
        var now: Double { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; value += seconds }
    }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
        func append(_ value: String) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
    }

    private actor ValidationCompletion {
        private var completed = false
        func wait() async throws -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !completed, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            return completed
        }
        func finish() { completed = true }
    }
}
