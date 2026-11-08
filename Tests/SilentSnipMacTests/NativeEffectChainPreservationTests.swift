import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import SilentSnipCore
import XCTest
@testable import SilentSnipMac

/// Pure native-plan and diagnostic XML contracts. No installed plugin is
/// instantiated, no source media is rendered, and no XML is imported here.
/// Private native settings still require a live host preservation check.
final class NativeEffectChainPreservationTests: XCTestCase {
    private let selection = TimelineSelection(timelineRange: .init(start: .zero, end: .init(10)))
    private let cuts = [TimeRange(start: .init(2), end: .init(3)), TimeRange(start: .init(6), end: .init(8))]
    private let orders = [["gate", "limiter", "unknown"], ["gate", "unknown", "limiter"],
                          ["limiter", "gate", "unknown"], ["limiter", "unknown", "gate"],
                          ["unknown", "gate", "limiter"], ["unknown", "limiter", "gate"]]

    func testEveryOrderedChainAndBypassCombinationRequiresNativeInstances() throws {
        for order in orders {
            for bypassMask in 0..<8 {
                let filters = order.enumerated().map { index, ref in
                    filter(ref, enabled: bypassMask & (1 << index) == 0, discriminator: index)
                } + [filter("limiter", enabled: true, discriminator: 99)]
                let input = fixture(filters: filters.joined())
                let plan = try NativeSourceEditPlan.make(projectData: input, selection: selection, removals: cuts)
                XCTAssertEqual(plan.removals, cuts)
                XCTAssertEqual(plan.final.segments.map(\.sourceRange), [range(102, 104), range(105, 108), range(110, 112)])
                XCTAssertThrowsError(try EditedProjectWriter.write(projectData: input, selection: selection,
                    selectedRanges: cuts, outputName: "Must Use Existing Instances"),
                    "Neither a plugin's UID format nor a bypassed instance can authorize XML reconstruction")

                let expectation = try diagnostic(input)
                let original = try XCTUnwrap(clips(input).first)
                let expectedChain = state(original, element: "filter-audio")
                XCTAssertEqual(expectedChain.count, 4)
                for clip in try clips(expectation.xmlData) {
                    XCTAssertEqual(state(clip, element: "filter-audio"), expectedChain,
                        "Keep instance order, repeated identities, bypass state, scalar controls and opaque bytes independently")
                }
            }
        }
    }

    func testSourceTimeAutomationKeepsItsOriginalClockAcrossAllRetainedSegments() throws {
        let input = fixture(filters: filter("unknown", enabled: true, discriminator: 1), componentProcessing: true)
        let plan = try NativeSourceEditPlan.make(projectData: input, selection: selection, removals: cuts)
        let expectation = try diagnostic(input)
        let original = try XCTUnwrap(clips(input).first)
        let originalVolume = state(original, element: "adjust-volume")
        let originalComponents = state(original, element: "audio-channel-source")
        XCTAssertEqual(plan.projectTimecodeStart, .init(3600))
        XCTAssertEqual(plan.final.segments.map(\.sourceRange), [range(102, 104), range(105, 108), range(110, 112)])
        let kept = try clips(expectation.xmlData)
        XCTAssertEqual(kept.count, 3)
        for clip in kept {
            XCTAssertEqual(state(clip, element: "adjust-volume"), originalVolume)
            XCTAssertEqual(state(clip, element: "audio-channel-source"), originalComponents)
            XCTAssertEqual(try clip.nodes(forXPath: "adjust-volume/param/keyframeAnimation/keyframe/@time").map(\.stringValue),
                ["100s", "104s", "108s", "115s"],
                "Preserve surrounding control points; do not reset or subtract removed project time from source automation")
        }
        let parsed = try TimelineParser.parse(data: expectation.xmlData)
        XCTAssertEqual(parsed.clips.map(\.sourceStart), [.init(102), .init(105), .init(110)])
        XCTAssertEqual(parsed.clips.map(\.timelineRange), [range(0, 2), range(2, 5), range(5, 7)])
        XCTAssertTrue(parsed.clips.allSatisfy { $0.mediaURL == URL(string: "file:///fixtures/Original.wav") })
        XCTAssertNil(expectation.report.losslessAudio)
    }

    func testReorderedRepeatedBypassedOrComponentEffectsCannotHideBehindMatchingResourceIdentity() throws {
        let input = fixture(filters: filter("limiter", enabled: true, discriminator: 1)
            + filter("limiter", enabled: false, discriminator: 2), componentProcessing: true)
        let baseline = try diagnostic(input).xmlData
        let mutations: [(XMLElement) throws -> Void] = [
            { clip in
                let filters = clip.elements(forName: "filter-audio")
                let index = filters[0].index
                filters[1].detach(); clip.insertChild(filters[1], at: index)
            },
            { $0.elements(forName: "filter-audio")[1].attribute(forName: "enabled")?.stringValue = "1" },
            { $0.elements(forName: "filter-audio")[0].elements(forName: "data")[0].stringValue = "Y2hhbmdlZA==" },
            { try $0.nodes(forXPath: "audio-channel-source/filter-audio/param/@value").first?.stringValue = "999" },
            { try $0.nodes(forXPath: "adjust-volume/param/keyframeAnimation/keyframe[2]/@time").first?.stringValue = "105s" }
        ]
        for mutate in mutations {
            let xml = try XMLDocument(data: baseline)
            let first = try XCTUnwrap(xml.nodes(forXPath: "//project/sequence/spine/asset-clip").first as? XMLElement)
            try mutate(first)
            XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: baseline, actual: xml.xmlData).verified,
                "Shared effect UIDs do not make differently ordered or configured instances equivalent")
        }
    }

    private func diagnostic(_ input: Data) throws -> EditedProjectOutput {
        try EditedProjectWriter.nativeEditExpectation(projectData: input, selection: selection,
            selectedRanges: cuts, outputName: "Diagnostic Only", projectUID: UUID())
    }

    private func range(_ start: Int64, _ end: Int64) -> TimeRange { .init(start: .init(start), end: .init(end)) }

    private func clips(_ data: Data) throws -> [XMLElement] {
        try XMLDocument(data: data).nodes(forXPath: "//project/sequence/spine/asset-clip").compactMap { $0 as? XMLElement }
    }

    private func state(_ clip: XMLElement, element name: String) -> [String] {
        clip.elements(forName: name).map { node in
            let copy = node.copy() as! XMLElement
            func removeIndentation(_ item: XMLElement) {
                for child in item.children ?? [] {
                    if let element = child as? XMLElement { removeIndentation(element) }
                    else if child.kind == .text,
                            (child.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { child.detach() }
                }
            }
            removeIndentation(copy)
            return copy.xmlString
        }
    }

    private func filter(_ ref: String, enabled: Bool, discriminator: Int) -> String {
        // Deliberately spoof the controller's display name for an unknown UID.
        let name = ref == "unknown" ? "Silent Snip Audio" : "Same Display Name"
        let payload = Data("private-instance-\(discriminator)".utf8).base64EncodedString()
        return "<filter-audio ref=\"\(ref)\" name=\"\(name)\" enabled=\"\(enabled ? 1 : 0)\"><data key=\"effectState\">\(payload)</data><param key=\"amount\" value=\"\(discriminator)\"/></filter-audio>"
    }

    private func fixture(filters: String, componentProcessing: Bool = false) -> Data {
        let component = componentProcessing
            ? "<audio-channel-source srcCh=\"1, 2\" role=\"dialogue.dialogue-1\">\(filter("unknown", enabled: false, discriminator: 10))</audio-channel-source>" : ""
        return Data("""
        <fcpxml version="1.14"><resources><format id="f" frameDuration="1/30s"/>
        <asset id="source" name="Original" start="100s" duration="30s" hasAudio="1"><media-rep kind="original-media" src="file:///fixtures/Original.wav"/></asset>
        <effect id="gate" name="Noise Gate" uid="AudioUnit: 0x61756678000000b3454d4147"/>
        <effect id="limiter" name="Limiter" uid="Limiter.Levels.audio.effectBundle"/>
        <effect id="unknown" name="Silent Snip Audio" uid="vendor.example.UnknownPlugin.v3"/>
        </resources><library location="file:///fixtures/Cutdown%20Integration.fcpbundle"><event name="Fixture" uid="BBBB0000-0000-4000-8000-000000000001"><project name="Original" uid="AAAA0000-0000-4000-8000-000000000001">
        <sequence format="f" duration="10s" tcStart="3600s"><spine>
        <asset-clip ref="source" name="Voice" offset="3600s" start="102s" duration="10s" audioRole="dialogue">
        <adjust-volume amount="3dB"><param name="amount"><keyframeAnimation>
        <keyframe time="100s" value="-9dB"/><keyframe time="104s" value="-3dB" curve="smooth"/><keyframe time="108s" value="1dB"/><keyframe time="115s" value="-6dB"/>
        </keyframeAnimation></param></adjust-volume>
        \(component)\(filters)</asset-clip>
        </spine></sequence></project></event></library></fcpxml>
        """.utf8)
    }
}
