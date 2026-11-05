import AppKit
import XCTest
@testable import SilentSnipMac

@MainActor final class FinalCutWorkflowWindowSizingTests: XCTestCase {
    private final class Clock { var value: TimeInterval = 0 }
    private final class Window: NSObject {}
    @MainActor private final class Driver: WorkflowSizingDriver {
        var trusted = true
        var identity: WorkflowSizingHost? = .init(pid: 123, launched: Date(timeIntervalSince1970: 1))
        var window: Window? = Window()
        var identityValid = true
        var settable = true
        var size: CGSize? = .init(width: 864, height: 798)
        var writeCode: Int32 = 0
        var observeCode: Int32 = 0
        var acceptWrites = true
        var destroyOnWrite = false
        var discovers = 0
        var writes: [CGSize] = []
        var observations = 0
        var stops = 0
        var resized: (() -> Void)?
        var destroyed: (() -> Void)?
        func host() -> WorkflowSizingHost? { identity }
        func discover(host: WorkflowSizingHost, view: UUID) -> AnyObject? { discovers += 1; return window }
        func valid(_ target: AnyObject, host: WorkflowSizingHost, view: UUID) -> Bool {
            identityValid && target === window && host == identity
        }
        func readSize(_ target: AnyObject) -> CGSize? { size }
        func writable(_ target: AnyObject) -> Bool { settable }
        func writeSize(_ target: AnyObject, size: CGSize) -> Int32 {
            writes.append(size)
            if writeCode == 0 && acceptWrites { self.size = size }
            if destroyOnWrite { destroyed?() }
            resized?() // An AX write can immediately produce its own notification.
            return writeCode
        }
        func observe(_ target: AnyObject, resized: @escaping () -> Void, destroyed: @escaping () -> Void) -> Int32 {
            observations += 1; self.resized = resized; self.destroyed = destroyed
            return observeCode
        }
        func stopObserving() { stops += 1; resized = nil; destroyed = nil }
    }

    func testExactSizeRestoreIsIdempotentAndUsesCachedTarget() {
        let clock = Clock(), driver = Driver()
        let sizing = FinalCutWorkflowWindowSizing(driver: driver, now: { clock.value })
        sizing.start()
        let view = UUID(), nonce = UUID()
        XCTAssertTrue(sizing.attach(view: view, nonce: nonce))
        XCTAssertEqual(driver.writes, [.init(width: 615, height: 736)])
        XCTAssertEqual(sizing.state, "fixed")
        XCTAssertEqual(sizing.corrections, 1)
        for _ in 0..<20 { driver.resized?(); sizing.tick() }
        XCTAssertEqual(driver.writes.count, 1, "Self-generated and duplicate events must not loop")
        XCTAssertEqual(driver.discovers, 1, "Bound events must not repeatedly enumerate the full host tree")
        driver.size = .init(width: 700, height: 800)
        clock.value = 0.2; driver.resized?(); sizing.tick()
        XCTAssertEqual(driver.writes.count, 2)
        XCTAssertEqual(sizing.state, "fixed")
        sizing.stop()
    }

    func testLiveLeaseRejectsOtherViewNonceAndExpiryInvalidatesCallbacks() {
        let clock = Clock(), driver = Driver()
        let sizing = FinalCutWorkflowWindowSizing(driver: driver, now: { clock.value })
        let view = UUID(), nonce = UUID()
        sizing.start(); XCTAssertTrue(sizing.attach(view: view, nonce: nonce))
        let oldResize = driver.resized, oldDestroyed = driver.destroyed
        XCTAssertFalse(sizing.attach(view: UUID(), nonce: UUID()))
        XCTAssertFalse(sizing.renew(view: view, nonce: UUID()))
        XCTAssertFalse(sizing.detach(view: UUID(), nonce: nonce))
        clock.value = 3.6; sizing.tick()
        XCTAssertEqual(sizing.state, "expired")
        let count = driver.writes.count
        driver.size = .init(width: 1000, height: 1000); oldResize?(); oldDestroyed?(); sizing.tick()
        XCTAssertEqual(driver.writes.count, count)
        XCTAssertFalse(sizing.renew(view: view, nonce: nonce))
        XCTAssertFalse(sizing.attach(view: view, nonce: nonce), "An expired attach replay must not recreate its lease")
        XCTAssertTrue(sizing.attach(view: view, nonce: UUID()))
        sizing.stop()
    }

    func testRenewalKeepsLeaseAliveAndBusyPausesAllWindowWrites() {
        let clock = Clock(), driver = Driver()
        var busy = true
        let sizing = FinalCutWorkflowWindowSizing(driver: driver, isBusy: { busy }, now: { clock.value })
        let view = UUID(), nonce = UUID()
        sizing.start(); XCTAssertTrue(sizing.attach(view: view, nonce: nonce))
        XCTAssertEqual(sizing.state, "paused"); XCTAssertEqual(driver.discovers, 0); XCTAssertTrue(driver.writes.isEmpty)
        clock.value = 3; XCTAssertTrue(sizing.renew(view: view, nonce: nonce))
        clock.value = 4; busy = false; sizing.tick()
        XCTAssertEqual(sizing.state, "fixed"); XCTAssertEqual(driver.writes.count, 1)
        busy = true; driver.size = .init(width: 900, height: 900); driver.resized?()
        clock.value = 4.5; sizing.tick()
        XCTAssertEqual(driver.writes.count, 1)
        busy = false; clock.value = 4.7; sizing.tick()
        XCTAssertEqual(driver.writes.count, 2)
        sizing.stop()
    }

    func testHostRestartOrChangedWindowNeverReceivesAnotherWrite() {
        for changedHost in [true, false] {
            let clock = Clock(), driver = Driver()
            let sizing = FinalCutWorkflowWindowSizing(driver: driver, now: { clock.value })
            sizing.start(); sizing.attach(view: UUID(), nonce: UUID())
            let count = driver.writes.count
            if changedHost { driver.identity = .init(pid: 123, launched: Date(timeIntervalSince1970: 2)) }
            else { driver.identityValid = false }
            driver.size = .init(width: 900, height: 900); driver.resized?(); clock.value = 0.2; sizing.tick()
            XCTAssertEqual(driver.writes.count, count)
            XCTAssertEqual(sizing.state, "unavailable")
            sizing.stop()
        }
    }

    func testDiscoveryIsBoundedAndDestroyedOrDetachedTargetsCannotBeReused() {
        let clock = Clock(), driver = Driver(); driver.window = nil
        let sizing = FinalCutWorkflowWindowSizing(driver: driver, now: { clock.value })
        let view = UUID(), nonce = UUID()
        sizing.start(); sizing.attach(view: view, nonce: nonce)
        for _ in 0..<20 { sizing.tick() }
        XCTAssertEqual(driver.discovers, 1)
        driver.window = Window(); clock.value = 0.7; sizing.tick()
        XCTAssertEqual(sizing.state, "fixed")
        let callback = driver.resized
        XCTAssertTrue(sizing.detach(view: view, nonce: nonce))
        driver.size = .init(width: 800, height: 800); callback?(); clock.value = 1; sizing.tick()
        XCTAssertEqual(driver.writes.count, 1)
        XCTAssertEqual(sizing.state, "inactive")
        clock.value = 1.5
        XCTAssertTrue(sizing.attach(view: view, nonce: UUID()))
        driver.destroyed?()
        XCTAssertEqual(sizing.state, "unavailable")
        sizing.stop()
    }

    func testDestroyedDuringSynchronousWriteCannotReviveFixedState() {
        let clock = Clock(), driver = Driver(); driver.destroyOnWrite = true
        let sizing = FinalCutWorkflowWindowSizing(driver: driver, now: { clock.value })
        let view = UUID(), nonce = UUID()
        sizing.start(); XCTAssertTrue(sizing.attach(view: view, nonce: nonce))
        XCTAssertEqual(driver.writes.count, 1)
        XCTAssertEqual(sizing.state, "unavailable")
        XCTAssertEqual(sizing.corrections, 0)
        XCTAssertFalse(sizing.renew(view: view, nonce: nonce))
        clock.value = 1; sizing.tick()
        XCTAssertEqual(driver.writes.count, 1)
        sizing.stop()
    }

    func testUnavailableControlWriteOrNotificationNeverPretendsFixed() {
        for failure in 0..<4 {
            let clock = Clock(), driver = Driver()
            if failure == 0 { driver.trusted = false }
            if failure == 1 { driver.settable = false }
            if failure == 2 { driver.observeCode = -25205 }
            if failure == 3 { driver.acceptWrites = false }
            let sizing = FinalCutWorkflowWindowSizing(driver: driver, now: { clock.value })
            let view = UUID(), nonce = UUID()
            sizing.start(); sizing.attach(view: view, nonce: nonce)
            for time in [0.2, 0.4, 0.6, 0.8] { clock.value = time; sizing.tick() }
            XCTAssertEqual(sizing.state, "unavailable")
            XCTAssertEqual(driver.writes.count, failure == 3 ? 3 : 0)
            XCTAssertEqual(sizing.corrections, 0)
            XCTAssertFalse(sizing.attach(view: view, nonce: nonce), "A failed lease must not restart from replayed attach packets")
            sizing.stop()
        }
    }

    func testVersionedTransportRejectsArbitrarySizesMalformedNumbersAndReplayIdentities() throws {
        let view = UUID(), nonce = UUID()
        let valid: [String: Any] = ["version": 1, "command": "attach", "view": view.uuidString, "nonce": nonce.uuidString]
        func encode(_ value: [String: Any]) throws -> String {
            String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
        }
        let object = try encode(valid)
        XCTAssertEqual(FinalCutWorkflowWindowSizing.Query.decode(object, userInfo: nil)?.view, view)
        XCTAssertNil(FinalCutWorkflowWindowSizing.Query.decode(object, userInfo: ["extra": true]))
        for (key, value) in [("version", true as Any), ("version", "1" as Any), ("version", 4_294_967_297 as Any), ("command", "resize" as Any),
                              ("view", "invalid" as Any), ("nonce", "invalid" as Any), ("width", 900 as Any)] {
            var invalid = valid; invalid[key] = value
            XCTAssertNil(FinalCutWorkflowWindowSizing.Query.decode(try encode(invalid), userInfo: nil))
        }
        XCTAssertNil(FinalCutWorkflowWindowSizing.Query.decode(String(repeating: "x", count: 2049), userInfo: nil))
    }
}
