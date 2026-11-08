import Foundation
import SilentSnipCore

/// Fresh audio must reproduce the reviewed candidates, including protected
/// intervals, before an audio-snapshot preview can authorize an import.
enum ReviewedCutValidation {
    static func verify(reviewed: AnalyzedAudioProject, fresh: AnalyzedAudioProject) throws {
        guard reviewed.settings == fresh.settings,
              reviewed.document.fingerprint == fresh.document.fingerprint,
              reviewed.target == fresh.target,
              reviewed.analysis.disposition == fresh.analysis.disposition,
              reviewed.review.cuts.map(\.range) == fresh.review.cuts.map(\.range),
              reviewed.review.cuts.map(\.isEligible) == fresh.review.cuts.map(\.isEligible) else {
            throw SnapshotPreviewError.audioChanged
        }
    }
}

enum SnapshotPreviewError: LocalizedError {
    case audioChanged
    var errorDescription: String? {
        "The current audio no longer matches the reviewed cuts. No project was imported. Click Analyze Again, review the new cuts, then click Apply Cuts."
    }
}
