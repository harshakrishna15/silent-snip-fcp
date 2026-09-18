import CryptoKit
import Foundation

/// Job-scoped content evidence. Never reuse this as a metadata-only or global cache:
/// analysis validates it after decoding, and Apply captures fresh file contents.
struct MediaContentSnapshot: Sendable, Equatable {
    let hashes: [URL: String]
    private let originalURLs: [URL]

    static func canonical(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw ProjectAnalysisError.invalidRenderArtifact }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    // A nonisolated async function runs hashing off the caller's MainActor.
    static func capture(_ urls: [URL],
                        hash: @Sendable (URL) throws -> String = { try contentHash(at: $0) }) async throws -> Self {
        let originals = Array(Set(urls)).sorted { $0.absoluteString < $1.absoluteString }
        let unique = try Set(originals.map(canonical)).sorted { $0.path < $1.path }
        var hashes: [URL: String] = [:]
        for url in unique {
            try Task.checkCancellation()
            hashes[url] = try hash(url)
        }
        return Self(hashes: hashes, originalURLs: originals)
    }

    func validate() async throws {
        guard try await Self.capture(originalURLs) == self else {
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
