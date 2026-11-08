import Foundation

/// Filesystem-only completion after the existing native result has passed its
/// XML/media verification. It never opens Final Cut, edits a clip or imports.
@MainActor enum NativeResultFinalization {
    static func complete(directory: URL, projectUID: UUID, projectName: String) throws {
        try FinalCutAXSession.markNativeSourceEditsVerified(directory: directory, projectUID: projectUID)
        // Journal completion is idempotent. If this status write fails, the
        // next read-only verification can finish it without replaying any cut.
        let message = "Verified native result ‘\(projectName)’ (\(projectUID.uuidString)). Original project unchanged.\n"
        try Data(message.utf8).write(to: directory.appendingPathComponent("Native-Edit-Status.txt"), options: .atomic)
    }
}
