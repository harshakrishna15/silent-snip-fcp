import Foundation

/// Pure interpretation of the native Libraries sidebar. A revealed browser
/// project does not imply that its containing event is selected.
enum FinalCutEventSidebar {
    enum Kind { case library, event, other }
    struct Row {
        let kind: Kind
        let name: String?
        let libraryPath: String?
        let selected: Bool?
    }
    enum Failure: Error, LocalizedError, Equatable {
        case missingEvent, ambiguousEvent, unreadableSelection, conflictingSelection
        var errorDescription: String? {
            switch self {
            case .missingEvent: return "The source event is not visible in its library. Expand the library and select that event."
            case .ambiguousEvent: return "More than one event has the source event's name in this library. The destination is ambiguous."
            case .unreadableSelection, .conflictingSelection:
                return "Final Cut Pro's Libraries sidebar selection could not be verified consistently. Select the source event before trying again."
            }
        }
    }

    static func kind(glyphs: [String], hasLibraryPath: Bool, disclosureLevel: Int?, knownCollection: Bool = false) -> Kind {
        let names = glyphs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if hasLibraryPath || names.contains(where: { $0.hasSuffix("SidebarGlyph Library") }) { return .library }
        if names.contains(where: { $0.hasSuffix("SidebarGlyph Event") }) { return .event }
        if knownCollection { return .other }
        // A new unreadable top-level header cannot inherit the preceding scope.
        return disclosureLevel == nil || disclosureLevel == 0 ? .library : .other
    }

    static func eventIndex(rows: [Row], libraryURL: URL, eventName: String) throws -> Int {
        let expected = canonicalPath(libraryURL.path)
        var scope: String?
        var matches: [Int] = []
        for (index, row) in rows.enumerated() {
            switch row.kind {
            case .library:
                // An unreadable header must end the previous library's scope.
                scope = row.libraryPath.flatMap(canonicalPath)
            case .event:
                if scope != nil, scope == expected, row.name == eventName { matches.append(index) }
            case .other: break
            }
        }
        guard !matches.isEmpty else { throw Failure.missingEvent }
        guard matches.count == 1 else { throw Failure.ambiguousEvent }
        return matches[0]
    }

    static func libraryIsSelected(rows: [Row], libraryURL: URL, selectedRows: [Int]?) throws -> Bool {
        let expected = canonicalPath(libraryURL.path)
        let matches = rows.indices.filter { index in
            guard case .library = rows[index].kind, let path = rows[index].libraryPath,
                  let canonical = canonicalPath(path) else { return false }
            return canonical == expected
        }
        guard matches.count == 1 else { return false }
        return try isSelected(matches[0], rows: rows, selectedRows: selectedRows)
    }

    static func isSelected(_ index: Int, rows: [Row], selectedRows: [Int]?) throws -> Bool {
        guard rows.indices.contains(index) else { throw Failure.unreadableSelection }
        let flags = rows.indices.filter { rows[$0].selected == true }
        if let selectedRows {
            guard Set(selectedRows).count == selectedRows.count,
                  selectedRows.allSatisfy({ rows.indices.contains($0) }) else { throw Failure.unreadableSelection }
            guard flags.allSatisfy(selectedRows.contains),
                  selectedRows.allSatisfy({ rows[$0].selected != false }) else { throw Failure.conflictingSelection }
            return selectedRows == [index]
        }
        guard rows.allSatisfy({ $0.selected != nil }) else { throw Failure.unreadableSelection }
        return flags == [index]
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var value = URL(fileURLWithPath: path).standardizedFileURL.path
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        guard URL(fileURLWithPath: value).pathExtension.lowercased() == "fcpbundle" else { return nil }
        return value
    }
}
