import Foundation
import SilentSnipCore
#if canImport(FoundationXML)
import FoundationXML
#endif
import XCTest
@testable import SilentSnipMac

final class BulkEffectTransferPlanTests: XCTestCase {
    private let selection = TimelineSelection(timelineRange: .init(start: .zero, end: .init(10)))
    private let cuts = [TimeRange(start: .init(2), end: .init(3)), TimeRange(start: .init(6), end: .init(8))]
    private let uid = UUID(uuidString: "CCCC0000-0000-4000-8000-000000000001")!

    private func fixture(filters: String? = nil, extra: String = "", volume: String = "<adjust-volume amount=\"-3dB\"/>") -> Data {
        let chain = filters ?? """
        <filter-audio ref="gate" name="Noise Gate" presetID="Original.aupreset"/>
        <filter-audio ref="limiter" name="Limiter"/>
        <filter-audio ref="limiter" name="Limiter" enabled="0"><data key="effectState">b3BhcXVl</data></filter-audio>
        """
        return Data("""
        <fcpxml version="1.14"><resources>
        <format id="f" frameDuration="1/30s"/>
        <asset id="a" name="Generated" start="100s" duration="30s" hasAudio="1" audioSources="1" audioChannels="2" audioRate="48000"><media-rep kind="original-media" src="file:///fixtures/Generated.wav"/></asset>
        <effect id="gate" name="Noise Gate" uid="AudioUnit: 0x61756678000000b3454d4147"/>
        <effect id="limiter" name="Limiter" uid="Limiter.Levels.audio.effectBundle"/>
        <effect id="unused" name="Unused" uid="vendor.Unused"/>
        </resources><library location="file:///fixtures/Cutdown%20Integration.fcpbundle/"><event name="Disposable" uid="BBBB0000-0000-4000-8000-000000000001"><project name="Original" uid="AAAA0000-0000-4000-8000-000000000001"><sequence format="f" duration="10s" tcStart="3600s"><spine><asset-clip ref="a" name="Generated Clip" offset="3600s" start="102s" duration="10s" audioRole="dialogue">\(volume)\(chain)\(extra)</asset-clip></spine></sequence></project></event></library></fcpxml>
        """.utf8)
    }

    private func make(_ data: Data? = nil) throws -> BulkEffectTransferPlan {
        try BulkEffectTransferPlan.make(projectData: data ?? fixture(), selection: selection,
            cuts: cuts, outputName: "Cleaned", projectUID: uid)
    }

    func testImportHasNoEffectsWhileSeparateExpectationRetainsOrderedRepeatedBypassedInstances() throws {
        let input = fixture()
        let result = try make(input)
        let imported = try XMLDocument(data: result.effectFreeOutput.xmlData)
        let expected = try XMLDocument(data: result.expectedXML)
        XCTAssertTrue(try imported.nodes(forXPath: "//filter-audio | //resources/effect").isEmpty,
            "Paste Attributes recipients must start with no reset or duplicate effects")
        XCTAssertEqual(try imported.nodes(forXPath: "//spine/asset-clip").count, 3)
        XCTAssertEqual(result.effectNames, ["Noise Gate", "Limiter", "Limiter"])
        XCTAssertEqual(result.effects.map(\.enabled), [true, true, false])
        XCTAssertEqual(result.sourceTargetName, "Generated Clip")
        for node in try expected.nodes(forXPath: "//spine/asset-clip") {
            XCTAssertEqual(try node.nodes(forXPath: "filter-audio/@ref").map(\.stringValue), ["gate", "limiter", "limiter"])
            XCTAssertEqual(try node.nodes(forXPath: "filter-audio[3]/@enabled").map(\.stringValue), ["0"])
            XCTAssertEqual(try node.nodes(forXPath: "filter-audio[3]/data").map(\.stringValue), ["b3BhcXVl"])
        }
        XCTAssertEqual(result.sourcePlan.projectUID, "AAAA0000-0000-4000-8000-000000000001")
        XCTAssertTrue(result.sourcePlan.steps.isEmpty, "A bulk transfer must never carry native per-cut instructions")
        XCTAssertNotNil(result.sourcePlan.bulkFinal)
        XCTAssertEqual(input, fixture(), "Planning cannot mutate original bytes or native effects")
    }

    func testBothDocumentsShareNewIdentitySourceTrimsAndProjectClock() throws {
        let result = try make()
        let want = try TimelineParser.parse(data: result.expectedXML)
        let imported = try TimelineParser.parse(data: result.effectFreeOutput.xmlData)
        XCTAssertEqual(want.projectUID, uid.uuidString)
        XCTAssertEqual(imported.projectUID, want.projectUID)
        XCTAssertEqual(imported.projectTimecodeStart, .init(3600))
        XCTAssertEqual(imported.projectRange.end, .init(7))
        XCTAssertEqual(imported.clips.map(\.sourceStart), [.init(102), .init(105), .init(110)])
        XCTAssertEqual(imported.clips.map(\.sourceStart), want.clips.map(\.sourceStart))
        XCTAssertEqual(imported.clips.map(\.timelineRange), want.clips.map(\.timelineRange))
        XCTAssertEqual(imported.clips.map(\.mediaURL), want.clips.map(\.mediaURL))
        XCTAssertEqual(result.effectFreeOutput.report.retainedSegments.map(\.sourceRange), result.sourcePlan.final.segments.map(\.sourceRange))
        XCTAssertEqual(result.effectFreeOutput.report.resultProjectDuration, result.sourcePlan.final.duration)
        XCTAssertNil(result.effectFreeOutput.report.losslessAudio)
        for data in [result.effectFreeOutput.xmlData, result.expectedXML] {
            let xml = try XMLDocument(data: data)
            XCTAssertEqual(try xml.nodes(forXPath: "//event/@uid").map(\.stringValue), ["BBBB0000-0000-4000-8000-000000000001"])
            XCTAssertEqual(try xml.nodes(forXPath: "//asset-clip/adjust-volume/@amount").map(\.stringValue), ["-3dB", "-3dB", "-3dB"])
        }
    }

    func testEffectAnimationIsRejectedWhileOriginalVolumeAutomationStaysOnSourceClock() throws {
        let animation = "<param key=\"gain\"><keyframeAnimation><keyframe time=\"102s\" value=\"2\"/><keyframe time=\"110s\" value=\"8\"/></keyframeAnimation></param>"
        let animatedEffect = fixture(filters: "<filter-audio ref=\"limiter\">\(animation)</filter-audio>")
        XCTAssertThrowsError(try make(animatedEffect)) {
            XCTAssertTrue($0.localizedDescription.contains("animated audio effects"))
        }
        let volume = "<adjust-volume amount=\"-3dB\">\(animation)</adjust-volume>"
        let result = try make(fixture(volume: volume))
        for data in [result.effectFreeOutput.xmlData, result.expectedXML] {
            let xml = try XMLDocument(data: data)
            for clip in try xml.nodes(forXPath: "//spine/asset-clip") {
                XCTAssertEqual(try clip.nodes(forXPath: "adjust-volume//keyframe/@time").map(\.stringValue), ["102s", "110s"])
            }
        }
    }

    func testComponentEffectsUnsupportedLayoutsAndUnknownIdentityStopBeforeImport() throws {
        let component = fixture(extra: "<audio-channel-source srcCh=\"1\"><filter-audio ref=\"gate\"/></audio-channel-source>")
        XCTAssertThrowsError(try make(component)) {
            XCTAssertTrue($0.localizedDescription.contains("component-level effects"))
        }
        XCTAssertThrowsError(try make(fixture(filters: "")))
        XCTAssertThrowsError(try make(fixture(filters: "<filter-audio ref=\"missing\"/>")))
        let video = Data(String(decoding: fixture(), as: UTF8.self).replacingOccurrences(of: "hasAudio=\"1\"", with: "hasAudio=\"1\" hasVideo=\"1\"").utf8)
        XCTAssertThrowsError(try make(video))
    }

    func testThePublicWriterGuardIsStillRequiredAndDiagnosticStateIsNeverDeliveryData() throws {
        let input = fixture()
        XCTAssertThrowsError(try EditedProjectWriter.write(projectData: input, selection: selection,
            selectedRanges: cuts, outputName: "Unsafe reconstruction"))
        let result = try make(input)
        XCTAssertNoThrow(try EditableEffectReconstruction.validate(projectData: result.effectFreeOutput.xmlData))
        XCTAssertThrowsError(try EditableEffectReconstruction.validate(projectData: result.expectedXML))
        XCTAssertNotEqual(result.effectFreeOutput.xmlData, result.expectedXML)
        let beforePaste = try ProjectRoundTripVerification.compare(expected: result.expectedXML,
            actual: result.effectFreeOutput.xmlData)
        XCTAssertFalse(beforePaste.verified, "An imported effect-free project is not a completed result")
        XCTAssertTrue(try ProjectRoundTripVerification.compare(expected: result.expectedXML, actual: result.expectedXML).verified)
    }

    func testUnknownVendorStaticStateAndRenamedEffectsKeepExplicitNativeTransferIdentity() throws {
        let input = Data(String(decoding: fixture(filters: "<filter-audio ref=\"limiter\" nameOverride=\"Voice Finish\" enabled=\"0\"><data key=\"effectState\">b3BhcXVl</data></filter-audio>"), as: UTF8.self)
            .replacingOccurrences(of: "uid=\"Limiter.Levels.audio.effectBundle\"", with: "uid=\"vendor.UnknownNativePlugin\"").utf8)
        let result = try make(input)
        XCTAssertEqual(result.effectNames, ["Voice Finish"])
        XCTAssertEqual(result.effects.map(\.uid), ["vendor.UnknownNativePlugin"])
        XCTAssertEqual(result.effects.map(\.enabled), [false])
        XCTAssertTrue(try XMLDocument(data: result.effectFreeOutput.xmlData).nodes(forXPath: "//filter-audio").isEmpty)
    }

    func testBulkThousandCutPlanRetainsOneFinalLayoutWithoutNativeSteps() throws {
        let data = Data(String(decoding: fixture(), as: UTF8.self)
            .replacingOccurrences(of: "duration=\"10s\"", with: "duration=\"2001s\"")
            .replacingOccurrences(of: "duration=\"30s\"", with: "duration=\"3000s\"").utf8)
        let removals: [TimeRange] = (0..<1_000).map { (index: Int) -> TimeRange in
            let lower: Int64 = Int64(index) * 2 + 1
            return TimeRange(start: RationalTime(lower), end: RationalTime(lower + 1))
        }
        let plan = try NativeSourceEditPlan.makeBulk(projectData: data,
            selection: .init(timelineRange: .init(start: .zero, end: .init(2001))),
            removals: Array(removals.reversed()))
        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertEqual(plan.initial.segments.count, 1)
        XCTAssertEqual(plan.final.segments.count, 1_001)
        XCTAssertEqual(plan.removals, removals)
        XCTAssertEqual(plan.removedDuration, RationalTime(1_000))
        XCTAssertEqual(plan.final.duration, RationalTime(1_001))
        XCTAssertEqual(plan.final.segments.first?.sourceRange, TimeRange(start: RationalTime(102), end: RationalTime(103)))
        XCTAssertEqual(plan.final.segments.last?.sourceRange, TimeRange(start: RationalTime(2102), end: RationalTime(2103)))
        XCTAssertEqual(plan.final.segments.last?.timelineRange, TimeRange(start: RationalTime(1000), end: RationalTime(1001)))
        // Exercise the complete effect-free writer and full post-transfer
        // expectation as well as the geometry planner at a bounded large size.
        let transfer = try BulkEffectTransferPlan.make(projectData: data,
            selection: .init(timelineRange: .init(start: .zero, end: .init(2001))),
            cuts: removals, outputName: "Thousand cuts", projectUID: uid)
        XCTAssertTrue(transfer.sourcePlan.steps.isEmpty)
        XCTAssertEqual(transfer.effectFreeOutput.report.retainedSegments.count, 1_001)
        let delivery = try XMLDocument(data: transfer.effectFreeOutput.xmlData)
        let expected = try XMLDocument(data: transfer.expectedXML)
        XCTAssertEqual(try delivery.nodes(forXPath: "//spine/asset-clip").count, 1_001)
        XCTAssertTrue(try delivery.nodes(forXPath: "//filter-audio").isEmpty)
        XCTAssertEqual(try expected.nodes(forXPath: "//filter-audio").count, 3_003)
    }

    func testBulkAndNativeFinalGeometryAgreeWithoutSharingIntermediateLayouts() throws {
        let data = fixture()
        let selections: [[TimeRange]] = [cuts,
            [.init(start: .zero, end: .init(1)), .init(start: .init(9), end: .init(10))],
            [.init(start: .init(2), end: .init(3)), .init(start: .init(3), end: .init(4))]]
        for removals in selections {
            let native = try NativeSourceEditPlan.make(projectData: data, selection: selection, removals: removals)
            let bulk = try NativeSourceEditPlan.makeBulk(projectData: data, selection: selection, removals: removals)
            XCTAssertEqual(bulk.final, native.final)
            XCTAssertEqual(bulk.initial, native.initial)
            XCTAssertEqual(bulk.baselineFingerprint, native.baselineFingerprint)
            XCTAssertTrue(bulk.steps.isEmpty)
            XCTAssertFalse(native.steps.isEmpty)
        }
    }

    func testBulkBoundsAndRangeGuardsRemainEnforced() throws {
        XCTAssertEqual(NativeSourceEditPlan.maximumBulkRemovals, 8_192)
        let tooMany = Array(repeating: TimeRange(start: .zero, end: .init(1)), count: 8_193)
        XCTAssertThrowsError(try NativeSourceEditPlan.makeBulk(projectData: fixture(), selection: selection, removals: tooMany)) {
            XCTAssertEqual($0 as? NativeSourceEditPlanError, .tooManyRemovals)
        }
        let invalid: [[TimeRange]] = [[],
            [.init(start: .init(-1), end: .init(1))],
            [.init(start: .zero, end: .init(11))],
            [.init(start: .zero, end: .init(10))],
            [.init(start: .init(1, 100), end: .init(1))],
            [.init(start: .init(1), end: .init(3)), .init(start: .init(2), end: .init(4))]]
        for removals in invalid {
            XCTAssertThrowsError(try NativeSourceEditPlan.makeBulk(projectData: fixture(), selection: selection, removals: removals))
        }
    }
}
