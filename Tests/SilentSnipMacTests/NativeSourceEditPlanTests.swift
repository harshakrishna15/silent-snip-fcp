import Foundation
import SilentSnipCore
import XCTest
@testable import SilentSnipMac

final class NativeSourceEditPlanTests: XCTestCase {
    private func range(_ start: Int64, _ end: Int64) -> TimeRange {
        .init(start: .init(start), end: .init(end))
    }

    private func fixture(clipChildren: String = "", extraSpine: String = "", sequenceChildren: String = "",
                         clipAttributes: String = "", assetAttributes: String = "",
                         duration: String = "10s", sourceStart: String = "102s", assetDuration: String = "30s",
                         frame: String = "1/30s", tcStart: String = "3600s") -> Data {
        Data("""
        <fcpxml version="1.14"><resources>
          <format id="f" frameDuration="\(frame)"/>
          <asset id="source" name="Original Audio" start="100s" duration="\(assetDuration)" hasAudio="1" audioSources="1" audioChannels="2" \(assetAttributes)>
            <media-rep kind="original-media" src="file:///fixtures/untouched-original.wav"/>
          </asset>
          <effect id="limiter" name="Limiter" uid="Limiter.Levels.audio.effectBundle"/>
          <effect id="gate" name="Noise Gate" uid="AudioUnit: 0x61756678000000b3454d4147"/>
        </resources>
        <library location="file:///fixtures/Cutdown%20Integration.fcpbundle/"><event name="Disposable" uid="BBBB0000-0000-4000-8000-000000000001">
          <project name="Original Project" uid="AAAA0000-0000-4000-8000-000000000001">
            <sequence format="f" duration="\(duration)" tcStart="\(tcStart)"><spine>
              <asset-clip ref="source" name="Original Clip" offset="\(tcStart)" start="\(sourceStart)" duration="\(duration)" audioRole="dialogue" \(clipAttributes)>\(clipChildren)</asset-clip>
              \(extraSpine)
            </spine>\(sequenceChildren)</sequence>
          </project>
        </event></library></fcpxml>
        """.utf8)
    }

    private func make(_ data: Data? = nil, removals: [TimeRange]? = nil) throws -> NativeSourceEditPlan {
        let input = data ?? fixture()
        let document = try TimelineParser.parse(data: input)
        return try NativeSourceEditPlan.make(projectData: input,
            selection: .init(timelineRange: document.projectRange), removals: removals ?? [range(2, 3)])
    }

    func testReverseStepsDescribeEverySourceIntervalAndIntermediateLayout() throws {
        let plan = try make(removals: [range(2, 3), range(6, 8)])
        XCTAssertEqual(plan.projectUID, "AAAA0000-0000-4000-8000-000000000001")
        XCTAssertEqual(plan.eventName, "Disposable")
        XCTAssertEqual(plan.libraryURL.path, "/fixtures/Cutdown Integration.fcpbundle")
        XCTAssertEqual(plan.projectTimecodeStart, .init(3600))
        XCTAssertEqual(plan.frameDuration, .init(1, 30))
        XCTAssertEqual(plan.removedDuration, .init(3))
        XCTAssertEqual(plan.steps.map(\.ordinal), [1, 2])
        XCTAssertEqual(plan.steps.map(\.removal), [range(6, 8), range(2, 3)])
        XCTAssertEqual(plan.steps.map(\.selectionRange), plan.steps.map(\.removal))
        XCTAssertEqual(plan.initial.segments.map(\.sourceRange), [range(102, 112)])
        XCTAssertEqual(plan.steps[0].expectedBefore, plan.initial)
        XCTAssertEqual(plan.steps[0].expectedAfter.segments.map(\.sourceRange), [range(102, 108), range(110, 112)])
        XCTAssertEqual(plan.steps[0].expectedAfter.segments.map(\.timelineRange), [range(0, 6), range(6, 8)])
        XCTAssertEqual(plan.steps[1].expectedBefore, plan.steps[0].expectedAfter)
        XCTAssertEqual(plan.steps[1].targetBefore.originalTimelineRange, range(0, 6))
        XCTAssertEqual(plan.final.duration, .init(7))
        XCTAssertEqual(plan.final.segments.map(\.sourceRange), [range(102, 104), range(105, 108), range(110, 112)])
        XCTAssertEqual(plan.final.segments.map(\.timelineRange), [range(0, 2), range(2, 5), range(5, 7)])
        XCTAssertEqual(plan.final.segments.map(\.originalTimelineRange), [range(0, 2), range(3, 6), range(8, 10)])
    }

    func testInputOrderDoesNotChangeTheReverseEditPlan() throws {
        let first = try make(removals: [range(2, 3), range(6, 8), range(9, 10)])
        let permuted = try make(removals: [range(9, 10), range(2, 3), range(6, 8)])
        XCTAssertEqual(first.steps, permuted.steps)
        XCTAssertEqual(first.final, permuted.final)
    }

    func testLeadingTrailingAndAdjacentRangesLeaveNoZeroLengthSegments() throws {
        let boundaries = try make(removals: [range(0, 1), range(9, 10)])
        XCTAssertEqual(boundaries.steps[0].expectedAfter.segments.map(\.sourceRange), [range(102, 111)])
        XCTAssertEqual(boundaries.final.segments.map(\.sourceRange), [range(103, 111)])
        XCTAssertEqual(boundaries.final.segments.map(\.timelineRange), [range(0, 8)])
        let adjacent = try make(removals: [range(2, 3), range(3, 4)])
        XCTAssertEqual(adjacent.final.segments.map(\.sourceRange), [range(102, 104), range(106, 112)])
        XCTAssertTrue(adjacent.steps.allSatisfy { $0.expectedAfter.segments.allSatisfy { !$0.sourceRange.isEmpty } })
    }

    func testBarePresetAndOpaqueAdvancedAudioEffectsRemainEligibleWithoutReconstruction() throws {
        let children = """
        <adjust-volume amount="3dB"><param name="amount"><keyframeAnimation><keyframe time="102s" value="3dB"/><keyframe time="110s" value="1dB"/></keyframeAnimation></param></adjust-volume>
        <filter-audio ref="gate" name="Noise Gate" presetID="[0]Original.aupreset"/>
        <filter-audio ref="limiter" name="Limiter"/>
        <filter-audio ref="limiter" name="Limiter" enabled="0"><data key="effectState">b3BhcXVlLW5hdGl2ZS1zdGF0ZQ==</data></filter-audio>
        """
        let input = fixture(clipChildren: children)
        let before = input
        let plan = try make(input)
        XCTAssertFalse(plan.target.effectsFingerprint.isEmpty)
        XCTAssertEqual(plan.target.sourceStart, .init(102))
        XCTAssertEqual(plan.target.assetStart, .init(100))
        XCTAssertEqual(input, before, "The pure plan must not rewrite source XML or require a readable source file")
    }

    func testMixedActiveRolesCannotMeasureHiddenEffectsThroughAnIsolatedXMLProject() throws {
        let mixed = fixture(clipChildren: """
        <audio-channel-source srcCh="1" role="dialogue.Voice"/>
        <audio-channel-source srcCh="2" role="music.Bed"/>
        <filter-audio ref="limiter" name="Limiter"/>
        """)
        let document = try TimelineParser.parse(data: mixed)
        XCTAssertEqual(document.clips.count, 1)
        XCTAssertEqual(document.clips[0].dialogueRoles, ["dialogue.Voice"])
        XCTAssertFalse(document.clips[0].effectsFingerprint.isEmpty)
        XCTAssertNil(try DirectAudioRender.scope(projectData: mixed, selection: .init(timelineRange: document.projectRange)))
        XCTAssertThrowsError(try make(mixed)) {
            guard let error = $0 as? NativeSourceEditPlanError, case .unsupported(let reason) = error else {
                return XCTFail("Expected an explicit native render eligibility error, got \($0)")
            }
            XCTAssertTrue(reason.contains("original native Dialogue render"))
        }
        // A disabled music component is absent from the native Dialogue render;
        // the remaining active source can still be measured without XML isolation.
        let disabled = Data(String(decoding: mixed, as: UTF8.self)
            .replacingOccurrences(of: "srcCh=\"2\" role=\"music.Bed\"", with: "srcCh=\"2\" role=\"music.Bed\" active=\"0\"").utf8)
        XCTAssertNoThrow(try make(disabled))
    }

    func testExistingSilentSnipControllerIsRejectedByExactUIDRatherThanDisplayName() throws {
        let ordinary = fixture(clipChildren: "<filter-audio ref=\"limiter\" name=\"Silent Snip Audio\"/>")
        XCTAssertNoThrow(try make(ordinary), "A display name alone must not identify our controller")
        let controller = Data(String(decoding: ordinary, as: UTF8.self)
            .replacingOccurrences(of: "uid=\"Limiter.Levels.audio.effectBundle\"", with: "uid=\"\(AudioControllerSettings.effectUID)\"")
            .replacingOccurrences(of: "<filter-audio ref=\"limiter\" name=\"Silent Snip Audio\"/>", with: "<filter-audio ref=\"limiter\" name=\"Renamed Effect\"/>").utf8)
        XCTAssertThrowsError(try make(controller)) {
            guard let error = $0 as? NativeSourceEditPlanError, case .unsupported(let reason) = error else {
                return XCTFail("Expected an exact controller identity rejection, got \($0)")
            }
            XCTAssertTrue(reason.contains("existing Silent Snip audio effect"))
        }
    }

    func testFractionalFrameRateAndSourceOriginStayExact() throws {
        let frame = RationalTime(1001, 30000)
        let cut = TimeRange(start: try frame.multiplied(by: .init(2)), end: try frame.multiplied(by: .init(4)))
        let input = fixture(duration: "1001/3000s", sourceStart: "4800001/48000s", frame: "1001/30000s", tcStart: "0s")
        let plan = try make(input, removals: [cut])
        XCTAssertEqual(plan.final.duration, try frame.multiplied(by: .init(8)))
        XCTAssertEqual(plan.final.segments[1].sourceRange.start, try RationalTime(4800001, 48000).adding(cut.end))
        XCTAssertEqual(plan.final.segments[1].timelineRange.start, cut.start)
    }

    func testEverySixFrameRemovalSubsetMatchesIndependentRetainedFrameModel() throws {
        // A small exhaustive model checks split/trim/delete interactions across
        // all nonempty retained outcomes, including adjacent one-frame cuts.
        let input = fixture(duration: "1/5s", tcStart: "0s")
        for mask in 1..<63 {
            let removed = (0..<6).filter { mask & (1 << $0) != 0 }
            let cuts = removed.map { TimeRange(start: .init(Int64($0), 30), end: .init(Int64($0 + 1), 30)) }
            let plan = try make(input, removals: cuts)
            var remaining = Array(0..<6)
            for step in plan.steps {
                XCTAssertEqual(try originalFrames(step.expectedBefore), remaining, "mask \(mask), before \(step.ordinal)")
                let lower = try frameIndex(step.removal.start)
                let upper = try frameIndex(step.removal.end)
                remaining.removeAll { lower <= $0 && $0 < upper }
                XCTAssertEqual(try originalFrames(step.expectedAfter), remaining, "mask \(mask), after \(step.ordinal)")
                var cursor = RationalTime.zero
                for segment in step.expectedAfter.segments {
                    XCTAssertEqual(segment.timelineRange.start, cursor)
                    XCTAssertEqual(try segment.timelineRange.checkedDuration(), try segment.sourceRange.checkedDuration())
                    XCTAssertEqual(segment.sourceRange.start, try RationalTime(102).adding(segment.originalTimelineRange.start))
                    cursor = segment.timelineRange.end
                }
                XCTAssertEqual(cursor, step.expectedAfter.duration)
            }
        }
    }

    func testRejectsEmptyOverlappingRepeatedOffFrameAndOutOfBoundsRemovals() throws {
        let bad: [[TimeRange]] = [[], [range(2, 2)], [range(-1, 1)], [range(9, 11)],
            [range(2, 4), range(3, 5)], [range(2, 3), range(2, 3)],
            [.init(start: .init(1, 31), end: .init(1))]]
        for ranges in bad { XCTAssertThrowsError(try make(removals: ranges), "\(ranges)") }
        XCTAssertThrowsError(try make(removals: Array(repeating: range(2, 3), count: NativeSourceEditPlan.maximumRemovals + 1))) {
            XCTAssertEqual($0 as? NativeSourceEditPlanError, .tooManyRemovals)
        }
    }

    func testRejectsCompleteRemovalEvenWhenSplitAcrossAdjacentRanges() throws {
        for cuts in [[range(0, 10)], [range(0, 5), range(5, 10)]] {
            XCTAssertThrowsError(try make(removals: cuts)) {
                XCTAssertEqual($0 as? NativeSourceEditPlanError, .noRetainedAudio)
            }
        }
    }

    func testRejectsExtraTimelineItemsVideoAndNonWholeProjectSelection() throws {
        assertRejected(fixture(extraSpine: "<gap offset=\"3610s\" duration=\"0s\"/>"))
        assertRejected(fixture(clipChildren: "<asset-clip ref=\"source\" lane=\"-1\" offset=\"102s\" start=\"102s\" duration=\"2s\"/>"))
        assertRejected(fixture(assetAttributes: "hasVideo=\"1\""))
        assertRejected(fixture(clipAttributes: "srcEnable=\"audio\"", assetAttributes: "hasVideo=\"1\""))
        let input = fixture()
        XCTAssertThrowsError(try NativeSourceEditPlan.make(projectData: input,
            selection: .init(timelineRange: range(0, 5)), removals: [range(2, 3)]))
        let shortClip = String(decoding: input, as: UTF8.self).replacingOccurrences(of: "start=\"102s\" duration=\"10s\"", with: "start=\"102s\" duration=\"9s\"")
        assertRejected(Data(shortClip.utf8))
    }

    func testRejectsParentProcessingRetimeFadesTrimmedComponentsAndUnknownClipSyntax() throws {
        assertRejected(fixture(sequenceChildren: "<filter-audio ref=\"limiter\"/>"))
        for children in ["<timeMap><timept time=\"0s\" value=\"0s\"/></timeMap>",
                         "<conform-rate scaleEnabled=\"0\"/>",
                         "<adjust-volume><fadeIn duration=\"1s\"/></adjust-volume>",
                         "<audio-channel-source srcCh=\"1\" role=\"dialogue\" start=\"102s\"/>",
                         "<filter-video ref=\"limiter\"/>", "<unknown-processing/>",
                         "<filter-audio ref=\"source\"/>"] {
            assertRejected(fixture(clipChildren: children))
        }
        assertRejected(fixture(clipAttributes: "unknownTiming=\"1\""))
        assertRejected(fixture(clipAttributes: "enabled=\"0\""))
        assertRejected(fixture(clipAttributes: "audioStart=\"103s\""))
    }

    func testRejectsUnboundNativeIdentityAlternateMediaAndInvalidSourceBounds() throws {
        for replacement in [
            (" uid=\"AAAA0000-0000-4000-8000-000000000001\"", ""),
            (" uid=\"BBBB0000-0000-4000-8000-000000000001\"", ""),
            ("file:///fixtures/Cutdown%20Integration.fcpbundle/", "https://example.test/Library.fcpbundle"),
            ("kind=\"original-media\"", "kind=\"proxy-media\"")
        ] {
            let input = String(decoding: fixture(), as: UTF8.self).replacingOccurrences(of: replacement.0, with: replacement.1)
            assertRejected(Data(input.utf8))
        }
        assertRejected(fixture(sourceStart: "99s"))
        assertRejected(fixture(sourceStart: "125s"))
        assertRejected(fixture(duration: "1001/100s"))
        assertRejected(fixture(tcStart: "1/100s"))
    }

    private func assertRejected(_ input: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try make(input), file: file, line: line)
    }

    private func frameIndex(_ time: RationalTime) throws -> Int {
        let frames = try time.multiplied(by: .init(30))
        XCTAssertEqual(frames.denominator, 1)
        return Int(frames.numerator)
    }

    private func originalFrames(_ layout: NativeSourceEditPlan.Layout) throws -> [Int] {
        try layout.segments.flatMap { segment in
            let lower = try frameIndex(segment.originalTimelineRange.start)
            let upper = try frameIndex(segment.originalTimelineRange.end)
            return Array(lower..<upper)
        }
    }
}
