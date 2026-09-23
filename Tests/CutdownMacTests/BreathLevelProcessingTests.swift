import CutdownCore
import Foundation
import XCTest
@testable import CutdownMac

/// These fixtures verify level-based processing of breath-like noise, not breath
/// recognition. Their noise is synthetic and is not a speech-classification test.
final class BreathLevelProcessingTests: XCTestCase {
    private var directory: URL!
    private let sampleRate = 48_000
    private let frameDuration = RationalTime(1, 30)
    private let target = TimeRange(start: .zero, end: RationalTime(6))

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CutdownBreathLevels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testQuietNoisePauseIsCutButLouderAndShortNoiseAreRetained() async throws {
        let audio = try await decodedFixture()
        XCTAssertEqual(audio.duration, RationalTime(6))
        XCTAssertEqual(audio.windows.count, 600)
        XCTAssertEqual(audio.sampleRate, 48_000)

        // Assert actual decoded levels, so the test cannot pass using zero-filled
        // silence in place of the nonzero, noisy audio supplied to AVFoundation.
        for window in audio.windows[100..<200] {
            XCTAssertEqual(20 * log10(window.channelRMS[0]), -50, accuracy: 0.1)
        }
        for window in audio.windows[300..<400] {
            XCTAssertEqual(20 * log10(window.channelRMS[0]), -28, accuracy: 0.1)
        }

        let result = try analyze(audio)
        XCTAssertEqual(result.disposition, .cuts)
        XCTAssertEqual(result.candidates, [range(11, 19, denominator: 10)])
        XCTAssertEqual(result.removedDuration, RationalTime(4, 5))
        // The louder noisy event at 3–4 seconds and short quiet noisy event at
        // 5–5.3 seconds remain, despite their similar noise-like character.
        XCTAssertTrue(result.candidates.allSatisfy { $0.end <= RationalTime(2) })
    }

    func testThresholdControlsNoiseRemovalWithoutIdentifyingItsContent() async throws {
        let audio = try await decodedFixture()
        let lowerThreshold = try analyze(audio, settings: AnalysisSettings(thresholdDBFS: -55))
        XCTAssertEqual(lowerThreshold.disposition, .noSilence)
        XCTAssertTrue(lowerThreshold.candidates.isEmpty)

        let higherThreshold = try analyze(audio, settings: AnalysisSettings(thresholdDBFS: -25))
        XCTAssertEqual(higherThreshold.candidates, [
            range(11, 19, denominator: 10), range(31, 39, denominator: 10)
        ])
        XCTAssertEqual(higherThreshold.removedDuration, RationalTime(8, 5))
    }

    func testShortQuietNoiseRequiresMinimumRemovalAfterPadding() async throws {
        let audio = try await decodedFixture()
        let tooShort = try analyze(audio, settings: AnalysisSettings(minimumSilenceDuration: 0.25))
        XCTAssertEqual(tooShort.candidates, [range(11, 19, denominator: 10)])
        let result = try analyze(audio, settings: AnalysisSettings(minimumSilenceDuration: 0.1))
        XCTAssertEqual(result.candidates, [
            range(11, 19, denominator: 10), range(51, 52, denominator: 10)
        ])
        XCTAssertEqual(result.removedDuration, RationalTime(9, 10))
    }

    func testLouderSecondChannelProtectsQuietNoiseInFirstChannel() async throws {
        let audio = try await decodedFixture(protectQuietPauseInRightChannel: true)
        XCTAssertEqual(audio.channelCount, 2)
        for window in audio.windows[100..<200] {
            XCTAssertEqual(20 * log10(window.channelRMS[0]), -50, accuracy: 0.1)
            XCTAssertEqual(20 * log10(window.channelRMS[1]), -28, accuracy: 0.1)
        }
        let result = try analyze(audio)
        XCTAssertEqual(result.disposition, .noSilence)
        XCTAssertTrue(result.candidates.isEmpty)
    }

    private func analyze(
        _ audio: DialogueAudio, settings: AnalysisSettings = .defaults
    ) throws -> SilenceAnalysisResult {
        try SilenceDetector.analyze(
            windows: audio.windows, target: target, frameDuration: frameDuration, settings: settings
        )
    }

    private func range(_ start: Int64, _ end: Int64, denominator: Int64) -> TimeRange {
        TimeRange(start: RationalTime(start, denominator), end: RationalTime(end, denominator))
    }

    /// Six seconds of tone with three noisy intervals: a long quiet pause, a
    /// long louder pause, and a short quiet pause. Every 10 ms noise window is
    /// normalized to a known RMS before 16-bit PCM quantization. Filtering the
    /// seeded noise removes most low-frequency energy without introducing a
    /// classifier or an assumption about the spectrum of a real human breath.
    private func decodedFixture(protectQuietPauseInRightChannel: Bool = false) async throws -> DialogueAudio {
        let channels = protectQuietPauseInRightChannel ? 2 : 1
        let frames = 6 * sampleRate
        let windowFrames = sampleRate / 100
        var samples = [[Int16]](repeating: [Int16](repeating: 0, count: frames), count: channels)
        var seed: UInt64 = 0xC07D0_0BEE_F123
        var lowPass = 0.0

        for channel in 0..<channels {
            for window in 0..<600 {
                let quietLong = (100..<200).contains(window)
                let louderLong = (300..<400).contains(window)
                let quietShort = (500..<530).contains(window)
                let isNoise = quietLong || louderLong || quietShort
                let protected = quietLong && channel == 1 && protectQuietPauseInRightChannel
                let rmsDBFS = (louderLong || protected) ? -28.0 : -50.0
                var waveform = [Double](repeating: 0, count: windowFrames)
                for index in 0..<windowFrames {
                    if isNoise {
                        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                        let raw = Double(seed >> 32) / Double(UInt32.max) * 2 - 1
                        lowPass = 0.9 * lowPass + 0.1 * raw
                        waveform[index] = raw - lowPass
                    } else {
                        // A 1 kHz tone has an exact number of periods per window.
                        waveform[index] = sin(2 * .pi * 1_000 * Double(index) / Double(sampleRate))
                    }
                }
                let unscaledRMS = sqrt(waveform.reduce(0) { $0 + $1 * $1 } / Double(windowFrames))
                let desiredRMS = pow(10, (isNoise ? rmsDBFS : -18.0) / 20)
                for index in 0..<windowFrames {
                    let value = waveform[index] * desiredRMS / unscaledRMS
                    samples[channel][window * windowFrames + index] = Int16((value * 32_767).rounded())
                }
            }
        }

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
            for channel in 0..<channels { integer(samples[channel][frame]) }
        }
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        try data.write(to: url)
        return try await DialogueAudioReader.read(
            url: url, expectedDuration: RationalTime(6), frameDuration: frameDuration
        )
    }
}
