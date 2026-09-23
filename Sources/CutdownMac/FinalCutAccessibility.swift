import ApplicationServices
import Foundation

public struct AccessibilityNode: Codable, Sendable {
    public let role: String?
    public let identifier: String?
    public let title: String?
    public let description: String?
    public let value: String?
    public let selected: Bool?
    public let enabled: Bool?
    public let children: [AccessibilityNode]
}

/// Final Cut process identity and macOS control-access status for the live workflow.
@MainActor public enum FinalCutAccessibility {
    public static let bundleIdentifier = "com.apple.FinalCut"

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public enum AccessibilityError: LocalizedError {
        case permissionRequired, notRunning
        public var errorDescription: String? {
            switch self {
            case .permissionRequired:
                let panel: String
                if #available(macOS 27.0, *) { panel = "Device Control and Data Access" }
                else { panel = "Accessibility" }
                return "Enable Cutdown in System Settings → Privacy & Security → \(panel). After a local rebuild, remove and re-add Cutdown if enabling it does not restore access."
            case .notRunning: return "Open Final Cut Pro and select the clip carrying Cutdown."
            }
        }
    }
}
