import CutdownCore
import Foundation

public enum FinalCutCaptureError: LocalizedError {
    case unavailable(String)
    case changedProject
    case invalidSelection(String)
    case unsupportedTimecode(String)
    case exportTimedOut
    case reviewRestoration(original: String, guidance: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail): return "Final Cut Pro could not complete this step: \(detail)"
        case .changedProject: return "The active project or Final Cut window changed. Return to the intended project and Analyze again."
        case .invalidSelection(let detail): return "Select one whole audio-only clip in the primary storyline carrying Cutdown Audio. \(detail)"
        case .unsupportedTimecode(let value): return "Cutdown cannot safely read the displayed timeline timecode ‘\(value)’. Use a supported hours:minutes:seconds:frames display."
        case .exportTimedOut: return "Final Cut Pro did not finish the project XML export in time. Close its export dialog if it remains open, then Analyze again."
        case .reviewRestoration(let original, let guidance): return "\(original) \(guidance)"
        }
    }
}

/// Exact conversion of the visible frame-number timecode. Fractional rates use
/// nominal frame labels; drop-frame labels omit frame numbers, not media frames.
