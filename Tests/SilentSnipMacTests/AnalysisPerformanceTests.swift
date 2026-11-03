import SilentSnipCore
import AVFoundation
import Foundation
import XCTest
@testable import SilentSnipMac

/// Opt-in, offline benchmark. Never launches Final Cut or mutates a library.
final class AnalysisPerformanceTests: XCTestCase {
    func testOfflineAnalysisBenchmark() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["SILENT_SNIP_BENCHMARK_INPUT"], let output = env["SILENT_SNIP_BENCHMARK_OUTPUT"] else {
            throw XCTSkip("Set SILENT_SNIP_BENCHMARK_INPUT and SILENT_SNIP_BENCHMARK_OUTPUT for the offline benchmark")
        }
        let url = URL(fileURLWithPath: input), frame = RationalTime(1, 30)
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard rate.isFinite, rate > 0, rate.rounded() == rate, file.length > 0 else {
            throw SourceAudioError.invalidAudio
        }
        let duration = RationalTime(file.length, Int64(rate))
        var renderedTimes: [Double] = [], sourceTimes: [Double] = [], reuseTimes: [Double] = [], hashTimes: [Double] = []
        var expected: [TimeRange]?
        for _ in 0..<3 {
            var start = ProcessInfo.processInfo.systemUptime
            _ = try await MediaContentSnapshot.capture([url])
            hashTimes.append(ProcessInfo.processInfo.systemUptime - start)
            start = ProcessInfo.processInfo.systemUptime
            let rendered = try await DialogueAudioReader.read(url: url, expectedDuration: duration, frameDuration: frame)
            renderedTimes.append(ProcessInfo.processInfo.systemUptime - start)
            start = ProcessInfo.processInfo.systemUptime
            let source = try await SourceAudioReader.read(url: url, range: .init(start: .zero, end: duration),
                timelineStart: .zero, windowDuration: 0.01)
            sourceTimes.append(ProcessInfo.processInfo.systemUptime - start)
            let target = TimeRange(start: .zero, end: duration)
            let baseline = try SilenceDetector.analyze(windows: rendered.windows, target: target, frameDuration: frame)
            let direct = try SilenceDetector.analyze(windows: source.windows, target: target, frameDuration: frame)
            XCTAssertEqual(baseline.candidates, direct.candidates)
            if let expected { XCTAssertEqual(baseline.candidates, expected) }
            expected = baseline.candidates
            for index in 0..<10 {
                let settings = try AnalysisSettings(thresholdDBFS: index % 2 == 0 ? -35 : -45)
                start = ProcessInfo.processInfo.systemUptime
                let result = try SilenceDetector.analyze(windows: rendered.windows, target: target, frameDuration: frame, settings: settings)
                reuseTimes.append(ProcessInfo.processInfo.systemUptime - start)
                XCTAssertFalse(result.candidates.isEmpty)
            }
        }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let report: [String: Any] = ["fixtureSeconds": duration.seconds,
            "channels": file.processingFormat.channelCount, "sampleRate": rate,
            "targetWholeWorkflowSeconds": duration.seconds / 60,
            "renderDecodeAndMeasureSeconds": renderedTimes, "sourceDecodeAndMeasureSeconds": sourceTimes,
            "hashSeconds": hashTimes, "recalculateSeconds": reuseTimes,
            "medianRenderDecodeAndMeasureSeconds": median(renderedTimes),
            "medianSourceDecodeAndMeasureSeconds": median(sourceTimes),
            "sourceDecodeAndMeasureSecondsPerMinute": median(sourceTimes) / (duration.seconds / 60),
            "medianHashSeconds": median(hashTimes), "medianRecalculateSeconds": median(reuseTimes),
            "candidateRanges": (expected ?? []).map { [$0.start.seconds, $0.end.seconds] },
            "scope": "Offline PCM processing only; excludes Final Cut export, rendering, verification and cleanup"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
