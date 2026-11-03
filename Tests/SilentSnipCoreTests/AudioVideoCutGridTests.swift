import XCTest
@testable import SilentSnipCore

final class AudioVideoCutGridTests: XCTestCase {
    func testCommonGridUsesFiveVideoFramesAt2997And5994With48kAudio() throws {
        for frame in [RationalTime(1001, 30_000), .init(1001, 60_000)] {
            let grid = try AudioVideoCutGrid.frameDuration(videoFrameDuration: frame, sampleRate: 48_000)
            XCTAssertEqual(grid, try frame.multiplied(by: .init(5)))
            XCTAssertEqual(try grid.multiplied(by: .init(48_000)).denominator, 1)
        }
    }

    func testAlreadyCompatibleFrameRatesKeepTheirExistingGrid() throws {
        for frame in [RationalTime(1, 24), .init(1, 25), .init(1, 30), .init(1001, 24_000)] {
            XCTAssertEqual(try AudioVideoCutGrid.frameDuration(videoFrameDuration: frame, sampleRate: 48_000), frame)
        }
        XCTAssertEqual(try AudioVideoCutGrid.frameDuration(videoFrameDuration: .init(1, 24), sampleRate: 44_100), .init(1, 12))
    }

    func testInwardGridRetainsPaddingAndChecksMinimumAfterAlignment() throws {
        let frame = RationalTime(1001, 30_000)
        let grid = try AudioVideoCutGrid.frameDuration(videoFrameDuration: frame, sampleRate: 48_000)
        let windows = [AudioLevelWindow(range: .init(start: .zero, end: .init(1)), channelRMS: [0.1]),
            .init(range: .init(start: .init(1), end: .init(9, 5)), channelRMS: [0]),
            .init(range: .init(start: .init(9, 5), end: .init(3)), channelRMS: [0.1])]
        let target = TimeRange(start: .zero, end: .init(3))
        let result = try SilenceDetector.analyze(windows: windows, target: target,
            frameDuration: grid, settings: .init(minimumSilenceDuration: 0.5))
        XCTAssertEqual(result.candidates.count, 1)
        let cut = try XCTUnwrap(result.candidates.first)
        XCTAssertGreaterThanOrEqual(cut.start, .init(11, 10))
        XCTAssertLessThanOrEqual(cut.end, .init(17, 10))
        for boundary in [cut.start, cut.end] {
            XCTAssertEqual(try boundary.multiplied(by: .init(48_000)).denominator, 1)
            XCTAssertEqual(try boundary.roundedDown(toFrame: frame), boundary)
        }
        let tooShort = try SilenceDetector.analyze(windows: windows, target: target,
            frameDuration: grid, settings: .init(minimumSilenceDuration: 0.55))
        XCTAssertTrue(tooShort.candidates.isEmpty)
    }

    func testInvalidRatesAndOverflowFailRatherThanGuessingOrTrapping() throws {
        for rate in [Int64(0), -1, 768_001] {
            XCTAssertThrowsError(try AudioVideoCutGrid.frameDuration(videoFrameDuration: .init(1, 30), sampleRate: rate))
        }
        XCTAssertThrowsError(try AudioVideoCutGrid.frameDuration(videoFrameDuration: .zero, sampleRate: 48_000))
        XCTAssertThrowsError(try AudioVideoCutGrid.frameDuration(videoFrameDuration: .init(Int64.max), sampleRate: 48_000))
    }
}
