import AppKit
import CutdownMac

@MainActor final class CutdownDelegate: NSObject, NSApplicationDelegate {
    private let transport = ReviewTransport()
    private let interactive = InteractiveAudioSession()
    private var reviewRequest: AnalyzeRequest?
    private lazy var coordinator = AnalysisReviewCoordinator(
        operation: { [unowned self] request, progress in
            reviewRequest = request
            return try await interactive.analyze(request, progress: progress)
        }, applyOperation: { [unowned self] request, result, progress in
            try await interactive.apply(request, result: result, progress: progress)
        }, highlightOperation: { [unowned self] request, result, cutID in
            try await interactive.highlight(request, result: result, cutID: cutID)
        }, verificationOperation: { [unowned self] request, progress in
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
            manager?.hasActiveRequest == true || self?.coordinator.isBusy == false
        }
        manager.onFailure = { error in
            try? IntegrationReport(state: "failed", message: error.localizedDescription).save()
        }
        manager.onReceive = { _ in
            try? IntegrationReport(state: "ready", message: "Share received. Select the clip carrying Cutdown Audio and use Analyze to start a verified review.").save()
        }
        transport.onReconnect = { [weak self] view in
            guard let self, let request = reviewRequest,
                  interactive.canReconnectReview(view: view) else { return nil }
            return request
        }
        transport.start { [weak self] command in
            self?.coordinator.handle(command)
            if command.command == .cancel { self?.interactive.discard(command.request) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !FinalCutAccessibility.isTrusted { FinalCutAccessibility.requestAccess() }
        try? IntegrationReport(state: "ready", message: "Ready. Analyze captures the selected audio clip; Apply replaces the project through XML in its existing event, with recovery XML saved first.").save()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // The Audio Unit Controls view is the only Cutdown window.
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
                        throw FinalCutCaptureError.unavailable("Wait for the current Cutdown operation to finish before verifying another result.")
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
                if !FinalCutAccessibility.isTrusted { FinalCutAccessibility.requestAccess() }
                coordinator.start(request)
            } catch { try? IntegrationReport(state: "failed", message: error.localizedDescription).save() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { coordinator.stop(); interactive.stop(); transport.stop() }
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
