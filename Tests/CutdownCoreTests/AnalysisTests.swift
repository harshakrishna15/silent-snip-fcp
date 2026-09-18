import Foundation
import XCTest
@testable import CutdownCore

final class AnalysisTests: XCTestCase {
    private let frame = RationalTime(1, 100)

    private func range(_ start: Double, _ end: Double) -> TimeRange {
        TimeRange(start: try! RationalTime(seconds: start), end: try! RationalTime(seconds: end))
    }

    private func window(_ start: Double, _ end: Double, _ levels: [Double]) -> AudioLevelWindow {
        AudioLevelWindow(range: range(start, end), channelRMS: levels)
    }

    private func analyze(
        _ windows: [AudioLevelWindow], target: TimeRange? = nil,
        settings: AnalysisSettings = .defaults
    ) throws -> SilenceAnalysisResult {
        try SilenceDetector.analyze(windows: windows, target: target ?? range(0, 3), frameDuration: frame, settings: settings)
    }

    func testDefaultsPreservePaddingAroundSpeech() throws {
        let result = try analyze([window(0, 1, [0.3]), window(1, 2, [0]), window(2, 3, [0.3])])
        XCTAssertEqual(result.disposition, .cuts)
        XCTAssertEqual(result.candidates, [range(1.1, 1.9)])
        XCTAssertEqual(result.removedDuration, RationalTime(4, 5))
    }

    func testAsymmetricPaddingUsesTheCorrectSidesOfSpeech() throws {
        let settings = try AnalysisSettings(beforeSpeechPadding: 0.2, afterSpeechPadding: 0.05)
        let result = try analyze([window(0, 1, [0.3]), window(1, 2, [0]), window(2, 3, [0.3])], settings: settings)
        // The quiet run follows speech at 1s and precedes speech at 2s.
        XCTAssertEqual(result.candidates, [range(1.05, 1.8)])
    }

    func testLevelEqualToThresholdIsRetained() throws {
        let result = try analyze([window(0, 3, [0.01])])
        XCTAssertEqual(result.disposition, .noSilence)
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testDialogueInAnyChannelProtectsTheRange() throws {
        let result = try analyze([
            window(0, 1, [0.3, 0]), window(1, 2, [0, 0.02]), window(2, 3, [0.3, 0.3])
        ])
        XCTAssertEqual(result.disposition, .noSilence)
    }

    func testContiguousQuietWindowsAreCombined() throws {
        let result = try analyze([
            window(0, 1, [0.3]), window(1, 1.25, [0]), window(1.25, 1.5, [0.001]),
            window(1.5, 2, [0]), window(2, 3, [0.3])
        ])
        XCTAssertEqual(result.candidates, [range(1.1, 1.9)])
    }

    func testMinimumDurationIncludesEqualityBeforePadding() throws {
        let below = try analyze([window(0, 1, [0.3]), window(1, 1.49, [0]), window(1.49, 3, [0.3])])
        XCTAssertEqual(below.disposition, .noSilence)
        let equal = try analyze([window(0, 1, [0.3]), window(1, 1.5, [0]), window(1.5, 3, [0.3])])
        XCTAssertEqual(equal.candidates, [range(1.1, 1.4)])
    }

    func testClipIntersectionHappensBeforeMinimumDuration() throws {
        let result = try analyze([
            window(0, 0.1, [0.3]), window(0.1, 1.4, [0]), window(1.4, 3, [0.3])
        ], target: range(1, 2))
        // The timeline has a 1.3s pause, but only 0.4s belongs to the target clip.
        XCTAssertEqual(result.disposition, .noSilence)
    }

    func testSilenceOutsideTargetDoesNotExpandCutScope() throws {
        let result = try analyze([
            window(0, 1, [0]), window(1, 2, [0.3]), window(2, 3, [0])
        ], target: range(1, 2))
        XCTAssertEqual(result.disposition, .noSilence)
    }

    func testLeadingAndTrailingSilenceRetainConservativeEdgePadding() throws {
        let result = try analyze([window(0, 1, [0]), window(1, 2, [0.3]), window(2, 3, [0])])
        XCTAssertEqual(result.candidates, [range(0.1, 0.9), range(2.1, 2.9)])
    }

    func testEntirelySilentTargetCannotBeDeletedEvenWithZeroPadding() throws {
        let settings = try AnalysisSettings(beforeSpeechPadding: 0, afterSpeechPadding: 0)
        let result = try analyze([window(0, 3, [0, 0])], settings: settings)
        XCTAssertEqual(result.disposition, .entirelySilent)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.removedDuration, .zero)
    }

    func testMeasurementGapsAreNeverJoinedOrMarkedEntirelySilent() throws {
        let result = try analyze([window(0, 1, [0]), window(2, 3, [0])])
        XCTAssertEqual(result.disposition, .cuts)
        XCTAssertEqual(result.candidates, [range(0.1, 0.9), range(2.1, 2.9)])
        XCTAssertTrue(result.candidates.allSatisfy { $0.intersection(range(1, 2)) == nil })
    }

    func testMissingMeasurementsAreNotSilence() throws {
        XCTAssertEqual(try analyze([]).disposition, .noSilence)
    }

    func testFractionalFrameRateRoundsBothBoundariesInwardExactly() throws {
        let frame = RationalTime(1001, 30_000)
        let result = try SilenceDetector.analyze(
            windows: [window(0, 1, [0.3]), window(1, 2, [0]), window(2, 3, [0.3])],
            target: range(0, 3), frameDuration: frame
        )
        XCTAssertEqual(result.candidates, [TimeRange(start: frame * 33, end: frame * 56)])
        XCTAssertGreaterThanOrEqual(result.candidates[0].start, RationalTime(11, 10))
        XCTAssertLessThanOrEqual(result.candidates[0].end, RationalTime(19, 10))
    }

    func testSampleWindowsStayAlignedAtALongTimelineOffset() throws {
        // Ten hours and 36 seconds is an exact 29.97 fps frame boundary. The
        // audio uses a different clock (44.1 kHz), so no floating-point clock
        // accumulation is allowed to move an edit across a frame boundary.
        let frame = RationalTime(1001, 30_000)
        let baseFrames: Int64 = 1_080_000
        let baseSamples: Int64 = 36_036 * 44_100
        let windows: [AudioLevelWindow] = (0..<300).map { (index: Int) -> AudioLevelWindow in
            let firstSample = baseSamples + Int64(index) * 441
            let interval = TimeRange(
                start: RationalTime(firstSample, 44_100), end: RationalTime(firstSample + 441, 44_100)
            )
            let amplitude: Double = index >= 100 && index < 200 ? 0 : 0.3
            return AudioLevelWindow(range: interval, channelRMS: [amplitude])
        }
        let target = TimeRange(start: frame * baseFrames, end: frame * (baseFrames + 90))
        let settings = try AnalysisSettings(beforeSpeechPadding: 0.2, afterSpeechPadding: 0.05)
        let result = try SilenceDetector.analyze(
            windows: windows, target: target, frameDuration: frame, settings: settings
        )
        XCTAssertEqual(result.candidates, [TimeRange(
            start: frame * (baseFrames + 32), end: frame * (baseFrames + 53)
        )])
        XCTAssertEqual(result.removedDuration, frame * 21)
    }

    func testOneFrameRemovalAndSubframeRemoval() throws {
        let settings = try AnalysisSettings(minimumSilenceDuration: 0.001, beforeSpeechPadding: 0, afterSpeechPadding: 0)
        let oneFrame = try analyze([
            window(0, 1, [0.3]), window(1, 1.01, [0]), window(1.01, 3, [0.3])
        ], settings: settings)
        XCTAssertEqual(oneFrame.candidates, [range(1, 1.01)])
        let subframe = try analyze([
            window(0, 1.001, [0.3]), window(1.001, 1.009, [0]), window(1.009, 3, [0.3])
        ], settings: settings)
        XCTAssertEqual(subframe.disposition, .noSilence)
    }

    func testExcessivePaddingProducesNoInvalidRange() throws {
        let settings = try AnalysisSettings(beforeSpeechPadding: 0.6, afterSpeechPadding: 0.4)
        let result = try analyze([window(0, 1, [0.3]), window(1, 2, [0]), window(2, 3, [0.3])], settings: settings)
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testSettingsRejectNonfiniteAndOutOfRangeValues() throws {
        XCTAssertThrowsError(try AnalysisSettings(thresholdDBFS: .nan))
        XCTAssertThrowsError(try AnalysisSettings(thresholdDBFS: 1))
        XCTAssertThrowsError(try AnalysisSettings(thresholdDBFS: -121))
        XCTAssertThrowsError(try AnalysisSettings(minimumSilenceDuration: 0))
        XCTAssertThrowsError(try AnalysisSettings(beforeSpeechPadding: -.infinity))
        XCTAssertThrowsError(try AnalysisSettings(afterSpeechPadding: -0.1))
        XCTAssertThrowsError(try AnalysisSettings(windowDuration: 0))
        XCTAssertThrowsError(try AnalysisSettings(windowDuration: Double.greatestFiniteMagnitude))
        XCTAssertThrowsError(try AnalysisSettings(minimumSilenceDuration: 0.0000000001))
    }

    func testRejectsInvalidChannelsAndOverlappingWindows() throws {
        for levels in [[Double.nan], [Double.infinity], [-0.1], []] {
            XCTAssertThrowsError(try analyze([window(0, 3, levels)]))
        }
        XCTAssertThrowsError(try analyze([window(0, 2, [0]), window(1, 3, [0])]))
        XCTAssertThrowsError(try analyze([window(2, 3, [0]), window(0, 1, [0])]))
        XCTAssertThrowsError(try analyze([window(1, 1, [0])]))
        XCTAssertThrowsError(try SilenceDetector.analyze(windows: [], target: range(0, 3), frameDuration: .zero))
    }

    func testExtremeTargetAndFrameTimesThrowInsteadOfTrapping() throws {
        let excessive = TimeRange(start: RationalTime(Int64.min), end: RationalTime(Int64.max))
        XCTAssertThrowsError(try analyze([], target: excessive))
        let extremeWindow = AudioLevelWindow(range: excessive, channelRMS: [0])
        XCTAssertThrowsError(try analyze([extremeWindow]))
        XCTAssertThrowsError(try SilenceDetector.analyze(
            windows: [window(0, 1, [0.3]), window(1, 2, [0]), window(2, 3, [0.3])],
            target: range(0, 3), frameDuration: RationalTime(1, Int64.max)
        ))
    }

    func testCodableRoundTripAndMalformedSettings() throws {
        let settings = try AnalysisSettings(beforeSpeechPadding: 0.2, afterSpeechPadding: 0.05)
        XCTAssertEqual(try JSONDecoder().decode(AnalysisSettings.self, from: JSONEncoder().encode(settings)), settings)
        let invalid = Data("{\"thresholdDBFS\":-40,\"minimumSilenceDuration\":0.5,\"beforeSpeechPadding\":-1,\"afterSpeechPadding\":0.1,\"windowDuration\":0.01}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AnalysisSettings.self, from: invalid))
        let result = try analyze([window(0, 1, [0.3]), window(1, 2, [0]), window(2, 3, [0.3])])
        XCTAssertEqual(try JSONDecoder().decode(SilenceAnalysisResult.self, from: JSONEncoder().encode(result)), result)
        XCTAssertThrowsError(try SilenceAnalysisResult(candidates: [], disposition: .cuts))
    }
}
