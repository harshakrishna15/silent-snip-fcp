import Foundation
import XCTest
@testable import CutdownMac

final class StableXMLDeliveryTests: XCTestCase {
    func testUnchangedXMLParsesOnceButStillWaitsForStableDelivery() {
        var delivery = StableXMLDelivery()
        var parses = 0
        let data = Data("complete project".utf8)
        for _ in 0..<30 {
            XCTAssertFalse(delivery.observe(data) { _ in parses += 1; return true })
        }
        XCTAssertTrue(delivery.observe(data) { _ in parses += 1; return true })
        XCTAssertEqual(parses, 1, "Status reads must not reparse identical project XML")
    }

    func testReplacementCannotInheritPreviousProjectsStability() {
        var delivery = StableXMLDelivery()
        let first = Data("first".utf8), replacement = Data("second".utf8)
        for _ in 0..<30 { XCTAssertFalse(delivery.observe(first) { _ in true }) }
        for _ in 0..<30 { XCTAssertFalse(delivery.observe(replacement) { _ in true }) }
        XCTAssertTrue(delivery.observe(replacement) { _ in true })
    }

    func testInvalidXMLIsNeverAcceptedAndCorrectedXMLIsRevalidated() {
        var delivery = StableXMLDelivery()
        var parses = 0
        for _ in 0..<60 {
            XCTAssertFalse(delivery.observe(Data("partial".utf8)) { _ in parses += 1; return false })
        }
        XCTAssertEqual(parses, 1)
        for _ in 0..<30 {
            XCTAssertFalse(delivery.observe(Data("complete".utf8)) { _ in parses += 1; return true })
        }
        XCTAssertTrue(delivery.observe(Data("complete".utf8)) { _ in parses += 1; return true })
        XCTAssertEqual(parses, 2)
    }

    func testMissingOrEmptyDataResetsCompletionEvidence() {
        for interruption: Data? in [nil, Data()] {
            var delivery = StableXMLDelivery()
            let data = Data("project".utf8)
            for _ in 0..<30 { XCTAssertFalse(delivery.observe(data) { _ in true }) }
            XCTAssertFalse(delivery.observe(interruption) { _ in XCTFail("No XML to validate"); return true })
            for _ in 0..<30 { XCTAssertFalse(delivery.observe(data) { _ in true }) }
            XCTAssertTrue(delivery.observe(data) { _ in true })
        }
    }
}
