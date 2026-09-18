import AVFoundation
import Accelerate
import CutdownCore
import Foundation

/// Reads only the selected source interval. No Final Cut render or temporary WAV.
public enum SourceAudioReader {
    public static func read(url: URL, range: TimeRange, timelineStart: RationalTime,
                            windowDuration: Double,
                            progress: @Sendable (Double) -> Void = { _ in }) async throws -> DialogueAudio {
        guard url.isFileURL, range.start >= .zero, !range.isEmpty,
              windowDuration.isFinite, windowDuration > 0 else { throw SourceAudioError.invalidRange }
        let asset = AVURLAsset(url: url)
        guard try await asset.loadTracks(withMediaType: .audio).count == 1 else {
            throw SourceAudioError.multipleTracks
        }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate.isFinite, rate >= 1, rate <= 768_000, rate.rounded() == rate,
              format.channelCount > 0, format.channelCount <= 64 else { throw SourceAudioError.invalidAudio }
        let firstValue = ceil(range.start.seconds * rate)
        let endValue = floor(range.end.seconds * rate)
        let capacity = (windowDuration * rate).rounded()
        guard firstValue >= 0, endValue < Double(Int64.max), endValue > firstValue,
              capacity >= 1, capacity <= Double(UInt32.max) else { throw SourceAudioError.invalidRange }
        let first = Int64(firstValue), end = Int64(endValue)
        guard end <= file.length else { throw SourceAudioError.incompleteAudio }
        file.framePosition = first
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(capacity)) else {
            throw SourceAudioError.invalidAudio
        }
        var position = first
        var windows: [AudioLevelWindow] = []
        var progressThrottle = AudioProgressThrottle()
        while position < end {
            try Task.checkCancellation()
            let count = UInt32(min(Int64(capacity), end - position))
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength == count, let channels = buffer.floatChannelData else {
                throw SourceAudioError.incompleteAudio
            }
            var rms: [Double] = []
            for channel in 0..<Int(format.channelCount) {
                let samples = UnsafeBufferPointer(start: channels[channel], count: Int(count))
                guard samples.allSatisfy({ $0.isFinite }) else { throw SourceAudioError.invalidAudio }
                var level: Float = 0
                vDSP_rmsqv(channels[channel], 1, &level, vDSP_Length(count))
                guard level.isFinite else { throw SourceAudioError.invalidAudio }
                rms.append(Double(level))
            }
            let start = position == first ? timelineStart : try timelineStart.adding(RationalTime(position, Int64(rate)).subtracting(range.start))
            position += Int64(count)
            let finish = position == end ? try timelineStart.adding(range.checkedDuration())
                : try timelineStart.adding(RationalTime(position, Int64(rate)).subtracting(range.start))
            windows.append(AudioLevelWindow(range: TimeRange(start: start, end: finish), channelRMS: rms))
            let fraction = Double(position - first) / Double(end - first)
            if progressThrottle.shouldReport(fraction) { progress(fraction) }
        }
        return DialogueAudio(windows: windows, duration: RationalTime(end - first, Int64(rate)),
                             sampleRate: rate, channelCount: Int(format.channelCount))
    }
}

public enum SourceAudioError: LocalizedError {
    case invalidRange, invalidAudio, multipleTracks, incompleteAudio
    public var errorDescription: String? {
        switch self {
        case .invalidRange: return "The selected source trim could not be mapped to audio samples."
        case .invalidAudio: return "The source audio could not be decoded as finite PCM samples."
        case .multipleTracks: return "Direct source analysis requires one audio track. Multitrack source files are not supported yet."
        case .incompleteAudio: return "The source audio does not completely cover the selected trim. No cuts were applied."
        }
    }
}
