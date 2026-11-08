import ApplicationServices
import Darwin
import Foundation

enum DirectShareAXError: LocalizedError {
    case preflight(String), uncertain(String)
    var errorDescription: String? {
        switch self {
        case .preflight(let detail): return "Direct Share stopped before dispatch: \(detail)"
        case .uncertain(let detail): return "Direct Share dispatched once but did not prove completion: \(detail) No alternate invocation was sent."
        }
    }
}

/// The caller declares the operation, rather than inferring authority from a
/// project name or a retained Workflow presentation. Analyze and Apply may
/// use the direct route only while still in their original pinned project.
/// Result verification and isolated projects keep ordinary invocation.
enum DirectShareAXPurpose: Equatable {
    case ordinary, analyze, apply, verification
}

enum DirectShareAXMode: String {
    case diagnostic, production
}

struct DirectShareAXConfiguration: Codable, Equatable {
    static let flagName = "EnableDirectShareAX"
    static let maximumBytes = 16_384
    let libraryURL: URL
    let projectUID: String
    let projectName: String

    static func production(origin: WorkflowReviewOrigin?, purpose: DirectShareAXPurpose,
                           projectName: String) -> Self? {
        guard purpose == .analyze || purpose == .apply,
              let origin, projectName == origin.projectName else { return nil }
        let configuration = Self(libraryURL: origin.libraryURL, projectUID: origin.projectUID,
            projectName: origin.projectName)
        do { try configuration.verify(origin) }
        catch { return nil }
        return configuration
    }

    func verify(_ origin: WorkflowReviewOrigin?) throws {
        guard let origin,
              libraryURL.isFileURL, libraryURL.host == nil || libraryURL.host == "",
              libraryURL.query == nil, libraryURL.fragment == nil, libraryURL.user == nil,
              libraryURL.password == nil, libraryURL.port == nil,
              libraryURL.pathExtension.lowercased() == "fcpbundle",
              libraryURL.standardizedFileURL == libraryURL, libraryURL.resolvingSymlinksInPath() == libraryURL,
              origin.libraryURL.standardizedFileURL == origin.libraryURL,
              origin.libraryURL.resolvingSymlinksInPath().standardizedFileURL.path == origin.libraryURL.path,
              libraryURL.path == origin.libraryURL.path,
              projectUID == origin.projectUID, projectName == origin.projectName,
              !projectUID.isEmpty, projectUID.utf8.count <= 4_096,
              !projectName.isEmpty, projectName.utf8.count <= 4_096 else {
            throw DirectShareAXError.preflight("The opt-in pin does not match this authorized Workflow library and project.")
        }
    }

    static func decode(_ data: Data, origin: WorkflowReviewOrigin?) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else { throw DirectShareAXError.preflight("The opt-in JSON is empty or too large.") }
        let configuration: Self
        do { configuration = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw DirectShareAXError.preflight("The opt-in JSON is invalid.") }
        try configuration.verify(origin)
        return configuration
    }

    static func load(directory: URL, origin: WorkflowReviewOrigin?) throws -> Self? {
        let url = directory.appendingPathComponent(flagName)
        var observed = stat()
        guard lstat(url.path, &observed) == 0 else {
            if errno == ENOENT { return nil }
            throw DirectShareAXError.preflight("The opt-in flag could not be inspected.")
        }
        guard directory.isFileURL, directory.standardizedFileURL == directory,
              directory.resolvingSymlinksInPath() == directory else { throw DirectShareAXError.preflight("The Integration directory must be canonical.") }
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard folder >= 0 else { throw DirectShareAXError.preflight("The Integration directory could not be opened.") }
        defer { close(folder) }
        var folderInfo = stat()
        guard fstat(folder, &folderInfo) == 0, folderInfo.st_uid == geteuid() else { throw DirectShareAXError.preflight("The Integration directory is not owned by this user.") }
        let file = openat(folder, flagName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw DirectShareAXError.preflight("The opt-in flag is not a readable regular file.") }
        defer { close(file) }
        var before = stat()
        guard fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_dev == observed.st_dev, before.st_ino == observed.st_ino,
              before.st_size > 0, before.st_size <= maximumBytes else { throw DirectShareAXError.preflight("The opt-in flag is not a bounded owned regular file.") }
        let data = try FileHandle(fileDescriptor: file, closeOnDealloc: false).read(upToCount: maximumBytes + 1) ?? Data()
        var after = stat()
        guard fstat(file, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, data.count == before.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw DirectShareAXError.preflight("The opt-in flag changed while reading.") }
        return try decode(data, origin: origin)
    }
}

/// A request-local ledger. The attempt is recorded before calling native AX;
/// neither an AX error nor a timeout grants a second invocation. Production
/// keeps its ledger in memory and emits counters with the operation's timing;
/// the explicit diagnostic additionally persists each state transition.
@MainActor final class DirectShareAXProbe {
    struct Report: Encodable {
        let request: UUID
        let phase: String
        var mode = DirectShareAXMode.diagnostic.rawValue
        var configurationAccepted = false
        var uniqueMatchedPath = false
        var advertisedActions: [String] = []
        var selectedAction: String?
        var attemptCount = 0
        var axResult: Int32?
        var observedOwnedPanel = false
        var foregroundBefore: Int32?
        var foregroundAfter: Int32?
        var projectBefore: String?
        var projectAfter: String?
        var menuBarTrackingStateAvailable = false
        var libraryURLPin: String?
        var projectUIDPin: String?
        var outcome = "preflight"
        var error: String?
        var preflightFallbackReason: String?
        var elapsedSeconds = 0.0
        var fallbackCount = 0
    }
    let configuration: DirectShareAXConfiguration
    let mode: DirectShareAXMode
    private let directory: URL?
    private let started = ProcessInfo.processInfo.systemUptime
    private(set) var report: Report

    init(configuration: DirectShareAXConfiguration, directory: URL? = nil, request: UUID, phase: String,
         mode: DirectShareAXMode = .diagnostic) {
        self.configuration = configuration; self.directory = directory; self.mode = mode
        report = Report(request: request, phase: phase, mode: mode.rawValue, configurationAccepted: true)
        report.libraryURLPin = String(configuration.libraryURL.absoluteString.prefix(4_096))
        report.projectUIDPin = String(configuration.projectUID.prefix(4_096))
        save()
    }

    func update(_ body: (inout Report) -> Void) { body(&report); save() }

    func dispatch(action: String, perform: () -> Int32) throws {
        try Task.checkCancellation()
        guard report.attemptCount == 0 else { throw DirectShareAXError.uncertain("A second action was rejected.") }
        guard report.fallbackCount == 0 else { throw DirectShareAXError.preflight("Ordinary invocation was already selected.") }
        let allowed = mode == .production ? [kAXPressAction] : [kAXPressAction, kAXPickAction]
        guard allowed.contains(action) else { throw DirectShareAXError.preflight("The advertised action is not permitted for this Share route.") }
        report.attemptCount = 1; report.selectedAction = action; report.outcome = "dispatched"
        guard save() else {
            report.attemptCount = 0
            throw DirectShareAXError.preflight("The one-attempt diagnostic ledger could not be saved. No AX call was sent.")
        }
        // The unknown native outcome is persisted before entering the AX call.
        report.axResult = perform()
        save()
    }

    /// A preflight miss can choose ordinary input before any AX attempt. The
    /// ledger consumes that choice as well, so neither route can later issue
    /// an alternate action for this invocation. Cancellation never falls back.
    @discardableResult func selectOrdinaryFallback(for error: Error) -> Bool {
        guard mode == .production, report.attemptCount == 0, report.fallbackCount == 0,
              !(error is CancellationError), !Task.isCancelled else { return false }
        report.fallbackCount = 1
        report.outcome = "ordinaryBeforeDispatch"
        report.error = String(error.localizedDescription.prefix(2_048))
        report.preflightFallbackReason = report.error
        save()
        return true
    }

    func finish(error: Error? = nil, foreground: Int32?, project: String?) {
        report.foregroundAfter = foreground
        report.projectAfter = project.map { String($0.prefix(512)) }
        report.error = error.map { String($0.localizedDescription.prefix(2_048)) }
        if report.fallbackCount > 0 {
            report.outcome = error == nil ? "ordinaryRouteCompleted" : "ordinaryRouteFailed"
        } else {
            report.outcome = error == nil ? "ownedPanelObserved" : (report.observedOwnedPanel ? "ownedPanelObservedThenFailed" : (report.attemptCount == 0 ? "preflightRejected" : "notProven"))
        }
        save()
    }

    func record(timing: AnalysisTiming, prefix: String) {
        timing.recordCounters([prefix + ".directAX.enabled": 1, prefix + ".directAX.attempts": report.attemptCount,
            prefix + ".directAX.production": mode == .production ? 1 : 0,
            prefix + ".directAX.ownedPanelObserved": report.observedOwnedPanel ? 1 : 0,
            prefix + ".directAX.fallbacks": report.fallbackCount,
            prefix + ".directAX.axResult": Int(report.axResult ?? Int32.min)])
    }

    @discardableResult private func save() -> Bool {
        report.elapsedSeconds = ProcessInfo.processInfo.systemUptime - started
        if mode == .production { return true }
        guard let directory else { return false }
        return Self.write(report, directory: directory)
    }

    static func rejected(request: UUID, phase: String, error: Error, directory: URL) {
        var report = Report(request: request, phase: phase)
        report.outcome = "configurationRejected"; report.error = String(error.localizedDescription.prefix(2_048))
        write(report, directory: directory)
    }

    @discardableResult private static func write(_ report: Report, directory: URL) -> Bool {
        guard directory.standardizedFileURL == directory, directory.resolvingSymlinksInPath() == directory else { return false }
        var folder = stat()
        guard lstat(directory.path, &folder) == 0, folder.st_mode & S_IFMT == S_IFDIR,
              folder.st_uid == geteuid() else { return false }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report), data.count <= 16_384 else { return false }
        do { try data.write(to: directory.appendingPathComponent("DirectShareAX.json"), options: .atomic); return true }
        catch { return false }
    }
}

struct DirectShareAXPanelObservation {
    let existedBeforeDispatch: Bool
    let ownedByPinnedHost: Bool
    let title: String?
    let enabledNextFound: Bool
    let projectMatches: Bool
    let foregroundIsHostOrHelper: Bool

    var provesCompletion: Bool {
        !existedBeforeDispatch && ownedByPinnedHost && title == "Silent Snip" && enabledNextFound
            && projectMatches && foregroundIsHostOrHelper
    }
}
