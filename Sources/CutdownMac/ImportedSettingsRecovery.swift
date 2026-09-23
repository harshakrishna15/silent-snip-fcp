import CryptoKit
import CutdownCore
import Foundation

/// Recover only settings belonging to occurrences in an otherwise verified
/// imported timeline. Never guess using a clip name or last-used defaults.
enum ImportedSettingsRecovery {
    struct Correction {
        let clip: TimelineClip
        let settings: AnalysisSettings
    }

    static func plan(expected: Data, actual: Data) throws -> [Correction] {
        try plan(ProjectRoundTripVerification.Comparison(
            expected: .init(data: expected), actual: .init(data: actual), allowHostAssignedIdentity: true))
    }

    static func plan(_ comparison: ProjectRoundTripVerification.Comparison) throws -> [Correction] {
        guard comparison.report.verified else { throw EditedProjectWriterError.verificationFailed("the imported timeline changed; settings were not restored") }
        let want = comparison.expected.document
        let got = comparison.actual.document
        let desired = comparison.expected.settings
        let existing = comparison.actual.settings
        return try want.clips.compactMap { clip in
            guard let settings = desired[clip.id] else { return nil }
            let matches = got.clips.filter { $0.timelineRange == clip.timelineRange && $0.sourceStart == clip.sourceStart && $0.mediaURL == clip.mediaURL }
            guard matches.count == 1, let returned = matches.first else { throw AudioControllerSettingsError.targetChanged }
            if let current = existing[returned.id], AudioControllerSettings.equivalent(current, settings) { return nil }
            guard returned.enabled, returned.isPrimaryStoryline, !returned.hasVideo else {
                throw EditedProjectWriterError.unsupported("automatic settings recovery requires an enabled audio-only primary clip")
            }
            return Correction(clip: returned, settings: settings)
        }
    }
}

/// A retry has no import operation. It consumes immutable expected bytes and
/// reads the existing host result. The first successful comparison binds its UID.
@MainActor final class ImportedResultVerification {
    private struct Receipt: Codable {
        let requestID: UUID
        let settings: AnalysisSettings
        let outputMode: String
        let originalProjectName: String
        let expectedSHA256: String
        var replacementTarget: XMLReplacementTarget?
        var hostProjectUID: String?
    }
    let request: AnalyzeRequest
    let expected: Data
    let outputURL: URL
    let originalProjectName: String
    let projectName: String
    let replacementTarget: XMLReplacementTarget?
    private(set) var hostProjectUID: String?
    private(set) var complete = false

    init(expected: Data, outputURL: URL, originalProjectName: String, request: AnalyzeRequest, replacementTarget: XMLReplacementTarget? = nil) throws {
        self.replacementTarget = replacementTarget
        self.request = request
        self.expected = expected; self.outputURL = outputURL
        self.originalProjectName = originalProjectName
        projectName = try TimelineParser.parse(data: expected).projectName
        if let replacementTarget {
            guard originalProjectName == replacementTarget.projectName else {
                throw EditedProjectWriterError.verificationFailed("replacement receipt has the wrong original project")
            }
            try replacementTarget.verifyDestination(expected)
        }
        guard replacementTarget != nil || projectName != originalProjectName else {
            throw EditedProjectWriterError.verificationFailed("settings recovery requires a separately named result project")
        }
    }

    private var receiptURL: URL { outputURL.deletingLastPathComponent().appendingPathComponent("Verification-Receipt.json") }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func savePending() throws {
        let receipt = Receipt(requestID: request.id, settings: request.settings, outputMode: request.outputMode.rawValue,
            originalProjectName: originalProjectName, expectedSHA256: Self.digest(expected), replacementTarget: replacementTarget, hostProjectUID: hostProjectUID)
        try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
    }

    static func load(outputURL: URL) throws -> ImportedResultVerification {
        guard outputURL.isFileURL, outputURL.lastPathComponent == "Cutdown.fcpxml" else {
            throw EditedProjectWriterError.verificationFailed("choose Cutdown.fcpxml from an existing result folder")
        }
        let directory = outputURL.deletingLastPathComponent()
        let data = try Data(contentsOf: outputURL)
        let receiptFile = directory.appendingPathComponent("Verification-Receipt.json")
        if !FileManager.default.fileExists(atPath: receiptFile.path) {
            // Older results predate receipts. The explicit file selection may
            // adopt their existing edit report and settings without importing.
            let edit = try JSONDecoder().decode(EditedProjectReport.self, from: Data(contentsOf: directory.appendingPathComponent("Edit-Report.json")))
            let settings = try JSONDecoder().decode(AnalysisSettings.self, from: Data(contentsOf: directory.appendingPathComponent("Analysis-Settings.json")))
            let document = try TimelineParser.parse(data: data)
            let saved = try AudioControllerSettings.settingsByPrimaryClip(projectData: data)
            guard document.projectName == edit.projectName, document.projectUID == edit.projectUID.uuidString,
                  document.projectRange.duration == edit.resultProjectDuration,
                  !edit.retainedSegments.isEmpty else {
                throw EditedProjectWriterError.verificationFailed("the older result does not match its saved edit report")
            }
            for segment in edit.retainedSegments {
                let matches = document.clips.filter { $0.timelineRange == segment.resultProjectRange && $0.sourceStart == segment.sourceRange.start }
                guard matches.count == 1, let clip = matches.first, let value = saved[clip.id],
                      AudioControllerSettings.equivalent(value, settings) else {
                    throw EditedProjectWriterError.verificationFailed("the older result is missing matching saved controller settings")
                }
            }
            let result = try ImportedResultVerification(expected: data, outputURL: outputURL,
                originalProjectName: edit.originalProjectName,
                request: AnalyzeRequest(id: UUID(uuidString: directory.lastPathComponent) ?? edit.projectUID,
                    settings: settings, outputMode: edit.insertedGapDuration > .zero ? .gaps : .remove), replacementTarget: edit.replacementTarget)
            if let previous = try? JSONDecoder().decode(ProjectRoundTripReport.self,
                from: Data(contentsOf: directory.appendingPathComponent("Import-Verification.json"))),
               previous.verified, previous.expectedProjectUID == document.projectUID {
                result.hostProjectUID = previous.actualProjectUID
            }
            try result.savePending()
            return result
        }
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptFile))
        guard Self.digest(data) == receipt.expectedSHA256,
              let mode = CutdownOutputMode(rawValue: receipt.outputMode) else {
            throw EditedProjectWriterError.verificationFailed("the saved verification receipt no longer matches the result")
        }
        let result = try ImportedResultVerification(expected: data, outputURL: outputURL,
            originalProjectName: receipt.originalProjectName,
            request: AnalyzeRequest(id: receipt.requestID, settings: receipt.settings, outputMode: mode), replacementTarget: receipt.replacementTarget)
        result.hostProjectUID = receipt.hostProjectUID
        return result
    }

    func markComplete() { complete = true }

    func verify(capture: () async throws -> Data,
                restore: (ImportedSettingsRecovery.Correction, TimelineDocument) async throws -> Void) async throws -> ProjectRoundTripReport {
        guard try Data(contentsOf: outputURL) == expected else {
            throw EditedProjectWriterError.verificationFailed("the saved result changed; verification did not run")
        }
        let directory = outputURL.deletingLastPathComponent()
        let expectedSnapshot = try ProjectRoundTripVerification.Snapshot(data: expected)
        let actualData = try await capture()
        try replacementTarget?.verifyDestination(actualData)
        let actualSnapshot = try ProjectRoundTripVerification.Snapshot(data: actualData)
        let comparison = ProjectRoundTripVerification.Comparison(expected: expectedSnapshot, actual: actualSnapshot,
            allowHostAssignedIdentity: true, expectedHostProjectUID: hostProjectUID)
        let reportURL = directory.appendingPathComponent("Import-Verification.json")
        var report = try comparison.verify(reportURL: reportURL)
        if let bound = hostProjectUID, bound != report.actualProjectUID {
            throw EditedProjectWriterError.verificationFailed("the imported project identity changed")
        }
        hostProjectUID = report.actualProjectUID
        try savePending()
        let corrections = try ImportedSettingsRecovery.plan(comparison)
        if !corrections.isEmpty {
            let document = actualSnapshot.document
            for correction in corrections {
                try Task.checkCancellation()
                try await restore(correction, document)
            }
            let recoveredData = try await capture()
            try replacementTarget?.verifyDestination(recoveredData)
            let recoveredSnapshot = try ProjectRoundTripVerification.Snapshot(data: recoveredData)
            report = try ProjectRoundTripVerification.Comparison(expected: expectedSnapshot, actual: recoveredSnapshot,
                allowHostAssignedIdentity: true, expectedHostProjectUID: hostProjectUID).verify(reportURL: reportURL)
            guard report.actualProjectUID == hostProjectUID else {
                throw EditedProjectWriterError.verificationFailed("the project changed during settings recovery")
            }
        }
        guard report.controllerSettingsPreserved != false else {
            throw EditedProjectWriterError.verificationFailed("Final Cut did not retain the recovered Cutdown settings. Retry Verification to try recovery again; no new import is needed")
        }
        try Task.checkCancellation()
        return report
    }
}
