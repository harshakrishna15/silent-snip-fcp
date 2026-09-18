import Foundation

struct FinalCutImportDialog: Codable, Equatable {
    let title: String
    let text: [String]
    let buttons: [String]

    /// Only acknowledge the completed-import warning for the file we just
    /// delivered. Never accept replacement, missing-media or other decisions.
    func isCompletedWarning(for fileName: String) -> Bool {
        title == "Import XML" && buttons == ["OK"]
            && text.contains(where: { $0.hasPrefix("Your XML was imported with the following warnings.") })
            && text.contains(fileName)
    }

    var explanation: String {
        ([title] + text).filter { !$0.isEmpty }.prefix(8).joined(separator: " — ")
    }
}

struct FinalCutImportReadiness {
    private var readySince: TimeInterval?

    /// Delivery via NSWorkspace is not completion. Require the exact generated
    /// project to appear and a quiet interval without a modal import panel.
    mutating func observe(projectVisible: Bool, hasDialog: Bool, elapsed: TimeInterval) -> Bool {
        guard projectVisible, !hasDialog else { readySince = nil; return false }
        if readySince == nil { readySince = elapsed }
        return elapsed - readySince! >= 0.6
    }
}

/// Browser navigation must not depend on the imported item already being
/// exposed. Reveal it once, after dialogs settle, while still on the original.
struct FinalCutImportBrowserReveal {
    private var quiet = FinalCutImportReadiness()
    private var revealed = false

    mutating func observe(projectVisible: Bool, originalProjectCurrent: Bool,
                          hasDialog: Bool, elapsed: TimeInterval) -> Bool {
        let settled = quiet.observe(projectVisible: originalProjectCurrent,
                                    hasDialog: hasDialog, elapsed: elapsed)
        guard !revealed, !projectVisible, settled else { return false }
        revealed = true
        return true
    }
}

struct XMLProjectApplyFailure: LocalizedError {
    let cause: Error
    let outputURL: URL
    let importAttempted: Bool

    var errorDescription: String? {
        let reason: String
        if case FinalCutCaptureError.unavailable(let detail) = cause { reason = detail }
        else { reason = cause.localizedDescription }
        let stage = importAttempted
            ? "Import was requested, but automatic verification could not finish. Use Retry Verification to check the existing project in Cutdown Results; do not import or apply again to recreate it."
            : "The edited XML was saved, but no import was requested."
        return "\(stage) \(reason) The original project is unchanged. Edited XML: \(outputURL.path)"
    }

    func saveStatus() throws {
        try Data((errorDescription! + "\n").utf8).write(
            to: outputURL.deletingLastPathComponent().appendingPathComponent("Import-Status.txt"), options: .atomic)
    }
}
