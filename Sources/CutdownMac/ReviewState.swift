import Foundation

/// Wire spellings stay stable; internal jobs use typed states.
public enum ReviewState: String, Codable, CaseIterable, Sendable {
    case analyzing, capturing, recalculating, review, applying, verifying, navigating, cancelling
    case completed, complete, failed, cancelled, unavailable

    public var isBusy: Bool {
        switch self {
        case .analyzing, .capturing, .recalculating, .applying, .verifying, .navigating, .cancelling: true
        default: false
        }
    }
    public var isTerminal: Bool {
        switch self {
        case .completed, .complete, .failed, .cancelled, .unavailable: true
        default: false
        }
    }
    public var canRetryVerification: Bool { self == .failed || self == .cancelled }
    var canCancel: Bool { self == .review || (isBusy && self != .cancelling) }
}
