import Foundation

public enum FinalCutReviewPresentation {
    /// Open Document may activate the helper after its delegate callback. Watch
    /// only this bounded handoff, and undo only the helper's own activation.
    @MainActor public static func returnOwnActivation(stillOwnsRequest: () -> Bool,
                                                      helperIsActive: () -> Bool,
                                                      restore: () async -> Void,
                                                      attempts: Int = 8,
                                                      pollInterval: Duration = .milliseconds(100)) async {
        for _ in 0..<max(0, attempts) {
            guard !Task.isCancelled, stillOwnsRequest() else { return }
            if helperIsActive() { await restore() }
            do { try await Task.sleep(for: pollInterval) } catch { return }
        }
    }

    /// A newly opened remote editor initially looks like an unknown dialog.
    /// Wait without input until its native ownership controls are available;
    /// strict dialog validation still runs before every toggle and on success.
    @MainActor static func waitForEditor(assertProject: () throws -> Void,
                                         raiseWhenReady: () async throws -> Bool,
                                         timeout: TimeInterval = 3,
                                         pollInterval: Duration = .milliseconds(150)) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            try assertProject()
            if try await raiseWhenReady() { return true }
            try await Task.sleep(for: pollInterval)
        }
        return false
    }

    /// Show Effect Editor is a toggle: an unlisted remote editor may need one
    /// close and one reopen. A verified focused window ends the sequence; never
    /// toggle it again merely because AXWindows still contains stale entries.
    @MainActor static func present(validate: () throws -> Void,
                                    raiseExisting: () async throws -> Bool,
                                    toggleEditor: () async throws -> Void,
                                    awaitEditor: () async throws -> Bool) async throws {
        try Task.checkCancellation()
        try validate()
        if try await raiseExisting() {
            try Task.checkCancellation()
            try validate()
            return
        }
        for _ in 0..<2 {
            try Task.checkCancellation()
            try validate()
            try await toggleEditor()
            if try await awaitEditor() {
                try Task.checkCancellation()
                try validate()
                return
            }
        }
        throw FinalCutCaptureError.unavailable("Final Cut did not bring Silent Snip Controls forward.")
    }
}
