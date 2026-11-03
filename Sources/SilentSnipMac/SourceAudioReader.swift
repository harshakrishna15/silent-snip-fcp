import AVFoundation
import Accelerate
import SilentSnipCore
import Foundation

/// Reads only the selected source interval. No Final Cut render or temporary WAV.
public enum SourceAudioReader {
    public static func read(url: URL, range: TimeRange, timelineStart: RationalTime,
                            windowDuration: Double,
                            expectedMediaDuration: RationalTime? = nil,
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
        if let expectedMediaDuration {
            guard abs(Double(file.length) / rate - expectedMediaDuration.seconds) <= 1.1 / rate else {
                throw ProjectAnalysisError.incompleteRender
            }
        }
        let firstValue = ceil(range.start.seconds * rate)
        let endValue = floor(range.end.seconds * rate)
        let capacity = (windowDuration * rate).rounded()
        guard firstValue >= 0, endValue < Double(Int64.max), endValue > firstValue,
              capacity >= 1, capacity <= Double(UInt32.max) else { throw SourceAudioError.invalidRange }
        let first = Int64(firstValue), end = Int64(endValue)
        let windowFrames = Int(capacity)
        // Decode in bounded blocks, then assemble the same sample groups in a
        // reusable window buffer. Some AVAudioFile decoders legitimately return
        // fewer frames than requested before EOF, so window boundaries must not
        // depend on read boundaries. Reducing from a fixed buffer base also
        // preserves the previous vDSP alignment and reduction behavior.
        let readCapacity = UInt32(min(Int64(32_768), end - first))
        guard end <= file.length else { throw SourceAudioError.incompleteAudio }
        file.framePosition = first
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readCapacity),
              let window = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(capacity)),
              let windowChannels = window.floatChannelData else {
            throw SourceAudioError.invalidAudio
        }
        var decodedPosition = first
        var position = first
        var framesInWindow = 0
        var windows: [AudioLevelWindow] = []
        var progressThrottle = AudioProgressThrottle()
        while decodedPosition < end {
            try Task.checkCancellation()
            guard file.framePosition == decodedPosition else { throw SourceAudioError.incompleteAudio }
            let requested = UInt32(min(Int64(readCapacity), end - decodedPosition))
            try file.read(into: buffer, frameCount: requested)
            let blockCount = Int(buffer.frameLength)
            guard blockCount > 0, blockCount <= Int(requested), let channels = buffer.floatChannelData,
                  file.framePosition == decodedPosition + Int64(blockCount) else {
                throw SourceAudioError.incompleteAudio
            }
            decodedPosition += Int64(blockCount)
            var offset = 0
            while offset < blockCount {
                try Task.checkCancellation()
                let count = min(windowFrames - framesInWindow, blockCount - offset)
                for channel in 0..<Int(format.channelCount) {
                    windowChannels[channel].advanced(by: framesInWindow)
                        .update(from: channels[channel].advanced(by: offset), count: count)
                }
                framesInWindow += count
                offset += count
                guard framesInWindow == windowFrames || (decodedPosition == end && offset == blockCount) else { continue }
                var rms: [Double] = []
                for channel in 0..<Int(format.channelCount) {
                    let samples = UnsafeBufferPointer(start: windowChannels[channel], count: framesInWindow)
                    guard samples.allSatisfy({ $0.isFinite }) else { throw SourceAudioError.invalidAudio }
                    var level: Float = 0
                    vDSP_rmsqv(windowChannels[channel], 1, &level, vDSP_Length(framesInWindow))
                    guard level.isFinite else { throw SourceAudioError.invalidAudio }
                    rms.append(Double(level))
                }
                let start = position == first ? timelineStart : try timelineStart.adding(RationalTime(position, Int64(rate)).subtracting(range.start))
                position += Int64(framesInWindow)
                let finish = position == end ? try timelineStart.adding(range.checkedDuration())
                    : try timelineStart.adding(RationalTime(position, Int64(rate)).subtracting(range.start))
                windows.append(AudioLevelWindow(range: TimeRange(start: start, end: finish), channelRMS: rms))
                framesInWindow = 0
                let fraction = Double(position - first) / Double(end - first)
                if progressThrottle.shouldReport(fraction) { progress(fraction) }
            }
        }
        guard position == end, framesInWindow == 0 else { throw SourceAudioError.incompleteAudio }
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
