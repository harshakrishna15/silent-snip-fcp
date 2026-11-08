import Foundation

/// An AX reference can be rebuilt while Final Cut inserts or sorts a project.
/// Recognize one semantic addition only inside a separately verified, complete
/// event snapshot. This observation authorizes no duplication or timeline edit.
enum FinalCutNativeDuplicateObservation {
    struct Entry: Equatable {
        let name: String
        let selected: Bool?
    }

    enum Failure: Error, LocalizedError, Equatable {
        case incompleteSnapshot, changedScope, invalidNames
        case unexpectedCount(expected: Int, actual: Int)
        case existingProjectsChanged, ambiguousAddition
        case invalidSelectionIndices, unreadableSelection, conflictingSelection, candidateNotSelected

        var errorDescription: String? {
            switch self {
            case .incompleteSnapshot: return "The project browser snapshot is incomplete; its reported item count must match every observed entry."
            case .changedScope: return "The project browser is no longer in the exact source library and event."
            case .invalidNames: return "The project browser has no baseline entries or contains an empty project name."
            case .unexpectedCount(let expected, let actual): return "The project browser contains \(actual) entries; exactly \(expected) were expected after one duplication."
            case .existingProjectsChanged: return "Existing project names or their multiplicities changed during duplication."
            case .ambiguousAddition: return "One uniquely named new project, absent from the baseline, could not be identified."
            case .invalidSelectionIndices: return "The project browser's selected-entry indices are duplicated or out of bounds."
            case .unreadableSelection: return "The project browser selection is unreadable."
            case .conflictingSelection: return "The project browser's aggregate selection conflicts with its readable entry flags."
            case .candidateNotSelected: return "The one new project is not the browser's sole selected entry."
            }
        }
    }

    static func candidateIndex(beforeNames: [String], after: [Entry], selectedIndices: [Int]?,
                               snapshotComplete: Bool, sameScope: Bool) throws -> Int {
        guard snapshotComplete else { throw Failure.incompleteSnapshot }
        guard sameScope else { throw Failure.changedScope }
        guard !beforeNames.isEmpty,
              (beforeNames + after.map(\.name)).allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw Failure.invalidNames
        }
        guard after.count == beforeNames.count + 1 else {
            throw Failure.unexpectedCount(expected: beforeNames.count + 1, actual: after.count)
        }
        let beforeCounts = Dictionary(grouping: beforeNames, by: { $0 }).mapValues(\.count)
        let afterCounts = Dictionary(grouping: after.map(\.name), by: { $0 }).mapValues(\.count)
        guard beforeCounts.allSatisfy({ afterCounts[$0.key] == $0.value }) else {
            throw Failure.existingProjectsChanged
        }
        let additions = after.indices.filter { beforeCounts[after[$0].name] == nil }
        guard additions.count == 1, let candidate = additions.first,
              afterCounts[after[candidate].name] == 1 else { throw Failure.ambiguousAddition }

        let selected: [Int]
        if let selectedIndices {
            guard Set(selectedIndices).count == selectedIndices.count,
                  selectedIndices.allSatisfy(after.indices.contains) else { throw Failure.invalidSelectionIndices }
            guard after.indices.filter({ after[$0].selected == true }).allSatisfy(selectedIndices.contains),
                  selectedIndices.allSatisfy({ after[$0].selected != false }) else { throw Failure.conflictingSelection }
            selected = selectedIndices
        } else {
            guard after.allSatisfy({ $0.selected != nil }) else { throw Failure.unreadableSelection }
            selected = after.indices.filter { after[$0].selected == true }
        }
        guard selected == [candidate] else { throw Failure.candidateNotSelected }
        return candidate
    }

    /// Parse only complete native count strings, never a number from arbitrary
    /// footer text. Duration is recognized but is not used as project identity.
    static func itemCount(inFooter text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 256 else { return nil }
        func groups(_ pattern: String) -> [String]? {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.range.length == text.utf16.count else { return nil }
            return (1..<match.numberOfRanges).compactMap { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
        }
        if let values = groups("^([0-9]+) (item|items)$"), values.count == 2,
           let count = Int(values[0]), (count == 1 ? values[1] == "item" : values[1] == "items") { return count }
        let number = "[0-9]+(?:\\.[0-9]+)?"
        let duration = "(?:\(number)h(?:\\s*\(number)m)?(?:\\s*\(number)s)?|\(number)m(?:\\s*\(number)s)?|\(number)s)"
        guard let values = groups("^([0-9]+) of ([0-9]+) selected,\\s*\(duration)$"), values.count == 2,
              let selected = Int(values[0]), let total = Int(values[1]), selected <= total else { return nil }
        return total
    }

    /// Final Cut can expose a static footer through value, title or description.
    /// Empty attributes must not hide a readable alternative. Multiple textual
    /// attributes on one footer describe one observation, not extra footers.
    static func reportedItemCount(footerTexts: [[String]]) -> Int? {
        let counts = footerTexts.compactMap { texts -> Set<Int>? in
            let values = Set(texts.compactMap(itemCount(inFooter:)))
            return values.isEmpty ? nil : values
        }
        guard counts.count == 1, counts[0].count == 1 else { return nil }
        return counts[0].first
    }
}
