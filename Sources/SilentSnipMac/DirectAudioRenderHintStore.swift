import Darwin
import Foundation

/// One small, disposable routing record across helper launches. It contains no
/// audio, content hashes, effects, or permission to accept a render. Every use
/// still hashes current sources and validates the newly delivered project XML.
struct DirectAudioRenderHintStore: Sendable {
    static let fileName = "Analysis Routing Hint.json"
    private static let temporaryName = ".Analysis Routing Hint.tmp"
    static let maximumBytes = 65_536
    let root: URL

    private struct Record: Codable {
        let version: Int
        let hint: DirectAudioRenderHint
    }

    init(root: URL? = nil) {
        self.root = (root ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("Silent Snip", isDirectory: true)).standardizedFileURL
    }

    /// Consume before capture so a failed or stale speculative route cannot
    /// recur indefinitely. A successful eligible Analyze writes a new record.
    /// Reading/deleting this optional cache never starts a host operation.
    func consume() async -> DirectAudioRenderHint? {
        withDirectory(create: false) { directory in
            guard let file = openRegularFile(directory: directory) else { return nil }
            defer { close(file) }
            var before = stat()
            guard fstat(file, &before) == 0 else { return nil }
            // Remove only the exact regular cache file that was opened, even
            // when it is corrupt/oversized. Never follow or remove a substitute.
            var removed = false
            defer { if !removed { removeIfUnchanged(directory: directory, identity: before) } }
            guard before.st_size > 0, before.st_size <= Self.maximumBytes else { return nil }
            let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
            guard let data = try? handle.read(upToCount: Self.maximumBytes + 1),
                  data.count == before.st_size else { return nil }
            var after = stat()
            guard fstat(file, &after) == 0, sameFileAndContents(before, after),
                  let record = try? JSONDecoder().decode(Record.self, from: data), record.version == 1,
                  record.hint.isValidRoutingHint,
                  record.hint.sourceByteCount() != nil else { return nil }
            // Failure to unlink must be an ordinary miss. Otherwise a readable
            // but immutable/read-only record could retry a failed route on
            // every launch, violating the consume-once boundary.
            guard removeIfUnchanged(directory: directory, identity: before) else { return nil }
            removed = true
            return record.hint
        }
    }

    @discardableResult func save(_ hint: DirectAudioRenderHint) async -> Bool {
        guard !Task.isCancelled, hint.isValidRoutingHint,
              hint.sourceByteCount() != nil else { return false }
        // Duplicate raw-source references carry no routing information.
        let bounded = DirectAudioRenderHint(selection: hint.selection,
            sourceURLs: Array(Set(hint.sourceURLs)).sorted { $0.absoluteString < $1.absoluteString }, scope: hint.scope)
        guard let data = try? JSONEncoder().encode(Record(version: 1, hint: bounded)),
              data.count <= Self.maximumBytes else { return false }
        return withDirectory(create: true) { directory in
            guard safeDestination(directory: directory) else { return false }
            // A fixed O_EXCL staging name bounds crash leftovers to one file.
            // A prior incomplete staging file disables storage until the user
            // clears the cache; it never authorizes overwriting another file.
            let temporary = Self.temporaryName
            let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard file >= 0 else { return false }
            defer { close(file); _ = unlinkat(directory, temporary, 0) }
            let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
            do { try handle.write(contentsOf: data) } catch { return false }
            var info = stat()
            guard !Task.isCancelled, fstat(file, &info) == 0, regularOwnedFile(info),
                  info.st_size == data.count, safeDestination(directory: directory) else { return false }
            return renameat(directory, temporary, directory, Self.fileName) == 0
        } ?? false
    }

    /// Clear Cached Audio also removes this exact optional routing record.
    /// Original media, rendered audio, results and receipts are never inputs.
    func clear() async {
        _ = withDirectory(create: false) { directory -> Bool? in
            for name in [Self.fileName, Self.temporaryName] {
                guard let file = openRegularFile(directory: directory, name: name) else { continue }
                var info = stat()
                if fstat(file, &info) == 0 { _ = removeIfUnchanged(directory: directory, identity: info, name: name) }
                close(file)
            }
            return true
        }
    }

    private func withDirectory<T>(create: Bool, _ body: (Int32) -> T?) -> T? {
        guard root.isFileURL, (root.host == nil || root.host == ""), root.query == nil, root.fragment == nil,
              StorageCleanup.canonicalLocation(root) == root else { return nil }
        if create {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            } catch { return nil }
        }
        guard root.resolvingSymlinksInPath() == root else { return nil }
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { return nil }
        defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else { return nil }
        return body(directory)
    }

    private func regularOwnedFile(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 && info.st_uid == geteuid()
    }

    private func openRegularFile(directory: Int32, name: String = Self.fileName) -> Int32? {
        // O_NONBLOCK keeps an unexpected FIFO/device from stalling Analyze.
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { return nil }
        var info = stat()
        guard fstat(file, &info) == 0, regularOwnedFile(info) else { close(file); return nil }
        return file
    }

    private func safeDestination(directory: Int32) -> Bool {
        var info = stat()
        if fstatat(directory, Self.fileName, &info, AT_SYMLINK_NOFOLLOW) != 0 { return errno == ENOENT }
        return regularOwnedFile(info)
    }

    private func sameFileAndContents(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    @discardableResult private func removeIfUnchanged(directory: Int32, identity: stat, name: String = Self.fileName) -> Bool {
        var current = stat()
        guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              regularOwnedFile(current), sameFileAndContents(identity, current) else { return false }
        return unlinkat(directory, name, 0) == 0
    }
}
