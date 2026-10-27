import Foundation

/// Opening the helper alone must still allow first-run setup. Once Final Cut
/// has been observed, its exit ends this helper session after work unwinds.
public struct FinalCutHelperLifetime {
    public enum Action: Equatable { case wait, cancelWork, quit }
    private var observedHost = false
    public private(set) var isStopping = false

    public init() {}

    public mutating func update(hostIsRunning: Bool, isBusy: Bool) -> Action {
        if !isStopping {
            if hostIsRunning { observedHost = true; return .wait }
            guard observedHost else { return .wait }
            isStopping = true
            if isBusy { return .cancelWork }
        }
        return isBusy ? .wait : .quit
    }
}
