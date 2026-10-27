import Foundation

/// Limit UI work independently of the number of decoded measurement windows.
/// Each reader owns its gate; the monotonic clock is injectable for tests.
struct AudioProgressThrottle {
    private var lastTime: TimeInterval?
    private var lastFraction = -Double.infinity

    mutating func shouldReport(_ fraction: Double,
                               at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard fraction.isFinite, (0...1).contains(fraction), fraction > lastFraction else { return false }
        guard lastTime == nil || fraction == 1 || time - lastTime! >= 0.1 else { return false }
        lastTime = time
        lastFraction = fraction
        return true
    }
}
