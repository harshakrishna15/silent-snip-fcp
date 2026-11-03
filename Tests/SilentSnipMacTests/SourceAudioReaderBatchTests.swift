import Accelerate
import AVFoundation
import Foundation
import SilentSnipCore
import XCTest
@testable import SilentSnipMac

final class SourceAudioReaderBatchTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SilentSnipSourceBatch-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testTrimmedStereoMatchesWindowReadsIncludingFractionalEdgesAndPartialLastWindow() async throws {
        let url = try fixture(frames: 100_003, rate: 48_000, channels: 2)
        // Both edges land halfway through a source sample. Preserve the existing
        // ceil/floor read and the original requested timeline range exactly.
        let range = TimeRange(start: .init(17, 96_000), end: .init(180_017, 96_000))
        let timelineStart = RationalTime(7, 3)
        let progress = ProgressProbe()
        let actual = try await SourceAudioReader.read(url: url, range: range, timelineStart: timelineStart,
            windowDuration: 0.01, progress: { progress.record($0) })
        let expected = try reference(url: url, range: range, timelineStart: timelineStart, windowDuration: 0.01)
        assertIdentical(actual, expected)
        XCTAssertEqual(actual.duration, RationalTime(89_999, 48_000))
        XCTAssertEqual(actual.windows.count, 188)
        XCTAssertEqual(actual.windows.first?.range.start, timelineStart)
        XCTAssertEqual(actual.windows.last?.range.end, try timelineStart.adding(range.checkedDuration()))
        XCTAssertEqual(progress.values.last, 1)
        XCTAssertTrue(zip(progress.values, progress.values.dropFirst()).allSatisfy { $0 < $1 })
    }

    func testMonoNonintegralWindowSizeMatchesWindowReadsAcrossSeveralBlocks() async throws {
        let url = try fixture(frames: 100_007, rate: 44_100, channels: 1)
        let range = TimeRange(start: .init(71, 44_100), end: .init(99_991, 44_100))
        let expected = try reference(url: url, range: range, timelineStart: .init(12), windowDuration: 0.007)
        let actual = try await SourceAudioReader.read(url: url, range: range, timelineStart: .init(12),
            windowDuration: 0.007)
        assertIdentical(actual, expected)
        XCTAssertEqual(actual.windows.count, 324, "A 308.7-frame duration must continue rounding to 309 samples")
    }

    func testLargeWindowRetainsSingleWindowReadSemantics() async throws {
        let url = try fixture(frames: 123_457, rate: 48_000, channels: 1)
        let range = TimeRange(start: .zero, end: .init(123_457, 48_000))
        let expected = try reference(url: url, range: range, timelineStart: .zero, windowDuration: 1)
        let actual = try await SourceAudioReader.read(url: url, range: range, timelineStart: .zero,
            windowDuration: 1)
        assertIdentical(actual, expected)
        XCTAssertEqual(actual.windows.count, 3)
    }

    func testCompressedSourceDecoderProducesIdenticalMeasurementsAtBothReadSizes() async throws {
        let url = try fixture(frames: 120_007, rate: 48_000, channels: 2, compressed: true)
        let range = TimeRange(start: .init(733, 48_000), end: .init(119_991, 48_000))
        let actual = try await SourceAudioReader.read(url: url, range: range, timelineStart: .init(5),
            windowDuration: 0.01)
        let expected = try reference(url: url, range: range, timelineStart: .init(5), windowDuration: 0.01)
        assertIdentical(actual, expected)
    }

    func testNonfiniteSampleInLaterWindowAndSecondChannelIsRejected() async throws {
        let url = try fixture(frames: 100_003, rate: 48_000, channels: 2, nonfiniteFrame: 70_001)
        do {
            _ = try await SourceAudioReader.read(url: url,
                range: .init(start: .zero, end: .init(100_003, 48_000)), timelineStart: .zero, windowDuration: 0.01)
            XCTFail("Every channel and window must retain its finite-sample validation")
        } catch SourceAudioError.invalidAudio { }
    }

    func testCancellationAfterFirstWindowStopsWithinDecodedBlock() async throws {
        let url = try fixture(frames: 100_003, rate: 48_000, channels: 1)
        let progress = ProgressProbe()
        let task = Task {
            try await SourceAudioReader.read(url: url,
                range: .init(start: .zero, end: .init(100_003, 48_000)), timelineStart: .zero, windowDuration: 0.01,
                progress: {
                    progress.record($0)
                    withUnsafeCurrentTask { $0?.cancel() }
                })
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation must be checked between windows, not just between larger reads")
        } catch is CancellationError { }
        XCTAssertEqual(progress.values.count, 1)
        XCTAssertLessThan(try XCTUnwrap(progress.values.first), 1)
    }

    func testIncompleteSourceAndMismatchedExpectedDurationRemainRejected() async throws {
        let url = try fixture(frames: 48_000, rate: 48_000, channels: 1)
        do {
            _ = try await SourceAudioReader.read(url: url, range: .init(start: .zero, end: .init(2)),
                timelineStart: .zero, windowDuration: 0.01)
            XCTFail("The larger read must not conceal a missing source interval")
        } catch SourceAudioError.incompleteAudio { }
        do {
            _ = try await SourceAudioReader.read(url: url, range: .init(start: .zero, end: .init(1)),
                timelineStart: .zero, windowDuration: 0.01, expectedMediaDuration: .init(2))
            XCTFail("Expected native render duration is still authoritative")
        } catch ProjectAnalysisError.incompleteRender { }
    }

    private func assertIdentical(_ actual: DialogueAudio, _ expected: DialogueAudio,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.sampleRate, expected.sampleRate, file: file, line: line)
        XCTAssertEqual(actual.channelCount, expected.channelCount, file: file, line: line)
        XCTAssertEqual(actual.duration, expected.duration, file: file, line: line)
        XCTAssertEqual(actual.windows.map(\.range), expected.windows.map(\.range), file: file, line: line)
        XCTAssertEqual(actual.windows.map { $0.channelRMS.map(\.bitPattern) },
            expected.windows.map { $0.channelRMS.map(\.bitPattern) }, file: file, line: line)
    }

    /// A per-window regression oracle with the previous vDSP reductions and
    /// timestamp mapping. Small decoder requests also support large windows
    /// on AVAudioFile implementations that short-read larger PCM requests.
    private func reference(url: URL, range: TimeRange, timelineStart: RationalTime,
                           windowDuration: Double) throws -> DialogueAudio {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        let first = Int64(ceil(range.start.seconds * rate)), end = Int64(floor(range.end.seconds * rate))
        let capacity = UInt32((windowDuration * rate).rounded())
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity))
        let readBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: min(capacity, 1024)))
        file.framePosition = first
        var position = first
        var windows: [AudioLevelWindow] = []
        while position < end {
            let count = UInt32(min(Int64(capacity), end - position))
            let channels = try XCTUnwrap(buffer.floatChannelData)
            var filled: UInt32 = 0
            while filled < count {
                let requested = min(readBuffer.frameCapacity, count - filled)
                try file.read(into: readBuffer, frameCount: requested)
                guard readBuffer.frameLength == requested else { throw SourceAudioError.incompleteAudio }
                let readChannels = try XCTUnwrap(readBuffer.floatChannelData)
                for channel in 0..<Int(file.processingFormat.channelCount) {
                    channels[channel].advanced(by: Int(filled)).update(from: readChannels[channel], count: Int(requested))
                }
                filled += requested
            }
            var rms: [Double] = []
            for channel in 0..<Int(file.processingFormat.channelCount) {
                var level: Float = 0
                vDSP_rmsqv(channels[channel], 1, &level, vDSP_Length(count))
                rms.append(Double(level))
            }
            let start = position == first ? timelineStart : try timelineStart.adding(RationalTime(position, Int64(rate)).subtracting(range.start))
            position += Int64(count)
            let finish = position == end ? try timelineStart.adding(range.checkedDuration())
                : try timelineStart.adding(RationalTime(position, Int64(rate)).subtracting(range.start))
            windows.append(AudioLevelWindow(range: .init(start: start, end: finish), channelRMS: rms))
        }
        return DialogueAudio(windows: windows, duration: .init(end - first, Int64(rate)),
            sampleRate: rate, channelCount: Int(file.processingFormat.channelCount))
    }

    private func fixture(frames: Int, rate: Double, channels: Int, compressed: Bool = false,
                         nonfiniteFrame: Int? = nil) throws -> URL {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: UInt32(channels)))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames)))
        buffer.frameLength = UInt32(frames)
        let samples = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<channels {
            for index in 0..<frames {
                samples[channel][index] = Float((index * 37 + channel * 47) % 4_096 - 2_048) / 2_048
            }
        }
        if let nonfiniteFrame { samples[channels - 1][nonfiniteFrame] = .nan }
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(compressed ? "m4a" : "wav")
        // Keep the on-disk PCM settings explicit and interleaved while the
        // decoder and measurement buffers remain planar Float32.
        var settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        if compressed {
            settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                        AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 128_000]
        }
        // Release the writer (and finish an AAC container) before opening readers.
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        return url
    }

    private final class ProgressProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var fractions: [Double] = []
        var values: [Double] { lock.lock(); defer { lock.unlock() }; return fractions }
        func record(_ value: Double) { lock.lock(); defer { lock.unlock() }; fractions.append(value) }
    }
}
