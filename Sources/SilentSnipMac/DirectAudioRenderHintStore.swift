import Darwin
import Foundation

/// Bounded routing records across helper launches. They contain no audio,
/// content hashes, effects, or permission to accept a render. Every use still
/// hashes current sources and validates the newly delivered project XML.
struct DirectAudioRenderHintStore: Sendable {
    static let fileName = "Analysis Routing Hint.json"
    static let stagingFileName = ".Analysis Routing Hints.v3.tmp"
    private static let legacyStagingFileName = ".Analysis Routing Hint.tmp"
    static let maximumBytes = 65_536
    static let maximumHints = 8
    let root: URL

    private struct Record: Codable {
        let version: Int
        let hints: [DirectAudioRenderHint]
    }

    private struct LegacyRecord: Decodable {
        let version: Int
        let hint: DirectAudioRenderHint
    }

    init(root: URL? = nil) {
        self.root = (root ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("Silent Snip", isDirectory: true)).standardizedFileURL
    }

    /// Consume only the current selection's hint before dispatch. Unrelated
    /// selections remain available, while a failed route cannot replay itself.
    func consume(matching selection: FinalCutSelectionSnapshot,
                 workflowOrigin: WorkflowReviewOrigin? = nil) async -> DirectAudioRenderHint? {
        withDirectory(create: false) { directory in
            guard let file = openRegularFile(directory: directory) else { return nil }
            defer { close(file) }
            var previous = stat()
            guard !Task.isCancelled, fstat(file, &previous) == 0 else { return nil }
            guard let hints = readHints(file, identity: previous) else {
                removeIfUnchanged(directory: directory, identity: previous)
                return nil
            }
            let valid = hints.filter(\.isValidRoutingHint)
            func matches(_ hint: DirectAudioRenderHint) -> Bool {
                hint.matches(selection, workflowOrigin: workflowOrigin)
            }
            let hint = valid.first(where: matches)
            let remaining = valid.filter { !matches($0) }
            if remaining.count != hints.count {
                // A hint is usable only after its removal succeeds. Remove
                // any duplicate match as well so it cannot replay the route.
                if remaining.isEmpty {
                    guard removeIfUnchanged(directory: directory, identity: previous) else { return nil }
                } else {
                    guard let data = encode(remaining),
                          write(data, directory: directory, previous: previous) else { return nil }
                }
            }
            guard let hint, hint.sourceByteCount() != nil else { return nil }
            return hint
        }
    }

    @discardableResult func save(_ hint: DirectAudioRenderHint) async -> Bool {
        guard !Task.isCancelled, hint.isValidRoutingHint,
              hint.sourceByteCount() != nil else { return false }
        // Duplicate raw-source references carry no routing information.
        let bounded = DirectAudioRenderHint(selection: hint.selection,
            sourceURLs: Array(Set(hint.sourceURLs)).sorted { $0.absoluteString < $1.absoluteString },
            scope: hint.scope, workflowIdentity: hint.workflowIdentity)
        return withDirectory(create: true) { directory in
            var previous: stat?
            var hints: [DirectAudioRenderHint] = []
            if let file = openRegularFile(directory: directory) {
                defer { close(file) }
                var info = stat()
                guard fstat(file, &info) == 0 else { return false }
                previous = info
                hints = readHints(file, identity: info) ?? []
            }
            hints.removeAll { $0.selection == bounded.selection && $0.workflowIdentity == bounded.workflowIdentity }
            hints.insert(bounded, at: 0)
            if hints.count > Self.maximumHints { hints.removeLast() }
            while !hints.isEmpty {
                if let data = encode(hints) { return write(data, directory: directory, previous: previous) }
                hints.removeLast()
            }
            return false
        } ?? false
    }

    /// Clear Cached Audio also removes this exact optional routing file.
    /// Original media, rendered audio, results and receipts are never inputs.
    func clear() async {
        _ = withDirectory(create: false) { directory -> Bool? in
            for name in [Self.fileName, Self.stagingFileName, Self.legacyStagingFileName] {
                _ = removeRegularFile(directory: directory, name: name)
            }
            return true
        }
    }

    private func readHints(_ file: Int32, identity: stat) -> [DirectAudioRenderHint]? {
        guard identity.st_size > 0, identity.st_size <= Self.maximumBytes else { return nil }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        var after = stat()
        guard let data = try? handle.read(upToCount: Self.maximumBytes + 1), data.count == identity.st_size,
              fstat(file, &after) == 0, sameFileAndContents(identity, after) else { return nil }
        let decoder = JSONDecoder()
        if let record = try? decoder.decode(Record.self, from: data), record.version == 3,
           !record.hints.isEmpty, record.hints.count <= Self.maximumHints {
            return record.hints
        }
        guard let legacy = try? decoder.decode(LegacyRecord.self, from: data),
              legacy.version == 2 || (legacy.version == 1 && legacy.hint.workflowIdentity == nil) else { return nil }
        return [legacy.hint]
    }

    private func encode(_ hints: [DirectAudioRenderHint]) -> Data? {
        guard let data = try? JSONEncoder().encode(Record(version: 3, hints: hints)),
              data.count <= Self.maximumBytes else { return nil }
        return data
    }

    private func write(_ data: Data, directory: Int32, previous: stat?) -> Bool {
        // Only writers holding the directory lock use this staging name, so an
        // exact owned file left here can be retired before one exclusive retry.
        let temporary = Self.stagingFileName
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW
        var file = openat(directory, temporary, flags, 0o600)
        if file < 0, errno == EEXIST, removeRegularFile(directory: directory, name: temporary) {
            file = openat(directory, temporary, flags, 0o600)
        }
        guard file >= 0 else { return false }
        defer {
            var info = stat()
            if fstat(file, &info) == 0 { removeIfUnchanged(directory: directory, identity: info, name: temporary) }
            close(file)
        }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        do { try handle.write(contentsOf: data) } catch { return false }
        var info = stat()
        guard !Task.isCancelled, fstat(file, &info) == 0, regularOwnedFile(info), info.st_size == data.count,
              matchesFile(directory: directory, identity: info, name: temporary),
              matchesFile(directory: directory, identity: previous) else { return false }
        return renameat(directory, temporary, directory, Self.fileName) == 0
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
        guard fstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
              flock(directory, LOCK_EX | LOCK_NB) == 0 else { return nil }
        // Serialize read/modify/write against another helper process or a cache
        // clear. A busy optional cache is a miss, so it cannot delay Analyze.
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

    private func removeRegularFile(directory: Int32, name: String) -> Bool {
        guard let file = openRegularFile(directory: directory, name: name) else { return false }
        defer { close(file) }
        var info = stat()
        return fstat(file, &info) == 0 && removeIfUnchanged(directory: directory, identity: info, name: name)
    }

    private func sameFileAndContents(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private func matchesFile(directory: Int32, identity: stat?, name: String = Self.fileName) -> Bool {
        var current = stat()
        if fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) != 0 { return errno == ENOENT && identity == nil }
        guard let identity, regularOwnedFile(current) else { return false }
        return sameFileAndContents(identity, current)
    }

    @discardableResult private func removeIfUnchanged(directory: Int32, identity: stat, name: String = Self.fileName) -> Bool {
        matchesFile(directory: directory, identity: identity, name: name) && unlinkat(directory, name, 0) == 0
    }
}
