import Foundation

/// Return only the helper's own foreground handoff before host input. A foreign
/// foreground receives no activation request. This gate sends no operation input;
/// a successful return always requires the caller's unchanged strict focus check.
@MainActor public enum FinalCutOwnedInputFocus {
    public static func prepare(ownsForeground: () -> Bool,
                               restore: () async throws -> Void,
                               assertFocused: () throws -> Void) async throws {
        try Task.checkCancellation()
        if ownsForeground() { try await restore() }
        try Task.checkCancellation()
        try assertFocused()
        try Task.checkCancellation()
    }
}
