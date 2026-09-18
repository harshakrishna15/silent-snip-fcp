import XCTest
@testable import CutdownMac

final class AudioProgressThrottleTests: XCTestCase {
    func testBurstIsBoundedButCompletionIsImmediate() {
        var gate = AudioProgressThrottle()
        var delivered: [Double] = []
        // A decoder can process thousands of windows between display updates.
        for index in 0...10_000 {
            let fraction = Double(index) / 10_000
            if gate.shouldReport(fraction, at: 100 + fraction * 0.05) { delivered.append(fraction) }
        }
        XCTAssertEqual(delivered, [0, 1])
        XCTAssertFalse(gate.shouldReport(1, at: 101))
    }

    func testSlowWorkContinuesReportingAndRejectsRegressions() {
        var gate = AudioProgressThrottle()
        XCTAssertTrue(gate.shouldReport(0.1, at: 10))
        XCTAssertFalse(gate.shouldReport(0.2, at: 10.05))
        XCTAssertTrue(gate.shouldReport(0.3, at: 10.125))
        XCTAssertFalse(gate.shouldReport(0.2, at: 11))
        XCTAssertFalse(gate.shouldReport(.nan, at: 11))
        XCTAssertFalse(gate.shouldReport(.infinity, at: 11))
        XCTAssertFalse(gate.shouldReport(-1, at: 11))
        XCTAssertTrue(gate.shouldReport(0.7, at: 11))
        XCTAssertTrue(gate.shouldReport(1, at: 11.01))
    }
}
