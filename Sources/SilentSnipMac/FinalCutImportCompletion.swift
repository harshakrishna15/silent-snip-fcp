import Foundation

/// A first XML import can briefly clear Final Cut's timeline while it creates
/// the imported item. The import itself is read-only until the exact generated
/// project is opened and verified, so an empty title is a transition, not a
/// different user project.
struct FinalCutImportTimeline {
    static func permits(_ current: String?, original: String, imported: String) -> Bool {
        guard let current, !current.isEmpty else { return true }
        return current == original || current == imported
    }
}

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

    /// The observed Final Cut replacement prompts name only the library.
    /// Call only during the one fresh, scoped replacement delivery, never retry.
    func isReplacementConfirmation(libraryName: String) -> Bool {
        guard Set(buttons) == Set(["Keep Both", "Replace", "Cancel"]), buttons.count == 3 else { return false }
        let question = "Do you want to replace them?"
        let target = "an XML document that is about to replace existing items with matching names in the library “\(libraryName)”."
        let legacy = "Final Cut Pro has received \(target) \(question)"
        // Final Cut 12.4 identifies the Apple-event sender and exposes the
        // question as a separate text element. Do not accept another sender,
        // a partial library name, or an unrelated destructive confirmation.
        let sentByUs = "Application “Silent Snip” sent \(target)"
        return text.contains(legacy)
            || (text.contains(sentByUs) && text.contains(question))
            || text.contains("\(sentByUs) \(question)")
    }

    var explanation: String {
        ([title] + text).filter { !$0.isEmpty }.prefix(8).joined(separator: " — ")
    }
}

/// Persist the exact once-only replacement decision independently of dialog
/// observations. A nil AX result means delivery was prepared but its outcome
/// is unknown; neither that state nor an AX error permits a second press.
struct FinalCutReplacementConfirmation: Encodable {
    let projectName: String
    let libraryName: String
    let button = "Replace"
    var axResult: Int32?
}

struct FinalCutImportReadiness {
    private var readySince: TimeInterval?

    /// Delivery via NSWorkspace is not completion. Require the exact generated
    /// project to appear and a quiet interval without a modal import panel.
    mutating func observe(projectVisible: Bool, hasDialog: Bool, elapsed: TimeInterval,
                          awaitingReplacement: Bool = false, replacementConfirmed: Bool = false,
                          originalTimelineClosed: Bool = false, requiresTimelineTransition: Bool = false) -> Bool {
        guard !awaitingReplacement || replacementConfirmed || originalTimelineClosed,
              !requiresTimelineTransition || originalTimelineClosed,
              projectVisible, !hasDialog else { readySince = nil; return false }
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
    var replacingOriginal = false

    var errorDescription: String? {
        let reason: String
        if case FinalCutCaptureError.unavailable(let detail) = cause { reason = detail }
        else { reason = cause.localizedDescription }
        let stage = importAttempted
            ? "Import was requested, but automatic verification could not finish. Use Retry Verification to check the existing result project; do not import or apply again to recreate it."
            : "The edited XML was saved, but no import was requested."
        let recovery = replacingOriginal && importAttempted
            ? "The project may already have been replaced. Recovery XML: \(outputURL.deletingLastPathComponent().appendingPathComponent("Before-Cuts.fcpxml").path)."
            : "The original project is unchanged."
        return "\(stage) \(reason) \(recovery) Edited XML: \(outputURL.path)"
    }

    func saveStatus() throws {
        try Data((errorDescription! + "\n").utf8).write(
            to: outputURL.deletingLastPathComponent().appendingPathComponent("Import-Status.txt"), options: .atomic)
    }
}
