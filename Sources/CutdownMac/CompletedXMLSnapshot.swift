import Darwin
import Foundation

/// A closed producer plus a complete, unchanged document can finish XML-only
/// delivery without a guessed stability delay. Never used for audio renders.
struct CompletedXMLSnapshot: Sendable {
    enum OpenState: Sendable { case exclusive, inUse, unavailable }
    enum Observation: Sendable { case snapshot(CompletedXMLSnapshot), inUse, unavailable, incomplete }
    struct Identity: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let seconds: Int64
        let nanoseconds: Int64
        init?(_ info: stat) {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  info.st_uid == geteuid(), info.st_size > 0 else { return nil }
            device = info.st_dev; inode = info.st_ino; size = info.st_size
            seconds = Int64(info.st_mtimespec.tv_sec); nanoseconds = Int64(info.st_mtimespec.tv_nsec)
        }
    }
    let data: Data
    let identity: Identity

    static func openState(_ fd: Int32) -> OpenState {
        // XNU FSIOC_FD_ONLY_OPEN_ONCE = _IOWR('A', 21, uint32_t).
        // The SDK omits this constant. Errors preserve the legacy fallback.
        // https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/fsctl.h
        var value: UInt32 = 0
        if ffsctl(fd, 0xC0044115, &value, 0) == 0 { return .exclusive }
        return errno == EBUSY ? .inUse : .unavailable
    }

    static func read(_ url: URL, probe: (Int32) -> OpenState = openState,
                     validate: (Data) -> Bool) -> Observation {
        guard !Task.isCancelled, url.isFileURL,
              url.standardizedFileURL.resolvingSymlinksInPath() == url else { return .incomplete }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .incomplete }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, let identity = Identity(before), identity.size <= 128 * 1_024 * 1_024 else {
            return .unavailable
        }
        switch probe(fd) {
        case .inUse: return .inUse
        case .unavailable: return .unavailable
        case .exclusive: break
        }
        guard let data = try? handle.readToEnd(), data.count == identity.size, !Task.isCancelled,
              validate(data) else { return .incomplete }
        var after = stat()
        guard fstat(fd, &after) == 0, Identity(after) == identity else { return .incomplete }
        switch probe(fd) {
        case .inUse: return .inUse
        case .unavailable: return .unavailable
        case .exclusive: break
        }
        let snapshot = Self(data: data, identity: identity)
        return snapshot.isCurrent(at: url) ? .snapshot(snapshot) : .incomplete
    }

    func isCurrent(at url: URL) -> Bool {
        var info = stat()
        return url.standardizedFileURL.resolvingSymlinksInPath() == url &&
            lstat(url.path, &info) == 0 && Identity(info) == identity
    }
}
