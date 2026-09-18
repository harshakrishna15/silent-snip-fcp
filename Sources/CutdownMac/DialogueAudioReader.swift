import AVFoundation
import Accelerate
import CutdownCore
import Foundation

/// Borrow aligned contiguous decoder storage for the duration of the callback.
/// Unaligned/segmented blocks use reusable scratch memory without zero-filling.
final class PCMFloatSampleBuffer {
    private var scratch: UnsafeMutablePointer<Float>?
    private var capacity = 0

    deinit { scratch?.deallocate() }

    func withSamples<T>(in block: CMBlockBuffer, count: Int,
                        _ body: (UnsafeBufferPointer<Float>) throws -> T) throws -> T {
        guard count > 0, count <= Int.max / MemoryLayout<Float>.stride,
              CMBlockBufferGetDataLength(block) == count * MemoryLayout<Float>.stride else {
            throw DialogueAudioReader.AudioError.invalidAudio
        }
        return try withExtendedLifetime(block) {
            var contiguousLength = 0
            var address: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(block, atOffset: 0,
                lengthAtOffsetOut: &contiguousLength, totalLengthOut: nil, dataPointerOut: &address)
            let samples: UnsafeBufferPointer<Float>
            if status == kCMBlockBufferNoErr, let address,
               contiguousLength >= count * MemoryLayout<Float>.stride,
               Int(bitPattern: address) % MemoryLayout<Float>.alignment == 0 {
                samples = UnsafeBufferPointer(start: UnsafeRawPointer(address).assumingMemoryBound(to: Float.self), count: count)
            } else {
                if capacity < count {
                    scratch?.deallocate()
                    scratch = .allocate(capacity: count)
                    capacity = count
                }
                guard let scratch, CMBlockBufferCopyDataBytes(block, atOffset: 0,
                    dataLength: count * MemoryLayout<Float>.stride, destination: scratch) == kCMBlockBufferNoErr else {
                    throw DialogueAudioReader.AudioError.invalidAudio
                }
                samples = UnsafeBufferPointer(start: scratch, count: count)
            }
            guard samples.allSatisfy({ $0.isFinite }) else { throw DialogueAudioReader.AudioError.invalidAudio }
            return try body(samples)
        }
    }
}

public struct DialogueAudio: Sendable {
    public let windows: [AudioLevelWindow]
    public let duration: RationalTime
    public let sampleRate: Double
    public let channelCount: Int
}

/// Reads the completed, full-project dialogue render. Never reconstructs a mix
/// from source clips or silently fills undecodable sections with silence.
public enum DialogueAudioReader {
    public static func read(
        url: URL,
        expectedDuration: RationalTime,
        frameDuration: RationalTime,
        windowDuration: Double = 0.01,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> DialogueAudio {
        guard url.isFileURL, expectedDuration > .zero, frameDuration > .zero,
              windowDuration.isFinite, windowDuration >= 0.000000001,
              let windowTime = try? RationalTime(seconds: windowDuration), windowTime > .zero else {
            throw AudioError.invalidAudio
        }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count == 1 else { throw AudioError.expectedSingleDialogueRender }
        let assetDuration = try await asset.load(.duration)
        let duration = try rational(assetDuration)
        guard abs(duration.seconds - expectedDuration.seconds) <= frameDuration.seconds else {
            throw AudioError.durationMismatch(expected: expectedDuration.seconds, actual: duration.seconds)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioError.invalidAudio }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AudioError.invalidAudio }

        var windows: [AudioLevelWindow] = []
        var rate: Int64 = 0
        var channels = 0
        var totalFrames: Int64 = 0
        var windowFrames = 0
        var framesInWindow = 0
        var windowStart: Int64 = 0
        var sums: [Double] = []
        let sampleStorage = PCMFloatSampleBuffer()
        var progressThrottle = AudioProgressThrottle()
        defer { if reader.status == .reading { reader.cancelReading() } }

        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let description = CMSampleBufferGetFormatDescription(buffer),
                  let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                  format.mSampleRate.isFinite, format.mSampleRate >= 1,
                  format.mSampleRate <= 768_000,
                  format.mSampleRate.rounded() == format.mSampleRate,
                  format.mChannelsPerFrame > 0, format.mChannelsPerFrame <= 64,
                  let block = CMSampleBufferGetDataBuffer(buffer) else { throw AudioError.invalidAudio }
            if rate == 0 {
                rate = Int64(format.mSampleRate)
                channels = Int(format.mChannelsPerFrame)
                let requestedFrames = (Double(rate) * windowDuration).rounded()
                guard requestedFrames.isFinite, requestedFrames < Double(Int.max) else {
                    throw AudioError.invalidAudio
                }
                windowFrames = max(1, Int(requestedFrames))
                sums = .init(repeating: 0, count: channels)
            }
            guard rate == Int64(format.mSampleRate), channels == Int(format.mChannelsPerFrame),
                  format.mBitsPerChannel == 32,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 else { throw AudioError.invalidAudio }
            let pts = try rational(CMSampleBufferGetPresentationTimeStamp(buffer))
            guard abs(pts.seconds - Double(totalFrames) / Double(rate)) <= 1.1 / Double(rate) else {
                throw AudioError.discontinuousAudio
            }
            let count = CMSampleBufferGetNumSamples(buffer)
            guard count >= 0, count <= Int.max / (channels * MemoryLayout<Float>.size) else { throw AudioError.invalidAudio }
            let sampleCount = count * channels
            guard CMBlockBufferGetDataLength(block) == sampleCount * MemoryLayout<Float>.size else { throw AudioError.invalidAudio }
            // Empty buffers contain no sample memory and cannot advance the clock.
            guard count > 0 else { continue }
            try sampleStorage.withSamples(in: block, count: sampleCount) { samples in
                var consumed = 0
                while consumed < count {
                    let take = min(windowFrames - framesInWindow, count - consumed)
                    for channel in 0..<channels {
                        var squareSum: Float = 0
                        vDSP_svesq(samples.baseAddress! + consumed * channels + channel,
                                   vDSP_Stride(channels), &squareSum, vDSP_Length(take))
                        sums[channel] += Double(squareSum)
                    }
                    guard sums.allSatisfy({ $0.isFinite }) else { throw AudioError.invalidAudio }
                    consumed += take
                    let nextFrames = totalFrames.addingReportingOverflow(Int64(take))
                    guard !nextFrames.overflow else { throw AudioError.invalidAudio }
                    totalFrames = nextFrames.partialValue
                    framesInWindow += take
                    if framesInWindow == windowFrames {
                        windows.append(AudioLevelWindow(
                            range: TimeRange(start: RationalTime(windowStart, rate), end: RationalTime(totalFrames, rate)),
                            channelRMS: sums.map { sqrt($0 / Double(framesInWindow)) }
                        ))
                        windowStart = totalFrames
                        framesInWindow = 0
                        for channel in sums.indices { sums[channel] = 0 }
                    }
                }
            }
            let fraction = min(1, Double(totalFrames) / Double(rate) / max(duration.seconds, 0.001))
            if fraction < 1, progressThrottle.shouldReport(fraction) { progress(fraction) }
        }
        guard reader.status == .completed else { throw reader.error ?? AudioError.invalidAudio }
        guard rate > 0, totalFrames > 0 else { throw AudioError.invalidAudio }
        if framesInWindow > 0 {
            windows.append(AudioLevelWindow(
                range: TimeRange(start: RationalTime(windowStart, rate), end: RationalTime(totalFrames, rate)),
                channelRMS: sums.map { sqrt($0 / Double(framesInWindow)) }
            ))
        }
        let decodedDuration = RationalTime(totalFrames, rate)
        guard abs(decodedDuration.seconds - expectedDuration.seconds) <= frameDuration.seconds else {
            throw AudioError.durationMismatch(expected: expectedDuration.seconds, actual: decodedDuration.seconds)
        }
        if progressThrottle.shouldReport(1) { progress(1) }
        return DialogueAudio(windows: windows, duration: decodedDuration, sampleRate: Double(rate), channelCount: channels)
    }

    private static func rational(_ time: CMTime) throws -> RationalTime {
        guard time.isValid, time.isNumeric, time.timescale > 0 else { throw AudioError.invalidAudio }
        return RationalTime(time.value, Int64(time.timescale))
    }

    public enum AudioError: LocalizedError {
        case invalidAudio, expectedSingleDialogueRender, discontinuousAudio
        case durationMismatch(expected: Double, actual: Double)
        public var errorDescription: String? {
            switch self {
            case .invalidAudio: return "The dialogue render could not be decoded completely as PCM audio."
            case .expectedSingleDialogueRender: return "Choose one completed, full-project dialogue-only audio render."
            case .discontinuousAudio: return "The dialogue render contains a timestamp gap. Cutdown cannot safely align it to the timeline."
            case let .durationMismatch(expected, actual):
                return String(format: "The dialogue render is %.3f seconds; the project is %.3f seconds. Export the entire project without a range selection.", actual, expected)
            }
        }
    }
}
