import AppKit
import CutdownMac

@MainActor final class CutdownDelegate: NSObject, NSApplicationDelegate {
    private let transport = ReviewTransport()
    private let interactive = InteractiveAudioSession()
    private var reviewRequest: AnalyzeRequest?
    private var menuBar: MenuBarController?
    private var storageTimer: Timer?
    private var lateActivationTask: Task<Void, Never>?
    private lazy var storageCleanup = StorageCleanupController(isBusy: { [unowned self] in
        coordinator.isBusy || ShareDestinationManager.shared.hasActiveRequest
    }, protectedURLs: { [unowned self] in interactive.storageProtectedURLs },
    clearMemory: { [unowned self] in interactive.clearAnalysisCache() })
    private lazy var coordinator = AnalysisReviewCoordinator(
        operation: { [unowned self] request, progress in
            await waitForStorageCleanup()
            reviewRequest = request
            return try await interactive.analyze(request, progress: progress)
        }, applyOperation: { [unowned self] request, result, progress in
            await waitForStorageCleanup()
            try await interactive.apply(request, result: result, progress: progress)
        }, authorizeApply: { [unowned self] command in
            guard let view = command.view, let gesture = command.applyGesture else { return false }
            return interactive.canAuthorizeApply(view: view, gesture: gesture)
        }, recalculationOperation: { [unowned self] request, result, progress in
            await waitForStorageCleanup()
            try await interactive.verifySettingsPreview(request, result: result, progress: progress)
        }, authorizeRecalculation: { [unowned self] command in
            guard let view = command.view else { return false }
            return interactive.canReconnectReview(view: view)
        }, highlightOperation: { [unowned self] request, result, cutID in
            await waitForStorageCleanup()
            try await interactive.highlight(request, result: result, cutID: cutID)
        }, verificationOperation: { [unowned self] request, progress in
            await waitForStorageCleanup()
            try await interactive.retryVerification(request.id, progress: progress)
        }, canRetryVerification: { [unowned self] id in
            interactive.canRetryVerification(id)
        }, emit: { [unowned self] response in
            transport.publish(response)
        })

    func applicationWillFinishLaunching(_ notification: Notification) {
        interactive.onPreviewReady = { [weak self] id, result in self?.coordinator.previewReady(id, result: result) }
        coordinator.onReviewChange = { [weak self] id, review in
            self?.interactive.updatePreview(id, review: review)
        }
        let manager = ShareDestinationManager.shared
        manager.canBeginShare = { [weak self, weak manager] in
            self?.storageCleanup.isRunning != true && (manager?.hasActiveRequest == true || self?.coordinator.isBusy == false)
        }
        manager.onFailure = { error in
            try? IntegrationReport(state: "failed", message: error.localizedDescription).save()
        }
        manager.onLateXMLCompletion = { [weak self] directory in
            guard let self, let request = self.coordinator.currentRequest?.id else { return }
            self.lateActivationTask?.cancel()
            self.lateActivationTask = Task { [weak self] in
                await FinalCutReviewPresentation.returnOwnActivation(
                    stillOwnsRequest: { self?.coordinator.currentRequest?.id == request },
                    helperIsActive: { NSApp.isActive }, restore: {
                        guard let self else { return }
                        if !self.coordinator.isBusy {
                            await self.interactive.restoreReviewAfterLateCompletion(directory, request: request)
                            return
                        }
                        let hosts = NSRunningApplication.runningApplications(withBundleIdentifier: FinalCutAccessibility.bundleIdentifier)
                        guard hosts.count == 1, let host = hosts.first else { return }
                        NSApp.yieldActivation(to: host)
                        host.activate(from: NSRunningApplication.current, options: [])
                    })
            }
        }
        manager.onReceive = { _ in
            try? IntegrationReport(state: "ready", message: "Share received. Select the clip carrying Silent Snip Audio and use Analyze to start a verified review.").save()
        }
        transport.onReconnect = { [weak self] view in
            guard let self, let request = coordinator.currentRequest ?? reviewRequest,
                  interactive.canReconnectReview(view: view) else { return nil }
            return request
        }
        transport.start { [weak self] command in
            self?.coordinator.handle(command)
            if command.command == .cancel { self?.interactive.discard(command.request) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController(isBusy: { [weak self] in
            self?.coordinator.isBusy == true || self?.storageCleanup.isRunning == true || ShareDestinationManager.shared.hasActiveRequest
        }, clearCache: { [weak self] in
            guard let self else { return nil }
            return await self.cleanStorage(manual: true)
        })
        Task { _ = await cleanStorage(manual: false) }
        storageTimer = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in _ = await self?.cleanStorage(manual: false) }
        }
        RunLoop.main.add(storageTimer!, forMode: .common)
        let trusted = FinalCutAccessibility.isTrusted
        if !trusted { FinalCutAccessibility.requestAccess() }
        try? IntegrationReport(state: trusted ? "ready" : "permission-required", message: trusted
            ? "Ready. Analyze captures the selected audio clip; Apply replaces the project through XML in its existing event, with recovery XML saved first."
            : "Open Silent Snip in System Settings and grant control access, then reopen the app. Your Final Cut Share destination must point to this combined app.").save()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // The Audio Unit Controls view is the only Silent Snip window.
        // URL delivery can also trigger this callback; never open a second UI.
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { _ = ShareDestinationManager.shared.handleOpen(urls: files) }
        for url in urls where !url.isFileURL {
            if url.host == "verify", let verification = try? ReviewVerificationRequest(url: url) {
                do {
                    guard !coordinator.isBusy else {
                        throw FinalCutCaptureError.unavailable("Wait for the current Silent Snip operation to finish before verifying another result.")
                    }
                    let request = try interactive.loadVerification(verification.result, view: verification.view)
                    reviewRequest = request
                    transport.connect(view: verification.view, request: request)
                    coordinator.restoreVerification(request)
                } catch {
                    transport.connectionFailed(view: verification.view, message: error.localizedDescription)
                }
                continue
            }
            do {
                let request = try AnalyzeRequest(url: url)
                lateActivationTask?.cancel()
                if !FinalCutAccessibility.isTrusted { FinalCutAccessibility.requestAccess() }
                coordinator.start(request)
            } catch { try? IntegrationReport(state: "failed", message: error.localizedDescription).save() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        storageTimer?.invalidate()
        coordinator.stop()
        interactive.stop()
        transport.stop()
        menuBar?.stop()
    }

    private func waitForStorageCleanup() async {
        await storageCleanup.waitUntilIdle()
    }

    private func cleanStorage(manual: Bool) async -> StorageCleanupReport? {
        await storageCleanup.clean(manual: manual)
    }
}

@main enum CutdownApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = CutdownDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
