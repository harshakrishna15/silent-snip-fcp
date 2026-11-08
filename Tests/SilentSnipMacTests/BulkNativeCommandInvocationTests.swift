import XCTest
@testable import SilentSnipMac

@MainActor final class BulkNativeCommandInvocationTests: XCTestCase {
    private struct UncertainDispatch: Error {}

    func testAdvertisedShortcutInvokesOnceWithoutOpeningMenu() async throws {
        var shortcuts = 0, menus = 0
        let usedShortcut = try await BulkNativeCommandInvocation.perform(shortcut: { shortcuts += 1; return true },
            menu: { menus += 1 })
        XCTAssertTrue(usedShortcut)
        XCTAssertEqual(shortcuts, 1)
        XCTAssertEqual(menus, 0)
    }

    func testNoAssignedShortcutFallsBackToOneMenuInvocation() async throws {
        var shortcuts = 0, menus = 0
        let usedShortcut = try await BulkNativeCommandInvocation.perform(shortcut: { shortcuts += 1; return false },
            menu: { menus += 1 })
        XCTAssertFalse(usedShortcut)
        XCTAssertEqual(shortcuts, 1)
        XCTAssertEqual(menus, 1)
    }

    func testShortcutErrorCannotReplayTheCommandThroughMenu() async {
        var shortcuts = 0, menus = 0
        do {
            _ = try await BulkNativeCommandInvocation.perform(shortcut: { shortcuts += 1; throw UncertainDispatch() },
                menu: { menus += 1 })
            XCTFail("An uncertain shortcut must fail without another command")
        } catch is UncertainDispatch { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(shortcuts, 1)
        XCTAssertEqual(menus, 0)
    }

    func testCancellationBetweenUnassignedShortcutAndFallbackSendsNoInput() async {
        var menus = 0
        let task = Task { @MainActor in
            try await BulkNativeCommandInvocation.perform(shortcut: {
                withUnsafeCurrentTask { $0?.cancel() }
                return false
            }, menu: { menus += 1 })
        }
        do { _ = try await task.value; XCTFail("Cancellation must escape") }
        catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(menus, 0)
    }
}
