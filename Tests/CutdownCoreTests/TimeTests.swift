import Foundation
import XCTest
@testable import CutdownCore

final class TimeTests: XCTestCase {
    func testNormalizationAndExactArithmetic() throws {
        XCTAssertEqual(RationalTime(2, 4), RationalTime(1, 2))
        XCTAssertEqual(RationalTime(-2, 4), RationalTime(-1, 2))
        XCTAssertEqual(RationalTime(0, 48_000).denominator, 1)
        XCTAssertEqual(RationalTime(1, 24) + RationalTime(1, 48), RationalTime(1, 16))
        XCTAssertEqual(RationalTime(1001, 30_000) * 30_000, RationalTime(1001))
        XCTAssertEqual(RationalTime(5, 2) - RationalTime(1, 2), RationalTime(2))
        XCTAssertEqual(RationalTime(2) / 4, RationalTime(1, 2))
    }

    func testParsesFCPXMLTimesAndRejectsMalformedValues() throws {
        XCTAssertEqual(try RationalTime.parse(" 1001/30000s "), RationalTime(1001, 30_000))
        XCTAssertEqual(try RationalTime.parse("-3s"), RationalTime(-3))
        XCTAssertEqual(try RationalTime.parse("0"), .zero)
        for value in ["", "s", "1/0s", "1/-2s", "1/2/3s", "1/s", "0.5s", "9223372036854775808s"] {
            XCTAssertThrowsError(try RationalTime.parse(value), value)
        }
    }

    func testComparisonsCannotOverflowAtInt64Bounds() {
        XCTAssertLessThan(RationalTime(Int64.min), RationalTime(Int64.max))
        XCTAssertLessThan(RationalTime(Int64.max, 2), RationalTime(Int64.max, 1))
        XCTAssertLessThan(RationalTime(-Int64.max, 2), RationalTime(-1, Int64.max))
        XCTAssertLessThan(RationalTime(Int64.max - 1, Int64.max), RationalTime(1))
    }

    func testCheckedArithmeticThrowsOnOverflow() throws {
        XCTAssertThrowsError(try RationalTime(Int64.max).adding(RationalTime(1)))
        XCTAssertThrowsError(try RationalTime(Int64.min).subtracting(RationalTime(1)))
        XCTAssertThrowsError(try RationalTime(Int64.max).multiplied(by: RationalTime(2)))
        XCTAssertThrowsError(try RationalTime(1, Int64.max).adding(RationalTime(1, Int64.max - 1)))
        XCTAssertEqual(try RationalTime(Int64.min).subtracting(RationalTime(Int64.min)), .zero)
        XCTAssertEqual(try RationalTime(Int64.max, 2).multiplied(by: RationalTime(2, Int64.max)), RationalTime(1))
    }

    func testPositiveAndNegativeFrameRounding() throws {
        let frame = RationalTime(1001, 30_000)
        XCTAssertEqual(try RationalTime(1).roundedDown(toFrame: frame), frame * 29)
        XCTAssertEqual(try RationalTime(1).roundedUp(toFrame: frame), frame * 30)
        XCTAssertEqual(try RationalTime(-1).roundedDown(toFrame: frame), frame * -30)
        XCTAssertEqual(try RationalTime(-1).roundedUp(toFrame: frame), frame * -29)
        XCTAssertEqual(try (frame * 31).roundedDown(toFrame: frame), frame * 31)
        XCTAssertEqual(try (frame * 31).roundedUp(toFrame: frame), frame * 31)
        XCTAssertThrowsError(try RationalTime(1).roundedUp(toFrame: .zero))
        XCTAssertThrowsError(try RationalTime(1).roundedDown(toFrame: RationalTime(-1, 30)))
        XCTAssertThrowsError(try RationalTime(Int64.max).roundedUp(toFrame: RationalTime(1, 2)))
    }

    func testSecondsConversionValidatesBounds() throws {
        XCTAssertEqual(try RationalTime(seconds: 0.1), RationalTime(1, 10))
        XCTAssertThrowsError(try RationalTime(seconds: .nan))
        XCTAssertThrowsError(try RationalTime(seconds: .infinity))
        XCTAssertThrowsError(try RationalTime(seconds: Double(Int64.max), timescale: 1))
        XCTAssertThrowsError(try RationalTime(seconds: 1, timescale: 0))
    }

    func testHalfOpenRangeAndIntersection() throws {
        let a = TimeRange(start: RationalTime(1), end: RationalTime(3))
        XCTAssertEqual(a.duration, RationalTime(2))
        XCTAssertTrue(a.contains(RationalTime(1)))
        XCTAssertFalse(a.contains(RationalTime(3)))
        XCTAssertEqual(a.intersection(TimeRange(start: RationalTime(2), end: RationalTime(4))), TimeRange(start: RationalTime(2), end: RationalTime(3)))
        XCTAssertNil(a.intersection(TimeRange(start: RationalTime(3), end: RationalTime(4))))
        XCTAssertThrowsError(try TimeRange(start: RationalTime(Int64.min), end: RationalTime(Int64.max)).checkedDuration())
    }

    func testCodableNormalizesTimesAndRejectsUnsafeRanges() throws {
        let decoder = JSONDecoder()
        let reduced = try decoder.decode(RationalTime.self, from: Data("{\"numerator\":2,\"denominator\":4}".utf8))
        XCTAssertEqual(reduced.numerator, 1)
        XCTAssertEqual(reduced.denominator, 2)
        for denominator in [0, -1] {
            XCTAssertThrowsError(try decoder.decode(RationalTime.self, from: Data("{\"numerator\":1,\"denominator\":\(denominator)}".utf8)))
        }
        let reversed = Data("{\"start\":{\"numerator\":2,\"denominator\":1},\"end\":{\"numerator\":1,\"denominator\":1}}".utf8)
        XCTAssertThrowsError(try decoder.decode(TimeRange.self, from: reversed))
        let extreme = Data("{\"start\":{\"numerator\":\(Int64.min),\"denominator\":1},\"end\":{\"numerator\":\(Int64.max),\"denominator\":1}}".utf8)
        XCTAssertThrowsError(try decoder.decode(TimeRange.self, from: extreme))
    }
}
