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
              reviewed.review.cuts.map(\.proposedRange) == fresh.review.cuts.map(\.proposedRange),
              reviewed.review.cuts.map(\.isEligible) == fresh.review.cuts.map(\.isEligible),
              try reviewed.review.selectedCuts.allSatisfy({ cut in
                  try [cut.range.start, cut.range.end].allSatisfy {
                      try $0.roundedDown(toFrame: fresh.review.cutGrid) == $0
                  }
              }) else {
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
