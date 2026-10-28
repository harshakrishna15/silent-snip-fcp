#if DEBUG
import AppKit
import SilentSnipMac

/// Isolated developer runner; the distributed prototype uses the normal AU UI.
@MainActor final class QuietSharePrototypeDelegate: NSObject, NSApplicationDelegate {
    private let configuration: URL
    private var task: Task<Void, Never>?
    init(configuration: URL) { self.configuration = configuration }
    func applicationDidFinishLaunching(_ notification: Notification) {
        task = Task {
            await QuietSharePrototype.run(configurationURL: configuration)
            try? await Task.sleep(for: .seconds(2))
            NSApp.terminate(nil)
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        _ = ShareDestinationManager.shared.handleOpen(urls: urls.filter(\.isFileURL))
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { task?.cancel() }
}
#endif
