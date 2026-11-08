import Foundation

/// A missing advertised shortcut permits menu navigation before any input.
/// A thrown or uncertain shortcut never falls through to a second invocation.
@MainActor enum BulkNativeCommandInvocation {
    @discardableResult static func perform(shortcut: () throws -> Bool,
                                           menu: () async throws -> Void) async throws -> Bool {
        try Task.checkCancellation()
        if try shortcut() { return true }
        try Task.checkCancellation()
        try await menu()
        return false
    }
}
