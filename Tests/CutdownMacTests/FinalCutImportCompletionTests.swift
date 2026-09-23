import XCTest
@testable import CutdownMac

final class FinalCutImportCompletionTests: XCTestCase {
    func testHiddenBrowserCanBeRevealedBeforeTheImportedProjectAppears() {
        var reveal = FinalCutImportBrowserReveal()
        var readiness = FinalCutImportReadiness()
        XCTAssertFalse(reveal.observe(projectVisible: false, originalProjectCurrent: true, hasDialog: false, elapsed: 0))
        XCTAssertFalse(readiness.observe(projectVisible: false, hasDialog: false, elapsed: 1))
        XCTAssertTrue(reveal.observe(projectVisible: false, originalProjectCurrent: true, hasDialog: false, elapsed: 1))
        XCTAssertFalse(reveal.observe(projectVisible: false, originalProjectCurrent: true, hasDialog: false, elapsed: 2), "Reveal only once while import continues")
        XCTAssertFalse(readiness.observe(projectVisible: true, hasDialog: false, elapsed: 2))
        XCTAssertTrue(readiness.observe(projectVisible: true, hasDialog: false, elapsed: 3))
    }

    func testBrowserRevealWaitsForDialogsAndOriginalProjectIdentity() {
        var reveal = FinalCutImportBrowserReveal()
        XCTAssertFalse(reveal.observe(projectVisible: false, originalProjectCurrent: true, hasDialog: false, elapsed: 0))
        XCTAssertFalse(reveal.observe(projectVisible: false, originalProjectCurrent: true, hasDialog: true, elapsed: 1))
        XCTAssertFalse(reveal.observe(projectVisible: false, originalProjectCurrent: true, hasDialog: false, elapsed: 2))
        XCTAssertFalse(reveal.observe(projectVisible: false, originalProjectCurrent: false, hasDialog: false, elapsed: 3))
        XCTAssertFalse(reveal.observe(projectVisible: false, originalProjectCurrent: true, hasDialog: false, elapsed: 4))
        XCTAssertFalse(reveal.observe(projectVisible: true, originalProjectCurrent: true, hasDialog: false, elapsed: 5))
        XCTAssertTrue(reveal.observe(projectVisible: false, originalProjectCurrent: true, hasDialog: false, elapsed: 6))
    }

    private let notice = "Your XML was imported with the following warnings. Depending on the warnings, you may want to modify the XML, then import it again."

    func testAcknowledgesOnlyTheCompletedWarningForOurDeliveredFile() {
        XCTAssertTrue(FinalCutImportDialog(title: "Import XML", text: [notice, "Cutdown.fcpxml", "A parameter was ignored"], buttons: ["OK"])
            .isCompletedWarning(for: "Cutdown.fcpxml"))
        for dialog in [
            FinalCutImportDialog(title: "Import XML", text: [notice, "Other.fcpxml"], buttons: ["OK"]),
            FinalCutImportDialog(title: "Import XML", text: [notice, "Cutdown.fcpxml.bak"], buttons: ["OK"]),
            FinalCutImportDialog(title: "Import XML", text: ["Import failed", "Cutdown.fcpxml"], buttons: ["OK"]),
            FinalCutImportDialog(title: "Import XML", text: [notice, "Cutdown.fcpxml"], buttons: ["Replace", "Cancel"]),
            FinalCutImportDialog(title: "Import XML", text: [notice, "Cutdown.fcpxml"], buttons: ["OK", "Cancel"]),
            FinalCutImportDialog(title: "Missing Files", text: [notice, "Cutdown.fcpxml"], buttons: ["OK"])
        ] { XCTAssertFalse(dialog.isCompletedWarning(for: "Cutdown.fcpxml")) }
    }

    func testReplacementConfirmationRequiresExactLibraryAndButtons() {
        let text = "Final Cut Pro has received an XML document that is about to replace existing items with matching names in the library “Fixture”. Do you want to replace them?"
        let dialog = FinalCutImportDialog(title: "", text: [text], buttons: ["Keep Both", "Replace", "Cancel"])
        XCTAssertTrue(dialog.isReplacementConfirmation(libraryName: "Fixture"))
        XCTAssertFalse(dialog.isReplacementConfirmation(libraryName: "Other"))
        XCTAssertFalse(FinalCutImportDialog(title: "", text: [text], buttons: ["Replace", "Cancel"])
            .isReplacementConfirmation(libraryName: "Fixture"))
        let failure = XMLProjectApplyFailure(cause: CocoaError(.fileReadUnknown), outputURL: URL(fileURLWithPath: "/tmp/Result/Cutdown.fcpxml"),
                                            importAttempted: true, replacingOriginal: true)
        XCTAssertFalse(failure.localizedDescription.contains("original project is unchanged"))
        XCTAssertTrue(failure.localizedDescription.contains("Before-Cuts.fcpxml"))
    }

    func testDeliveryWithoutVisibleProjectDoesNotCountAsImportCompletion() {
        var readiness = FinalCutImportReadiness()
        XCTAssertFalse(readiness.observe(projectVisible: false, hasDialog: false, elapsed: 0))
        XCTAssertFalse(readiness.observe(projectVisible: false, hasDialog: false, elapsed: 20))
        XCTAssertFalse(readiness.observe(projectVisible: true, hasDialog: false, elapsed: 21))
        XCTAssertTrue(readiness.observe(projectVisible: true, hasDialog: false, elapsed: 22))
    }

    func testLateDialogResetsReadinessEvenWhenResultAlreadyExists() {
        var readiness = FinalCutImportReadiness()
        XCTAssertFalse(readiness.observe(projectVisible: true, hasDialog: false, elapsed: 0))
        XCTAssertFalse(readiness.observe(projectVisible: true, hasDialog: true, elapsed: 0.5))
        XCTAssertFalse(readiness.observe(projectVisible: true, hasDialog: true, elapsed: 10))
        XCTAssertFalse(readiness.observe(projectVisible: true, hasDialog: false, elapsed: 11))
        XCTAssertFalse(readiness.observe(projectVisible: true, hasDialog: false, elapsed: 11.2))
        XCTAssertTrue(readiness.observe(projectVisible: true, hasDialog: false, elapsed: 12))
    }

    func testMissingProjectResetsTheQuietInterval() {
        var readiness = FinalCutImportReadiness()
        XCTAssertFalse(readiness.observe(projectVisible: true, hasDialog: false, elapsed: 0))
        XCTAssertFalse(readiness.observe(projectVisible: false, hasDialog: false, elapsed: 0.4))
        XCTAssertFalse(readiness.observe(projectVisible: true, hasDialog: false, elapsed: 0.8))
        XCTAssertTrue(readiness.observe(projectVisible: true, hasDialog: false, elapsed: 1.5))
    }

    func testExistingNameAndCancelledPromptCannotCompleteFreshReplacement() {
        var readiness = FinalCutImportReadiness()
        XCTAssertFalse(readiness.observe(projectVisible: true, hasDialog: false, elapsed: 0, awaitingReplacement: true))
        XCTAssertFalse(readiness.observe(projectVisible: true, hasDialog: true, elapsed: 1, awaitingReplacement: true))
        XCTAssertFalse(readiness.observe(projectVisible: true, hasDialog: false, elapsed: 20, awaitingReplacement: true))
        // The host can close the old timeline before we observe its prompt.
        XCTAssertFalse(readiness.observe(projectVisible: true, hasDialog: false, elapsed: 21,
                                         awaitingReplacement: true, originalTimelineClosed: true))
        XCTAssertTrue(readiness.observe(projectVisible: true, hasDialog: false, elapsed: 22,
                                        awaitingReplacement: true, originalTimelineClosed: true))
    }

    func testPostImportFailureIsPersistedWithoutDuplicateErrorPrefixOrSuccessClaim() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let error = XMLProjectApplyFailure(cause: FinalCutCaptureError.unavailable("Import warning still open."),
            outputURL: directory.appendingPathComponent("Cutdown.fcpxml"), importAttempted: true)
        try error.saveStatus()
        let status = try String(contentsOf: directory.appendingPathComponent("Import-Status.txt"))
        XCTAssertTrue(status.contains("automatic verification could not finish"))
        XCTAssertTrue(status.contains("do not import or apply again"))
        XCTAssertTrue(status.contains("Import warning still open."))
        XCTAssertFalse(status.contains("Final Cut Pro could not complete this step:"))
        XCTAssertFalse(status.contains("before analyzing"))
        let unsent = XMLProjectApplyFailure(cause: CocoaError(.fileWriteUnknown), outputURL: error.outputURL, importAttempted: false)
        XCTAssertTrue(unsent.localizedDescription.contains("no import was requested"))
        XCTAssertFalse(unsent.localizedDescription.contains("Import was requested,"))
    }
}
