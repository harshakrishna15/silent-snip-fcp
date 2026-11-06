import ApplicationServices
import Foundation

/// Retains only successful routes inside a native Workflow window. Window
/// enumeration and every route edge remain fresh; an unsuccessful window scan
/// never exempts that window from a later scan.
final class WorkflowReviewAXLookups<Element> {
    struct Statistics {
        var searches = 0
        var cacheHits = 0
        var invalidations = 0
        var visitedNodes = 0
        var pathChecks = 0
        var mainWindowSkips = 0
    }

    private struct Entry {
        let window: Element
        let marker: FinalCutAXLookup<Element>
        var actions: [(identifier: String, lookup: FinalCutAXLookup<Element>)] = []
    }

    private let read: (Element, [String]) -> [String: Any]
    private let children: (Element) -> [Element]
    private let equals: (Element, Element) -> Bool
    private var markerIdentifier: String?
    private var entries: [Entry] = []
    private(set) var statistics = Statistics()

    init(read: @escaping (Element, [String]) -> [String: Any], children: @escaping (Element) -> [Element],
         equals: @escaping (Element, Element) -> Bool) {
        self.read = read; self.children = children; self.equals = equals
    }

    func matchingWindows(_ candidates: [Element], excluding mainWindow: Element, markerIdentifier: String,
                         shouldContinue: () -> Bool = { !Task.isCancelled }) -> [Element] {
        let windows = WorkflowReviewWindowIdentity.distinct(candidates, equals: equals)
        entries.removeAll { entry in !windows.contains(where: { equals($0, entry.window) }) }
        let matches = windows.filter {
            self.matches($0, excluding: mainWindow, markerIdentifier: markerIdentifier, shouldContinue: shouldContinue)
        }
        // A deadline/cancellation part way through enumeration must not turn a
        // pair of matching windows into an apparently unique partial result.
        return shouldContinue() ? matches : []
    }

    func matches(_ window: Element, excluding mainWindow: Element, markerIdentifier: String,
                 shouldContinue: () -> Bool = { !Task.isCancelled }) -> Bool {
        // This is the exact, already-proven project workspace, not a title or
        // role heuristic. The floating Workflow view cannot be that window.
        guard !equals(window, mainWindow) else { statistics.mainWindowSkips += 1; return false }
        if self.markerIdentifier != markerIdentifier {
            self.markerIdentifier = markerIdentifier
            entries.removeAll()
        }
        let shell = read(window, [kAXRoleAttribute, kAXIdentifierAttribute])
        guard shell[kAXRoleAttribute] as? String != kAXSheetRole,
              !["save-panel", "open-panel", "GoToWindow"].contains(shell[kAXIdentifierAttribute] as? String ?? "") else {
            entries.removeAll { equals($0.window, window) }
            return false
        }
        let index = entries.firstIndex { equals($0.window, window) }
        let lookup = index.map { entries[$0].marker } ?? makeLookup(window, identifier: markerIdentifier)
        guard resolve(lookup, shouldContinue: shouldContinue) != nil else {
            if let index { entries.remove(at: index) }
            return false
        }
        if index == nil {
            // AXWindows is bounded to 32 by the caller, with focused/retained
            // references appended. Bound direct currentSheet lookups as well.
            if entries.count >= 34 { entries.removeFirst() }
            entries.append(Entry(window: window, marker: lookup))
        }
        return true
    }

    func action(in window: Element, identifier: String,
                shouldContinue: () -> Bool = { !Task.isCancelled }) -> FinalCutAXMatch<Element>? {
        // Only a window matched in this view's current scan is eligible.
        guard let index = entries.firstIndex(where: { equals($0.window, window) }) else { return nil }
        let actionIndex = entries[index].actions.firstIndex { $0.identifier == identifier }
        let lookup = actionIndex.map { entries[index].actions[$0].lookup }
            ?? makeLookup(window, identifier: identifier, additionalAttributes: [kAXEnabledAttribute])
        let match = resolve(lookup, shouldContinue: shouldContinue)
        if match == nil {
            if let actionIndex { entries[index].actions.remove(at: actionIndex) }
        } else if actionIndex == nil {
            if entries[index].actions.count >= 4 { entries[index].actions.removeFirst() }
            entries[index].actions.append((identifier, lookup))
        }
        return match
    }

    private func makeLookup(_ window: Element, identifier: String, additionalAttributes: [String] = []) -> FinalCutAXLookup<Element> {
        FinalCutAXLookup(root: window, query: .init(role: kAXButtonRole, identifier: identifier,
            additionalAttributes: additionalAttributes), read: read, children: children, equals: equals)
    }

    private func resolve(_ lookup: FinalCutAXLookup<Element>, shouldContinue: () -> Bool) -> FinalCutAXMatch<Element>? {
        let before = lookup.statistics
        let result = lookup.resolve(maxDepth: 24, maxNodes: 3000, shouldContinue: shouldContinue)
        let after = lookup.statistics
        statistics.searches += after.searches - before.searches
        statistics.cacheHits += after.cacheHits - before.cacheHits
        statistics.invalidations += after.invalidations - before.invalidations
        statistics.visitedNodes += after.visitedNodes - before.visitedNodes
        statistics.pathChecks += after.pathChecks - before.pathChecks
        return result
    }
}
