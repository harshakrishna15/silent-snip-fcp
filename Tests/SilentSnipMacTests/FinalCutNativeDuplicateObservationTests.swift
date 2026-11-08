import XCTest
@testable import SilentSnipMac

final class FinalCutNativeDuplicateObservationTests: XCTestCase {
    private typealias Model = FinalCutNativeDuplicateObservation
    private typealias Entry = Model.Entry

    func testNormalSingleAdditionIsIdentifiedFromReadableEntryFlags() throws {
        let after = entries(["Original", "Existing", "Original 1"], selected: [2])
        XCTAssertEqual(try candidate(after), 2)
    }

    func testReorderedRebuiltRowsNeedNoPreviousAXReferences() throws {
        // Inputs intentionally contain no AX object identity. Every row and its
        // container may have been rebuilt during the native insertion/sort.
        let after = entries(["Existing", "Original 1", "Original"], selected: [1])
        XCTAssertEqual(try candidate(after), 1)
    }

    func testAggregateSelectionCanSupplyUnreadableIndividualFlags() throws {
        let after = [Entry(name: "Existing", selected: false), Entry(name: "Original 1", selected: nil),
                     Entry(name: "Original", selected: nil)]
        XCTAssertEqual(try candidate(after, selectedIndices: [1]), 1)
    }

    func testExistingDuplicateNamesMustKeepTheirExactMultiplicities() throws {
        let before = ["Original", "Existing", "Existing"]
        let after = entries(["Existing", "Original 1", "Original", "Existing"], selected: [1])
        XCTAssertEqual(try Model.candidateIndex(beforeNames: before, after: after, selectedIndices: nil,
            snapshotComplete: true, sameScope: true), 1)
    }

    func testIncompleteOrDifferentEventSnapshotsCannotAuthorizeACandidate() throws {
        let after = entries(["Original", "Existing", "Original 1"], selected: [2])
        XCTAssertThrowsError(try Model.candidateIndex(beforeNames: ["Original", "Existing"], after: after,
            selectedIndices: [2], snapshotComplete: false, sameScope: true)) { XCTAssertEqual($0 as? Model.Failure, .incompleteSnapshot) }
        XCTAssertThrowsError(try Model.candidateIndex(beforeNames: ["Original", "Existing"], after: after,
            selectedIndices: [2], snapshotComplete: true, sameScope: false)) { XCTAssertEqual($0 as? Model.Failure, .changedScope) }
    }

    func testMissingOrEmptyNamesAreRejected() throws {
        XCTAssertThrowsError(try Model.candidateIndex(beforeNames: [], after: [Entry(name: "New", selected: true)],
            selectedIndices: [0], snapshotComplete: true, sameScope: true))
        for name in ["", " ", "\n"] {
            XCTAssertThrowsError(try candidate(entries(["Original", "Existing", name], selected: [2])))
        }
    }

    func testNoAdditionOrTwoAdditionsCannotBeAccepted() throws {
        XCTAssertThrowsError(try candidate(entries(["Original", "Existing"], selected: [0])))
        XCTAssertThrowsError(try candidate(entries(["Original", "Existing", "New 1", "New 2"], selected: [2])))
    }

    func testRemovedRenamedOrDuplicatedExistingNameCannotMasqueradeAsOneAddition() throws {
        for names in [["Original", "New 1", "New 2"], ["Renamed", "Existing", "New"],
                      ["Original", "Existing", "Existing"], ["Original", "New", "New"]] {
            XCTAssertThrowsError(try candidate(entries(names, selected: [2])))
        }
    }

    func testOriginalOrMultipleSelectionCannotAuthorizeTheNewProject() throws {
        for selected in [[], [0], [0, 2]] {
            XCTAssertThrowsError(try candidate(entries(["Original", "Existing", "New"], selected: selected))) {
                XCTAssertEqual($0 as? Model.Failure, .candidateNotSelected)
            }
        }
    }

    func testAggregateSelectionRejectsDuplicatesInvalidIndicesAndConflicts() throws {
        let after = entries(["Original", "Existing", "New"], selected: [2])
        for selection in [[2, 2], [-1], [3]] {
            XCTAssertThrowsError(try candidate(after, selectedIndices: selection)) {
                XCTAssertEqual($0 as? Model.Failure, .invalidSelectionIndices)
            }
        }
        for selection in [[], [0], [0, 2]] {
            XCTAssertThrowsError(try candidate(after, selectedIndices: selection)) {
                XCTAssertEqual($0 as? Model.Failure, .conflictingSelection)
            }
        }
    }

    func testAbsentAggregateRequiresEveryIndividualFlagToBeReadable() throws {
        let after = [Entry(name: "Original", selected: nil), Entry(name: "Existing", selected: false),
                     Entry(name: "New", selected: true)]
        XCTAssertThrowsError(try candidate(after)) { XCTAssertEqual($0 as? Model.Failure, .unreadableSelection) }
        XCTAssertEqual(try candidate(after, selectedIndices: [2]), 2)
    }

    func testFooterParsesCompleteNativeSelectionAndItemCountStrings() {
        for (text, count) in [("1 of 3 selected, 5m 0.23s", 3), ("1 of 1 selected,12s", 1),
                              ("0 of 4 selected, 0s", 4), ("2 of 3 selected, 1h 2m 3.5s", 3),
                              ("3 items", 3), ("1 item", 1), ("0 items", 0)] {
            XCTAssertEqual(Model.itemCount(inFooter: text), count, text)
        }
    }

    func testFooterRejectsAmbiguousTruncatedAndGarbledText() {
        for text in ["", "3", "3 clips", "1 items", "2 item", "3 items selected", "3 items, 12s",
                     "1 of 3 selected", "1 of 3 selected,", "1 of 3 selected, unknown", "1 of 3 selected, 5m junk",
                     "1 of 3 selected, 5m 2m", "2 of 1 selected,12s", "1 of many selected,12s",
                     "prefix 1 of 3 selected,12s", "1 of 3 selected,12s trailing", "1 of 3 selected,12s\n3 items",
                     "1 of 999999999999999999999999999999999999 selected,12s"] {
            XCTAssertNil(Model.itemCount(inFooter: text), text)
        }
    }

    func testFooterUsesReadableAlternativesWithoutDoubleCountingOneNode() {
        XCTAssertEqual(Model.reportedItemCount(footerTexts: [["", "", "1 of 3 selected, 60.00s"]]), 3)
        XCTAssertEqual(Model.reportedItemCount(footerTexts: [["3 items", "3 items", ""], ["Info"]]), 3)
        XCTAssertEqual(Model.reportedItemCount(footerTexts: [["3 items", "1 of 3 selected, 60.00s"]]), 3)
        XCTAssertNil(Model.reportedItemCount(footerTexts: [["3 items", "4 items"]]))
        XCTAssertNil(Model.reportedItemCount(footerTexts: [["3 items"], ["3 items"]]))
        XCTAssertNil(Model.reportedItemCount(footerTexts: [["", "Info"]]))
    }

    private func entries(_ names: [String], selected: [Int]) -> [Entry] {
        names.enumerated().map { Entry(name: $0.element, selected: selected.contains($0.offset)) }
    }

    private func candidate(_ after: [Entry], selectedIndices: [Int]? = nil) throws -> Int {
        try Model.candidateIndex(beforeNames: ["Original", "Existing"], after: after,
            selectedIndices: selectedIndices, snapshotComplete: true, sameScope: true)
    }
}
