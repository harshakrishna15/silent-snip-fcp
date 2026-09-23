import CutdownCore
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import XCTest
@testable import CutdownMac

/// XML contract tests, not validation of any vendor's DSP or Final Cut import.
final class AudioPluginCompatibilityTests: XCTestCase {
    private var directory: URL!
    private let selection = TimelineSelection(timelineRange: .init(start: .init(3), end: .init(8)))
    private let cut = TimeRange(start: .init(4), end: .init(5))
    private let plugins = ["Noise Gate", "Compressor", "EQ", "Limiter", "Third Party"]

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Fixture.fcpbundle"),
                                               withIntermediateDirectories: true)
        try Data([0]).write(to: directory.appendingPathComponent("Voice.wav"))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testEveryPluginAndStackUsesHostAudioRegardlessOfControllerPosition() throws {
        for plugin in plugins {
            XCTAssertEqual(try ClipAudioAnalysisRoute.resolve(projectData: fixture(filters: filter(plugin)),
                selection: selection), .finalCutRender, plugin)
        }
        for index in 0...plugins.count {
            var filters = plugins.map(filter)
            filters.insert("<filter-audio ref=\"controller\"/>", at: index)
            XCTAssertEqual(try ClipAudioAnalysisRoute.resolve(projectData: fixture(filters: filters.joined()),
                selection: selection), .finalCutRender)
        }
    }

    func testGateLimiterStackSurvivesIsolationAndCutsWithControllerAtEveryPosition() throws {
        let processors = [filter("Noise Gate"), filter("Limiter"), filter("Third Party")]
        for index in 0...processors.count {
            var filters = processors
            filters.insert("<filter-audio ref=\"controller\" name=\"Cutdown Audio\"/>", at: index)
            let original = fixture(filters: filters.joined())
            let isolation = try IsolatedAudioProject.make(projectData: original, selection: selection)
            let isolatedXML = try XMLDocument(data: isolation.data)
            XCTAssertEqual(try payloads(isolatedXML).count, processors.count)
            XCTAssertEqual(try payloads(isolatedXML), try payloads(XMLDocument(data: fixture(filters: processors.joined()))))
            let deliveredXML = try XMLDocument(data: isolation.data)
            let deliveredProject = try XCTUnwrap(deliveredXML.nodes(forXPath: "//project").first as? XMLElement)
            deliveredProject.removeAttribute(forName: "uid")
            deliveredProject.addAttribute(XMLNode.attribute(withName: "uid", stringValue: "host-assigned") as! XMLNode)
            let delivered = deliveredXML.xmlData
            XCTAssertTrue(try ProjectRoundTripVerification.compare(expected: isolation.data, actual: delivered, allowHostAssignedIdentity: true).verified)
            let output = try EditedProjectWriter.write(projectData: original, selection: selection,
                selectedRanges: [cut], outputName: "Gate Limiter Result")
            let segments = try XMLDocument(data: output.xmlData).nodes(forXPath: "//project/sequence/spine/asset-clip")
            let expected = try payloads(XMLDocument(data: original))
            XCTAssertEqual(segments.count, 2)
            for segment in segments { XCTAssertEqual(try segment.nodes(forXPath: "./filter-audio").map(\.xmlString), expected) }
        }
    }

    func testIsolatedRenderPreservesOrderedPluginsAndComponentProcessing() throws {
        let data = fixture(filters: stack, neighbor: true, componentEffect: true)
        let isolated = try IsolatedAudioProject.make(projectData: data, selection: selection)
        let original = try XMLDocument(data: data)
        let output = try XMLDocument(data: isolated.data)
        XCTAssertEqual(try payloads(output), try payloads(original).filter { !$0.contains("ref=\"controller\"") })
        let document = try TimelineParser.parse(data: isolated.data)
        XCTAssertEqual(document.clips.count, 1)
        XCTAssertEqual(document.clips[0].sourceFileStart, .init(2))
        XCTAssertEqual(document.clips[0].timelineRange, .init(start: .zero, end: .init(5)))
        XCTAssertEqual(try output.nodes(forXPath: "//audio-channel-source/@srcCh").first?.stringValue, "1, 2")
        XCTAssertEqual(try output.nodes(forXPath: "//audio-channel-source/@role").first?.stringValue, "dialogue.dialogue-1")
        XCTAssertEqual(try output.nodes(forXPath: "/fcpxml/import-options/option[@key='copy assets']/@value").first?.stringValue, "0")
    }

    func testCutsAndGapsPreserveCompletePluginStackOnEveryRetainedSegment() throws {
        let data = fixture(filters: stack, componentEffect: true)
        let original = try XMLDocument(data: data)
        let expected = try payloads(original)
        for gaps in [[:], [cut: RationalTime(1)]] {
            let result = try EditedProjectWriter.write(projectData: data, selection: selection,
                selectedRanges: [cut], outputName: "Plugin Result", replacementGaps: gaps)
            let output = try XMLDocument(data: result.xmlData)
            let clips = try output.nodes(forXPath: "//project/sequence/spine/asset-clip")
            XCTAssertEqual(clips.count, 2)
            for clip in clips {
                let filters = try clip.nodes(forXPath: "./filter-audio | ./audio-channel-source/filter-audio")
                XCTAssertEqual(filters.map(\.xmlString), expected)
            }
            let parsed = try TimelineParser.parse(data: result.xmlData)
            let segments = parsed.clips.filter { $0.kind == "asset-clip" }
            XCTAssertEqual(segments.map(\.sourceStart), [.init(3602), .init(3604)])
            XCTAssertEqual(segments.map(\.mediaURL), Array(repeating: directory.appendingPathComponent("Voice.wav"), count: 2),
                           "Cuts must reference original media, never substitute the analysis render")
            XCTAssertEqual(try output.nodes(forXPath: "/fcpxml/resources/asset").count, 1,
                           "No baked replacement asset is introduced")
        }
    }

    func testChangedOrderBypassPresetParametersAndOpaqueStateFailVerification() throws {
        let data = fixture(filters: stack)
        let source = String(decoding: data, as: UTF8.self)
        let mutations = [
            source.replacingOccurrences(of: filter("Noise Gate") + filter("Compressor"),
                                       with: filter("Compressor") + filter("Noise Gate")),
            source.replacingOccurrences(of: "enabled=\"0\"", with: "enabled=\"1\""),
            source.replacingOccurrences(of: "Voice.aupreset", with: "Other.aupreset"),
            source.replacingOccurrences(of: "value=\"-35\"", with: "value=\"-20\""),
            source.replacingOccurrences(of: "b3BhcXVl", with: "Y2hhbmdlZA=="),
            source.replacingOccurrences(of: "test-EQ", with: "test-OtherEQ"),
            source.replacingOccurrences(of: filter("Limiter"), with: "")
        ]
        let baseline = try TimelineParser.parse(data: data,
            exclusions: .init(controllerEffectUIDs: [AudioControllerSettings.effectUID]))
        for mutation in mutations {
            let changed = Data(mutation.utf8)
            XCTAssertNotEqual(changed, data)
            XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: data, actual: changed).verified)
            let current = try TimelineParser.parse(data: changed,
                exclusions: .init(controllerEffectUIDs: [AudioControllerSettings.effectUID]))
            XCTAssertThrowsError(try XMLProjectApply.verifyBaseline(current, analyzed: baseline))
        }
    }

    private func payloads(_ xml: XMLDocument) throws -> [String] {
        try xml.nodes(forXPath: "//project/sequence/spine/asset-clip/filter-audio | //project/sequence/spine/asset-clip/audio-channel-source/filter-audio").map(\.xmlString)
    }

    private func filter(_ name: String) -> String {
        let ref = name.replacingOccurrences(of: " ", with: "")
        if name == "Third Party" {
            return "<filter-audio ref=\"\(ref)\" name=\"Third Party\" presetID=\"Voice.aupreset\"><data key=\"effectState\">b3BhcXVl</data></filter-audio>"
        }
        return "<filter-audio ref=\"\(ref)\" name=\"\(name)\" enabled=\"\(name == "EQ" ? "0" : "1")\"><param name=\"Threshold\" key=\"1\" value=\"-35\"/></filter-audio>"
    }

    private var stack: String {
        plugins.map(filter).joined() + "<filter-audio ref=\"controller\" name=\"Cutdown Audio\"/>"
    }

    private func fixture(filters: String, neighbor: Bool = false, componentEffect: Bool = false) -> Data {
        // Synthetic identities deliberately exercise generic handling, not a whitelist.
        let resources = plugins.map {
            "<effect id=\"\($0.replacingOccurrences(of: " ", with: ""))\" uid=\"test-\($0)\"/>"
        }.joined()
        let connected = neighbor ? "<asset-clip ref=\"a\" lane=\"-1\" offset=\"3603s\" start=\"3600s\" duration=\"1s\" audioRole=\"music\"/>" : ""
        let component = componentEffect ? "<audio-channel-source srcCh=\"1, 2\" role=\"effects\">\(filter("EQ"))</audio-channel-source>" : ""
        return Data("""
        <fcpxml version="1.14"><resources><format id="f" frameDuration="1/30s"/>
        <asset id="a" start="3600s" duration="20s" hasAudio="1"><media-rep kind="original-media" src="\(directory.appendingPathComponent("Voice.wav").absoluteString)"/></asset>
        \(resources)<effect id="controller" uid="\(AudioControllerSettings.effectUID)"/></resources>
        <library location="\(directory.appendingPathComponent("Fixture.fcpbundle").absoluteString)"><event name="Original" uid="CE445773-F54F-433A-91B6-F367E99C20B4"><project name="Plugins" uid="original">
        <sequence format="f" duration="8s" tcStart="7200s"><spine><gap offset="7200s" start="0s" duration="3s"/>
        <asset-clip ref="a" name="Voice" offset="7203s" start="3602s" duration="5s" audioRole="music">
        \(component)\(connected)\(filters)</asset-clip></spine></sequence></project></event></library></fcpxml>
        """.utf8)
    }
}
