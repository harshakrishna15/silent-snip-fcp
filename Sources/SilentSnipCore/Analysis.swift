import Foundation

public enum AnalysisError: Error, Equatable, LocalizedError {
    case invalidSetting(String)
    case invalidAudioWindow(Int)
    case unorderedOrOverlappingWindows(Int)
    case invalidFrameDuration

    public var errorDescription: String? {
        switch self {
        case .invalidSetting(let name): return "Invalid analysis setting: \(name)."
        case .invalidAudioWindow(let index): return "Audio window \(index + 1) has an invalid range or channel level."
        case .unorderedOrOverlappingWindows(let index): return "Audio window \(index + 1) overlaps an earlier window or is out of order."
        case .invalidFrameDuration: return "The project frame duration must be positive."
        }
    }
}

public struct AnalysisSettings: Codable, Equatable, Sendable {
    public let thresholdDBFS: Double
    public let minimumSilenceDuration: Double
    public let beforeSpeechPadding: Double
    public let afterSpeechPadding: Double
    public let windowDuration: Double
    public let pauseTargetDuration: Double?

    public static let defaults = try! AnalysisSettings()

    public init(
        thresholdDBFS: Double = -40,
        minimumSilenceDuration: Double = 0.5,
        beforeSpeechPadding: Double = 0.1,
        afterSpeechPadding: Double = 0.1,
        windowDuration: Double = 0.01,
        pauseTargetDuration: Double? = nil
    ) throws {
        guard thresholdDBFS.isFinite, (-120...0).contains(thresholdDBFS) else {
            throw AnalysisError.invalidSetting("threshold must be between −120 and 0 dBFS")
        }
        if let pauseTargetDuration {
            guard pauseTargetDuration.isFinite, pauseTargetDuration > 0,
                  let time = try? RationalTime(seconds: pauseTargetDuration), time > .zero else {
                throw AnalysisError.invalidSetting("pause target duration")
            }
        }
        for (name, value, zeroAllowed) in [
            ("minimum silence duration", minimumSilenceDuration, false),
            ("padding before speech", beforeSpeechPadding, true),
            ("padding after speech", afterSpeechPadding, true),
            ("analysis window duration", windowDuration, false)
        ] {
            guard value.isFinite, value >= 0, zeroAllowed || value >= 0.000000001,
                  let rational = try? RationalTime(seconds: value), zeroAllowed || rational > .zero else {
                throw AnalysisError.invalidSetting(name)
            }
        }
        self.thresholdDBFS = thresholdDBFS
        self.minimumSilenceDuration = minimumSilenceDuration
        self.beforeSpeechPadding = beforeSpeechPadding
        self.afterSpeechPadding = afterSpeechPadding
        self.windowDuration = windowDuration
        self.pauseTargetDuration = pauseTargetDuration
    }

    private enum CodingKeys: String, CodingKey {
        case thresholdDBFS, minimumSilenceDuration, beforeSpeechPadding, afterSpeechPadding, windowDuration, pauseTargetDuration
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            thresholdDBFS: values.decode(Double.self, forKey: .thresholdDBFS),
            minimumSilenceDuration: values.decode(Double.self, forKey: .minimumSilenceDuration),
            beforeSpeechPadding: values.decode(Double.self, forKey: .beforeSpeechPadding),
            afterSpeechPadding: values.decode(Double.self, forKey: .afterSpeechPadding),
            windowDuration: values.decode(Double.self, forKey: .windowDuration),
            pauseTargetDuration: values.decodeIfPresent(Double.self, forKey: .pauseTargetDuration)
        )
    }
}

/// RMS amplitudes for each rendered dialogue channel, before any channel averaging.
public struct AudioLevelWindow: Codable, Equatable, Sendable {
    public let range: TimeRange
    public let channelRMS: [Double]

    public init(range: TimeRange, channelRMS: [Double]) {
        self.range = range
        self.channelRMS = channelRMS
    }
}

public enum SilenceAnalysisDisposition: String, Codable, Sendable {
    case cuts
    case noSilence
    case entirelySilent
}

public struct SilenceAnalysisResult: Codable, Equatable, Sendable {
    public let candidates: [TimeRange]
    public let disposition: SilenceAnalysisDisposition
    public let removedDuration: RationalTime

    public init(candidates: [TimeRange], disposition: SilenceAnalysisDisposition) throws {
        var total = RationalTime.zero
        var previousEnd: RationalTime?
        for (index, range) in candidates.enumerated() {
            guard !range.isEmpty else { throw AnalysisError.invalidAudioWindow(index) }
            if let previousEnd, range.start < previousEnd {
                throw AnalysisError.unorderedOrOverlappingWindows(index)
            }
            total = try total.adding(range.checkedDuration())
            previousEnd = range.end
        }
        guard (disposition == .cuts) == !candidates.isEmpty else {
            throw AnalysisError.invalidSetting("analysis disposition does not match its cut ranges")
        }
        self.candidates = candidates
        self.disposition = disposition
        self.removedDuration = total
    }

    private enum CodingKeys: String, CodingKey { case candidates, disposition }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            candidates: values.decode([TimeRange].self, forKey: .candidates),
            disposition: values.decode(SilenceAnalysisDisposition.self, forKey: .disposition)
        )
    }
}

public enum SilenceDetector {
    /// Input windows are in project time and must be ordered and non-overlapping.
    /// Unmeasured gaps always split quiet runs and are never eligible for removal.
    public static func analyze(
        windows: [AudioLevelWindow],
        target: TimeRange,
        frameDuration: RationalTime,
        settings: AnalysisSettings = .defaults,
        allowsEntireScope: Bool = false
    ) throws -> SilenceAnalysisResult {
        guard frameDuration > .zero else { throw AnalysisError.invalidFrameDuration }
        _ = try target.checkedDuration()
        var previousEnd: RationalTime?
        for (index, window) in windows.enumerated() {
            guard !window.range.isEmpty, !window.channelRMS.isEmpty,
                  window.channelRMS.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw AnalysisError.invalidAudioWindow(index)
            }
            _ = try window.range.checkedDuration()
            if let previousEnd, window.range.start < previousEnd {
                throw AnalysisError.unorderedOrOverlappingWindows(index)
            }
            previousEnd = window.range.end
        }
        guard !target.isEmpty else { return try SilenceAnalysisResult(candidates: [], disposition: .noSilence) }

        let thresholdAmplitude = pow(10, settings.thresholdDBFS / 20)
        let minimum = try RationalTime(seconds: settings.minimumSilenceDuration)
        let beforeSpeech = try RationalTime(seconds: settings.beforeSpeechPadding)
        let afterSpeech = try RationalTime(seconds: settings.afterSpeechPadding)
        let totalPadding = try beforeSpeech.adding(afterSpeech)
        let pauseTarget = try settings.pauseTargetDuration.map { try RationalTime(seconds: $0) }
        let roomTonePerSide = try pauseTarget.map { try max(.zero, $0.subtracting(totalPadding)).multiplied(by: RationalTime(1, 2)) }
        var quietRuns: [TimeRange] = []
        var coverageEnd = target.start
        var coverageHasGap = false
        var hasAudibleWindow = false

        for window in windows {
            guard let clipped = window.range.intersection(target) else { continue }
            if clipped.start > coverageEnd { coverageHasGap = true }
            coverageEnd = clipped.end
            // A channel at the threshold is retained. Never average channels: opposite
            // waveforms must not cancel and turn real dialogue into apparent silence.
            let isQuiet = window.channelRMS.allSatisfy { $0 < thresholdAmplitude }
            if isQuiet {
                if let previous = quietRuns.last, previous.end == clipped.start {
                    quietRuns[quietRuns.count - 1] = TimeRange(start: previous.start, end: clipped.end)
                } else {
                    quietRuns.append(clipped)
                }
            } else {
                hasAudibleWindow = true
            }
        }
        if coverageEnd < target.end { coverageHasGap = true }
        if !allowsEntireScope && !coverageHasGap && !hasAudibleWindow {
            return try SilenceAnalysisResult(candidates: [], disposition: .entirelySilent)
        }

        var candidates: [TimeRange] = []
        for quiet in quietRuns {
            let duration = try quiet.checkedDuration()
            // Padding is retained at both boundaries, including target edges and gaps
            // in the measurements. Minimum Silence qualifies the padded cut
            // on the grid before any target-length shortening.
            guard duration > totalPadding else { continue }
            let paddedStart = try quiet.start.adding(afterSpeech)
            let paddedEnd = try quiet.end.subtracting(beforeSpeech)
            var start = try paddedStart.roundedUp(toFrame: frameDuration)
            var end = try paddedEnd.roundedDown(toFrame: frameDuration)
            guard end > start, try end.subtracting(start) >= minimum else { continue }
            if let pauseTarget, let roomTonePerSide {
                guard duration > pauseTarget else { continue }
                start = try paddedStart.adding(roomTonePerSide).roundedUp(toFrame: frameDuration)
                end = try paddedEnd.subtracting(roomTonePerSide).roundedDown(toFrame: frameDuration)
            }
            if end > start { candidates.append(TimeRange(start: start, end: end)) }
        }
        return try SilenceAnalysisResult(candidates: candidates, disposition: candidates.isEmpty ? .noSilence : .cuts)
    }
}
