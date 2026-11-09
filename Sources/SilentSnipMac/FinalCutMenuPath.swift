import ApplicationServices
import Foundation

/// Retain only menu-object identities for one request. Attribute values are
/// read again at every use, and the current command must remain unique in its
/// current container. This is not a cross-request or negative-result cache.
final class FinalCutMenuPath<Element> {
    struct Item {
        let element: Element
        let container: Element
        let values: [String: Any]
        var actions: [String] = []
    }

    let titles: [String]
    private let read: (Element, [String]) -> [String: Any]
    private let owned: (Element) -> Bool
    private let actions: (Element) -> [String]?
    private let equals: (Element, Element) -> Bool
    private var hierarchy: [Element]?
    private(set) var counters = ["menuPath.searches": 0, "menuPath.cacheHits": 0,
        "menuPath.invalidations": 0, "menuPath.pathChecks": 0, "menuPath.visitedNodes": 0,
        "menuPath.attributeBatches": 0, "menuPath.attributeNames": 0,
        "menuPath.ownerChecks": 0, "menuPath.actionReads": 0, "menuPath.rebuiltMounts": 0]

    init(titles: [String], read: @escaping (Element, [String]) -> [String: Any],
         owned: @escaping (Element) -> Bool, actions: @escaping (Element) -> [String]?,
         equals: @escaping (Element, Element) -> Bool) {
        self.titles = titles; self.read = read; self.owned = owned
        self.actions = actions; self.equals = equals
    }

    /// Shortcut discovery also mounts the ordinary menu route when there is no
    /// assigned shortcut. A valid shortcut still needs a second fresh command
    /// observation immediately before its keyboard event.
    func command(in menuBar: Element, shouldContinue: () -> Bool) -> Item? {
        guard validTitles, shouldContinue() else { return nil }
        if let hierarchy {
            counters["menuPath.pathChecks", default: 0] += 1
            if let result = mounted(hierarchy, menuBar: menuBar, index: titles.count - 1,
                                    expectedContainer: nil, shortcut: true, uniqueAncestors: true,
                                    requireEnabled: false, shouldContinue: shouldContinue) {
                counters["menuPath.cacheHits", default: 0] += 1
                return result
            }
            invalidate()
        }
        guard let discovery = discover(in: menuBar, through: titles.count - 1,
            shortcut: true, shouldContinue: shouldContinue) else { return nil }
        hierarchy = discovery.route
        return discovery.item
    }

    /// Before an ordinary menu input, all retained parent-child edges and named
    /// ancestors are fresh. Recheck the current level's sibling titles/roles so
    /// an added or renamed duplicate cannot silently authorize the old target.
    /// Earlier levels were independently unique before their own input.
    func input(in menuBar: Element, index: Int, container: Element,
               shouldContinue: () -> Bool) -> Item? {
        guard validTitles, titles.indices.contains(index), shouldContinue() else { return nil }
        // Preserve the already-checked prefix even when the closed menu did
        // not expose descendants and this level must be discovered afresh.
        let previous = hierarchy ?? []
        guard previous.count >= index * 2,
              previous.first.map({ equals($0, menuBar) }) != false else { return nil }
        func discoverInput() -> [Element]? {
            guard let fresh = discover(in: menuBar, through: index, shortcut: false, shouldContinue: shouldContinue),
                  equals(fresh.item.container, container),
                  (0..<(index * 2)).allSatisfy({ equals(previous[$0], fresh.route[$0]) }) else { return nil }
            return fresh.route
        }
        func mountedInput(_ path: [Element]) -> Item? {
            counters["menuPath.pathChecks", default: 0] += 1
            return mounted(path, menuBar: menuBar, index: index, expectedContainer: container,
                shortcut: false, uniqueAncestors: false, requireEnabled: true, shouldContinue: shouldContinue)
        }
        guard var route = previous.count >= (index + 1) * 2 ? previous : discoverInput() else { return nil }
        var target = mountedInput(route)
        if target == nil {
            invalidate()
            // The first mount can go stale even after a fresh discovery. Allow
            // one read-only rebuild of this level, before any action lookup.
            guard index > 0, let fresh = discoverInput() else { return nil }
            route = fresh
            target = mountedInput(route)
            if target != nil { counters["menuPath.rebuiltMounts", default: 0] += 1 }
        }
        guard var result = target else { return nil }
        counters["menuPath.actionReads", default: 0] += 1
        guard shouldContinue(), let available = actions(result.element), available.count <= 32,
              available.allSatisfy({ $0.utf8.count <= 128 }),
              FinalCutControlAction.preferred(from: available) != nil,
              shouldContinue() else { return nil }
        result.actions = available
        hierarchy = route
        counters["menuPath.cacheHits", default: 0] += 1
        return result
    }

    private var validTitles: Bool {
        !titles.isEmpty && titles.count <= 8 && titles.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 }
    }

    private func invalidate() {
        hierarchy = nil
        counters["menuPath.invalidations", default: 0] += 1
    }

    private func values(_ element: Element, _ names: [String], shouldContinue: () -> Bool) -> [String: Any]? {
        guard shouldContinue() else { return nil }
        counters["menuPath.ownerChecks", default: 0] += 1
        guard owned(element), shouldContinue() else { return nil }
        counters["menuPath.attributeBatches", default: 0] += 1
        counters["menuPath.attributeNames", default: 0] += names.count
        return read(element, names)
    }

    private func commandNames(shortcut: Bool) -> [String] {
        let basic = [kAXRoleAttribute, kAXTitleAttribute, kAXEnabledAttribute, kAXChildrenAttribute]
        return shortcut ? basic + [kAXMenuItemCmdVirtualKeyAttribute, kAXMenuItemCmdModifiersAttribute,
            kAXMenuItemCmdCharAttribute, kAXMenuItemCmdGlyphAttribute] : basic
    }

    private func uniqueItem(in container: Element, index: Int,
                            shouldContinue: () -> Bool) -> (Element, [Element])? {
        guard let parent = values(container, [kAXRoleAttribute, kAXChildrenAttribute], shouldContinue: shouldContinue),
              parent[kAXRoleAttribute] as? String == (index == 0 ? kAXMenuBarRole : kAXMenuRole),
              let children = parent[kAXChildrenAttribute] as? [Element], children.count <= 256 else { return nil }
        var found: Element?
        for child in children {
            counters["menuPath.visitedNodes", default: 0] += 1
            guard let value = values(child, [kAXRoleAttribute, kAXTitleAttribute], shouldContinue: shouldContinue),
                  let role = value[kAXRoleAttribute] as? String else { return nil }
            // An unreadable command title cannot prove absence of a duplicate.
            // Non-command roles (such as separators) need no command title.
            if [kAXMenuBarItemRole, kAXMenuItemRole].contains(role), value[kAXTitleAttribute] as? String == nil { return nil }
            if value[kAXTitleAttribute] as? String == titles[index] {
                guard found == nil,
                      role == (index == 0 ? kAXMenuBarItemRole : kAXMenuItemRole) else { return nil }
                found = child
            }
        }
        return found.map { ($0, children) }
    }

    private func submenu(of item: Element, value: [String: Any], shouldContinue: () -> Bool) -> Element? {
        guard let children = value[kAXChildrenAttribute] as? [Element], children.count <= 16 else { return nil }
        var found: Element?
        for child in children {
            guard let childValues = values(child, [kAXRoleAttribute], shouldContinue: shouldContinue),
                  let role = childValues[kAXRoleAttribute] as? String else { return nil }
            if role == kAXMenuRole {
                guard found == nil else { return nil }
                found = child
            }
        }
        return found
    }

    private func discover(in menuBar: Element, through lastIndex: Int, shortcut: Bool,
                          shouldContinue: () -> Bool) -> (item: Item, route: [Element])? {
        counters["menuPath.searches", default: 0] += 1
        var route = [menuBar], container = menuBar
        for index in 0...lastIndex {
            guard let (item, _) = uniqueItem(in: container, index: index, shouldContinue: shouldContinue),
                  let value = values(item, commandNames(shortcut: shortcut && index == lastIndex), shouldContinue: shouldContinue),
                  value[kAXRoleAttribute] as? String == (index == 0 ? kAXMenuBarItemRole : kAXMenuItemRole),
                  value[kAXTitleAttribute] as? String == titles[index] else { return nil }
            route.append(item)
            if index == lastIndex {
                guard shouldContinue() else { return nil }
                return (Item(element: item, container: container, values: value), route)
            }
            guard value[kAXEnabledAttribute] as? Bool == true,
                  let menu = submenu(of: item, value: value, shouldContinue: shouldContinue),
                  !route.contains(where: { equals($0, menu) }) else { return nil }
            route.append(menu); container = menu
        }
        return nil
    }

    private func mounted(_ route: [Element], menuBar: Element, index: Int, expectedContainer: Element?,
                         shortcut: Bool, uniqueAncestors: Bool, requireEnabled: Bool,
                         shouldContinue: () -> Bool) -> Item? {
        guard route.count >= (index + 1) * 2, route.count <= titles.count * 2,
              let bar = route.first, equals(bar, menuBar) else { return nil }
        for level in 0...index {
            let container = route[level * 2], item = route[level * 2 + 1]
            if level == index, let expectedContainer, !equals(container, expectedContainer) { return nil }
            if uniqueAncestors || level == index {
                guard let (fresh, _) = uniqueItem(in: container, index: level, shouldContinue: shouldContinue),
                      equals(fresh, item) else { return nil }
            } else {
                guard let parent = values(container, [kAXRoleAttribute, kAXChildrenAttribute], shouldContinue: shouldContinue),
                      parent[kAXRoleAttribute] as? String == (level == 0 ? kAXMenuBarRole : kAXMenuRole),
                      let children = parent[kAXChildrenAttribute] as? [Element], children.count <= 256,
                      children.filter({ equals($0, item) }).count == 1 else { return nil }
            }
            guard let value = values(item, commandNames(shortcut: shortcut && level == index), shouldContinue: shouldContinue),
                  value[kAXRoleAttribute] as? String == (level == 0 ? kAXMenuBarItemRole : kAXMenuItemRole),
                  value[kAXTitleAttribute] as? String == titles[level],
                  (!(requireEnabled || level < index) || value[kAXEnabledAttribute] as? Bool == true) else { return nil }
            if level == index { return Item(element: item, container: container, values: value) }
            guard let menu = submenu(of: item, value: value, shouldContinue: shouldContinue),
                  equals(menu, route[level * 2 + 2]) else { return nil }
        }
        return nil
    }
}
