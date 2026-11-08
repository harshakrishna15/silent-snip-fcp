import ApplicationServices
import Foundation

/// Resolves retained menu objects without opening a menu. Every resolution
/// requires a unique, enabled hierarchy; no search result authorizes input
/// after a different object or advertised action replaces that hierarchy.
struct ClosedShareAXCommand<Element> {
    struct Node {
        let role: String?
        let title: String?
        let enabled: Bool?
        let children: [Element]
    }
    let hierarchy: [Element]
    let item: Element
    let actions: [String]
    let action: String

    static func resolve(menuBar: Element, read: (Element) throws -> Node,
                        actions: (Element) throws -> [String],
                        pressOnly: Bool = false,
                        shouldContinue: () -> Bool) throws -> Self {
        var hierarchy = [menuBar]
        var container = menuBar
        let bar = try read(menuBar)
        guard bar.role == kAXMenuBarRole else { throw DirectShareAXError.preflight("The retained menu bar changed.") }
        let titles = ["File", "Share", "Silent Snip…"]
        var visited = 0
        for (index, title) in titles.enumerated() {
            try Task.checkCancellation()
            guard shouldContinue() else { throw DirectShareAXError.preflight("Closed-menu lookup timed out.") }
            let parent = try read(container)
            guard parent.children.count <= 256 else { throw DirectShareAXError.preflight("The retained menu hierarchy is too large.") }
            var matches: [(Element, Node)] = []
            for child in parent.children {
                try Task.checkCancellation()
                visited += 1
                guard visited <= 600, shouldContinue() else { throw DirectShareAXError.preflight("Closed-menu lookup timed out.") }
                let value = try read(child)
                // An unreadable sibling could be a second matching command.
                // Production must not mistake an incomplete read for uniqueness.
                if pressOnly {
                    guard let role = value.role,
                          ![kAXMenuBarItemRole, kAXMenuItemRole].contains(role) || value.title != nil else {
                        throw DirectShareAXError.preflight("A retained menu command could not be identified.")
                    }
                }
                if value.title == title { matches.append((child, value)) }
            }
            guard matches.count == 1, let (item, node) = matches.first,
                  node.role == (index == 0 ? kAXMenuBarItemRole : kAXMenuItemRole), node.enabled == true else {
                throw DirectShareAXError.preflight("The closed \(title) command is missing, ambiguous, disabled, or unreadable.")
            }
            hierarchy.append(item)
            if index == titles.count - 1 {
                try Task.checkCancellation()
                let available = try actions(item)
                let preferred = pressOnly
                    ? (available.contains(kAXPressAction) ? kAXPressAction : nil)
                    : FinalCutControlAction.preferred(from: available)
                guard available.count <= 32, available.allSatisfy({ $0.utf8.count <= 128 }),
                      let action = preferred else {
                    throw DirectShareAXError.preflight("The closed Silent Snip command advertises no permitted action.")
                }
                return Self(hierarchy: hierarchy, item: item, actions: available, action: action)
            }
            guard node.children.count <= 16 else { throw DirectShareAXError.preflight("A retained submenu is ambiguous.") }
            let menus = try node.children.filter {
                try Task.checkCancellation()
                return try read($0).role == kAXMenuRole
            }
            guard menus.count == 1, let menu = menus.first else { throw DirectShareAXError.preflight("The closed \(title) submenu is unavailable or ambiguous.") }
            hierarchy.append(menu)
            container = menu
        }
        throw DirectShareAXError.preflight("The closed Share command was not resolved.")
    }

    func isSame(as other: Self, equals: (Element, Element) -> Bool) -> Bool {
        action == other.action && Set(actions) == Set(other.actions) && hierarchy.count == other.hierarchy.count
            && zip(hierarchy, other.hierarchy).allSatisfy { equals($0, $1) }
    }
}
