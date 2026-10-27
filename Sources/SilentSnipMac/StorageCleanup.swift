import Darwin
import Foundation

public struct StorageCleanupReport: Sendable {
    public internal(set) var removedFiles = 0
    public internal(set) var removedBytes: Int64 = 0
    public internal(set) var preservedFiles = 0
    public internal(set) var errors = 0
    public internal(set) var cancelled = false
}

/// An explicit inventory of disposable audio, never a recursive folder purge.
/// XML, results, source media and unregistered files are not deletion candidates.
public struct StorageCleanup: Sendable {
    public let root: URL
    public let byteLimit: Int64
    public let maximumAge: TimeInterval
    private let rootWasSymlink: Bool
    private var records: URL { root.appendingPathComponent("Cache Records", isDirectory: true) }

    public init(root: URL? = nil, byteLimit: Int64 = 256 * 1_024 * 1_024,
                maximumAge: TimeInterval = 7 * 24 * 3600) {
        let requested = (root ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("Silent Snip", isDirectory: true)).standardizedFileURL
        rootWasSymlink = (try? requested.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        self.root = Self.canonicalLocation(requested)
        self.byteLimit = max(0, byteLimit)
        self.maximumAge = max(0, maximumAge)
    }

    /// Resolve existing ancestors before appending folders that have not been
    /// created yet. Foundation otherwise retains /var until the folder exists.
    static func canonicalLocation(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var result = ancestor.resolvingSymlinksInPath()
        for name in missing.reversed() { result.appendPathComponent(name, isDirectory: true) }
        return result
    }

    private struct Identity: Codable, Equatable {
        let device: UInt64, inode: UInt64, size: Int64
        let modifiedSeconds: Int64, modifiedNanoseconds: Int64
        init(_ url: URL) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_nlink == 1, info.st_uid == geteuid() else { throw Failure.unverified }
            device = UInt64(info.st_dev); inode = UInt64(info.st_ino); size = info.st_size
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        }
    }
    private struct Record: Codable {
        let version: Int
        let id: UUID
        let category: String
        let job: UUID
        let name: String
        let identity: Identity
        let sha256: String
        let created: Date
    }
    private enum Failure: Error { case unverified }

    private func safeDirectory(_ url: URL) -> Bool {
        guard !rootWasSymlink, root.resolvingSymlinksInPath() == root,
              url.resolvingSymlinksInPath() == url else { return false }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    private func audioURL(category: String, job: UUID, name: String) -> URL? {
        guard ["Temporary", "Share Inbox"].contains(category),
              !name.isEmpty, !name.contains("/"), !name.contains(":"), !name.contains("\0"),
              ["wav", "aif", "aiff", "caf"].contains((name as NSString).pathExtension.lowercased()),
              category != "Temporary" || name == "Cached-Processed-Audio.wav" else { return nil }
        let folder = root.appendingPathComponent(category, isDirectory: true)
        let directory = folder.appendingPathComponent(job.uuidString, isDirectory: true)
        guard safeDirectory(root), safeDirectory(folder), safeDirectory(directory) else { return nil }
        return directory.appendingPathComponent(name)
    }

    /// Call only for an app-created cache copy or a verified request-owned render.
    /// `expectedHash` is the hash already verified while copying the cache.
    private func location(_ url: URL) throws -> (String, UUID, String) {
        let relative = url.standardizedFileURL.pathComponents.dropFirst(root.pathComponents.count)
        guard url.path.hasPrefix(root.path + "/"), relative.count == 3,
              let category = relative.first, let job = UUID(uuidString: Array(relative)[1]),
              let name = relative.last, audioURL(category: category, job: job, name: name) == url else {
            throw Failure.unverified
        }
        return (category, job, name)
    }

    func validateDisposableLocation(_ url: URL) throws { _ = try location(url) }

    @discardableResult func register(_ url: URL, expectedHash: String? = nil, now: Date = Date()) throws -> UUID {
        let (category, job, name) = try location(url)
        let before = try Identity(url)
        let hash = try expectedHash ?? MediaContentSnapshot.contentHash(at: url)
        guard try Identity(url) == before else { throw Failure.unverified }
        if !FileManager.default.fileExists(atPath: records.path) {
            try FileManager.default.createDirectory(at: records, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        guard safeDirectory(records) else { throw Failure.unverified }
        let value = Record(version: 1, id: UUID(), category: category, job: job, name: name,
            identity: before, sha256: hash, created: now)
        try JSONEncoder().encode(value).write(to: records.appendingPathComponent(value.id.uuidString + ".json"),
            options: .withoutOverwriting)
        return value.id
    }

    @discardableResult func remove(_ id: UUID) -> StorageCleanupReport {
        sweep(manual: true, protectedURLs: [], now: Date(), only: id)
    }

    /// Run off the UI thread. Active jobs/cache files must be pinned by the caller.
    public func clean(manual: Bool = false, protectedURLs: Set<URL> = [], now: Date = Date()) -> StorageCleanupReport {
        sweep(manual: manual, protectedURLs: protectedURLs, now: now, only: nil)
    }

    private func sweep(manual: Bool, protectedURLs: Set<URL>, now: Date, only: UUID?) -> StorageCleanupReport {
        var report = StorageCleanupReport()
        guard !Task.isCancelled else { report.cancelled = true; return report }
        guard safeDirectory(root), safeDirectory(records),
              let files = try? FileManager.default.contentsOfDirectory(at: records,
                includingPropertiesForKeys: nil) else { return report }
        var entries: [(URL, Record, URL)] = []
        for file in files.prefix(10_000) where file.pathExtension == "json" {
            guard !Task.isCancelled else { report.cancelled = true; return report }
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), only == nil || only == id,
                  let size = try? Identity(file).size, size <= 16_384,
                  let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.version == 1, record.id == id,
                  let audio = audioURL(category: record.category, job: record.job, name: record.name) else { continue }
            // A completed ordinary cleanup may already have removed this audio.
            var info = stat()
            if lstat(audio.path, &info) != 0 && errno == ENOENT { _ = unlink(file.path); continue }
            entries.append((file, record, audio))
        }
        var total = entries.reduce(Int64(0)) {
            let (sum, overflow) = $0.addingReportingOverflow(max(0, $1.1.identity.size))
            return overflow ? Int64.max : sum
        }
        for (file, record, audio) in entries.sorted(by: { $0.1.created < $1.1.created }) {
            guard !Task.isCancelled else { report.cancelled = true; return report }
            let pinned = protectedURLs.contains { audio == $0 || audio.path.hasPrefix($0.path + "/") }
            guard !pinned, manual || now.timeIntervalSince(record.created) >= maximumAge || total > byteLimit else {
                report.preservedFiles += 1; continue
            }
            do {
                guard try Identity(audio) == record.identity,
                      try MediaContentSnapshot.contentHash(at: audio) == record.sha256,
                      try Identity(audio) == record.identity,
                      safeDirectory(records),
                      audioURL(category: record.category, job: record.job, name: record.name) == audio else {
                    report.preservedFiles += 1; continue
                }
                // Unlink one verified regular file. Never recursively delete a job.
                let directoryFD = open(audio.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard directoryFD >= 0 else { throw Failure.unverified }
                defer { close(directoryFD) }
                var final = stat()
                guard fstatat(directoryFD, record.name, &final, AT_SYMLINK_NOFOLLOW) == 0,
                      final.st_mode & S_IFMT == S_IFREG, final.st_nlink == 1,
                      UInt64(final.st_ino) == record.identity.inode,
                      UInt64(final.st_dev) == record.identity.device,
                      final.st_size == record.identity.size,
                      Int64(final.st_mtimespec.tv_sec) == record.identity.modifiedSeconds,
                      Int64(final.st_mtimespec.tv_nsec) == record.identity.modifiedNanoseconds else {
                    report.preservedFiles += 1; continue
                }
                guard unlinkat(directoryFD, record.name, 0) == 0 else { throw Failure.unverified }
                _ = unlink(file.path)
                report.removedFiles += 1; report.removedBytes += record.identity.size
                total -= record.identity.size
                // rmdir succeeds only if empty; XML/unknown siblings keep the job.
                _ = rmdir(audio.deletingLastPathComponent().path)
            } catch { report.errors += 1 }
        }
        return report
    }
}

/// One current and one previous event log, each at most 1 MiB.
enum BoundedShareLog {
    static let byteLimit = 1_024 * 1_024
    static func append(_ data: Data, root: URL) {
        let file = root.appendingPathComponent("events.jsonl")
        let previous = root.appendingPathComponent("events.previous.jsonl")
        guard root.resolvingSymlinksInPath() == root,
              (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
        let payload = data.count <= 65_536 ? data : Data("{\"event\":\"oversized-log-entry-omitted\"}\n".utf8)
        func safe(_ url: URL) -> Bool {
            var info = stat()
            if lstat(url.path, &info) != 0 { return errno == ENOENT }
            return info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1
        }
        guard safe(file), safe(previous) else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        if size + payload.count > byteLimit {
            guard unlink(previous.path) == 0 || errno == ENOENT else { return }
            if size <= byteLimit { guard rename(file.path, previous.path) == 0 else { return } }
            else { guard unlink(file.path) == 0 else { return } } // Discard an oversized pre-cap log.
        }
        let fd = open(file.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { return }
        try? handle.write(contentsOf: payload)
    }
}

/// Serialize disk cleanup with operations that may need cached audio. The app
/// awaits this gate before starting analysis, Apply, navigation or verification.
@MainActor public final class StorageCleanupController {
    private var task: Task<StorageCleanupReport, Never>?
    private var generation = 0
    private let isBusy: () -> Bool
    private let protectedURLs: () -> Set<URL>
    private let clearMemory: () -> Void
    var runner: @Sendable (Bool, Set<URL>) -> StorageCleanupReport
    public var isRunning: Bool { task != nil }

    public init(storage: StorageCleanup = StorageCleanup(), isBusy: @escaping () -> Bool,
                protectedURLs: @escaping () -> Set<URL>, clearMemory: @escaping () -> Void) {
        self.isBusy = isBusy; self.protectedURLs = protectedURLs; self.clearMemory = clearMemory
        runner = { manual, protected in storage.clean(manual: manual, protectedURLs: protected) }
    }

    public func waitUntilIdle() async {
        if let task {
            let token = generation
            // A new user operation takes priority over cache maintenance.
            // Hashing observes cancellation between 1 MiB reads.
            task.cancel()
            _ = await task.value
            if generation == token { self.task = nil }
        }
    }

    public func clean(manual: Bool) async -> StorageCleanupReport? {
        guard task == nil, !isBusy() else { return nil }
        if manual { clearMemory() }
        let protected = protectedURLs(), runner = runner
        generation += 1
        let token = generation
        let operation = Task.detached(priority: .utility) { runner(manual, protected) }
        task = operation
        let report = await operation.value
        if generation == token { task = nil }
        return report
    }
}
