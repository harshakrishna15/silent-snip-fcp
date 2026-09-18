import AppKit
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

/// The first integration probe reads the real accessibility tree. It does not
/// infer timeline selections from a clip name or issue unverified keyboard edits.
@MainActor public enum FinalCutAccessibility {
    public static let bundleIdentifier = "com.apple.FinalCut"

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public static func capture() throws -> AccessibilityNode {
        guard isTrusted else { throw AccessibilityError.permissionRequired }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            throw AccessibilityError.notRunning
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 2)
        var budget = 10_000
        return read(root, depth: 0, budget: &budget)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) else { return nil }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func read(_ element: AXUIElement, depth: Int, budget: inout Int) -> AccessibilityNode {
        budget -= 1
        var children: [AccessibilityNode] = []
        if depth < 40, budget > 0, let elements = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            for child in elements where budget > 0 {
                children.append(read(child, depth: depth + 1, budget: &budget))
            }
        }
        return AccessibilityNode(
            role: string(element, kAXRoleAttribute), identifier: string(element, kAXIdentifierAttribute),
            title: string(element, kAXTitleAttribute), description: string(element, kAXDescriptionAttribute),
            value: string(element, kAXValueAttribute),
            selected: (attribute(element, kAXSelectedAttribute) as? NSNumber)?.boolValue,
            enabled: (attribute(element, kAXEnabledAttribute) as? NSNumber)?.boolValue,
            children: children
        )
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
