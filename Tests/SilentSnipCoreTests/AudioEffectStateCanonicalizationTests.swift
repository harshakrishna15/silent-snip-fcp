import XCTest
import Foundation
@testable import SilentSnipCore

final class AudioEffectStateCanonicalizationTests: XCTestCase {
    // Actual Gate archives before and after one native bulk Paste Attributes.
    // Their AU state dictionaries/data match; their key/object ordering differs.
    private let nativeBefore = "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVtlZmZlY3RTdGF0ZYABrxAPCwwfICEiIyQlJicoKSorVSRudWxs0w0ODxAXHldOUy5rZXlzWk5TLm9iamVjdHNWJGNsYXNzphESExQVFoACgAOABIAFgAaAB6YYGRobHB2ACIAJgAqAC4AMgA2ADld2ZXJzaW9uXG1hbnVmYWN0dXJlclRkYXRhVG5hbWVUdHlwZVdzdWJ0eXBlEAASRU1BR08QWFgAAAACAAAAEAAAAEdBTUVUU1BQswAAAAAAAAAAAKjBAABgwAAAyMIAAIA/AAAAAP//P0AAQJxGAACgQQAAAAAAAAAAAACAPwAAAAAAAAAAAAAAAAAAoMFYVW50aXRsZWQSYXVmeBCz0iwtLi9aJGNsYXNzbmFtZVgkY2xhc3Nlc1xOU0RpY3Rpb25hcnmiLjBYTlNPYmplY3QACAARABoAJAApADIANwBJAEwAWABaAGwAcgB5AIEAjACTAJoAnACeAKAAogCkAKYArQCvALEAswC1ALcAuQC7AMMA0ADVANoA3wDnAOkA7gFJAVIBVwFZAV4BaQFyAX8BggAAAAAAAAIBAAAAAAAAADEAAAAAAAAAAAAAAAAAAAGL"
    private let nativeAfter = "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVtlZmZlY3RTdGF0ZYABrxAPCwwfICEiIyQlJicoKSorVSRudWxs0w0ODxAXHldOUy5rZXlzWk5TLm9iamVjdHNWJGNsYXNzphESExQVFoACgAOABIAFgAaAB6YYGRobHB2ACIAJgAqAC4AMgA2ADldzdWJ0eXBlXG1hbnVmYWN0dXJlclRkYXRhVG5hbWVUdHlwZVd2ZXJzaW9uELMSRU1BR08QWFgAAAACAAAAEAAAAEdBTUVUU1BQswAAAAAAAAAAAKjBAABgwAAAyMIAAIA/AAAAAP//P0AAQJxGAACgQQAAAAAAAAAAAACAPwAAAAAAAAAAAAAAAAAAoMFYVW50aXRsZWQSYXVmeBAA0iwtLi9aJGNsYXNzbmFtZVgkY2xhc3Nlc1xOU0RpY3Rpb25hcnmiLjBYTlNPYmplY3QACAARABoAJAApADIANwBJAEwAWABaAGwAcgB5AIEAjACTAJoAnACeAKAAogCkAKYArQCvALEAswC1ALcAuQC7AMMA0ADVANoA3wDnAOkA7gFJAVIBVwFZAV4BaQFyAX8BggAAAAAAAAIBAAAAAAAAADEAAAAAAAAAAAAAAAAAAAGL"

    private func archive(_ state: NSDictionary) -> String {
        let encoder = NSKeyedArchiver(requiringSecureCoding: true)
        encoder.encode(state, forKey: "effectState")
        encoder.finishEncoding()
        return encoder.encodedData.base64EncodedString()
    }

    private func inertArchive(_ transform: (inout [String: Any]) -> Void) throws -> String {
        let bytes = try XCTUnwrap(Data(base64Encoded: nativeBefore))
        var mutable = try XCTUnwrap(PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any])
        transform(&mutable)
        return try PropertyListSerialization.data(fromPropertyList: mutable, format: .binary, options: 0).base64EncodedString()
    }

    private func state(_ extra: [String: Any] = [:]) -> NSDictionary {
        var result: [String: Any] = ["manufacturer": 1162690887, "type": 1635083896, "subtype": 179, "version": 0, "data": Data([0, 1, 2, 255]), "name": "Edited"]
        result.merge(extra) { _, new in new }
        return result as NSDictionary
    }

    private func fingerprint(_ payload: String, key: String = "effectState") throws -> String {
        let xml = """
        <fcpxml version="1.14"><resources><format id="f" frameDuration="1/30s"/>
        <asset id="a" start="0s" duration="3s" hasAudio="1"><media-rep kind="original-media" src="file:///tmp/state.wav"/></asset>
        <effect id="fx" name="Gate" uid="AudioUnit: 0x61756678000000b3454d4147"/></resources>
        <library><event><project name="State" uid="state"><sequence format="f" duration="3s"><spine>
        <asset-clip ref="a" offset="0s" duration="3s" audioRole="dialogue"><filter-audio ref="fx" name="Gate"><data key="\(key)">\(payload)</data></filter-audio></asset-clip>
        </spine></sequence></project></event></library></fcpxml>
        """
        return try TimelineParser.parse(data: Data(xml.utf8)).fingerprint
    }

    func testActualNativeDictionaryReorderingHasSameStateAndTimelineFingerprint() throws {
        XCTAssertNotEqual(nativeBefore, nativeAfter)
        let before = try XCTUnwrap(AudioEffectStateCanonicalization.canonical(nativeBefore))
        XCTAssertEqual(before, AudioEffectStateCanonicalization.canonical(nativeAfter))
        XCTAssertEqual(try fingerprint(nativeBefore), try fingerprint(nativeAfter))
        XCTAssertNotEqual(try fingerprint(nativeBefore, key: "effectData"), try fingerprint(nativeAfter, key: "effectData"))
    }

    func testRawPayloadCannotImpersonateCanonicalComparisonText() throws {
        let semantic = try XCTUnwrap(AudioEffectStateCanonicalization.canonical(nativeBefore))
        let tagged = "semantic:\(semantic.utf8.count):\(semantic)"
        for raw in [semantic, tagged, "raw:\(semantic.utf8.count):\(semantic)"] {
            XCTAssertNil(AudioEffectStateCanonicalization.canonical(raw))
            XCTAssertNotEqual(try fingerprint(nativeBefore), try fingerprint(raw))
        }
        XCTAssertNotEqual(try fingerprint(semantic), try fingerprint(tagged))
    }

    func testOpaqueBytesAndEveryDictionaryFieldRemainStrict() throws {
        let original = archive(state())
        let canonical = try XCTUnwrap(AudioEffectStateCanonicalization.canonical(original))
        let changes: [[String: Any]] = [["data": Data([0, 1, 3, 255])], ["version": 1], ["manufacturer": 1], ["subtype": 180], ["type": 1], ["name": "Other"], ["additional": "state"]]
        for change in changes {
            let changed = archive(state(change))
            XCTAssertNotEqual(canonical, AudioEffectStateCanonicalization.canonical(changed))
            XCTAssertNotEqual(try fingerprint(original), try fingerprint(changed))
        }
    }

    func testValuesRemainTypedAndNestedArraysRetainOrder() throws {
        let extras: [Any] = [NSNumber(value: true), NSNumber(value: 1), NSNumber(value: 1.0), "1", Data([49]), ["a", "b"], ["b", "a"], ["inner": "one"], ["inner": "two"]]
        let values = try extras.map { try XCTUnwrap(AudioEffectStateCanonicalization.canonical(archive(state(["extra": $0])))) }
        XCTAssertEqual(Set(values).count, values.count)
        let minusZero = try XCTUnwrap(AudioEffectStateCanonicalization.canonical(archive(state(["extra": -0.0]))))
        let plusZero = try XCTUnwrap(AudioEffectStateCanonicalization.canonical(archive(state(["extra": 0.0]))))
        XCTAssertNotEqual(minusZero, plusZero)
    }

    func testNestedContainersMayShareTheirFoundationClassDescriptors() throws {
        let original = archive(state(["extra": ["nested": ["deeper": true], "ordered": [1, 2, 3]]]))
        XCTAssertNotNil(AudioEffectStateCanonicalization.canonical(original))
    }

    func testUnknownClassCycleDuplicateKeysAndExtraGraphFallBackToRaw() throws {
        let variants: [String] = try [
            inertArchive { value in
                var objects = value["$objects"] as! [Any]
                objects[14] = ["$classname": "UnknownEffect", "$classes": ["UnknownEffect", "NSObject"]]
                value["$objects"] = objects
            },
            inertArchive { value in
                var objects = value["$objects"] as! [Any]
                var root = objects[1] as! [String: Any]
                var values = root["NS.objects"] as! [Any]
                values[0] = (value["$top"] as! [String: Any])["effectState"]!
                root["NS.objects"] = values; objects[1] = root; value["$objects"] = objects
            },
            inertArchive { value in
                var objects = value["$objects"] as! [Any]
                var root = objects[1] as! [String: Any]
                var keys = root["NS.keys"] as! [Any]
                keys[1] = keys[0]
                root["NS.keys"] = keys; objects[1] = root; value["$objects"] = objects
            },
            inertArchive { value in
                var objects = value["$objects"] as! [Any]
                objects.append("unreachable")
                value["$objects"] = objects
            },
            inertArchive { value in value["$top"] = ["root": (value["$top"] as! [String: Any])["effectState"]!] },
            inertArchive { value in value["$top"] = ["effectState": ["CF$UID": 1]] }
        ]
        for payload in variants {
            XCTAssertNil(AudioEffectStateCanonicalization.canonical(payload))
            XCTAssertNotEqual(try fingerprint(payload), try fingerprint(nativeBefore))
        }
    }

    func testMalformedIncompleteNonfiniteAndOversizedStatesAreNotNormalized() {
        for payload in ["bad", "", archive(["data": Data([0])]), archive(state(["extra": Double.nan])), String(repeating: "a", count: 1_500_001)] {
            XCTAssertNil(AudioEffectStateCanonicalization.canonical(payload))
        }
    }
}
