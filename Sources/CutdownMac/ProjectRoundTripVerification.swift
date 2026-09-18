import CutdownCore
import Foundation

struct ProjectRoundTripReport: Codable, Sendable {
    let verified: Bool
    let differences: [String]
    let expectedProjectUID: String?
    let actualProjectUID: String?
    let expectedFingerprint: String
    let actualFingerprint: String
    /// Separate from rendering verification: FCP can omit passthrough AU state.
    let controllerSettingsPreserved: Bool?
}

enum ProjectRoundTripVerification {
    /// Local to a verification attempt. Never reuse a host snapshot after a
    /// restore or another export; the expected output bytes remain immutable.
    struct Snapshot {
        let document: TimelineDocument
        let settings: [String: AnalysisSettings]

        init(data: Data) throws {
            let exclusions = TimelineFingerprintExclusions(controllerEffectUIDs: [AudioControllerSettings.effectUID])
            document = try TimelineParser.parse(data: data, exclusions: exclusions)
            settings = try AudioControllerSettings.settingsByPrimaryClip(projectData: data)
        }
    }

    struct Comparison {
        let expected: Snapshot
        let actual: Snapshot
        let report: ProjectRoundTripReport

        init(expected: Snapshot, actual: Snapshot, allowHostAssignedIdentity: Bool = false,
             expectedHostProjectUID: String? = nil) {
            self.expected = expected
            self.actual = actual
            report = ProjectRoundTripVerification.compare(expected: expected, actual: actual,
                allowHostAssignedIdentity: allowHostAssignedIdentity, expectedHostProjectUID: expectedHostProjectUID)
        }

        @discardableResult func verify(reportURL: URL) throws -> ProjectRoundTripReport {
            try ProjectRoundTripVerification.saveAndVerify(report, reportURL: reportURL)
        }
    }

    /// Compare complete semantic timelines. Resource IDs, bookmarks, numeric
    /// time spelling, and only the passthrough controller's private settings are
    /// normalized by the parser. Rendering effects are never excluded.
    static func compare(expected: Data, actual: Data, allowHostAssignedIdentity: Bool = false, expectedHostProjectUID: String? = nil) throws -> ProjectRoundTripReport {
        try Comparison(expected: Snapshot(data: expected), actual: Snapshot(data: actual),
            allowHostAssignedIdentity: allowHostAssignedIdentity, expectedHostProjectUID: expectedHostProjectUID).report
    }

    private static func compare(expected: Snapshot, actual: Snapshot, allowHostAssignedIdentity: Bool,
                                expectedHostProjectUID: String?) -> ProjectRoundTripReport {
        let want = expected.document
        let got = actual.document
        var differences: [String] = []
        // Final Cut assigns a fresh project UUID on XML import. The first host
        // delivery may bind that UUID (including XML delivered with a render).
        // Comparisons against already bound host projects remain strict.
        if want.projectUID != got.projectUID && !allowHostAssignedIdentity { differences.append("project identity") }
        if allowHostAssignedIdentity && (got.projectUID?.isEmpty != false) { differences.append("missing imported project identity") }
        if let bound = expectedHostProjectUID, got.projectUID != bound { differences.append("imported project identity changed") }
        if want.projectName != got.projectName { differences.append("project name") }
        if want.projectRange != got.projectRange { differences.append("project duration") }
        if want.frameDuration != got.frameDuration { differences.append("frame rate") }
        if want.fingerprint != got.fingerprint { differences.append("timeline, media references, or effect settings") }
        let expectedSettings = expected.settings
        let actualSettings = actual.settings
        var settingsPreserved: Bool? = expectedSettings.isEmpty ? nil : true
        let returnedClips = Dictionary(grouping: got.clips, by: \.timelineRange)
        for clip in want.clips {
            guard let settings = expectedSettings[clip.id] else { continue }
            guard let returned = returnedClips[clip.timelineRange]?.first(where: { $0.sourceStart == clip.sourceStart }),
                  let actual = actualSettings[returned.id],
                  AudioControllerSettings.equivalent(actual, settings) else {
                settingsPreserved = false
                continue
            }
        }
        return .init(verified: differences.isEmpty, differences: differences,
            expectedProjectUID: want.projectUID, actualProjectUID: got.projectUID,
            expectedFingerprint: want.fingerprint, actualFingerprint: got.fingerprint,
            controllerSettingsPreserved: settingsPreserved)
    }

    @discardableResult static func verify(expected: Data, actual: Data, reportURL: URL, allowHostAssignedIdentity: Bool = false, expectedHostProjectUID: String? = nil) throws -> ProjectRoundTripReport {
        let report = try compare(expected: expected, actual: actual, allowHostAssignedIdentity: allowHostAssignedIdentity, expectedHostProjectUID: expectedHostProjectUID)
        return try saveAndVerify(report, reportURL: reportURL)
    }

    private static func saveAndVerify(_ report: ProjectRoundTripReport, reportURL: URL) throws -> ProjectRoundTripReport {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL, options: .atomic)
        guard report.verified else {
            throw EditedProjectWriterError.verificationFailed("Final Cut's imported project differs in \(report.differences.joined(separator: ", ")). The original project is unchanged. Verification report: \(reportURL.path)")
        }
        return report
    }
}
