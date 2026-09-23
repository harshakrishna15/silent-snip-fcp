import CutdownCore
import Foundation
import XCTest
@testable import CutdownMac

final class AudioControllerSettingsTests: XCTestCase {
    func testExplicitWindowRequestSuppliesOnlyCompletelyOmittedPrivateSettings() throws {
        let bare = try fixture(filter: "<filter-audio ref=\"au\" name=\"Cutdown Audio\"/>")
        XCTAssertThrowsError(try AudioControllerSettings.validate(projectData: bare.data, target: bare.target, requested: requested))
        XCTAssertTrue(try AudioControllerSettings.validate(projectData: bare.data, target: bare.target,
            requested: requested, allowOmittedPrivateSettings: true))
        XCTAssertThrowsError(try AudioControllerSettings.read(projectData: bare.data, target: bare.target))
        for invalid in ["", "<filter-audio ref=\"au\" enabled=\"0\"/>",
                        "<filter-audio ref=\"au\"/><filter-audio ref=\"au\"/>",
                        "<filter-audio ref=\"au\"><data key=\"effectState\">bad</data></filter-audio>",
                        "<filter-audio ref=\"au\"><param name=\"Silence Threshold\" key=\"4037165010\" value=\"-32\"/></filter-audio>"] {
            let f = try fixture(filter: invalid)
            XCTAssertThrowsError(try AudioControllerSettings.validate(projectData: f.data, target: f.target,
                requested: requested, requireController: false, allowOmittedPrivateSettings: true), invalid)
        }
    }

    func testInteractiveRequestIsAuthoritativeButStrictArtifactValidationRemainsStrict() throws {
        let saved = try fixture(filter: filter(values: [-26, 0.8, 0.15, 0.3]))
        XCTAssertNoThrow(try AudioControllerSettings.validateInteractive(projectData: saved.data, target: saved.target, requested: requested))
        XCTAssertThrowsError(try AudioControllerSettings.validate(projectData: saved.data, target: saved.target, requested: requested))
        let bare = try fixture(filter: "<filter-audio ref=\"au\" presetID=\"Saved.aupreset\"/>")
        XCTAssertNoThrow(try AudioControllerSettings.validateInteractive(projectData: bare.data, target: bare.target, requested: requested))
        let malformed = try fixture(filter: "<filter-audio ref=\"au\"><data key=\"effectState\">bad</data></filter-audio>")
        XCTAssertThrowsError(try AudioControllerSettings.validateInteractive(projectData: malformed.data, target: malformed.target, requested: requested))
    }

    private let values = [-32.0, 0.75, 0.125, 0.25]
    private var requested: AnalysisSettings {
        get throws {
            try AnalysisSettings(thresholdDBFS: values[0], minimumSilenceDuration: values[1],
                beforeSpeechPadding: values[2], afterSpeechPadding: values[3])
        }
    }

    func testReadReturnsExplicitInspectorControlsWithoutUsingDefaultsOrOpaqueState() throws {
        let custom = [-26.0, 0.8, 0.15, 0.3]
        let fixture = try fixture(filter: filter(values: custom))
        let settings = try AudioControllerSettings.read(projectData: fixture.data, target: fixture.target)
        XCTAssertEqual(settings, try AnalysisSettings(thresholdDBFS: custom[0], minimumSilenceDuration: custom[1],
            beforeSpeechPadding: custom[2], afterSpeechPadding: custom[3]))
        XCTAssertEqual(settings.windowDuration, 0.01)
        XCTAssertTrue(try AudioControllerSettings.validate(projectData: fixture.data, target: fixture.target, requested: settings))
    }

    func testReadRecoversEveryOmittedControlFromTheVerifiedInstanceArchive() throws {
        let saved = [-47.0, 0.65, 0.08, 0.22]
        let fixture = try fixture(filter: "<filter-audio ref=\"au\">\(try archive(values: saved))</filter-audio>")
        let settings = try AudioControllerSettings.read(projectData: fixture.data, target: fixture.target)
        XCTAssertEqual(settings.thresholdDBFS, Double(Float(saved[0])))
        XCTAssertEqual(settings.minimumSilenceDuration, Double(Float(saved[1])))
        XCTAssertEqual(settings.beforeSpeechPadding, Double(Float(saved[2])))
        XCTAssertEqual(settings.afterSpeechPadding, Double(Float(saved[3])))
    }

    func testReadExplicitScalarOverridesStaleArchiveWhileRecoveringRemainingControls() throws {
        let saved = try archive(values: [-40, 0.75, 0.125, 0.25])
        let fixture = try fixture(filter: """
        <filter-audio ref="au">\(saved)<param name="Silence Threshold" key="4037165010" value="-32"/></filter-audio>
        """)
        XCTAssertEqual(try AudioControllerSettings.read(projectData: fixture.data, target: fixture.target), try requested)
    }

    func testReadRequiresExactlyOneEnabledDirectKnownController() throws {
        for (content, expected) in [
            ("", AudioControllerSettingsError.missingController),
            (filter() + filter(), .ambiguousController),
            (filter().replacingOccurrences(of: "<filter-audio ", with: "<filter-audio enabled=\"0\" "), .disabledController),
            ("<audio-channel-source srcCh=\"1, 2\" role=\"dialogue\">\(filter())</audio-channel-source>", .unsupportedControllerLocation)
        ] {
            let fixture = try fixture(filter: content)
            XCTAssertThrowsError(try AudioControllerSettings.read(projectData: fixture.data, target: fixture.target)) {
                XCTAssertEqual($0 as? AudioControllerSettingsError, expected)
            }
        }
        let unrelated = try fixture(filter: filter(), uid: "unrelated Audio Unit")
        XCTAssertThrowsError(try AudioControllerSettings.read(projectData: unrelated.data, target: unrelated.target)) {
            XCTAssertEqual($0 as? AudioControllerSettingsError, .missingController)
        }
    }

    func testReadResolvesExactRepeatedOccurrenceAndRejectsUnsupportedSavedValues() throws {
        let repeated = try fixture(filter: filter(values: [-40, 0.5, 0.1, 0.1]), second: filter())
        XCTAssertEqual(try AudioControllerSettings.read(projectData: repeated.data, target: repeated.target), try requested)
        for controls in [
            "<data key=\"effectState\">unknown archive</data>",
            "<param name=\"Silence Threshold\" key=\"4037165010\" value=\"-32\"><keyframeAnimation/></param>",
            parameters().replacingOccurrences(of: "value=\"-32.0\"", with: "value=\"nan\"")
        ] {
            let fixture = try fixture(filter: "<filter-audio ref=\"au\">\(controls)</filter-audio>")
            XCTAssertThrowsError(try AudioControllerSettings.read(projectData: fixture.data, target: fixture.target))
        }
    }

    func testCompletePublishedValuesValidateDespiteStaleOpaqueState() throws {
        let fixture = try fixture(filter: filter())
        XCTAssertTrue(try AudioControllerSettings.validate(projectData: fixture.data,
            target: fixture.target, requested: requested))
    }

    func testNativeInheritedSettingsWithOnlyThresholdPublished() throws {
        // Captured from a Cutdown effect instance in FCP 12.3.
        // This preserves the native archive independently of our test encoder.
        let archive = "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVtlZmZlY3RTdGF0ZYABrQsMHR4fICEiIyQlJidVJG51bGzTDQ4PEBYcV05TLmtleXNaTlMub2JqZWN0c1YkY2xhc3OlERITFBWAAoADgASABYAGpRcYGRobgAeACIAJgAqAC4AMXG1hbnVmYWN0dXJlclRkYXRhVHR5cGVXc3VidHlwZVd2ZXJzaW9uEkN0ZG5PEGMAAAAACQAAAHQAaAByAGUAcwBoAG8AbABkAAAA0MEAAAcAAABtAGkAbgBpAG0AdQBtAAAAQD8AAAYAAABiAGUAZgBvAHIAZQAAAAA+AAAAAAUAAABhAGYAdABlAHIAAACAPv8SYXVmeBJjdGRuEAHSKCkqK1okY2xhc3NuYW1lWCRjbGFzc2VzXxATTlNNdXRhYmxlRGljdGlvbmFyeaMqLC1cTlNEaWN0aW9uYXJ5WE5TT2JqZWN0AAgAEQAaACQAKQAyADcASQBMAFgAWgBoAG4AdQB9AIgAjwCVAJcAmQCbAJ0AnwClAKcAqQCrAK0ArwCxAL4AwwDIANAA2ADdAUMBSAFNAU8BVAFfAWgBfgGCAY8AAAAAAAACAQAAAAAAAAAuAAAAAAAAAAAAAAAAAAABmA=="
        let fixture = try fixture(filter: "<filter-audio ref=\"au\"><data key=\"effectState\">\(archive)</data><param name=\"Silence Threshold\" key=\"4037165010\" value=\"-26\"/></filter-audio>")
        let request = try AnalysisSettings(thresholdDBFS: -26, minimumSilenceDuration: 0.75,
            beforeSpeechPadding: 0.125, afterSpeechPadding: 0.25)
        XCTAssertTrue(try AudioControllerSettings.validate(projectData: fixture.data, target: fixture.target, requested: request))
    }

    func testSavedInstanceValuesSupplyOmittedControlsAndExplicitScalarWins() throws {
        let saved = try archive(values: [-40, 0.75, 0.125, 0.25])
        let fixture = try fixture(filter: "<filter-audio ref=\"au\">\(saved)<param name=\"Silence Threshold\" key=\"4037165010\" value=\"-32\"/></filter-audio>")
        XCTAssertTrue(try AudioControllerSettings.validate(projectData: fixture.data, target: fixture.target, requested: requested))
        XCTAssertThrowsError(try AudioControllerSettings.validate(projectData: fixture.data, target: fixture.target, requested: .defaults)) {
            XCTAssertEqual($0 as? AudioControllerSettingsError,
                .settingsMismatch(["Silence Threshold", "Minimum Silence", "Before Speech", "After Speech"]))
        }
    }

    func testSavedStateOnlyValidatesAndDoesNotGuessDefaults() throws {
        let fixture = try fixture(filter: "<filter-audio ref=\"au\">\(try archive())</filter-audio>")
        XCTAssertTrue(try AudioControllerSettings.validate(projectData: fixture.data, target: fixture.target, requested: requested))
        XCTAssertThrowsError(try AudioControllerSettings.validate(projectData: fixture.data, target: fixture.target, requested: .defaults))
    }

    func testInvalidOrUnknownSavedStateCannotSupplyOmittedControls() throws {
        var wrongIdentifier = packet()
        wrongIdentifier[8] = 0x58
        var trailingByte = packet()
        trailingByte.append(0)
        let saved = try archive()
        let variants = [
            try archive(overrides: ["manufacturer": NSNumber(value: 0)]),
            try archive(overrides: ["type": NSNumber(value: 0)]),
            try archive(overrides: ["subtype": NSNumber(value: 0)]),
            try archive(overrides: ["version": NSNumber(value: 2)]),
            try archive(overrides: ["version": NSNumber(value: true)]),
            try archive(overrides: ["data": Data()]),
            try archive(overrides: ["data": wrongIdentifier]),
            try archive(overrides: ["data": trailingByte]),
            try archive(overrides: ["unrecognized": NSNumber(value: 1)]),
            saved + saved,
            "<data key=\"effectState\">\(String(repeating: "A", count: 16_385))</data>"
        ]
        for variant in variants {
            let fixture = try fixture(filter: "<filter-audio ref=\"au\">\(variant)</filter-audio>")
            XCTAssertThrowsError(try AudioControllerSettings.validate(projectData: fixture.data, target: fixture.target, requested: requested)) {
                XCTAssertEqual($0 as? AudioControllerSettingsError, .unavailableSettings)
            }
        }
    }

    func testArchivedValuesMustBeFiniteAndInRange() throws {
        for threshold in [Double.nan, .infinity, -81] {
            let fixture = try fixture(filter: "<filter-audio ref=\"au\">\(try archive(values: [threshold, 0.75, 0.125, 0.25]))</filter-audio>")
            XCTAssertThrowsError(try AudioControllerSettings.validate(projectData: fixture.data, target: fixture.target, requested: requested)) {
                XCTAssertEqual($0 as? AudioControllerSettingsError, .invalidParameter("Silence Threshold"))
            }
        }
    }

    func testValidArchiveDoesNotRescueAnimatedDuplicateOrUnknownExplicitControls() throws {
        let saved = try archive()
        for controls in [
            "<param name=\"Silence Threshold\" key=\"4037165010\" value=\"-32\"><keyframeAnimation/></param>",
            String(repeating: "<param name=\"Silence Threshold\" key=\"4037165010\" value=\"-32\"/>", count: 2),
            "<param name=\"Other\" key=\"unknown\" value=\"0\"/>"
        ] {
            let fixture = try fixture(filter: "<filter-audio ref=\"au\">\(saved)\(controls)</filter-audio>")
            XCTAssertThrowsError(try AudioControllerSettings.validate(projectData: fixture.data, target: fixture.target, requested: requested)) {
                guard case .invalidParameter = $0 as? AudioControllerSettingsError else { return XCTFail("Unexpected error \($0)") }
            }
        }
    }

    func testHostDelayedLastParameterRejectsBeforeReview() throws {
        let fixture = try fixture(filter: filter())
        let stale = try AnalysisSettings(thresholdDBFS: -32, minimumSilenceDuration: 0.75,
            beforeSpeechPadding: 0.125, afterSpeechPadding: 0.1)
        XCTAssertThrowsError(try AudioControllerSettings.validate(projectData: fixture.data,
            target: fixture.target, requested: stale)) {
            XCTAssertEqual($0 as? AudioControllerSettingsError, .settingsMismatch(["After Speech"]))
        }
    }

    func testRepeatedSourceUsesExactTimelineOccurrence() throws {
        let fixture = try fixture(filter: filter(values: [-40, 0.5, 0.1, 0.1]), second: filter())
        XCTAssertEqual(fixture.target.id, "spine/1")
        XCTAssertTrue(try AudioControllerSettings.validate(projectData: fixture.data,
            target: fixture.target, requested: requested))
    }

    func testXMLPathMustStillIdentifySelectedOccurrence() throws {
        let original = try fixture(filter: filter())
        let changed = String(decoding: original.data, as: UTF8.self)
            .replacingOccurrences(of: "<spine>", with: "<spine><gap offset=\"0s\" duration=\"0s\"/>")
        XCTAssertThrowsError(try AudioControllerSettings.validate(projectData: Data(changed.utf8),
            target: original.target, requested: requested)) {
            XCTAssertEqual($0 as? AudioControllerSettingsError, .targetChanged)
        }
    }

    func testMissingAndOpaqueOnlyParametersNeverAssumeDefaults() throws {
        for content in ["", "<data key=\"effectState\">opaque state without explicit controls</data>",
                        parameters().replacingOccurrences(of: "<param name=\"After Speech\" key=\"252981911\" value=\"0.25\"/>", with: "")] {
            let fixture = try fixture(filter: "<filter-audio ref=\"au\">\(content)</filter-audio>")
            XCTAssertThrowsError(try AudioControllerSettings.validate(projectData: fixture.data,
                target: fixture.target, requested: .defaults)) {
                XCTAssertEqual($0 as? AudioControllerSettingsError, .unavailableSettings)
            }
        }
    }

    func testAmbiguousEffectsAndDisabledOrComponentEffectsReject() throws {
        for (content, expected) in [
            (filter() + filter(), AudioControllerSettingsError.ambiguousController),
            (filter().replacingOccurrences(of: "<filter-audio ", with: "<filter-audio enabled=\"0\" "), .disabledController),
            ("<audio-channel-source srcCh=\"1, 2\" role=\"dialogue\">\(filter())</audio-channel-source>", .unsupportedControllerLocation)
        ] {
            let fixture = try fixture(filter: content)
            XCTAssertThrowsError(try AudioControllerSettings.validate(projectData: fixture.data,
                target: fixture.target, requested: requested)) {
                XCTAssertEqual($0 as? AudioControllerSettingsError, expected)
            }
        }
    }

    func testWrongKeysNamesDuplicateAndAnimatedControlsReject() throws {
        let valid = parameters()
        let variants = [
            valid.replacingOccurrences(of: "252981911", with: "unverified-key"),
            valid.replacingOccurrences(of: "After Speech", with: "Before Speech"),
            valid.replacingOccurrences(of: "252981911", with: "4090893112"),
            valid.replacingOccurrences(of: "value=\"0.25\"/>", with: "value=\"0.25\"><keyframeAnimation><keyframe time=\"0s\" value=\"0.1\"/></keyframeAnimation></param>"),
            valid.replacingOccurrences(of: "value=\"0.25\"", with: "value=\"0.25\" interpolation=\"linear\"")
        ]
        for variant in variants {
            let fixture = try fixture(filter: "<filter-audio ref=\"au\">\(variant)</filter-audio>")
            XCTAssertThrowsError(try AudioControllerSettings.validate(projectData: fixture.data,
                target: fixture.target, requested: requested)) {
                guard case .invalidParameter = $0 as? AudioControllerSettingsError else {
                    return XCTFail("Unexpected error \($0)")
                }
            }
        }
    }

    func testNonfiniteAndOutOfAUParameterRangeReject() throws {
        for (needle, replacement, name) in [
            ("-32.0", "nan", "Silence Threshold"),
            ("-32.0", "-81", "Silence Threshold"),
            ("0.75", "0.00009", "Minimum Silence"),
            ("0.125", "-0.01", "Before Speech"),
            ("0.25", "2.1", "After Speech")
        ] {
            let fixture = try fixture(filter: filter().replacingOccurrences(of: "value=\"\(needle)\"", with: "value=\"\(replacement)\""))
            XCTAssertThrowsError(try AudioControllerSettings.validate(projectData: fixture.data,
                target: fixture.target, requested: requested)) {
                XCTAssertEqual($0 as? AudioControllerSettingsError, .invalidParameter(name))
            }
        }
    }

    func testRepresentationsOfSameAUFloatValueCompareExactly() throws {
        let xmlValues = [-40.0, 0.5, Double(Float(0.1)), Double(Float(0.1))]
        let fixture = try fixture(filter: filter(values: xmlValues))
        XCTAssertTrue(try AudioControllerSettings.validate(projectData: fixture.data,
            target: fixture.target, requested: .defaults))
    }

    func testMinimumSilenceBoundarySurvivesAUFloatExport() throws {
        let minimum = Double(Float(0.0001))
        let fixture = try fixture(filter: filter(values: [-40, minimum, 0, 0]))
        let requested = try AnalysisSettings(thresholdDBFS: -40, minimumSilenceDuration: 0.0001,
                                             beforeSpeechPadding: 0, afterSpeechPadding: 0)
        XCTAssertTrue(try AudioControllerSettings.validate(projectData: fixture.data,
            target: fixture.target, requested: requested))
        XCTAssertEqual(try AudioControllerSettings.read(projectData: fixture.data,
            target: fixture.target).minimumSilenceDuration, minimum)
    }

    func testNameWithoutVerifiedUIDCannotMasqueradeAsController() throws {
        let fixture = try fixture(filter: filter(), uid: "an unrelated audio effect")
        XCTAssertThrowsError(try AudioControllerSettings.validate(projectData: fixture.data,
            target: fixture.target, requested: requested)) {
            XCTAssertEqual($0 as? AudioControllerSettingsError, .missingController)
        }
    }

    func testMissingControllerRequiresExplicitReadOnlyOptOut() throws {
        let fixture = try fixture(filter: "")
        XCTAssertThrowsError(try AudioControllerSettings.validate(projectData: fixture.data,
            target: fixture.target, requested: .defaults)) {
            XCTAssertEqual($0 as? AudioControllerSettingsError, .missingController)
        }
        XCTAssertFalse(try AudioControllerSettings.validate(projectData: fixture.data,
            target: fixture.target, requested: .defaults, requireController: false))
    }

    func testReadOnlyOptOutStillValidatesAnExistingController() throws {
        let fixture = try fixture(filter: filter())
        XCTAssertThrowsError(try AudioControllerSettings.validate(projectData: fixture.data,
            target: fixture.target, requested: .defaults, requireController: false)) {
            guard case .settingsMismatch = $0 as? AudioControllerSettingsError else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testConnectedClipsControllerCannotAuthorizeTheSelectedPrimaryClip() throws {
        let connected = "<asset-clip ref=\"a\" name=\"Other occurrence\" lane=\"-1\" offset=\"1s\" start=\"1s\" duration=\"2s\" audioRole=\"dialogue\">\(filter())</asset-clip>"
        let fixture = try fixture(filter: connected)
        XCTAssertThrowsError(try AudioControllerSettings.validate(projectData: fixture.data,
            target: fixture.target, requested: requested)) {
            XCTAssertEqual($0 as? AudioControllerSettingsError, .missingController)
        }
    }

    func testBundleURLResolvesSameSettings() throws {
        let fixture = try fixture(filter: filter())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CutdownAU-\(UUID()).fcpxmld")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try fixture.data.write(to: url.appendingPathComponent("Info.fcpxml"))
        XCTAssertTrue(try AudioControllerSettings.validate(projectXML: url, target: fixture.target, requested: requested))
        XCTAssertEqual(try AudioControllerSettings.read(projectXML: url, target: fixture.target), try requested)
    }

    private func parameters(values: [Double]? = nil) -> String {
        let values = values ?? self.values
        return zip(zip(["Silence Threshold", "Minimum Silence", "Before Speech", "After Speech"],
                       ["4037165010", "3342540801", "4090893112", "252981911"]), values)
            .map { "<param name=\"\($0.0.0)\" key=\"\($0.0.1)\" value=\"\($0.1)\"/>" }.joined()
    }
    private func packet(values: [Double]? = nil) -> Data {
        var result = Data(base64Encoded: "AAAAAAkAAAB0AGgAcgBlAHMAaABvAGwAZAAAAAAAAAAHAAAAbQBpAG4AaQBtAHUAbQAAAAAAAAAGAAAAYgBlAGYAbwByAGUAAAAAAAAAAAAFAAAAYQBmAHQAZQByAAAAAAD/")!
        for (value, offset) in zip(values ?? self.values, [26, 50, 72, 94]) {
            let bits = Float(value).bitPattern
            result.replaceSubrange(offset..<(offset + 4), with: (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) })
        }
        return result
    }
    private func archive(values: [Double]? = nil, overrides: [String: Any] = [:]) throws -> String {
        var state: [String: Any] = ["manufacturer": NSNumber(value: 0x4374646e),
            "type": NSNumber(value: 0x61756678), "subtype": NSNumber(value: 0x6374646e),
            "version": NSNumber(value: 1), "data": packet(values: values)]
        state.merge(overrides) { _, replacement in replacement }
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode(NSMutableDictionary(dictionary: state), forKey: "effectState")
        archiver.finishEncoding()
        return "<data key=\"effectState\">\(archiver.encodedData.base64EncodedString())</data>"
    }
    private func filter(values: [Double]? = nil) -> String {
        "<filter-audio ref=\"au\" name=\"Cutdown Audio\"><data key=\"effectState\">stale opaque state</data>\(parameters(values: values))</filter-audio>"
    }
    private func fixture(filter: String, second: String? = nil, uid: String = AudioControllerSettings.effectUID) throws -> (data: Data, target: TimelineClip) {
        let secondClip = second.map { "<asset-clip ref=\"a\" name=\"Same source\" offset=\"3s\" start=\"1s\" duration=\"3s\" audioRole=\"dialogue\">\($0)</asset-clip>" } ?? ""
        let data = Data("""
        <fcpxml version="1.14"><resources>
        <format id="f" frameDuration="1/30s"/><asset id="a" start="0s" duration="10s" hasAudio="1"><media-rep kind="original-media" src="file:///Cutdown-Test-Source.wav"/></asset>
        <effect id="au" name="Cutdown Audio" uid="\(uid)"/></resources>
        <library><event><project name="AU settings" uid="settings-project"><sequence format="f" duration="\(second == nil ? 3 : 6)s" tcStart="0s">
        <spine><asset-clip ref="a" name="Same source" offset="0s" start="1s" duration="3s" audioRole="dialogue">\(filter)</asset-clip>\(secondClip)</spine>
        </sequence></project></event></library></fcpxml>
        """.utf8)
        let document = try TimelineParser.parse(data: data)
        let selection = TimelineSelection(timelineRange: TimeRange(start: RationalTime(second == nil ? 0 : 3), end: RationalTime(second == nil ? 3 : 6)))
        return (data, try document.selectedTarget(selection, requireExistingMedia: false))
    }
}
