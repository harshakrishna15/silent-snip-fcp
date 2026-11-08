import Foundation
import XCTest
@testable import SilentSnipMac

final class FinalCutEventSidebarTests: XCTestCase {
    private let library = URL(fileURLWithPath: "/fixtures/Cutdown Integration.fcpbundle/")
    private func lib(_ path: String? = "/fixtures/Cutdown Integration.fcpbundle", selected: Bool? = false) -> FinalCutEventSidebar.Row {
        .init(kind: .library, name: "Cutdown Integration", libraryPath: path, selected: selected)
    }
    private func event(_ name: String = "10-21-26", selected: Bool? = false) -> FinalCutEventSidebar.Row {
        .init(kind: .event, name: name, libraryPath: nil, selected: selected)
    }

    func testNativeGlyphsDistinguishEventsFromUnreadableLibraryBoundaries() {
        if case .library = FinalCutEventSidebar.kind(glyphs: ["F Events SidebarGlyph Library"], hasLibraryPath: false, disclosureLevel: nil) {} else { XCTFail() }
        if case .event = FinalCutEventSidebar.kind(glyphs: ["F Events SidebarGlyph Event"], hasLibraryPath: false, disclosureLevel: 0) {} else { XCTFail() }
        if case .event = FinalCutEventSidebar.kind(glyphs: [" \nF Events SidebarGlyph Event\n"], hasLibraryPath: false, disclosureLevel: 0) {} else { XCTFail() }
        if case .library = FinalCutEventSidebar.kind(glyphs: [], hasLibraryPath: false, disclosureLevel: 0) {} else { XCTFail() }
        if case .library = FinalCutEventSidebar.kind(glyphs: [], hasLibraryPath: false, disclosureLevel: nil) {} else { XCTFail() }
        if case .other = FinalCutEventSidebar.kind(glyphs: [], hasLibraryPath: false, disclosureLevel: nil, knownCollection: true) {} else { XCTFail() }
        if case .other = FinalCutEventSidebar.kind(glyphs: [], hasLibraryPath: false, disclosureLevel: 1) {} else { XCTFail() }
    }

    func testRevealCanLeaveLibrarySelectedWhileExactEventIsAvailable() throws {
        let rows = [lib(selected: true), event()]
        let index = try FinalCutEventSidebar.eventIndex(rows: rows, libraryURL: library, eventName: "10-21-26")
        XCTAssertEqual(index, 1)
        XCTAssertFalse(try FinalCutEventSidebar.isSelected(index, rows: rows, selectedRows: [0]))
        XCTAssertTrue(try FinalCutEventSidebar.libraryIsSelected(rows: rows, libraryURL: library, selectedRows: [0]))
        let after = [lib(), event(selected: true)]
        XCTAssertTrue(try FinalCutEventSidebar.isSelected(index, rows: after, selectedRows: [1]))
        XCTAssertFalse(try FinalCutEventSidebar.libraryIsSelected(rows: after, libraryURL: library, selectedRows: [1]))
    }

    func testSelectionMayUseAggregateWhenIndividualFlagIsUnavailable() throws {
        let rows = [lib(), event(selected: nil)]
        XCTAssertTrue(try FinalCutEventSidebar.isSelected(1, rows: rows, selectedRows: [1]))
        XCTAssertThrowsError(try FinalCutEventSidebar.isSelected(1, rows: rows, selectedRows: nil))
        XCTAssertThrowsError(try FinalCutEventSidebar.isSelected(1, rows: [lib(), event()], selectedRows: [1]))
        XCTAssertThrowsError(try FinalCutEventSidebar.isSelected(1, rows: rows, selectedRows: [1, 1]))
        XCTAssertThrowsError(try FinalCutEventSidebar.isSelected(1, rows: rows, selectedRows: [3]))
    }

    func testExactLibraryScopeAndUniqueEventAreRequired() throws {
        let rows = [lib("/other/Same.fcpbundle"), event(selected: true), lib(), event()]
        XCTAssertEqual(try FinalCutEventSidebar.eventIndex(rows: rows, libraryURL: library, eventName: "10-21-26"), 3)
        XCTAssertFalse(try FinalCutEventSidebar.isSelected(3, rows: rows, selectedRows: nil))
        XCTAssertFalse(try FinalCutEventSidebar.libraryIsSelected(rows: rows, libraryURL: library, selectedRows: nil))
        XCTAssertThrowsError(try FinalCutEventSidebar.eventIndex(rows: [lib(), event(), event()], libraryURL: library, eventName: "10-21-26"))
        XCTAssertThrowsError(try FinalCutEventSidebar.eventIndex(rows: [lib("/other/Same.fcpbundle"), event()], libraryURL: library, eventName: "10-21-26"))
        XCTAssertThrowsError(try FinalCutEventSidebar.eventIndex(rows: [lib(), event("Different")], libraryURL: library, eventName: "10-21-26"))
    }

    func testUnreadableNextLibraryNeverInheritsPreviousLibraryAuthority() throws {
        let invalidPaths: [String?] = [nil, "relative.fcpbundle", "/fixtures/not-a-library"]
        for path in invalidPaths {
            let rows = [lib(), event("Other"), lib(path), event(selected: true)]
            XCTAssertThrowsError(try FinalCutEventSidebar.eventIndex(rows: rows, libraryURL: library, eventName: "10-21-26"))
        }
        let rows = [lib(), FinalCutEventSidebar.Row(kind: .other, name: "10-21-26", libraryPath: nil, selected: true)]
        XCTAssertThrowsError(try FinalCutEventSidebar.eventIndex(rows: rows, libraryURL: library, eventName: "10-21-26"))
        let unknown = FinalCutEventSidebar.Row(kind: FinalCutEventSidebar.kind(glyphs: [], hasLibraryPath: false, disclosureLevel: nil), name: nil, libraryPath: nil, selected: false)
        XCTAssertThrowsError(try FinalCutEventSidebar.eventIndex(rows: [lib(), unknown, event()], libraryURL: library, eventName: "10-21-26"))
    }

    func testConflictingOrMultipleSelectionDoesNotAuthorizeTheEvent() throws {
        let rows = [lib(selected: true), event(selected: true)]
        XCTAssertFalse(try FinalCutEventSidebar.isSelected(1, rows: rows, selectedRows: nil))
        XCTAssertFalse(try FinalCutEventSidebar.isSelected(1, rows: rows, selectedRows: [0, 1]))
        XCTAssertThrowsError(try FinalCutEventSidebar.isSelected(1, rows: rows, selectedRows: [1]))
    }
}
