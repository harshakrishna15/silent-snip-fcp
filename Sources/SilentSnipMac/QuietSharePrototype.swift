#if DEBUG
import AppKit
import ApplicationServices
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import SilentSnipCore

/// Development-only request diagnostics and an isolated Share probe. Only run(configurationURL:)
/// avoids editing; the plugin wrapper retains the existing Analyze/Apply pipeline.
@MainActor public enum QuietSharePrototype {
    @TaskLocal static var pluginLease: QuietSharePluginPrototypeLease?

    /// Experimental build only: normal effect controls remain the entry point,
    /// and the existing coordinator still owns the operation and cancellation.
    public static func withPluginPresentation<T>(request: UUID, cancel: @escaping (UUID) -> Void,
        operation: () async throws -> T) async rethrows -> T {
        guard Bundle.main.object(forInfoDictionaryKey: "SilentSnipQuietSharePrototype") as? Bool == true else {
            return try await operation()
        }
        let directory = try? FinalCutDialogueExport.makeJobDirectory(jobID: request)
        let lease = QuietSharePluginPrototypeLease(request: request, cancel: cancel,
            reportURL: directory?.appendingPathComponent("Quiet-Presentation.json"))
        return try await $pluginLease.withValue(lease) {
            defer { lease.finish() }
            return try await withTaskCancellationHandler {
                try await operation()
            } onCancel: {
                lease.cancellation.cancel()
                Task { @MainActor in lease.stopInput(reason: "cancelled") }
            }
        }
    }

    public static func pluginStage(_ message: String) { pluginLease?.update(message) }
    public static var integrationLibraryURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Cutdown Integration.fcpbundle")
            .standardizedFileURL.resolvingSymlinksInPath()
    }
    public struct Configuration: Decodable {
        let project: String
        let output: URL
        let intent: String
        let cancelAt: String?
        let covered: Bool
        let legacyMenu: Bool?
    }
    struct Report: Encodable {
        let project: String
        let intent: String
        var outcome = "failed"
        var message = ""
        var stages: [String] = []
        var invocations: [String] = []
        var hostRemainedActive = false
        var controlAccessGranted = false
        var foregroundApplications: [String] = []
        var coverDismissed = true
        var xmlVerified = false
        var mediaCount = 0
        var seconds = 0.0
    }

    public static func run(configurationURL: URL) async {
        guard let data = try? Data(contentsOf: configurationURL),
              let config = try? JSONDecoder().decode(Configuration.self, from: data),
              config.project.hasPrefix("Silent Snip Quiet Prototype "), config.output.isFileURL,
              ["xml", "audio"].contains(config.intent) else { return }
        var report = Report(project: config.project, intent: config.intent)
        let started = ProcessInfo.processInfo.systemUptime
        var work: Task<Void, Error>?
        func observeForeground() {
            let name = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unavailable"
            if report.foregroundApplications.last != name { report.foregroundApplications.append(name) }
        }
        do {
            try FileManager.default.createDirectory(at: config.output, withIntermediateDirectories: true)
            guard !config.covered else {
                throw FinalCutCaptureError.unavailable("The covering window has been removed. Run the visible Share probe instead.")
            }
            report.controlAccessGranted = FinalCutAccessibility.isTrusted
            guard report.controlAccessGranted else { throw FinalCutAccessibility.AccessibilityError.permissionRequired }
            // A background developer launch must not steal focus. Allow time
            // for the tester to switch from their reply to the fixture.
            let deadline = ProcessInfo.processInfo.systemUptime + 120
            while NSWorkspace.shared.frontmostApplication?.bundleIdentifier != FinalCutAccessibility.bundleIdentifier {
                observeForeground()
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw FinalCutCaptureError.unavailable("Bring the disposable Final Cut fixture to the front before running the prototype.")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            let session = try FinalCutAXSession()
            guard session.projectName == config.project else { throw FinalCutCaptureError.changedProject }
            try verifyOpenLibrary(session)
            try session.assertInputFocus()
            observeForeground()
            report.hostRemainedActive = true
            session.quietPrototypeMenu = config.legacyMenu != true
            if config.legacyMenu == true { report.invocations.append("legacy-visible-menu") }
            session.quietPrototypeInvocation = { report.invocations.append($0) }
            session.quietPrototypeStage = { stage in
                report.stages.append(stage)
                if config.cancelAt == stage { work?.cancel() }
            }
            let operation = Task { @MainActor in
                if config.cancelAt == "beforePreparation" { throw CancellationError() }
                if config.intent == "xml" {
                    let xml = try await session.exportProjectXML(to: config.output.appendingPathComponent("Captured.fcpxmld"))
                    let document = try TimelineParser.parse(url: xml)
                    try verifyLibrary(xml)
                    guard document.projectName == config.project else { throw FinalCutCaptureError.changedProject }
                    report.xmlVerified = true
                } else {
                    let receipt = try await session.shareRenderedAudio()
                    try ShareDestinationManager.shared.validateReceipt(receipt)
                    try verifyLibrary(receipt.xmlURL)
                    let document = try TimelineParser.parse(url: receipt.xmlURL)
                    guard document.projectName == config.project, receipt.mediaURLs.count == 1 else {
                        throw ProjectAnalysisError.invalidRenderArtifact
                    }
                    _ = try await DialogueAudioReader.read(url: receipt.mediaURLs[0],
                        expectedDuration: document.projectRange.checkedDuration(), frameDuration: document.frameDuration)
                    report.xmlVerified = true
                    report.mediaCount = receipt.mediaURLs.count
                    // Preserve every receipt and rendered file as integration evidence.
                    try JSONSerialization.data(withJSONObject: ["xml": receipt.xmlURL.path,
                        "media": receipt.mediaURLs.map(\.path)], options: [.prettyPrinted, .sortedKeys])
                        .write(to: config.output.appendingPathComponent("Receipt.json"), options: .atomic)
                }
                try Task.checkCancellation()
                try session.assertCurrentProject()
                report.hostRemainedActive = report.hostRemainedActive &&
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == session.application.processIdentifier
            }
            work = operation
            try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
            }
            report.outcome = "completed"
        } catch is CancellationError {
            report.outcome = "cancelled"
            report.message = "Cancelled without retrying or applying edits."
        } catch { report.message = error.localizedDescription }
        observeForeground()
        report.seconds = ProcessInfo.processInfo.systemUptime - started
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            try? data.write(to: config.output.appendingPathComponent("Report.json"), options: .atomic)
        }
    }

    static func verifyOpenLibrary(_ session: FinalCutAXSession) throws {
        guard let sidebar = session.find(in: session.mainWindow, role: kAXOutlineRole,
            description: "Event media sidebar", maxDepth: 16, maxNodes: 400) else {
            throw FinalCutCaptureError.unavailable("Show the Libraries sidebar before running the prototype.")
        }
        var help: [String] = []
        var pending = [(sidebar, 0)]
        var visited = 0
        while let (element, depth) = pending.popLast() {
            try Task.checkCancellation()
            visited += 1
            guard visited <= 500, depth <= 12 else { throw FinalCutCaptureError.projectWindowUnavailable }
            if let value = session.string(element, kAXHelpAttribute) { help.append(value) }
            pending.append(contentsOf: session.children(element).map { ($0, depth + 1) })
        }
        guard QuietSharePrototypeLibrary.verifies(help: help, expected: integrationLibraryURL) else {
            throw FinalCutCaptureError.unavailable("Run this prototype with only the workspace's Cutdown Integration.fcpbundle open. Other libraries were left untouched.")
        }
    }

    static func verifyLibrary(_ url: URL) throws {
        let file = url.pathExtension == "fcpxmld" ? url.appendingPathComponent("Info.fcpxml") : url
        let xml = try XMLDocument(data: Data(contentsOf: file), options: [.nodeLoadExternalEntitiesNever])
        let location = try xml.nodes(forXPath: "/fcpxml/library/@location").first?.stringValue
        // The generated fixture's embedded location must remain the required
        // workspace library. No prototype work is allowed in another library.
        guard let location, let library = URL(string: location),
              library.lastPathComponent == "Cutdown Integration.fcpbundle",
              library.standardizedFileURL.resolvingSymlinksInPath().path == integrationLibraryURL.path else {
            throw FinalCutCaptureError.unavailable("The quiet Share prototype is restricted to the workspace integration library.")
        }
    }
}

/// Request-scoped development diagnostics and focus monitoring. It creates no
/// window, owns no second analysis job, and never retries a dispatch.
@MainActor final class QuietSharePluginPrototypeLease {
    let request: UUID
    private let cancel: (UUID) -> Void
    private let reportURL: URL?
    private var focusTimer: Timer?
    private var pinnedWindow: AXUIElement?
    private var hostPID: pid_t?
    // Re-pinning may return a session whose caller immediately discards it.
    // Own the current pin until the request ends; session callbacks weakly
    // reference this lease, so retaining the session creates no cycle.
    private var currentSession: FinalCutAXSession?
    nonisolated let cancellation = QuietSharePrototypeCancellation()
    private(set) var revealed = false
    private(set) var finished = false
    var inputStopped: Bool { cancellation.isCancelled }
    private var cancelRequested = false
    private var fallbackReason: String?
    private var invocations: [String] = []
    private var stage = "Preparing Final Cut…"

    init(request: UUID, cancel: @escaping (UUID) -> Void, reportURL: URL? = nil) {
        self.request = request; self.cancel = cancel; self.reportURL = reportURL
    }

    func attach(_ session: FinalCutAXSession) throws {
        try assertMayContinue()
        guard !revealed, !finished else { return }
        if currentSession === session { return }
        if let pinnedWindow, let hostPID {
            guard hostPID == session.application.processIdentifier, CFEqual(pinnedWindow, session.mainWindow) else {
                reveal(reason: "The pinned Final Cut workspace changed.")
                return
            }
            currentSession = session
            return
        }
        pinnedWindow = session.mainWindow; hostPID = session.application.processIdentifier
        currentSession = session
        focusTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.finished, !self.revealed, let session = self.currentSession else { return }
                let loss: QuietSharePrototypeVisibilityLoss
                if session.application.isTerminated { loss = .hostExited }
                else {
                    let foreground = NSWorkspace.shared.frontmostApplication
                    guard foreground?.processIdentifier != session.application.processIdentifier else { return }
                    loss = .foregroundChanged(foreground?.bundleIdentifier)
                }
                let matchingShare = self.currentSession.map {
                    ShareDestinationManager.shared.prototypeShareRequestMatches(projectName: $0.projectName)
                } ?? false
                if QuietSharePrototypeVisibilityRecovery.mayContinueVisibly(loss: loss,
                    helperBundle: Bundle.main.bundleIdentifier, matchingShare: matchingShare) {
                    // Keep the same exchange alive. Existing input checks still
                    // require fresh Final Cut focus; no command is dispatched again.
                    self.reveal(reason: loss.description)
                } else { self.cancelWork(reason: loss.description) }
            }
        }
        RunLoop.main.add(focusTimer!, forMode: .common)
    }

    func assertMayContinue() throws {
        if inputStopped || finished { throw CancellationError() }
    }

    func update(_ message: String) {
        guard !finished else { return }
        stage = message
    }

    func recordInvocation(_ method: String) {
        guard !finished else { return }
        invocations.append(method)
    }

    func reveal(reason: String) {
        guard !finished, !revealed else { return }
        revealed = true; fallbackReason = reason
        focusTimer?.invalidate(); focusTimer = nil
    }

    func stopInput(reason: String) {
        guard !finished else { return }
        cancellation.cancel()
        reveal(reason: reason)
    }

    func cancelWork(reason: String = "Cancel selected.") {
        guard !finished, !cancelRequested else { return }
        cancelRequested = true
        stopInput(reason: reason)
        cancel(request)
    }

    func finish() {
        guard !finished else { return }
        focusTimer?.invalidate(); focusTimer = nil; currentSession = nil; finished = true
        guard let reportURL else { return }
        let report: [String: Any] = ["request": request.uuidString, "mode": "visible-plugin-prototype", "lastStage": stage,
            "fallbackReason": fallbackReason ?? "none", "invocations": invocations,
            "transitions": 0, "inputStopped": inputStopped, "coverDismissed": true]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: reportURL, options: .atomic)
        }
    }
}

/// Cancellation can arrive off the main actor. Stop input synchronously before
/// scheduling main-actor cleanup, including inside unstructured cleanup tasks.
final class QuietSharePrototypeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
}

enum QuietSharePrototypeVisibilityLoss {
    case hostExited
    case foregroundChanged(String?)

    var description: String {
        switch self {
        case .hostExited: return "Final Cut exited."
        case .foregroundChanged(let app): return "Foreground changed to \(app ?? "an unidentified application")."
        }
    }
}

enum QuietSharePrototypeVisibilityRecovery {
    static func mayContinueVisibly(loss: QuietSharePrototypeVisibilityLoss, helperBundle: String?, matchingShare: Bool) -> Bool {
        switch loss {
        case .foregroundChanged(let app):
            return app != nil && app == helperBundle && matchingShare
        case .hostExited: return false
        }
    }
}

enum QuietSharePrototypeLibrary {
    static func verifies(help: [String], expected: URL) -> Bool {
        let paths = help.flatMap { $0.components(separatedBy: .newlines) }.compactMap { line -> String? in
            let path = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/"), path.hasSuffix(".fcpbundle") || path.hasSuffix(".fcpbundle/") else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        }
        return Set(paths) == [expected.standardizedFileURL.resolvingSymlinksInPath().path]
    }
}

#endif
