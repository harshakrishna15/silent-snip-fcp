import Foundation

/// Avoid changing focus only when the exact pinned workspace already owns it.
/// This retains no state: application ownership is checked on both sides of
/// the fresh AX window read so a stale window snapshot cannot authorize a skip.
enum FinalCutActivationReadiness {
    struct ApplicationState {
        let active: Bool
        let foregroundPID: Int32?
    }

    static func alreadyFocused<Element>(hostPID: Int32, mainWindow: Element,
        readApplication: () -> ApplicationState,
        readWindows: () -> (focused: Element?, main: Element?),
        equals: (Element, Element) -> Bool) -> Bool {
        func owned(_ state: ApplicationState) -> Bool {
            hostPID > 0 && state.active && state.foregroundPID == hostPID
        }
        guard owned(readApplication()) else { return false }
        let windows = readWindows()
        guard let focused = windows.focused, let main = windows.main,
              equals(focused, mainWindow), equals(main, mainWindow) else { return false }
        return owned(readApplication())
    }
}
