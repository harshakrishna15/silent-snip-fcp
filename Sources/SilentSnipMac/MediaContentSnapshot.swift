import CryptoKit
import Darwin
import Foundation

/// Job-scoped content evidence. Never reuse this as a metadata-only or global cache:
/// analysis validates it after decoding, and Apply captures fresh file contents.
struct MediaContentSnapshot: Sendable, Equatable, Codable {
    let hashes: [URL: String]
    private let originalURLs: [URL]
    /// Paired with originalURLs, rather than an unordered set. Two source
    /// aliases may exchange targets while leaving every canonical hash/stamp
    /// unchanged; their original associations must remain authoritative.
    private let canonicalURLs: [URL]?
    private let stamps: [URL: FileStamp]?

    /// Every historical input protected by this receipt, including original
    /// sources that a rendered-audio result no longer references directly.
    var sourceURLs: [URL] { originalURLs }

    func covers(_ urls: [URL]) -> Bool {
        originalURLs == Array(Set(urls)).sorted { $0.absoluteString < $1.absoluteString }
    }

    /// Import receipts may additionally protect the original raw sources after
    /// a result adopts a lossless processed render. Every result reference must
    /// still have its exact original URL represented; this is not a content or
    /// canonical-path substitute for validating the whole historical snapshot.
    func containsReferences(_ urls: [URL]) -> Bool {
        Set(urls).isSubset(of: Set(originalURLs))
    }

    /// A selected-clip result references only part of the original project.
    /// Retain the captured hashes, rather than adopting new content at Apply.
    func restricting(to urls: [URL]) throws -> Self {
        let originals = Array(Set(urls)).sorted { $0.absoluteString < $1.absoluteString }
        guard Set(originals).isSubset(of: Set(originalURLs)) else { throw ProjectAnalysisError.changedRenderArtifact }
        let historical = try referenceMapping()
        var selected: [URL: String] = [:]
        var selectedCanonical: [URL] = []
        for url in originals {
            let canonical = try Self.canonical(url)
            guard let index = originalURLs.firstIndex(of: url), historical[index] == canonical,
                  let hash = hashes[canonical] else { throw ProjectAnalysisError.changedRenderArtifact }
            selected[canonical] = hash
            selectedCanonical.append(canonical)
        }
        return Self(hashes: selected, originalURLs: originals, canonicalURLs: selectedCanonical,
            stamps: stamps?.filter { selected[$0.key] != nil })
    }

    /// Legacy receipts did not store an ordered reference mapping. Identity is
    /// inferable only when every original URL was itself a canonical hash key.
    /// Historical aliases with no mapping require fresh Analyze; hashing the
    /// same canonical files again cannot prove which alias originally used each.
    private func referenceMapping() throws -> [URL] {
        if let canonicalURLs {
            guard canonicalURLs.count == originalURLs.count,
                  Set(canonicalURLs) == Set(hashes.keys) else { throw ProjectAnalysisError.changedRenderArtifact }
            return canonicalURLs
        }
        guard Set(originalURLs) == Set(hashes.keys) else { throw ProjectAnalysisError.changedRenderArtifact }
        return originalURLs
    }

    private func validateReferences(_ current: [URL]) throws {
        guard try referenceMapping() == current else { throw ProjectAnalysisError.changedRenderArtifact }
    }

    static func canonical(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw ProjectAnalysisError.invalidRenderArtifact }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Capture identities synchronously before launching concurrent host work.
    /// Metadata only detects mutation; accepting audio still requires full hashes.
    struct ReadGuard: Sendable {
        let originals: [URL]
        let canonicalURLs: [URL]
        let stamps: [URL: FileStamp]

        func validate() throws {
            guard try originals.map(MediaContentSnapshot.canonical) == canonicalURLs else {
                throw ProjectAnalysisError.changedRenderArtifact
            }
            for (url, stamp) in stamps where try FileStamp(url) != stamp {
                throw ProjectAnalysisError.changedRenderArtifact
            }
        }

        /// Eligibility to discard one COMPLETED, verified read-only XML phase.
        /// Canonical references and every raw-source stamp remain exact. The
        /// sole permitted delta is ctime on one already-bound durable render.
        func onlyRenderedCTimeChanged(_ audio: LosslessRenderedAudio) throws -> Bool {
            guard audio.scope == .projectMix, audio.mediaIdentity != nil, audio.nativeSourceSHA256 != nil,
                  audio.pcmDataSHA256 != nil, audio.formatDataSHA256 != nil,
                  originals.contains(audio.url), canonicalURLs.filter({ $0 == audio.url }).count == 1,
                  try originals.map(MediaContentSnapshot.canonical) == canonicalURLs else { return false }
            var changed = false
            for (url, old) in stamps {
                let now = try FileStamp(url)
                if url == audio.url {
                    guard old.sameIdentitySizeAndModification(as: now) else { return false }
                    changed = old != now
                } else if old != now { return false }
            }
            return changed
        }
    }

    struct FileStamp: Sendable, Equatable, Codable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int, modifiedNanoseconds: Int
        let changedSeconds: Int, changedNanoseconds: Int
        init(_ url: URL) throws {
            var value = stat()
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            guard fstat(file.fileDescriptor, &value) == 0 else { throw ProjectAnalysisError.changedRenderArtifact }
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
        }

        func sameIdentitySizeAndModification(as other: Self) -> Bool {
            device == other.device && inode == other.inode && size == other.size
                && modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
        }
    }

    static func prepareRead(_ urls: [URL]) throws -> ReadGuard {
        try Task.checkCancellation()
        let originals = Array(Set(urls)).sorted { $0.absoluteString < $1.absoluteString }
        let canonicalURLs = try originals.map(canonical)
        var stamps: [URL: FileStamp] = [:]
        for url in Set(canonicalURLs) { stamps[url] = try FileStamp(url) }
        return ReadGuard(originals: originals, canonicalURLs: canonicalURLs, stamps: stamps)
    }

    // A nonisolated async function runs hashing off the caller's MainActor.
    static func capture(_ urls: [URL],
                        hash: @Sendable (URL) throws -> String = { try contentHash(at: $0) }) async throws -> Self {
        try await capture(prepared: prepareRead(urls), hash: hash)
    }

    static func capture(prepared: ReadGuard,
                        hash: @Sendable (URL) throws -> String = { try contentHash(at: $0) }) async throws -> Self {
        try prepared.validate()
        var hashes: [URL: String] = [:]
        for url in Set(prepared.canonicalURLs).sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            hashes[url] = try hash(url)
        }
        try prepared.validate()
        return Self(hashes: hashes, originalURLs: prepared.originals,
            canonicalURLs: prepared.canonicalURLs, stamps: prepared.stamps)
    }

    func validate() async throws {
        let prepared = try Self.prepareRead(originalURLs)
        try validateReferences(prepared.canonicalURLs)
        let current = try await Self.capture(prepared: prepared)
        // Receipts from earlier releases contain hashes but no mutation stamps.
        // Keep their original full-content verification; every new capture also
        // requires unchanged file identity and change times across the render.
        guard current.hashes == hashes, current.originalURLs == originalURLs,
              stamps == nil || stamps == current.stamps else {
            throw ProjectAnalysisError.changedRenderArtifact
        }
    }

    /// A source phase can overlap its full hashes with native rendering only
    /// after the historical reference mapping and every mutation stamp match.
    /// This is preflight evidence, not authorization to accept rendered audio.
    /// Legacy receipts keep their full-content preflight before host dispatch.
    func prepareValidationRead() throws -> ReadGuard? {
        try Task.checkCancellation()
        let references = try referenceMapping()
        guard canonicalURLs != nil, let stamps else { return nil }
        let prepared = try Self.prepareRead(originalURLs)
        guard prepared.originals == originalURLs, prepared.canonicalURLs == references,
              prepared.stamps == stamps else { throw ProjectAnalysisError.changedRenderArtifact }
        try prepared.validate()
        return prepared
    }

    /// Complete the full-content half of prepareValidationRead. The same
    /// historical mapping/stamps remain pinned while hashing; a new snapshot
    /// must never adopt changed bytes or identities for this source phase.
    func validatedSnapshot(prepared: ReadGuard,
                           hash: @Sendable (URL) throws -> String = { try MediaContentSnapshot.contentHash(at: $0) }) async throws -> Self {
        try Task.checkCancellation()
        guard canonicalURLs != nil, let stamps,
              prepared.originals == originalURLs, prepared.stamps == stamps else {
            throw ProjectAnalysisError.changedRenderArtifact
        }
        try validateReferences(prepared.canonicalURLs)
        let current = try await Self.capture(prepared: prepared, hash: hash)
        guard current.hashes == hashes, current.originalURLs == originalURLs,
              current.canonicalURLs == canonicalURLs, current.stamps == stamps else {
            throw ProjectAnalysisError.changedRenderArtifact
        }
        return current
    }

    /// Final Cut can update xattrs on newly imported durable PCM, changing only
    /// ctime. Historical bytes and all identity/size/mtime evidence remain
    /// authoritative. The returned snapshot is CURRENT-PHASE evidence only;
    /// callers must keep the original snapshot in their persistent receipt.
    func validatedForImport(renderedAudio: LosslessRenderedAudio?) async throws -> Self {
        let phaseGuard = try Self.prepareRead(originalURLs)
        try validateReferences(phaseGuard.canonicalURLs)
        let current = try await Self.capture(prepared: phaseGuard)
        guard current.hashes == hashes, current.originalURLs == originalURLs else {
            throw ProjectAnalysisError.changedRenderArtifact
        }
        guard let stamps else {
            // Existing hash-only receipts retain their old strict-content
            // behavior, but cannot prove the identity/mtime side of a new PCM
            // import exception.
            guard renderedAudio == nil else { throw ProjectAnalysisError.changedRenderArtifact }
            try phaseGuard.validate()
            return current
        }
        if stamps == current.stamps {
            if let renderedAudio { try renderedAudio.validate() }
            try phaseGuard.validate()
            return current
        }
        guard let renderedAudio, renderedAudio.scope == .projectMix,
              renderedAudio.mediaIdentity != nil, renderedAudio.nativeSourceSHA256 != nil,
              renderedAudio.pcmDataSHA256 != nil, renderedAudio.formatDataSHA256 != nil,
              originalURLs.contains(renderedAudio.url),
              try Self.canonical(renderedAudio.url) == renderedAudio.url,
              hashes[renderedAudio.url] == renderedAudio.sha256,
              let currentStamps = current.stamps, Set(stamps.keys) == Set(currentStamps.keys) else {
            throw ProjectAnalysisError.changedRenderArtifact
        }
        for (url, historical) in stamps {
            guard let now = currentStamps[url] else { throw ProjectAnalysisError.changedRenderArtifact }
            if url == renderedAudio.url {
                guard historical.sameIdentitySizeAndModification(as: now) else {
                    throw ProjectAnalysisError.changedRenderArtifact
                }
            } else if historical != now {
                throw ProjectAnalysisError.changedRenderArtifact
            }
        }
        // Independently prove encoded bytes, PCM payload, format, and the new
        // media identity. A missing legacy proof never grants this exception.
        try renderedAudio.validate()
        try phaseGuard.validate()
        return current
    }

    static func contentHash(at url: URL) throws -> String {
        try Task.checkCancellation()
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
