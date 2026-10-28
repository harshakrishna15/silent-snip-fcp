import XCTest
@testable import SilentSnipMac

final class FinalCutImportCompletionTests: XCTestCase {
    func testFirstImportAllowsEmptyTimelineButRejectsOtherProjects() {
        XCTAssertTrue(FinalCutImportTimeline.permits(nil, original: "Original", imported: "Silent Snip Analysis 1"))
        XCTAssertTrue(FinalCutImportTimeline.permits("", original: "Original", imported: "Silent Snip Analysis 1"))
        XCTAssertTrue(FinalCutImportTimeline.permits("Original", original: "Original", imported: "Silent Snip Analysis 1"))
        XCTAssertTrue(FinalCutImportTimeline.permits("Silent Snip Analysis 1", original: "Original", imported: "Silent Snip Analysis 1"))
        XCTAssertFalse(FinalCutImportTimeline.permits("Another project", original: "Original", imported: "Silent Snip Analysis 1"))
    }

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
        XCTAssertTrue(FinalCutImportDialog(title: "Import XML", text: [notice, "Silent Snip.fcpxml", "A parameter was ignored"], buttons: ["OK"])
            .isCompletedWarning(for: "Silent Snip.fcpxml"))
        for dialog in [
            FinalCutImportDialog(title: "Import XML", text: [notice, "Other.fcpxml"], buttons: ["OK"]),
            FinalCutImportDialog(title: "Import XML", text: [notice, "Silent Snip.fcpxml.bak"], buttons: ["OK"]),
            FinalCutImportDialog(title: "Import XML", text: ["Import failed", "Silent Snip.fcpxml"], buttons: ["OK"]),
            FinalCutImportDialog(title: "Import XML", text: [notice, "Silent Snip.fcpxml"], buttons: ["Replace", "Cancel"]),
            FinalCutImportDialog(title: "Import XML", text: [notice, "Silent Snip.fcpxml"], buttons: ["OK", "Cancel"]),
            FinalCutImportDialog(title: "Missing Files", text: [notice, "Silent Snip.fcpxml"], buttons: ["OK"])
        ] { XCTAssertFalse(dialog.isCompletedWarning(for: "Silent Snip.fcpxml")) }
    }

    func testReplacementConfirmationRequiresExactLibraryAndButtons() {
        let text = "Final Cut Pro has received an XML document that is about to replace existing items with matching names in the library “Fixture”. Do you want to replace them?"
        let dialog = FinalCutImportDialog(title: "", text: [text], buttons: ["Keep Both", "Replace", "Cancel"])
        XCTAssertTrue(dialog.isReplacementConfirmation(libraryName: "Fixture"))
        XCTAssertFalse(dialog.isReplacementConfirmation(libraryName: "Other"))
        XCTAssertFalse(FinalCutImportDialog(title: "", text: [text], buttons: ["Replace", "Cancel"])
            .isReplacementConfirmation(libraryName: "Fixture"))
        let failure = XMLProjectApplyFailure(cause: CocoaError(.fileReadUnknown), outputURL: URL(fileURLWithPath: "/tmp/Result/Silent Snip.fcpxml"),
                                            importAttempted: true, replacingOriginal: true)
        XCTAssertFalse(failure.localizedDescription.contains("original project is unchanged"))
        XCTAssertTrue(failure.localizedDescription.contains("Before-Cuts.fcpxml"))
    }

    func testSenderIdentifiedReplacementPromptAcceptsOnlyOurExactDelivery() {
        let message = "Application “Silent Snip” sent an XML document that is about to replace existing items with matching names in the library “Fixture”."
        let question = "Do you want to replace them?"
        let buttons = ["Keep Both", "Replace", "Cancel"]
        for text in [[message, question], ["\(message) \(question)"]] {
            XCTAssertTrue(FinalCutImportDialog(title: "", text: text, buttons: buttons)
                .isReplacementConfirmation(libraryName: "Fixture"))
            XCTAssertFalse(FinalCutImportDialog(title: "", text: text, buttons: buttons)
                .isReplacementConfirmation(libraryName: "Other"))
        }
        for text in [
            [message.replacingOccurrences(of: "Silent Snip", with: "Other App"), question],
            [message.replacingOccurrences(of: "“Fixture”", with: "“Fixture Copy”"), question],
            [message],
            [question],
            ["Missing media in Fixture", question]
        ] {
            XCTAssertFalse(FinalCutImportDialog(title: "", text: text, buttons: buttons)
                .isReplacementConfirmation(libraryName: "Fixture"))
        }
        for wrongButtons in [["Replace", "Cancel"], buttons + ["Replace"], ["Keep Both", "Replace", "Delete"]] {
            XCTAssertFalse(FinalCutImportDialog(title: "", text: [message, question], buttons: wrongButtons)
                .isReplacementConfirmation(libraryName: "Fixture"))
        }
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

    func testReplaceAcknowledgmentCannotStandInForTheTimelineTransition() {
        var readiness = FinalCutImportReadiness()
        for elapsed in [0.0, 1, 5] {
            XCTAssertFalse(readiness.observe(projectVisible: true, hasDialog: false, elapsed: elapsed,
                awaitingReplacement: true, replacementConfirmed: true, requiresTimelineTransition: true))
        }
        XCTAssertFalse(readiness.observe(projectVisible: true, hasDialog: false, elapsed: 6,
            awaitingReplacement: true, replacementConfirmed: true, originalTimelineClosed: true, requiresTimelineTransition: true))
        XCTAssertTrue(readiness.observe(projectVisible: true, hasDialog: false, elapsed: 7,
            awaitingReplacement: true, replacementConfirmed: true, originalTimelineClosed: true, requiresTimelineTransition: true))
    }

    func testPostImportFailureIsPersistedWithoutDuplicateErrorPrefixOrSuccessClaim() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let error = XMLProjectApplyFailure(cause: FinalCutCaptureError.unavailable("Import warning still open."),
            outputURL: directory.appendingPathComponent("Silent Snip.fcpxml"), importAttempted: true)
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
