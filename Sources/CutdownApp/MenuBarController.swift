import AppKit
import CutdownMac

@MainActor final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit Silent Snip", action: #selector(quit), keyEquivalent: "q")
    private let isBusy: () -> Bool
    private let clearCacheAction: () async -> StorageCleanupReport?
    private let clearCacheItem = NSMenuItem(title: "Clear Cache…", action: #selector(clearCache), keyEquivalent: "")

    init(isBusy: @escaping () -> Bool, clearCache: @escaping () async -> StorageCleanupReport?) {
        self.isBusy = isBusy
        self.clearCacheAction = clearCache
        super.init()

        if let button = item.button {
            if let image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Silent Snip") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "SS"
            }
            button.toolTip = "Silent Snip is running"
            button.setAccessibilityLabel("Silent Snip")
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let heading = NSMenuItem(title: "Silent Snip is running", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())
        let results = NSMenuItem(title: "Open Results Folder", action: #selector(openResults), keyEquivalent: "")
        results.target = self
        menu.addItem(results)
        clearCacheItem.target = self
        clearCacheItem.toolTip = "Remove verified temporary audio. Keep recovery files, saved results, settings, and original media."
        menu.addItem(clearCacheItem)
        menu.addItem(.separator())
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        updateState()
    }

    func menuWillOpen(_ menu: NSMenu) { updateState() }

    private func updateState() {
        let busy = isBusy()
        stateItem.title = busy ? "Working in Final Cut Pro…"
            : FinalCutAccessibility.isTrusted ? "Ready — use Controls in Final Cut Pro" : "Control access required in System Settings"
        // Let an active capture, import, or verification finish before quitting.
        quitItem.isEnabled = !busy
        clearCacheItem.isEnabled = !busy
    }

    @objc private func openResults() {
        let folder = IntegrationReport.reportURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Results", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if !NSWorkspace.shared.open(folder) { NSSound.beep() }
        } catch {
            NSApplication.shared.presentError(error)
        }
    }

    @objc private func quit() {
        guard !isBusy() else { return }
        NSApplication.shared.terminate(nil)
    }

    @objc private func clearCache() {
        guard !isBusy() else { return }
        Task {
            guard let report = await clearCacheAction(), !report.cancelled, !isBusy() else { return }
            let alert = NSAlert()
            alert.messageText = "Cache Cleanup Complete"
            let freed = ByteCountFormatter.string(fromByteCount: report.removedBytes, countStyle: .file)
            alert.informativeText = "Freed \(freed). Recovery files, saved results, settings, and original media were kept."
            if report.preservedFiles > 0 || report.errors > 0 {
                alert.informativeText += " Some files were kept because they are in use, changed, or could not be safely removed."
            }
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    func stop() { NSStatusBar.system.removeStatusItem(item) }
}
