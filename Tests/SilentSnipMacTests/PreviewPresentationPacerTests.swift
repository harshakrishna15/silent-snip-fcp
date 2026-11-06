import Foundation
import XCTest
@testable import SilentSnipMac

final class PreviewPresentationPacerTests: XCTestCase {
    func testOcclusionNotificationBypassesThrottleAndDefersFollowingTimerCheck() {
        let start = Date(timeIntervalSince1970: 100)
        var pacer = PreviewPresentationPacer()
        XCTAssertTrue(pacer.begin(at: start))
        pacer.finish()
        XCTAssertFalse(pacer.begin(at: start.addingTimeInterval(0.010)))
        XCTAssertTrue(pacer.begin(at: start.addingTimeInterval(0.010), urgent: true),
                      "A covered panel must not wait for the fallback timer interval")
        pacer.finish()
        XCTAssertFalse(pacer.begin(at: start.addingTimeInterval(0.011)))
        XCTAssertFalse(pacer.begin(at: start.addingTimeInterval(0.042)))
        XCTAssertTrue(pacer.begin(at: start.addingTimeInterval(0.044)),
                      "An urgent check restarts the timer interval")
    }

    func testSynchronousOrderingNotificationCannotReenterActiveCheck() {
        let start = Date(timeIntervalSince1970: 100)
        var pacer = PreviewPresentationPacer()
        XCTAssertTrue(pacer.begin(at: start, urgent: true))
        XCTAssertFalse(pacer.begin(at: start, urgent: true))
        XCTAssertFalse(pacer.begin(at: start.addingTimeInterval(1), urgent: true))
        XCTAssertFalse(pacer.begin(at: start.addingTimeInterval(1)))
        pacer.finish()
        XCTAssertTrue(pacer.begin(at: start.addingTimeInterval(0.034)),
                      "Rejected nested callbacks must not advance the last accepted check")
    }

    func testFallbackChecksRunAtThirtyHertzAndResetStartsFreshEpisode() {
        let start = Date(timeIntervalSince1970: 100)
        var pacer = PreviewPresentationPacer()
        XCTAssertTrue(pacer.begin(at: start))
        pacer.finish()
        XCTAssertFalse(pacer.begin(at: start.addingTimeInterval(1.0 / 60)))
        XCTAssertTrue(pacer.begin(at: start.addingTimeInterval(1.0 / 30 + 0.000001)))
        pacer.reset()
        XCTAssertTrue(pacer.begin(at: start.addingTimeInterval(1.0 / 30 + 0.000002)),
                      "A new preview is eligible immediately, even if the prior check was active")
    }
}
