import ApplicationServices
import Foundation

/// Batches host reads without retaining attribute values between checks.
enum FinalCutAXAttributes {
    static func read(_ element: AXUIElement, names: [String]) -> [String: Any] {
        values(names: names, batch: {
            var result: CFArray?
            let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &result)
            // A dead element stays absent. Hosts that cannot supply a usable
            // batch retain the existing individual-attribute read path.
            if error == .invalidUIElement {
                return names.map { _ in NSNull() }
            }
            return error == .success ? result as? [Any] : nil
        }, single: { name in
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        })
    }

    static func values(names: [String], batch: () -> [Any]?, single: (String) -> Any?) -> [String: Any] {
        guard let values = batch(), values.count == names.count else {
            return names.reduce(into: [:]) { if let value = single($1) { $0[$1] = value } }
        }
        var result: [String: Any] = [:]
        for (name, value) in zip(names, values) {
            guard !(value is NSNull) else { continue }
            if CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID(),
               AXValueGetType(value as! AXValue) == .axError {
                var error = AXError.success
                _ = AXValueGetValue(value as! AXValue, .axError, &error)
                if error != .noValue && error != .invalidUIElement { result[name] = single(name) }
                continue
            }
            result[name] = value
        }
        return result
    }
}

struct FinalCutAXQuery {
    var role: String? = nil
    var identifier: String? = nil
    var title: String? = nil
    var description: String? = nil
    var containersOnly = false
    var additionalAttributes: [String] = []

    var attributes: [String] {
        var names = [String]()
        if role != nil || containersOnly { names.append(kAXRoleAttribute) }
        if identifier != nil || containersOnly { names.append(kAXIdentifierAttribute) }
        if title != nil { names.append(kAXTitleAttribute) }
        if description != nil { names.append(kAXDescriptionAttribute) }
        for name in additionalAttributes where !names.contains(name) { names.append(name) }
        return names
    }
    func matches(_ values: [String: Any]) -> Bool {
        (role == nil || values[kAXRoleAttribute] as? String == role) &&
        (identifier == nil || values[kAXIdentifierAttribute] as? String == identifier) &&
        (title == nil || values[kAXTitleAttribute] as? String == title) &&
        (description == nil || values[kAXDescriptionAttribute] as? String == description)
    }
    func canDescend(_ values: [String: Any]) -> Bool {
        guard containersOnly else { return true }
        return [kAXWindowRole, kAXGroupRole, kAXSplitGroupRole, kAXScrollAreaRole].contains(values[kAXRoleAttribute] as? String ?? "") &&
            !(values[kAXIdentifierAttribute] as? String ?? "").lowercased().contains("inspector")
    }
}

struct FinalCutAXMatch<Element> {
    let element: Element
    let path: [Element]
    let values: [String: Any]
}

/// A bounded search shared by native lookup and deterministic host-tree tests.
enum FinalCutAXSearch {
    static func find<Element>(root: Element, query: FinalCutAXQuery, maxDepth: Int = 24, maxNodes: Int = 600,
                              read: (Element, [String]) -> [String: Any], children: (Element) -> [Element],
                              equals: (Element, Element) -> Bool,
                              shouldContinue: () -> Bool, visited: () -> Void = {}) -> FinalCutAXMatch<Element>? {
        guard maxDepth >= 0, maxNodes > 0 else { return nil }
        var queue: [[Element]] = [[root]]
        var cursor = 0
        while cursor < queue.count && cursor < maxNodes && shouldContinue() {
            let path = queue[cursor], element = path[path.count - 1]
            cursor += 1; visited()
            let values = read(element, query.attributes)
            if query.matches(values) { return FinalCutAXMatch(element: element, path: path, values: values) }
            guard path.count - 1 < maxDepth, query.canDescend(values), shouldContinue() else { continue }
            for child in children(element).prefix(maxNodes - cursor) {
                guard queue.count < maxNodes else { break }
                if !path.contains(where: { equals($0, child) }) { queue.append(path + [child]) }
            }
        }
        return nil
    }
}

/// Cache only a route to one pinned control, never its title, selection or other
/// state. Every edge must still appear in a fresh parent AXChildren response.
final class FinalCutAXLookup<Element> {
    struct Statistics {
        var searches = 0
        var cacheHits = 0
        var invalidations = 0
        var visitedNodes = 0
        var pathChecks = 0
    }
    private(set) var statistics = Statistics()
    private let root: Element
    private let query: FinalCutAXQuery
    private let read: (Element, [String]) -> [String: Any]
    private let children: (Element) -> [Element]
    private let equals: (Element, Element) -> Bool
    private var path: [Element]?

    init(root: Element, query: FinalCutAXQuery, read: @escaping (Element, [String]) -> [String: Any],
         children: @escaping (Element) -> [Element], equals: @escaping (Element, Element) -> Bool) {
        self.root = root; self.query = query; self.read = read; self.children = children; self.equals = equals
    }

    func resolve(shouldContinue: () -> Bool = { !Task.isCancelled }) -> FinalCutAXMatch<Element>? {
        if let path {
            statistics.pathChecks += 1
            if mounted(path, shouldContinue: shouldContinue), let element = path.last {
                let values = read(element, query.attributes)
                if shouldContinue(), query.matches(values), query.additionalAttributes.allSatisfy({ values[$0] != nil }) {
                    statistics.cacheHits += 1
                    return FinalCutAXMatch(element: element, path: path, values: values)
                }
            }
            self.path = nil; statistics.invalidations += 1
        }
        guard shouldContinue() else { return nil }
        statistics.searches += 1
        let result = FinalCutAXSearch.find(root: root, query: query, read: read, children: children,
            equals: equals, shouldContinue: shouldContinue, visited: { self.statistics.visitedNodes += 1 })
        path = result?.path
        return result
    }

    private func mounted(_ path: [Element], shouldContinue: () -> Bool) -> Bool {
        guard let first = path.first, equals(first, root), shouldContinue() else { return false }
        for (parent, child) in zip(path, path.dropFirst()) {
            guard shouldContinue(), query.canDescend(read(parent, [kAXRoleAttribute, kAXIdentifierAttribute])),
                  children(parent).contains(where: { equals($0, child) }) else { return false }
        }
        return true
    }
}
