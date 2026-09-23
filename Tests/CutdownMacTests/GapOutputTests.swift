import XCTest
import CutdownCore
@testable import CutdownMac

final class GapOutputTests: XCTestCase {
    private let selection = TimelineSelection(timelineRange: .init(start: .zero, end: .init(10)))
    private let short = TimeRange(start: .init(2), end: .init(5, 2))
    private let long = TimeRange(start: .init(6), end: .init(8))
    private var data: Data { Data("""
    <fcpxml version="1.11"><resources><format id="f" frameDuration="1/30s"/>
    <asset id="a" name="Voice" start="0s" duration="20s" hasAudio="1"><media-rep kind="original-media" src="file:///tmp/voice.wav"/></asset>
    </resources><library><event name="Test"><project name="Gap fixture" uid="gap-fixture">
    <sequence format="f" duration="14s" tcStart="3600s"><spine>
    <asset-clip ref="a" name="Voice" offset="3600s" start="1s" duration="10s" audioRole="dialogue"/>
    <asset-clip ref="a" name="Later" offset="3610s" start="12s" duration="4s" audioRole="dialogue"/>
    </spine></sequence></project></event></library></fcpxml>
    """.utf8) }

    func testOneSecondGapsReplaceShortAndLongPausesAndPreserveSourceTrims() throws {
        let result = try EditedProjectWriter.write(projectData: data, selection: selection,
            selectedRanges: [long, short], outputName: "With gaps", replacementGaps: [short: .init(1), long: .init(1)])
        let document = try TimelineParser.parse(data: result.xmlData)
        XCTAssertEqual(result.report.insertedGapDuration, .init(2))
        XCTAssertEqual(document.projectRange.duration, .init(27, 2))
        XCTAssertEqual(document.clips.filter { $0.kind == "gap" }.map(\.timelineRange), [
            .init(start: .init(2), end: .init(3)), .init(start: .init(13, 2), end: .init(15, 2))])
        XCTAssertEqual(document.clips.filter { $0.kind == "gap" }.map(\.sourceStart), [.init(3600), .init(3600)])
        XCTAssertEqual(result.report.retainedSegments.map(\.sourceRange.start), [.init(1), .init(7, 2), .init(9)])
        XCTAssertEqual(document.clips.last?.timelineRange.start, .init(19, 2))
        XCTAssertEqual(document.clips.last?.sourceStart, .init(12))
        XCTAssertEqual(document.projectTimecodeStart, .init(3600))
    }

    func testGapCanLengthenTimelineAndRippleModeRemainsUnchanged() throws {
        let gap = try EditedProjectWriter.write(projectData: data, selection: selection,
            selectedRanges: [short], outputName: "Gap", replacementGaps: [short: .init(1)])
        XCTAssertEqual(gap.report.resultProjectDuration, .init(29, 2))
        let removed = try EditedProjectWriter.write(projectData: data, selection: selection,
            selectedRanges: [short], outputName: "Removed")
        XCTAssertEqual(removed.report.resultProjectDuration, .init(27, 2))
        XCTAssertEqual(removed.report.insertedGapDuration, .zero)
    }

    func testRejectsIncompleteOrUnalignedGapPlans() throws {
        for gaps: [TimeRange: RationalTime] in [[short: .init(1)], [short: .zero, long: .init(1)],
                                               [short: .init(1, 100), long: .init(1)]] {
            XCTAssertThrowsError(try EditedProjectWriter.write(projectData: data, selection: selection,
                selectedRanges: [short, long], outputName: "Invalid", replacementGaps: gaps))
        }
    }

    func testOutputRequestDefaultsAndFractionalFrameRounding() throws {
        let base = "cutdown://analyze?request=\(UUID())&threshold=-40&minimum=0.5&before=0.1&after=0.1"
        XCTAssertEqual(try AnalyzeRequest(url: URL(string: base)!).outputMode, .remove)
        XCTAssertEqual(try AnalyzeRequest(url: URL(string: base + "&output=gaps")!).outputMode, .gaps)
        XCTAssertThrowsError(try AnalyzeRequest(url: URL(string: base + "&output=unknown")!))
        XCTAssertEqual(try CutdownOutputMode.gaps.gapDuration(frame: .init(1, 30)), .init(1))
        XCTAssertEqual(try CutdownOutputMode.gaps.gapDuration(frame: .init(1001, 30000)), .init(1001, 1000))
        XCTAssertNil(try CutdownOutputMode.remove.gapDuration(frame: .init(1, 30)))
    }
}
