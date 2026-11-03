import Foundation

/// The smallest project-frame step whose duration is an integer number of
/// native audio samples. Inward rounding to this grid retains padding and
/// avoids resampling or rounding the kept audio at newly generated joins.
public enum AudioVideoCutGrid {
    public static func frameDuration(videoFrameDuration: RationalTime,
                                     sampleRate: Int64) throws -> RationalTime {
        guard videoFrameDuration > .zero else { throw AnalysisError.invalidFrameDuration }
        guard sampleRate > 0, sampleRate <= 768_000 else {
            throw AnalysisError.invalidSetting("audio sample rate")
        }
        let samplesPerFrame = try videoFrameDuration.multiplied(by: RationalTime(sampleRate))
        return try videoFrameDuration.multiplied(by: RationalTime(samplesPerFrame.denominator))
    }
}
