/// WindowServer can report the old stack during an application switch. Use
/// application activation directly before painting or ordering the preview.
enum PreviewForegroundPolicy {
    static func permits(hostPID: Int32, hostIsActive: Bool, foregroundPID: Int32?) -> Bool {
        hostPID > 0 && hostIsActive && foregroundPID == hostPID
    }
}
