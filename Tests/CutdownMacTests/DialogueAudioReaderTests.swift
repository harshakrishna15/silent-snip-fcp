import CutdownCore
import CoreMedia
import Foundation
import XCTest
@testable import CutdownMac

final class DialogueAudioReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CutdownAudioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testBorrowsContiguousPCMAndReusesScratchForUnalignedAndSegmentedBlocks() throws {
        let storage = PCMFloatSampleBuffer()
        let values: [Float] = [0.25, -0.5, 0, 1, -1, 0.125]
        let contiguous = try block(values)
        var original: UnsafeMutablePointer<Int8>?
        XCTAssertEqual(CMBlockBufferGetDataPointer(contiguous, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: nil, dataPointerOut: &original), kCMBlockBufferNoErr)
        try storage.withSamples(in: contiguous, count: values.count) {
            XCTAssertEqual(Array($0), values)
            XCTAssertEqual(UnsafeRawPointer($0.baseAddress), UnsafeRawPointer(original), "Contiguous audio must be borrowed, not copied")
        }
        let unaligned = try block(values, offset: 1)
        var scratchAddress: UInt = 0
        try storage.withSamples(in: unaligned, count: values.count) {
            XCTAssertEqual(Array($0), values)
            scratchAddress = UInt(bitPattern: $0.baseAddress!)
            XCTAssertEqual(scratchAddress % UInt(MemoryLayout<Float>.alignment), 0)
        }
        var segmented: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateEmpty(allocator: kCFAllocatorDefault, capacity: 2,
            flags: 0, blockBufferOut: &segmented), kCMBlockBufferNoErr)
        let joined = try XCTUnwrap(segmented)
        for half in [Array(values.prefix(3)), Array(values.suffix(3))] {
            let part = try block(half)
            XCTAssertEqual(CMBlockBufferAppendBufferReference(joined, targetBBuf: part, offsetToData: 0,
                dataLength: half.count * MemoryLayout<Float>.stride, flags: 0), kCMBlockBufferNoErr)
        }
        XCTAssertFalse(CMBlockBufferIsRangeContiguous(joined, atOffset: 0, length: values.count * 4))
        try storage.withSamples(in: joined, count: values.count) {
            XCTAssertEqual(Array($0), values)
            XCTAssertEqual(UInt(bitPattern: $0.baseAddress!), scratchAddress, "Fallback storage is reused across decoder chunks")
        }
        let shorter = try block([0.75, -0.75], offset: 1)
        try storage.withSamples(in: shorter, count: 2) {
            XCTAssertEqual(Array($0), [0.75, -0.75])
            XCTAssertEqual(UInt(bitPattern: $0.baseAddress!), scratchAddress)
        }
    }

    func testBorrowedAndCopiedPCMRejectNonfiniteSamplesAndWrongLengths() throws {
        let storage = PCMFloatSampleBuffer()
        for offset in [0, 1] {
            for invalid: Float in [.nan, .infinity, -.infinity] {
                let invalidBlock = try block([0.25, invalid], offset: offset)
                XCTAssertThrowsError(try storage.withSamples(in: invalidBlock, count: 2) { _ in
                    XCTFail("Invalid audio must not reach measurement")
                })
            }
            let valid = try block([0.25, -0.25], offset: offset)
            for count in [0, 1, 3, Int.max] {
                XCTAssertThrowsError(try storage.withSamples(in: valid, count: count) { _ in XCTFail("Wrong length") })
            }
            XCTAssertThrowsError(try storage.withSamples(in: valid, count: 2) { _ in throw CancellationError() })
            try storage.withSamples(in: valid, count: 2) { XCTAssertEqual(Array($0), [0.25, -0.25]) }
        }
    }

    private func block(_ samples: [Float], offset: Int = 0) throws -> CMBlockBuffer {
        let length = samples.count * MemoryLayout<Float>.stride
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: length + offset, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: offset, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block), kCMBlockBufferNoErr)
        let result = try XCTUnwrap(block)
        try samples.withUnsafeBytes {
            guard CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: result,
                offsetIntoDestination: 0, dataLength: length) == kCMBlockBufferNoErr else { throw CocoaError(.fileWriteUnknown) }
        }
        return result
    }

    func testMultichannelMeasurementsMatchPCMReferenceAcrossChunksAndPartialWindows() async throws {
        for rate in [44_100, 48_000] {
            let frames = rate + 137, channels = 6
            func sample(_ frame: Int, _ channel: Int) -> Int16 {
                Int16((frame * (channel + 1) % 20_000) - 10_000)
            }
            let url = try wave(sampleRate: rate, channels: channels, frames: frames, sample: sample)
            let audio = try await DialogueAudioReader.read(url: url, expectedDuration: RationalTime(Int64(frames), Int64(rate)),
                frameDuration: RationalTime(1, 30), windowDuration: 0.007)
            let width = Int((Double(rate) * 0.007).rounded())
            XCTAssertEqual(audio.windows.count, (frames + width - 1) / width)
            for (index, window) in audio.windows.enumerated() {
                let start = index * width, end = min(frames, start + width)
                XCTAssertEqual(window.range, TimeRange(start: RationalTime(Int64(start), Int64(rate)), end: RationalTime(Int64(end), Int64(rate))))
                for channel in 0..<channels {
                    let sum = (start..<end).reduce(0.0) { total, frame in
                        let value = Double(sample(frame, channel)) / 32_768
                        return total + value * value
                    }
                    XCTAssertEqual(window.channelRMS[channel], sqrt(sum / Double(end - start)), accuracy: 0.000_002)
                }
            }
        }
    }

    func testReadsExactSampleCountAndFinalPartialWindow() async throws {
        let url = try wave(sampleRate: 44_100, channels: 1, frames: 1_000) { _, _ in 8_192 }
        let audio = try await DialogueAudioReader.read(
            url: url, expectedDuration: RationalTime(1_000, 44_100), frameDuration: RationalTime(1, 30)
        )
        XCTAssertEqual(audio.duration, RationalTime(1_000, 44_100))
        XCTAssertEqual(audio.sampleRate, 44_100)
        XCTAssertEqual(audio.channelCount, 1)
        XCTAssertEqual(audio.windows.map(\.range), [
            TimeRange(start: .zero, end: RationalTime(441, 44_100)),
            TimeRange(start: RationalTime(441, 44_100), end: RationalTime(882, 44_100)),
            TimeRange(start: RationalTime(882, 44_100), end: RationalTime(1_000, 44_100))
        ])
        for window in audio.windows {
            // The final 118-sample window must not be padded with invented zeros.
            XCTAssertEqual(window.channelRMS[0], 0.25, accuracy: 0.000_001)
        }
    }

    func testThrottledProgressPreservesSourceTrimAndRenderedMeasurements() async throws {
        let url = try wave(sampleRate: 48_000, channels: 1, frames: 96_000) { frame, _ in
            frame < 48_000 ? 0 : 8_192
        }
        for source in [false, true] {
            let recorded = RecordedProgress()
            let audio: DialogueAudio
            if source {
                audio = try await SourceAudioReader.read(url: url,
                    range: TimeRange(start: RationalTime(1), end: RationalTime(2)),
                    timelineStart: RationalTime(10), windowDuration: 0.01,
                    progress: { recorded.append($0) })
                XCTAssertEqual(audio.windows.count, 100)
                XCTAssertEqual(audio.windows.first?.range.start, RationalTime(10))
                XCTAssertEqual(audio.windows.last?.range.end, RationalTime(11))
                XCTAssertTrue(audio.windows.allSatisfy { abs($0.channelRMS[0] - 0.25) < 0.000_001 })
            } else {
                audio = try await DialogueAudioReader.read(url: url, expectedDuration: RationalTime(2),
                    frameDuration: RationalTime(1, 30), progress: { recorded.append($0) })
                XCTAssertEqual(audio.windows.count, 200)
                XCTAssertEqual(audio.windows.last?.range.end, RationalTime(2))
                XCTAssertEqual(audio.windows[0].channelRMS[0], 0)
                XCTAssertEqual(audio.windows[100].channelRMS[0], 0.25, accuracy: 0.000_001)
            }
            let values = recorded.values
            XCTAssertEqual(values.last, 1)
            XCTAssertEqual(values.filter { $0 == 1 }.count, 1)
            XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
        }
    }

    private final class RecordedProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Double] = []
        func append(_ value: Double) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
        var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    func testAntiphaseStereoRemainsAudible() async throws {
        let url = try wave(sampleRate: 48_000, channels: 2, frames: 48_000) { _, channel in
            channel == 0 ? 8_192 : -8_192
        }
        let audio = try await DialogueAudioReader.read(
            url: url, expectedDuration: RationalTime(1), frameDuration: RationalTime(1, 30)
        )
        XCTAssertEqual(audio.channelCount, 2)
        XCTAssertEqual(audio.windows.count, 100)
        for window in audio.windows {
            XCTAssertEqual(window.channelRMS[0], 0.25, accuracy: 0.000_001)
            XCTAssertEqual(window.channelRMS[1], 0.25, accuracy: 0.000_001)
        }
        let result = try SilenceDetector.analyze(
            windows: audio.windows, target: TimeRange(start: .zero, end: RationalTime(1)),
            frameDuration: RationalTime(1, 30)
        )
        XCTAssertEqual(result.disposition, .noSilence)
    }

    func testDecodedSilenceRetainsExactProjectAlignment() async throws {
        let url = try wave(sampleRate: 48_000, channels: 2, frames: 144_000) { frame, _ in
            (48_000..<96_000).contains(frame) ? 0 : 8_192
        }
        let audio = try await DialogueAudioReader.read(
            url: url, expectedDuration: RationalTime(3), frameDuration: RationalTime(1, 30)
        )
        let result = try SilenceDetector.analyze(
            windows: audio.windows, target: TimeRange(start: .zero, end: RationalTime(3)),
            frameDuration: RationalTime(1, 30)
        )
        XCTAssertEqual(audio.duration, RationalTime(3))
        XCTAssertEqual(result.candidates, [TimeRange(start: RationalTime(11, 10), end: RationalTime(19, 10))])
    }

    func testDurationMismatchCannotBeAnalyzed() async throws {
        let url = try wave(sampleRate: 48_000, channels: 1, frames: 48_000) { _, _ in 8_192 }
        do {
            _ = try await DialogueAudioReader.read(
                url: url, expectedDuration: RationalTime(2), frameDuration: RationalTime(1, 30)
            )
            XCTFail("A range-only export must not be accepted as the entire project.")
        } catch DialogueAudioReader.AudioError.durationMismatch(let expected, let actual) {
            XCTAssertEqual(expected, 2)
            XCTAssertEqual(actual, 1, accuracy: 0.000_001)
        }
    }

    func testRejectsInvalidWindowAndProjectDurations() async throws {
        let url = try wave(sampleRate: 48_000, channels: 1, frames: 48_000) { _, _ in 8_192 }
        for window in [0, -1, Double.leastNonzeroMagnitude, 1e-100, .greatestFiniteMagnitude, .nan, .infinity] {
            await assertReadFails(url, windowDuration: window)
        }
        await assertReadFails(url, expectedDuration: .zero)
        await assertReadFails(url, expectedDuration: RationalTime(-1))
        await assertReadFails(url, frameDuration: .zero)
        await assertReadFails(url, frameDuration: RationalTime(-1, 30))
    }

    func testEmptyAndTruncatedFilesCannotBeTurnedIntoSilence() async throws {
        let empty = try wave(sampleRate: 48_000, channels: 1, frames: 0) { _, _ in 0 }
        await assertReadFails(empty)

        let truncated = try wave(sampleRate: 48_000, channels: 1, frames: 48_000) { _, _ in 8_192 }
        let data = try Data(contentsOf: truncated)
        // Keep the original 1-second header but remove half the physical samples.
        try data.dropLast(48_000).write(to: truncated)
        await assertReadFails(truncated)

        let corrupt = directory.appendingPathComponent("corrupt.wav")
        try Data("not an audio file".utf8).write(to: corrupt)
        await assertReadFails(corrupt)
    }

    private func assertReadFails(
        _ url: URL, expectedDuration: RationalTime = RationalTime(1),
        frameDuration: RationalTime = RationalTime(1, 30), windowDuration: Double = 0.01,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await DialogueAudioReader.read(
                url: url, expectedDuration: expectedDuration, frameDuration: frameDuration,
                windowDuration: windowDuration
            )
            XCTFail("Invalid or incomplete audio must fail without a crash.", file: file, line: line)
        } catch { }
    }

    /// A standard little-endian PCM WAV, generated without an external encoder.
    private func wave(
        sampleRate: Int, channels: Int, frames: Int, sample: (Int, Int) -> Int16
    ) throws -> URL {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = frames * channels * 2
        text("RIFF"); integer(UInt32(36 + byteCount)); text("WAVE")
        text("fmt "); integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(channels))
        integer(UInt32(sampleRate)); integer(UInt32(sampleRate * channels * 2))
        integer(UInt16(channels * 2)); integer(UInt16(16))
        text("data"); integer(UInt32(byteCount))
        for frame in 0..<frames {
            for channel in 0..<channels { integer(sample(frame, channel)) }
        }
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }
}
