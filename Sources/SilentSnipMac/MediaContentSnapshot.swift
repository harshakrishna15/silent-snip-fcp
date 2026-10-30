import CryptoKit
import Darwin
import Foundation

/// Job-scoped content evidence. Never reuse this as a metadata-only or global cache:
/// analysis validates it after decoding, and Apply captures fresh file contents.
struct MediaContentSnapshot: Sendable, Equatable, Codable {
    let hashes: [URL: String]
    private let originalURLs: [URL]
    private let stamps: [URL: FileStamp]?

    func covers(_ urls: [URL]) -> Bool {
        originalURLs == Array(Set(urls)).sorted { $0.absoluteString < $1.absoluteString }
    }

    /// A selected-clip result references only part of the original project.
    /// Retain the captured hashes, rather than adopting new content at Apply.
    func restricting(to urls: [URL]) throws -> Self {
        let originals = Array(Set(urls)).sorted { $0.absoluteString < $1.absoluteString }
        guard Set(originals).isSubset(of: Set(originalURLs)) else { throw ProjectAnalysisError.changedRenderArtifact }
        var selected: [URL: String] = [:]
        for url in originals {
            let canonical = try Self.canonical(url)
            guard let hash = hashes[canonical] else { throw ProjectAnalysisError.changedRenderArtifact }
            selected[canonical] = hash
        }
        return Self(hashes: selected, originalURLs: originals, stamps: stamps?.filter { selected[$0.key] != nil })
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
        return Self(hashes: hashes, originalURLs: prepared.originals, stamps: prepared.stamps)
    }

    func validate() async throws {
        let current = try await Self.capture(originalURLs)
        // Receipts from earlier releases contain hashes but no mutation stamps.
        // Keep their original full-content verification; every new capture also
        // requires unchanged file identity and change times across the render.
        guard current.hashes == hashes, current.originalURLs == originalURLs,
              stamps == nil || stamps == current.stamps else {
            throw ProjectAnalysisError.changedRenderArtifact
        }
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
