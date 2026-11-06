import XCTest
@testable import SilentSnipMac

final class PreviewDiagnosticBufferTests: XCTestCase {
    func testWrappingRetainsTheLastSamplesInChronologicalOrder() {
        var buffer = PreviewDiagnosticBuffer<Int>(capacity: 3)
        for value in 0..<5 { buffer.append(value) }
        XCTAssertEqual(buffer.values, [2, 3, 4])
        buffer.append(5)
        XCTAssertEqual(buffer.values, [3, 4, 5])
    }

    func testCountsAndResetPreserveTheConfiguredCapacity() {
        var buffer = PreviewDiagnosticBuffer<String>(capacity: 3)
        buffer.append("a"); buffer.append("b")
        XCTAssertEqual(buffer.count, 2)
        XCTAssertEqual(buffer.totalAppended, 2)
        XCTAssertEqual(buffer.overwrittenCount, 0)
        buffer.append("c"); buffer.append("d")
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.totalAppended, 4)
        XCTAssertEqual(buffer.overwrittenCount, 1)
        buffer.removeAll()
        XCTAssertEqual(buffer.values, [])
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.totalAppended, 0)
        XCTAssertEqual(buffer.overwrittenCount, 0)
        XCTAssertEqual(buffer.capacity, 3)
        buffer.append("fresh")
        XCTAssertEqual(buffer.values, ["fresh"])
    }

    func testRepeatedWrappingAndSingleSampleCapacity() {
        var buffer = PreviewDiagnosticBuffer<Int>(capacity: 4)
        var single = PreviewDiagnosticBuffer<Int>(capacity: 1)
        for value in 0..<100 { buffer.append(value); single.append(value) }
        XCTAssertEqual(buffer.values, [96, 97, 98, 99])
        XCTAssertEqual(buffer.count, 4)
        XCTAssertEqual(buffer.totalAppended, 100)
        XCTAssertEqual(buffer.overwrittenCount, 96)
        XCTAssertEqual(single.values, [99])
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single.totalAppended, 100)
        XCTAssertEqual(single.overwrittenCount, 99)
    }
}
