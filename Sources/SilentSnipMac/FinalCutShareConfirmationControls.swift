import ApplicationServices
import Foundation

/// Keep a route to Next only inside the exact currently observed Share panel.
/// Every use rereads enabled state and proves all retained parent-child edges.
final class FinalCutShareConfirmationControls<Element> {
    private let read: (Element, [String]) -> [String: Any]
    private let children: (Element) -> [Element]
    private let equals: (Element, Element) -> Bool
    private var panel: Element?
    private var lookup: FinalCutAXLookup<Element>?
    private var retired: [FinalCutAXLookup<Element>.Statistics] = []

    init(read: @escaping (Element, [String]) -> [String: Any], children: @escaping (Element) -> [Element],
         equals: @escaping (Element, Element) -> Bool) {
        self.read = read; self.children = children; self.equals = equals
    }

    func next(in panel: Element, shouldContinue: () -> Bool) -> Element? {
        if self.panel.map({ !equals($0, panel) }) ?? true {
            if let lookup { retired.append(lookup.statistics) }
            self.panel = panel
            lookup = FinalCutAXLookup(root: panel,
                query: .init(role: kAXButtonRole, title: "Next…", additionalAttributes: [kAXEnabledAttribute]),
                read: read, children: children, equals: equals)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        guard let match = lookup?.resolve(maxDepth: 12, maxNodes: 350,
            shouldContinue: { shouldContinue() && ProcessInfo.processInfo.systemUptime < deadline }),
              (match.values[kAXEnabledAttribute] as? NSNumber)?.boolValue == true else { return nil }
        return match.element
    }

    var counters: [String: Int] {
        let all = retired + (lookup.map { [$0.statistics] } ?? [])
        return ["confirmation.searches": all.reduce(0) { $0 + $1.searches },
            "confirmation.cacheHits": all.reduce(0) { $0 + $1.cacheHits },
            "confirmation.invalidations": all.reduce(0) { $0 + $1.invalidations },
            "confirmation.visitedNodes": all.reduce(0) { $0 + $1.visitedNodes },
            "confirmation.pathChecks": all.reduce(0) { $0 + $1.pathChecks }]
    }
}
