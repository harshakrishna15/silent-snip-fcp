#if DEBUG
import AppKit
import ApplicationServices
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import SilentSnipCore

/// Development-only presentation and an isolated Share gate. Only run(configurationURL:)
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
        var coverDismissed = false
        var xmlVerified = false
        var mediaCount = 0
        var seconds = 0.0
    }

    public static func run(configurationURL: URL) async {
        guard let data = try? Data(contentsOf: configurationURL),
              let config = try? JSONDecoder().decode(Configuration.self, from: data),
              config.project.hasPrefix("Silent Snip Quiet Prototype "), config.output.isFileURL,
              ["xml", "audio"].contains(config.intent),
              !(config.covered && config.legacyMenu == true) else { return }
        var report = Report(project: config.project, intent: config.intent)
        let started = ProcessInfo.processInfo.systemUptime
        var cover: QuietSharePrototypeCover?
        var work: Task<Void, Error>?
        func observeForeground() {
            let name = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unavailable"
            if report.foregroundApplications.last != name { report.foregroundApplications.append(name) }
        }
        do {
            try FileManager.default.createDirectory(at: config.output, withIntermediateDirectories: true)
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
                cover?.update(stage)
                if config.cancelAt == stage { cover?.dismiss(); work?.cancel() }
            }
            if config.covered {
                cover = try QuietSharePrototypeCover(session: session, cancel: {
                    work?.cancel()
                }, focusLost: {
                    observeForeground()
                    report.hostRemainedActive = false
                    work?.cancel()
                })
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
        cover?.dismiss()
        report.coverDismissed = cover?.isVisible != true
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

    private static func verifyLibrary(_ url: URL) throws {
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

/// Request-scoped development presentation. It never owns a second analysis
/// job, retries a dispatch, or resurrects a revealed/finished cover.
@MainActor final class QuietSharePluginPrototypeLease {
    let request: UUID
    private let cancel: (UUID) -> Void
    private let reportURL: URL?
    private var cover: QuietSharePrototypeCover?
    private var pinnedWindow: AXUIElement?
    private var hostPID: pid_t?
    private weak var currentSession: FinalCutAXSession?
    nonisolated let cancellation = QuietSharePrototypeCancellation()
    private(set) var revealed = false
    private(set) var finished = false
    var inputStopped: Bool { cancellation.isCancelled }
    private var cancelRequested = false
    private var fallbackReason: String?
    private var invocations: [String] = []
    private var transitions = 0
    private var stage = "Preparing Final Cut…"

    init(request: UUID, cancel: @escaping (UUID) -> Void, reportURL: URL? = nil) {
        self.request = request; self.cancel = cancel; self.reportURL = reportURL
    }

    func attach(_ session: FinalCutAXSession) throws {
        try assertMayContinue()
        guard !revealed, !finished else { return }
        currentSession = session
        if let pinnedWindow, let hostPID {
            guard hostPID == session.application.processIdentifier, CFEqual(pinnedWindow, session.mainWindow) else {
                reveal(reason: "The pinned Final Cut workspace changed.")
                return
            }
            try cover?.repin(session)
            return
        }
        pinnedWindow = session.mainWindow; hostPID = session.application.processIdentifier
        cover = try QuietSharePrototypeCover(session: session, cancel: { [weak self] in self?.cancelWork() },
            focusLost: { [weak self] in
                guard let self, !self.finished else { return }
                // A matching Share completion can activate its own receiver.
                // Reveal it and let the existing verified return path run.
                if let session = self.currentSession,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier == NSRunningApplication.current.processIdentifier,
                   ShareDestinationManager.shared.prototypeShareHasResponse(projectName: session.projectName) {
                    self.reveal(reason: "Final Cut activated the Share receiver after delivery.")
                } else { self.cancelWork(reason: "Final Cut lost foreground focus.") }
            }, showHost: { [weak self] in self?.reveal(reason: "Show Final Cut selected.") })
        transitions += 1
        cover?.update(stage)
    }

    func assertMayContinue() throws {
        if inputStopped || finished { throw CancellationError() }
    }

    func update(_ message: String) {
        guard !finished else { return }
        stage = message
        cover?.update(message)
    }

    func recordInvocation(_ method: String) {
        guard !finished else { return }
        invocations.append(method)
    }

    func reveal(reason: String) {
        guard !finished, !revealed else { return }
        revealed = true; fallbackReason = reason
        if cover?.isVisible == true { transitions += 1 }
        cover?.dismiss()
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
        if cover?.isVisible == true { transitions += 1 }
        cover?.dismiss(); cover = nil; finished = true
        guard let reportURL else { return }
        let report: [String: Any] = ["request": request.uuidString, "mode": "plugin-prototype",
            "fallbackReason": fallbackReason ?? "none", "invocations": invocations,
            "transitions": transitions, "inputStopped": inputStopped, "coverDismissed": true]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: reportURL, options: .atomic)
        }
    }
}

/// Cancellation can arrive off the main actor. Stop input synchronously before
/// scheduling the panel dismissal, including inside unstructured cleanup tasks.
final class QuietSharePrototypeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
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

@MainActor private final class QuietSharePrototypePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor private final class QuietSharePrototypeCover: NSObject {
    private let panel: NSPanel
    private let stage = NSTextField(labelWithString: "Preparing Final Cut…")
    private var timer: Timer?
    private var dismissed = false
    private let cancel: () -> Void
    private let showHostAction: () -> Void
    private weak var session: FinalCutAXSession?
    var isVisible: Bool { panel.isVisible }
    init(session: FinalCutAXSession, cancel: @escaping () -> Void, focusLost: @escaping () -> Void,
         showHost onShowHost: @escaping () -> Void = {}) throws {
        let frame = try Self.frame(session.mainWindow)
        panel = QuietSharePrototypePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.cancel = cancel
        self.showHostAction = onShowHost
        self.session = session
        super.init()
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        let root = NSView(); panel.contentView = root
        let title = NSTextField(labelWithString: "Silent Snip — " + session.projectName)
        title.font = .boldSystemFont(ofSize: 18)
        let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.startAnimation(nil)
        let stop = NSButton(title: "Cancel", target: self, action: #selector(cancelNow))
        let show = NSButton(title: "Show Final Cut", target: self, action: #selector(showHost))
        let buttons = NSStackView(views: [stop, show]); buttons.orientation = .horizontal
        let stack = NSStackView(views: [title, stage, spinner, buttons]); stack.orientation = .vertical; stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor), stack.widthAnchor.constraint(lessThanOrEqualToConstant: 600)])
        panel.orderFrontRegardless()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == session.application.processIdentifier else {
            panel.orderOut(nil); throw FinalCutCaptureError.unavailable("The nonactivating cover changed application focus.")
        }
        timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.dismissed else { return }
                guard let session = self.session, !session.application.isTerminated,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == session.application.processIdentifier,
                      let frame = try? Self.frame(session.mainWindow) else {
                    self.dismiss(); focusLost(); return
                }
                self.panel.setFrame(frame, display: true)
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    func repin(_ session: FinalCutAXSession) throws {
        guard !dismissed else { return }
        let frame = try Self.frame(session.mainWindow)
        self.session = session
        panel.setFrame(frame, display: true)
    }
    func update(_ text: String) { stage.stringValue = text }
    func dismiss() { dismissed = true; timer?.invalidate(); timer = nil; panel.orderOut(nil) }
    @objc private func cancelNow() { dismiss(); cancel() }
    @objc private func showHost() { dismiss(); showHostAction() }
    private static func frame(_ window: AXUIElement) throws -> CGRect {
        let values = FinalCutAXAttributes.read(window, names: [kAXPositionAttribute, kAXSizeAttribute])
        guard let position = values[kAXPositionAttribute], let size = values[kAXSizeAttribute],
              CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID(), CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID() else {
            throw FinalCutCaptureError.projectWindowUnavailable
        }
        var origin = CGPoint.zero; var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              origin.x.isFinite, origin.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 100, dimensions.height > 100, let top = NSScreen.screens.first?.frame.maxY else {
            throw FinalCutCaptureError.projectWindowUnavailable
        }
        return CGRect(x: origin.x, y: top - origin.y - dimensions.height, width: dimensions.width, height: dimensions.height)
    }
}
#endif
