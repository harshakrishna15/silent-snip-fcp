import ApplicationServices
import Foundation

/// One import/browser observation. Values and children come from the same
/// batched read; field editors and other leaf controls are never traversed.
struct FinalCutImportObservation<Element> {
    struct Control {
        let element: Element
        let role: String
        let title: String?
        let value: String?
        let description: String?

        var text: [String] { [title, value, description].compactMap { $0 }.filter { !$0.isEmpty } }
    }

    enum CaptureError: Error { case incomplete }
    let controls: [Control]

    static func capture(root: Element, read: (Element) throws -> (Control, [Element]),
                        shouldContinue: () -> Bool, maxNodes: Int = 600, maxDepth: Int = 12) throws -> Self {
        let leaves = Set([kAXTextFieldRole, kAXTextAreaRole, kAXStaticTextRole, kAXButtonRole, kAXImageRole])
        var queue: [(Element, Int)] = [(root, 0)]
        var cursor = 0
        var result: [Control] = []
        while cursor < queue.count {
            try Task.checkCancellation()
            guard cursor < maxNodes, shouldContinue() else { throw CaptureError.incomplete }
            let (element, depth) = queue[cursor]; cursor += 1
            let (control, children) = try read(element)
            result.append(control)
            guard !leaves.contains(control.role), !children.isEmpty else { continue }
            guard depth < maxDepth, children.count <= maxNodes - queue.count else { throw CaptureError.incomplete }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return Self(controls: result)
    }

    func containsProject(named name: String) -> Bool {
        controls.contains { [kAXImageRole, kAXTextFieldRole].contains($0.role) && $0.text.contains(name) }
    }

    var buttons: [Control] { controls.filter { $0.role == kAXButtonRole } }

    var dialog: FinalCutImportDialog {
        FinalCutImportDialog(title: controls.first?.title ?? "Untitled Final Cut dialog",
            text: controls.filter { [kAXStaticTextRole, kAXRowRole, kAXTextAreaRole].contains($0.role) }.flatMap(\.text),
            buttons: buttons.compactMap(\.title))
    }
}

/// Retain only a successful organizer route for this import operation. Every
/// reuse checks fresh parent-child edges and attributes; absent routes are not
/// cached, and a rebuilt browser is discovered normally on the next poll.
final class FinalCutImportBrowserLookups<Element> {
    private let lookups: [FinalCutAXLookup<Element>]
    private var preferred: Int?
    private(set) var exactTimelineSkips = 0
    private(set) var lastResolutionComplete = true

    init(root: Element, read: @escaping (Element, [String]) -> [String: Any],
         children: @escaping (Element) -> [Element], equals: @escaping (Element, Element) -> Bool) {
        lookups = ["organizer", "Organizer filmlist scroll view"].map { description in
            FinalCutAXLookup(root: root, query: .init(role: kAXScrollAreaRole, description: description, containersOnly: true),
                read: read, children: children, equals: equals)
        }
    }

    func resolve(currentProject: String?, importedProject: String,
                 shouldContinue: () -> Bool) -> Element? {
        lastResolutionComplete = true
        if currentProject == importedProject { exactTimelineSkips += 1; return nil }
        let indices = preferred.map { chosen in [chosen] + lookups.indices.filter { $0 != chosen } } ?? Array(lookups.indices)
        for index in indices {
            if let found = lookups[index].resolve(maxDepth: 24, maxNodes: 600, shouldContinue: shouldContinue) {
                preferred = index
                return found.element
            }
            guard shouldContinue() else { lastResolutionComplete = false; return nil }
        }
        preferred = nil
        return nil
    }

    var counters: [String: Int] {
        let stats = lookups.map(\.statistics)
        return ["browser.searches": stats.reduce(0) { $0 + $1.searches },
            "browser.cacheHits": stats.reduce(0) { $0 + $1.cacheHits },
            "browser.invalidations": stats.reduce(0) { $0 + $1.invalidations },
            "browser.visitedNodes": stats.reduce(0) { $0 + $1.visitedNodes },
            "browser.pathChecks": stats.reduce(0) { $0 + $1.pathChecks },
            "browser.exactTimelineSkips": exactTimelineSkips]
    }
}
