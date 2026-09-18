import Foundation

/// Avoid host input when the full timeline is already selected for sharing.
/// An unreadable selection must throw, never masquerade as an empty selection.
@MainActor enum FinalCutRangePreparation {
    static func clearIfNeeded(hasRanges: () throws -> Bool,
                              clear: () async throws -> Void,
                              verifyCleared: () async throws -> Void) async throws {
        guard try hasRanges() else { return }
        try await clear()
        // A command may have been delivered even if verification fails. Never retry.
        try await verifyCleared()
    }
}
