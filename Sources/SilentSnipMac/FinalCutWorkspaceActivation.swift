import Foundation

/// Request focus on the exact pinned workspace once. Some native floating
/// windows ignore AXMain/AXFocused writes; use only the workspace's advertised
/// Raise action, after fresh authorization. This never dispatches an edit or
/// repeats the Share command that caused the focus handoff.
enum FinalCutWorkspaceActivation {
    @discardableResult static func pin(setAttributes: () -> Void, isFocused: () -> Bool,
                                      supportsRaise: () -> Bool, authorizeRaise: () throws -> Void,
                                      raise: () throws -> Void) rethrows -> Bool {
        setAttributes()
        guard !isFocused(), supportsRaise() else { return false }
        try authorizeRaise()
        try raise()
        return true
    }
}
