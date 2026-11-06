import XCTest
@testable import SilentSnipMac

final class PreviewForegroundPolicyTests: XCTestCase {
    func testOnlyTheActivePinnedHostOwnsThePreview() {
        XCTAssertTrue(PreviewForegroundPolicy.permits(hostPID: 101, hostIsActive: true, foregroundPID: 101))
        XCTAssertFalse(PreviewForegroundPolicy.permits(hostPID: 101, hostIsActive: true, foregroundPID: 202))
        XCTAssertFalse(PreviewForegroundPolicy.permits(hostPID: 101, hostIsActive: true, foregroundPID: nil))
    }

    func testInactiveHostRejectsThePreviousFrontmostSnapshotUntilActualReturn() {
        XCTAssertFalse(PreviewForegroundPolicy.permits(hostPID: 101, hostIsActive: false, foregroundPID: 101),
                       "A stale frontmost PID must not undo the host's deactivation")
        XCTAssertFalse(PreviewForegroundPolicy.permits(hostPID: 101, hostIsActive: false, foregroundPID: 202))
        XCTAssertTrue(PreviewForegroundPolicy.permits(hostPID: 101, hostIsActive: true, foregroundPID: 101),
                      "Fresh activation state permits restoring the same review without Analyze")
    }

    func testActivationAloneOrInvalidHostIdentityCannotRestoreThePreview() {
        XCTAssertFalse(PreviewForegroundPolicy.permits(hostPID: 101, hostIsActive: true, foregroundPID: 202),
                       "A delayed host activation callback cannot override a different current app")
        for host: Int32 in [0, -1] {
            XCTAssertFalse(PreviewForegroundPolicy.permits(hostPID: host, hostIsActive: true, foregroundPID: host))
        }
    }
}
