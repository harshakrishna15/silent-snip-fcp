import Foundation

/// One Apply source phase. Modern historical evidence pins identities before
/// dispatch and joins full content validation with the native mix render.
/// Legacy direct-source receipts retain their full-hash preflight. No failed
/// or uncertain host action is repeated by either route.
enum ApplyAudioRenderCapture {
    struct Result<Receipt> {
        let receipt: Receipt
        let readGuard: MediaContentSnapshot.ReadGuard
        let overlappedSourceValidation: Bool
        fileprivate let sourceMedia: MediaContentSnapshot

        /// Fresh delivered XML must reference exactly the protected sources.
        /// A matching hash for some other URL cannot authorize substitution.
        func validateSourceReferences(_ urls: [URL]) throws {
            guard sourceMedia.covers(urls) else { throw ProjectAnalysisError.changedRenderArtifact }
            try readGuard.validate()
        }
    }

    @MainActor static func perform<Receipt>(sourceMedia: MediaContentSnapshot,
        hash: @escaping @Sendable (URL) throws -> String = { try MediaContentSnapshot.contentHash(at: $0) },
        render: () async throws -> Receipt,
        cleanup: (Receipt) -> Void) async throws -> Result<Receipt> {
        try Task.checkCancellation()
        if let prepared = try sourceMedia.prepareValidationRead() {
            let combined = try await DirectAudioRenderCapture.perform(prepared: prepared,
                captureSources: { try await sourceMedia.validatedSnapshot(prepared: $0, hash: hash) },
                render: render, cleanup: cleanup)
            return Result(receipt: combined.receipt, readGuard: prepared,
                overlappedSourceValidation: true, sourceMedia: sourceMedia)
        }

        // Missing historical mapping/stamps cannot silently authorize overlap.
        // validate() also rejects unprovable legacy aliases before any input.
        try await sourceMedia.validate()
        let prepared = try MediaContentSnapshot.prepareRead(sourceMedia.sourceURLs)
        try Task.checkCancellation()
        let receipt = try await render()
        var transferred = false
        defer { if !transferred { cleanup(receipt) } }
        try Task.checkCancellation()
        try prepared.validate()
        transferred = true
        return Result(receipt: receipt, readGuard: prepared,
            overlappedSourceValidation: false, sourceMedia: sourceMedia)
    }
}
