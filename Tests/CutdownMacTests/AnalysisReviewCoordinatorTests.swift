import CutdownCore
import Foundation
import XCTest
@testable import CutdownMac

@MainActor final class AnalysisReviewCoordinatorTests: XCTestCase {
    func testEarlyPreviewCannotApplyOrChangeUntilCleanupCompletes() async throws {
        let fixture = try makeFixture(); defer { fixture.remove() }
        let request = try makeRequest()
        var finish: CheckedContinuation<Void, Never>?
        var response: ReviewResponse?
        var preview: ReviewPlan?
        var applies = 0
        let coordinator = AnalysisReviewCoordinator(operation: { _, _ in
            await withCheckedContinuation { finish = $0 }
            return fixture.result
        }, applyOperation: { _, _, _ in applies += 1 }, authorizeApply: { _ in true },
            emit: { response = $0.response }, record: { _, _, _ in })
        defer { coordinator.stop() }
        coordinator.onReviewChange = { _, plan in preview = plan }
        coordinator.start(request)
        try await waitUntil { finish != nil }
        coordinator.previewReady(request.id, result: fixture.result)
        XCTAssertEqual(response?.state, "analyzing")
        XCTAssertFalse(try XCTUnwrap(response).canApply)
        XCTAssertFalse(try XCTUnwrap(response).canChangeSelection)
        XCTAssertFalse(try XCTUnwrap(response).cuts.isEmpty)
        XCTAssertNotNil(preview)
        let cuts = response?.cuts
        coordinator.handle(.init(request: request.id, command: .apply))
        coordinator.handle(.init(request: request.id, command: .deselectAll))
        XCTAssertEqual(applies, 0); XCTAssertEqual(response?.cuts, cuts)
        finish?.resume(); finish = nil
        try await waitUntil { response?.state == "review" }
        XCTAssertTrue(try XCTUnwrap(response).canApply)
    }

    func testCancelEarlyPreviewClearsItAndLateReadyCannotReviveIt() async throws {
        let fixture = try makeFixture(); defer { fixture.remove() }
        let request = try makeRequest()
        var finish: CheckedContinuation<Void, Never>?
        var response: ReviewResponse?
        var preview: ReviewPlan?
        let coordinator = AnalysisReviewCoordinator(operation: { _, _ in
            await withCheckedContinuation { finish = $0 }; return fixture.result
        }, emit: { response = $0.response }, record: { _, _, _ in })
        defer { coordinator.stop() }
        coordinator.onReviewChange = { _, plan in preview = plan }
        coordinator.start(request)
        try await waitUntil { finish != nil }
        coordinator.previewReady(request.id, result: fixture.result)
        XCTAssertNotNil(preview)
        coordinator.handle(.init(request: request.id, command: .cancel))
        coordinator.previewReady(request.id, result: fixture.result)
        XCTAssertNil(preview)
        finish?.resume(); finish = nil
        try await waitUntil { response?.state == "cancelled" }
        XCTAssertNil(preview)
    }

    func testRejectedRemoteRetryAcknowledgesWithoutStartingWhileAnotherReviewIsActive() async throws {
        let fixture = try makeFixture(); defer { fixture.remove() }
        let retryRequest = try makeRequest(), otherRequest = try makeRequest()
        var responses: [UUID: ReviewResponse] = [:]
        var attempts = 0
        let coordinator = AnalysisReviewCoordinator(operation: { _, _ in fixture.result },
            verificationOperation: { _, _ in attempts += 1; throw FixtureError.exportFailed },
            canRetryVerification: { _ in true }, emit: { responses[$0.response.request] = $0.response }, record: { _, _, _ in })
        defer { coordinator.stop() }
        coordinator.restoreVerification(retryRequest)
        try await waitUntil { responses[retryRequest.id]?.state == "failed" }
        let revision = try XCTUnwrap(responses[retryRequest.id]).revision
        coordinator.start(otherRequest)
        try await waitUntil { responses[otherRequest.id]?.state == "review" }
        let command = ReviewCommand(request: retryRequest.id, command: .retryVerification, expectedRevision: revision)
        coordinator.handle(command)
        let declined = try XCTUnwrap(responses[retryRequest.id])
        XCTAssertGreaterThan(declined.revision, revision)
        XCTAssertEqual(declined.state, "failed")
        XCTAssertEqual(attempts, 1)
        coordinator.handle(command)
        XCTAssertEqual(responses[retryRequest.id], declined)
        XCTAssertEqual(responses[otherRequest.id]?.state, "review")
    }

    func testRemoteVerificationRetryCannotReplayAfterAnotherFailure() async throws {
        let request = try makeRequest()
        var latest: ReviewResponse?
        var attempts = 0
        let coordinator = AnalysisReviewCoordinator(operation: { _, _ in throw FixtureError.exportFailed },
            verificationOperation: { _, _ in attempts += 1; throw FixtureError.exportFailed },
            canRetryVerification: { _ in true }, emit: { latest = $0.response }, record: { _, _, _ in })
        defer { coordinator.stop() }
        coordinator.restoreVerification(request)
        try await waitUntil { latest?.state == "failed" }
        let command = ReviewCommand(request: request.id, command: .retryVerification, expectedRevision: try XCTUnwrap(latest).revision)
        coordinator.handle(command)
        coordinator.handle(command)
        try await waitUntil { latest?.state == "failed" }
        XCTAssertEqual(attempts, 2)
        for _ in 0..<10 { coordinator.handle(command) }
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(coordinator.isBusy)
        coordinator.handle(.init(request: request.id, command: .retryVerification, expectedRevision: try XCTUnwrap(latest).revision))
        try await waitUntil { attempts == 3 && !coordinator.isBusy }
    }

    func testStatusRetriesUseIdenticalWirePayloadUntilSelectionChanges() async throws {
        let fixture = try makeFixture(); defer { fixture.remove() }
        let request = try makeRequest()
        var sent: [ReviewPublication] = []
        var local: ReviewResponse?
        let coordinator = AnalysisReviewCoordinator(operation: { _, _ in fixture.result },
            applyOperation: { _, _, _ in }, authorizeApply: { _ in true }, emit: { sent.append($0) },
            receiveLocal: { local = $0 }, record: { _, _, _ in })
        defer { coordinator.stop() }
        coordinator.start(request)
        try await waitUntil { sent.last?.response.state == "review" }
        let original = try XCTUnwrap(sent.last)
        for _ in 0..<10 {
            coordinator.handle(.init(request: request.id, command: .status))
            XCTAssertEqual(sent.last?.object, original.object)
            XCTAssertEqual(local, original.response)
        }
        let cut = try XCTUnwrap(original.response.cuts.first)
        coordinator.handle(.init(request: request.id, command: .include, cutID: cut.id, included: false))
        let changed = try XCTUnwrap(sent.last)
        XCTAssertGreaterThan(changed.response.revision, original.response.revision)
        XCTAssertNotEqual(changed.object, original.object)
        XCTAssertEqual(changed.response.cuts.first?.included, false)
        coordinator.handle(.init(request: request.id, command: .status))
        XCTAssertEqual(sent.last?.object, changed.object)
        XCTAssertEqual(local, changed.response)
    }

    func testDelayedSelectionReplayCannotUndoNewerChoice() async throws {
        let fixture = try makeFixture(); defer { fixture.remove() }
        let request = try makeRequest()
        var response: ReviewResponse?
        let coordinator = AnalysisReviewCoordinator(operation: { _, _ in fixture.result },
            emit: { response = $0.response }, record: { _, _, _ in })
        defer { coordinator.stop() }
        coordinator.start(request)
        try await waitUntil { response?.state == "review" }
        let original = try XCTUnwrap(response)
        let cut = try XCTUnwrap(original.cuts.first)
        let old = ReviewCommand(request: request.id, command: .include, cutID: cut.id,
            included: false, expectedRevision: original.revision)
        coordinator.handle(old)
        let firstRevision = try XCTUnwrap(response).revision
        XCTAssertFalse(try XCTUnwrap(response).cuts[0].included)
        coordinator.handle(.init(request: request.id, command: .include, cutID: cut.id,
            included: true, expectedRevision: firstRevision))
        let current = try XCTUnwrap(response)
        XCTAssertTrue(current.cuts[0].included)
        coordinator.handle(old)
        XCTAssertEqual(response, current)
    }

    func testUnconfirmedApplyCannotStartTimelineEdit() async throws {
        let fixture = try makeFixture(); defer { fixture.remove() }
        let request = try makeRequest()
        var response: ReviewResponse?
        var applies = 0
        let coordinator = AnalysisReviewCoordinator(operation: { _, _ in fixture.result },
            applyOperation: { _, _, _ in applies += 1 }, authorizeApply: { _ in false },
            emit: { response = $0.response }, record: { _, _, _ in })
        defer { coordinator.stop() }
        coordinator.start(request)
        try await waitUntil { response?.state == "review" }
        coordinator.handle(.init(request: request.id, command: .apply,
            expectedRevision: try XCTUnwrap(response).revision, view: UUID(), applyGesture: UUID()))
        XCTAssertEqual(applies, 0)
        XCTAssertEqual(response?.state, "failed")
        XCTAssertFalse(try XCTUnwrap(response).canApply)
    }

    func testStaleNavigationInvalidatesCutsAndPreviewWhileOrdinaryErrorsKeepReview() async throws {
        for error in [XMLProjectBaselineError(changes: ["timeline content"]) as Error,
                      FinalCutCaptureError.changedProject as Error, FixtureError.exportFailed as Error] {
            let fixture = try makeFixture(); defer { fixture.remove() }
            let request = try makeRequest()
            var response: ReviewResponse?
            var preview: ReviewPlan?
            let coordinator = AnalysisReviewCoordinator(operation: { _, _ in fixture.result },
                applyOperation: { _, _, _ in XCTFail("A stale plan must not apply") }, authorizeApply: { _ in true },
                highlightOperation: { _, _, _ in throw error },
                emit: { response = $0.response }, record: { _, _, _ in })
            coordinator.onReviewChange = { _, plan in preview = plan }
            defer { coordinator.stop() }
            coordinator.start(request)
            try await waitUntil { response?.state == "review" }
            let cut = try XCTUnwrap(response?.cuts.first)
            coordinator.handle(.init(request: request.id, command: .highlight, cutID: cut.id))
            try await waitUntil { !coordinator.isBusy }
            if error is FixtureError {
                XCTAssertEqual(response?.state, "review")
                XCTAssertEqual(response?.canApply, true)
                XCTAssertNotNil(preview)
            } else {
                XCTAssertEqual(response?.state, "failed")
                XCTAssertEqual(response?.canApply, false)
                XCTAssertEqual(response?.canHighlight, false)
                XCTAssertTrue(try XCTUnwrap(response).cuts.isEmpty)
                XCTAssertNil(preview)
                coordinator.handle(.init(request: request.id, command: .apply))
            }
        }
    }

    func testRestoredVerificationJobsRemainBounded() async throws {
        let coordinator = AnalysisReviewCoordinator(operation: { _, _ in throw FixtureError.exportFailed },
            verificationOperation: { _, _ in }, canRetryVerification: { _ in true },
            emit: { _ in }, record: { _, _, _ in })
        defer { coordinator.stop() }
        for _ in 0..<40 {
            coordinator.restoreVerification(try makeRequest())
            try await waitUntil { !coordinator.isBusy }
            XCTAssertLessThanOrEqual(coordinator.retainedJobCount, 24)
        }
    }

    func testHelperReviewRemainsActionableWhenPluginTransportFails() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let request = try makeRequest()
        var local: ReviewResponse?
        var transportFailed = true
        var remote: [ReviewResponse] = []
        var applies = 0
        let coordinator = AnalysisReviewCoordinator(operation: { _, _ in fixture.result },
            applyOperation: { _, result, _ in
                applies += 1
                XCTAssertEqual(result.analyzed.review.selectedCuts.count, 1)
            }, authorizeApply: { _ in true }, emit: { publication in
                let response = publication.response
                if transportFailed { throw FixtureError.exportFailed }
                remote.append(response)
            }, receiveLocal: { local = $0 }, record: { _, _, _ in })
        defer { coordinator.stop() }
        coordinator.start(request)
        try await waitUntil { local?.state == "review" }
        XCTAssertTrue(try XCTUnwrap(local).canApply)
        let cut = try XCTUnwrap(local?.cuts.first)
        coordinator.handle(.init(request: request.id, command: .include, cutID: cut.id, included: false))
        XCTAssertFalse(try XCTUnwrap(local?.cuts.first).included)
        transportFailed = false
        coordinator.handle(.init(request: request.id, command: .status))
        XCTAssertEqual(remote.last, local, "Status retries the latest selection without restarting analysis")
        transportFailed = true
        coordinator.handle(.init(request: request.id, command: .apply))
        coordinator.handle(.init(request: request.id, command: .apply))
        try await waitUntil { local?.state == "completed" }
        XCTAssertEqual(applies, 1)
        XCTAssertFalse(try XCTUnwrap(local).canApply)
    }

    func testLocalReviewStillRejectsAnOversizedPayload() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let request = try makeRequest()
        var local: [ReviewResponse] = []
        let coordinator = AnalysisReviewCoordinator(operation: { _, _ in
            ReviewAnalysisResult(analyzed: fixture.result.analyzed,
                presentationNotice: String(repeating: "x", count: ReviewWire.maximumBytes))
        }, emit: { _ in throw FixtureError.exportFailed },
            receiveLocal: { local.append($0) }, record: { _, _, _ in })
        defer { coordinator.stop() }
        coordinator.start(request)
        try await waitUntil { local.last?.state == "failed" }
        XCTAssertFalse(local.contains { $0.state == "review" })
        XCTAssertFalse(try XCTUnwrap(local.last).canApply)
    }

    func testRetryVerificationNeverReappliesAndRejectsConcurrentRetries() async throws {
        let fixture = try makeFixture(); defer { fixture.remove() }
        let request = try makeRequest()
        var responses: [ReviewResponse] = []
        var imports = 0, verifications = 0
        var pending = false
        let coordinator = AnalysisReviewCoordinator(operation: { _, _ in fixture.result },
            applyOperation: { _, _, _ in imports += 1; pending = true; throw FixtureError.exportFailed },
            authorizeApply: { _ in true },
            verificationOperation: { _, progress in
                verifications += 1
                try await Task.sleep(for: .milliseconds(10))
                pending = false; progress("Verified existing result", 1)
            }, canRetryVerification: { _ in pending }, emit: { responses.append($0.response) }, record: { _, _, _ in })
        defer { coordinator.stop() }
        coordinator.start(request)
        try await waitUntil { responses.last?.state == "review" }
        coordinator.handle(.init(request: request.id, command: .apply))
        try await waitUntil { responses.last?.state == "failed" }
        XCTAssertEqual(responses.last?.canRetryVerification, true)
        coordinator.handle(.init(request: request.id, command: .retryVerification))
        coordinator.handle(.init(request: request.id, command: .retryVerification))
        coordinator.handle(.init(request: request.id, command: .apply))
        try await waitUntil { responses.last?.state == "completed" }
        XCTAssertEqual(imports, 1); XCTAssertEqual(verifications, 1)
        XCTAssertEqual(responses.last?.canRetryVerification, false)
    }

    func testRestoredVerificationDoesNotAnalyzeOrApply() async throws {
        var responses: [ReviewResponse] = []
        let coordinator = AnalysisReviewCoordinator(operation: { _, _ in XCTFail("No analysis during recovery"); throw FixtureError.exportFailed },
            applyOperation: { _, _, _ in XCTFail("No import during recovery") }, authorizeApply: { _ in true },
            verificationOperation: { _, progress in progress("Recovered verification", 1) },
            canRetryVerification: { _ in true }, emit: { responses.append($0.response) }, record: { _, _, _ in })
        defer { coordinator.stop() }
        coordinator.restoreVerification(try makeRequest())
        try await waitUntil { responses.last?.state == "completed" }
        XCTAssertFalse(responses.contains { $0.state == "analyzing" || $0.state == "applying" })
        let previous = try XCTUnwrap(responses.last)
        coordinator.restoreVerification(AnalyzeRequest(id: previous.request, settings: .defaults, outputMode: .remove))
        XCTAssertGreaterThan(try XCTUnwrap(responses.last).revision, previous.revision)
        try await waitUntil { responses.last?.state == "completed" }
    }

    func testJumpUsesExactCutAndBlocksApplyUntilNavigationFinishes() async throws {
        let fixture = try makeFixture(); defer { fixture.remove() }
        let request = try makeRequest()
        var responses: [ReviewResponse] = []
        var jumps: [String] = []
        let coordinator = AnalysisReviewCoordinator(operation: { _, _ in fixture.result },
            applyOperation: { _, _, _ in XCTFail("Must not apply while navigating") }, authorizeApply: { _ in true },
            highlightOperation: { _, _, cutID in
                jumps.append(cutID)
                try await Task.sleep(for: .milliseconds(10))
            }, emit: { responses.append($0.response) }, record: { _, _, _ in })
        defer { coordinator.stop() }
        coordinator.start(request)
        try await waitUntil { responses.last?.state == "review" }
        let original = try XCTUnwrap(responses.last)
        XCTAssertTrue(original.canHighlight)
        coordinator.handle(.init(request: request.id, command: .highlight, cutID: "stale"))
        XCTAssertTrue(jumps.isEmpty)
        let id = try XCTUnwrap(original.cuts.first).id
        coordinator.handle(.init(request: request.id, command: .highlight, cutID: id))
        XCTAssertEqual(responses.last?.state, "navigating")
        coordinator.handle(.init(request: request.id, command: .apply))
        coordinator.handle(.init(request: request.id, command: .highlight, cutID: id))
        try await waitUntil { responses.last?.state == "review" }
        XCTAssertEqual(jumps, [id])
        XCTAssertEqual(responses.last?.cuts, original.cuts)
        XCTAssertTrue(try XCTUnwrap(responses.last).canApply)
    }

    func testJumpKeepsPreviewVisibleUntilNavigationFinishes() async throws {
        let fixture = try makeFixture(); defer { fixture.remove() }
        let request = try makeRequest()
        var response: ReviewResponse?
        var preview: ReviewPlan?
        var finishJump: CheckedContinuation<Void, Never>?
        let coordinator = AnalysisReviewCoordinator(operation: { _, _ in fixture.result },
            highlightOperation: { _, _, _ in await withCheckedContinuation { finishJump = $0 } },
            emit: { response = $0.response }, record: { _, _, _ in })
        defer { coordinator.stop(); finishJump?.resume() }
        coordinator.onReviewChange = { _, plan in preview = plan }
        coordinator.start(request)
        try await waitUntil { response?.state == "review" }
        XCTAssertNotNil(preview)
        let cut = try XCTUnwrap(response?.cuts.first)
        coordinator.handle(.init(request: request.id, command: .highlight, cutID: cut.id))
        XCTAssertEqual(response?.state, "navigating")
        XCTAssertNotNil(preview, "Moving the playhead must not blink the cut lines.")
        try await waitUntil { finishJump != nil }
        finishJump?.resume(); finishJump = nil
        try await waitUntil { response?.state == "review" }
        XCTAssertNotNil(preview)
    }

    func testSourceAndIsolatedMusicReviewsCanApply() async throws {
        for isolated in [false, true] {
            let fixture = try makeFixture(role: "music", isolated: isolated)
            defer { fixture.remove() }
            var responses: [ReviewResponse] = []
            let coordinator = AnalysisReviewCoordinator(operation: { _, _ in fixture.result },
                applyOperation: { _, _, _ in }, authorizeApply: { _ in true },
                emit: { responses.append($0.response) }, record: { _, _, _ in })
            coordinator.start(try makeRequest())
            try await waitUntil { responses.last?.state == "review" }
            XCTAssertTrue(try XCTUnwrap(responses.last).canApply)
            coordinator.stop()
        }
    }

    func testLateAnalysisProgressCannotOverwriteCompletedReview() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let request = try makeRequest()
        var responses: [ReviewResponse] = []
        var delayedProgress: AnalysisReviewCoordinator.Progress?
        let coordinator = AnalysisReviewCoordinator(operation: { _, progress in
            delayedProgress = progress
            return fixture.result
        }, emit: { responses.append($0.response) }, record: { _, _, _ in })
        defer { coordinator.stop() }
        coordinator.start(request)
        try await waitUntil { responses.last?.state == "review" }
        let completed = responses.last
        let count = responses.count
        delayedProgress?("Measuring selected source audio…", 0.25)
        XCTAssertEqual(responses.count, count)
        XCTAssertEqual(responses.last, completed)
    }

    func testFailedReviewPublicationClearsPreview() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        var responses: [ReviewResponse] = []
        var preview: ReviewPlan?
        let coordinator = AnalysisReviewCoordinator(operation: { _, _ in fixture.result },
            emit: { publication in
                let response = publication.response
                if response.state == "review" { throw FixtureError.exportFailed }
                responses.append(response)
            }, record: { _, _, _ in })
        coordinator.onReviewChange = { _, value in preview = value }
        defer { coordinator.stop() }
        coordinator.start(try makeRequest())
        try await waitUntil { responses.last?.state == "failed" }
        XCTAssertNil(preview, "An undisplayable review must not leave cut lines active.")
        XCTAssertFalse(try XCTUnwrap(responses.last).canApply)
    }

    func testLegacyPreviewHideCommandCannotDismissValidGuidelines() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let request = try makeRequest()
        var responses: [ReviewResponse] = []
        var preview: ReviewPlan?
        let coordinator = AnalysisReviewCoordinator(operation: { _, _ in fixture.result },
            applyOperation: { _, _, _ in }, authorizeApply: { _ in true },
            emit: { responses.append($0.response) }, record: { _, _, _ in })
        coordinator.onReviewChange = { _, value in preview = value }
        defer { coordinator.stop() }
        coordinator.start(request)
        try await waitUntil { responses.last?.state == "review" }
        XCTAssertEqual(responses.last?.previewVisible, true)
        let cuts = try XCTUnwrap(responses.last).cuts
        XCTAssertNotNil(preview)
        coordinator.handle(.init(request: request.id, command: .preview, included: false))
        coordinator.handle(.init(request: request.id, command: .status))
        XCTAssertNotNil(preview)
        XCTAssertEqual(responses.last?.previewVisible, true)
        XCTAssertEqual(responses.last?.cuts, cuts)
        XCTAssertEqual(responses.last?.canApply, true)
        coordinator.handle(.init(request: request.id, command: .apply))
        XCTAssertNil(preview)
        try await waitUntil { responses.last?.state == "completed" }
    }

    func testExplicitApplyRunsOnceAndPublishesWindowCompatibleCompletion() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let request = try makeRequest()
        var responses: [ReviewResponse] = []
        var applyCalls = 0
        let coordinator = AnalysisReviewCoordinator(operation: { _, _ in fixture.result },
            applyOperation: { received, result, progress in
                XCTAssertEqual(received.id, request.id)
                XCTAssertEqual(result.analyzed.review.selectedCuts.count, 2)
                applyCalls += 1
                progress("Cut-up project saved and sent to Final Cut. Original preserved.", 1)
            }, authorizeApply: { _ in true }, emit: { responses.append($0.response) }, record: { _, _, _ in })
        defer { coordinator.stop() }
        coordinator.start(request)
        try await waitUntil { responses.last?.state == "review" }
        XCTAssertEqual(applyCalls, 0, "Analyze must never initiate Apply.")
        XCTAssertEqual(responses.last?.canApply, true)
        coordinator.handle(.init(request: request.id, command: .apply))
        coordinator.handle(.init(request: request.id, command: .apply))
        try await waitUntil { responses.last?.state == "completed" }
        coordinator.handle(.init(request: request.id, command: .apply))
        XCTAssertEqual(applyCalls, 1)
        XCTAssertEqual(responses.last?.canApply, false)
        XCTAssertEqual(responses.last?.message, "Cut-up project saved and sent to Final Cut. Original preserved.")
    }

    func testAnalysisPublishesProgressAndUsableCutReview() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let request = try makeRequest()
        var responses: [ReviewResponse] = []
        var records: [String] = []
        let coordinator = AnalysisReviewCoordinator(operation: { received, progress in
            XCTAssertEqual(received, request)
            progress("Exporting Dialogue…", 0.4)
            return fixture.result
        }, emit: { responses.append($0.response) }, record: { received, state, _ in
            XCTAssertEqual(received, request)
            records.append(state)
        })
        defer { coordinator.stop() }

        coordinator.start(request)
        XCTAssertEqual(responses.last?.state, "analyzing")
        XCTAssertTrue(try XCTUnwrap(responses.last).canCancel)
        XCTAssertFalse(try XCTUnwrap(responses.last).canChangeSelection)
        try await waitUntil { responses.last?.state == "review" }

        XCTAssertTrue(responses.contains { $0.message == "Exporting Dialogue…" && $0.progress == 0.4 })
        let review = try XCTUnwrap(responses.last)
        XCTAssertEqual(review.request, request.id)
        XCTAssertEqual(review.cuts.count, 2)
        XCTAssertEqual(review.cuts[0].start, "01:00:01:03")
        XCTAssertEqual(review.cuts[0].end, "01:00:01:27")
        XCTAssertEqual(review.cuts[0].duration, "0.800 s")
        XCTAssertTrue(review.cuts.allSatisfy { $0.included && $0.eligible })
        XCTAssertEqual(review.summary, "2 selected · 1.600 s removed · 5.000 s → 3.400 s")
        XCTAssertTrue(review.canChangeSelection)
        XCTAssertTrue(review.canCancel)
        XCTAssertFalse(review.canApply)
        XCTAssertFalse(review.canHighlight)
        XCTAssertEqual(records, ["review"])
    }

    func testOperationFailureIsVisibleAndStatusPollReplaysIt() async throws {
        let request = try makeRequest()
        var responses: [ReviewResponse] = []
        let coordinator = AnalysisReviewCoordinator(operation: { _, progress in
            progress("Reading the selected recording…", nil)
            throw FixtureError.exportFailed
        }, emit: { responses.append($0.response) }, record: { _, _, _ in })
        defer { coordinator.stop() }

        coordinator.start(request)
        try await waitUntil { responses.last?.state == "failed" }
        let failure = try XCTUnwrap(responses.last)
        XCTAssertEqual(failure.message, "Dialogue export failed in the test operation.")
        XCTAssertTrue(failure.cuts.isEmpty)
        XCTAssertFalse(failure.canApply)
        XCTAssertFalse(failure.canCancel)
        XCTAssertNil(failure.progress)
        coordinator.handle(ReviewCommand(request: request.id, command: .status))
        XCTAssertEqual(responses.last, failure)
    }

    func testDuplicateLaunchAndBusyRequestCannotRunTwoExports() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let first = try makeRequest()
        let second = try makeRequest()
        let gate = OperationGate()
        var calls = 0
        var responses: [ReviewResponse] = []
        let coordinator = AnalysisReviewCoordinator(operation: { _, _ in
            calls += 1
            return try await gate.wait()
        }, emit: { responses.append($0.response) }, record: { _, _, _ in })
        defer { gate.finish(fixture.result); coordinator.stop() }

        coordinator.start(first)
        try await waitUntil { gate.isWaiting }
        let initial = try XCTUnwrap(responses.last)
        coordinator.start(first)
        XCTAssertEqual(responses.last, initial)
        coordinator.start(second)
        let rejected = try XCTUnwrap(responses.last)
        XCTAssertEqual(rejected.request, second.id)
        XCTAssertEqual(rejected.state, "failed")
        XCTAssertTrue(rejected.message.contains("Another Cutdown analysis is running"))
        XCTAssertEqual(calls, 1)

        gate.finish(fixture.result)
        try await waitUntil { responses.contains { $0.request == first.id && $0.state == "review" } }
        coordinator.start(first)
        XCTAssertEqual(responses.last?.state, "review")
        XCTAssertEqual(calls, 1, "Reopening or polling a completed request must reuse its cached review.")
    }

    func testCancellationWaitsForExportBoundaryAndDiscardsLateResult() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let request = try makeRequest()
        let blockedRequest = try makeRequest()
        let gate = OperationGate()
        var calls = 0
        var responses: [ReviewResponse] = []
        let coordinator = AnalysisReviewCoordinator(operation: { _, _ in
            calls += 1
            // A native export can finish after cancellation. Its completed result
            // must not resurrect the review or allow another concurrent export.
            return try await gate.wait()
        }, emit: { responses.append($0.response) }, record: { _, _, _ in })
        defer { gate.finish(fixture.result); coordinator.stop() }

        coordinator.start(request)
        try await waitUntil { gate.isWaiting }
        coordinator.handle(ReviewCommand(request: request.id, command: .cancel))
        let cancelling = try XCTUnwrap(responses.last)
        XCTAssertEqual(cancelling.state, "cancelling")
        XCTAssertTrue(cancelling.cuts.isEmpty)
        XCTAssertFalse(cancelling.canApply)
        coordinator.start(blockedRequest)
        XCTAssertEqual(responses.last?.state, "failed")
        XCTAssertEqual(calls, 1)

        gate.finish(fixture.result)
        try await waitUntil { responses.contains { $0.request == request.id && $0.state == "cancelled" } }
        XCTAssertFalse(responses.contains { $0.request == request.id && $0.state == "review" })
        coordinator.handle(ReviewCommand(request: request.id, command: .status))
        XCTAssertEqual(responses.last?.state, "cancelled")
        XCTAssertTrue(try XCTUnwrap(responses.last).cuts.isEmpty)
    }

    func testNewAnalysisReplacesOldReviewAndIgnoresItsCommands() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let first = try makeRequest()
        let second = try makeRequest()
        var responses: [ReviewResponse] = []
        let coordinator = AnalysisReviewCoordinator(operation: { _, _ in fixture.result },
            emit: { responses.append($0.response) }, record: { _, _, _ in })
        defer { coordinator.stop() }
        coordinator.start(first)
        try await waitUntil { responses.last?.state == "review" }
        coordinator.start(second)
        try await waitUntil { responses.last?.request == second.id && responses.last?.state == "review" }
        XCTAssertTrue(responses.contains { $0.request == first.id && $0.state == "cancelled" })
        let current = try XCTUnwrap(responses.last)
        coordinator.handle(ReviewCommand(request: first.id, command: .deselectAll))
        XCTAssertEqual(responses.last, current)
        coordinator.handle(ReviewCommand(request: first.id, command: .status))
        XCTAssertEqual(responses.last?.state, "cancelled")
        XCTAssertTrue(try XCTUnwrap(responses.last).cuts.isEmpty)
        coordinator.handle(ReviewCommand(request: second.id, command: .status))
        XCTAssertEqual(responses.last, current)
    }

    func testUnsupportedEditCommandsRemainDisabledAndDoNotConsumeReview() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let request = try makeRequest()
        var calls = 0
        var responses: [ReviewResponse] = []
        let coordinator = AnalysisReviewCoordinator(operation: { _, _ in
            calls += 1
            return fixture.result
        }, emit: { responses.append($0.response) }, record: { _, _, _ in })
        defer { coordinator.stop() }
        coordinator.start(request)
        try await waitUntil { responses.last?.state == "review" }
        let cuts = try XCTUnwrap(responses.last).cuts
        for command in [ReviewCommand.Kind.highlight, .apply] {
            coordinator.handle(ReviewCommand(request: request.id, command: command, cutID: cuts[0].id))
            let response = try XCTUnwrap(responses.last)
            XCTAssertEqual(response.state, "review")
            XCTAssertEqual(response.cuts, cuts)
            XCTAssertFalse(response.canApply)
            XCTAssertFalse(response.canHighlight)
            XCTAssertTrue(response.message.contains("not connected"))
        }
        XCTAssertEqual(calls, 1)
    }

    func testUnknownReviewCommandsCannotStartAnOperation() throws {
        let request = try makeRequest()
        var calls = 0
        var responses: [ReviewResponse] = []
        let coordinator = AnalysisReviewCoordinator(operation: { _, _ in
            calls += 1
            throw FixtureError.exportFailed
        }, emit: { responses.append($0.response) }, record: { _, _, _ in })
        defer { coordinator.stop() }
        for command in [ReviewCommand.Kind.apply, .highlight, .cancel, .selectAll] {
            coordinator.handle(ReviewCommand(request: request.id, command: command, cutID: "unowned-cut"))
        }
        XCTAssertTrue(responses.isEmpty)
        coordinator.handle(ReviewCommand(request: request.id, command: .status))
        XCTAssertTrue(responses.isEmpty, "A helper must not answer another helper's job.")
        XCTAssertEqual(calls, 0)
    }

    func testUnrelatedHelperCannotOverwriteOwnedReviewOnBroadcastStatus() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let request = try makeRequest()
        var responses: [ReviewResponse] = []
        let owner = AnalysisReviewCoordinator(operation: { _, _ in fixture.result },
            emit: { responses.append($0.response) }, record: { _, _, _ in })
        let other = AnalysisReviewCoordinator(operation: { _, _ in
            XCTFail("Status must never start an analysis")
            throw FixtureError.exportFailed
        }, emit: { responses.append($0.response) }, record: { _, _, _ in })
        defer { owner.stop(); other.stop() }
        // A poll can also arrive before the URL that starts the job.
        other.handle(.init(request: request.id, command: .status))
        XCTAssertTrue(responses.isEmpty)
        owner.start(request)
        try await waitUntil { responses.last?.state == "review" }
        let review = try XCTUnwrap(responses.last)
        for helpers in [[owner, other], [other, owner]] {
            let count = responses.count
            for helper in helpers { helper.handle(.init(request: request.id, command: .status)) }
            XCTAssertEqual(responses.count, count + 1)
            XCTAssertEqual(responses.last, review)
        }
    }

    func testEmptyReviewsExplainNoSilenceAndWholeClipSilence() async throws {
        for level in [0.25, 0.0] {
            let fixture = try makeFixture(uniformLevel: level)
            defer { fixture.remove() }
            let request = try makeRequest()
            var responses: [ReviewResponse] = []
            let coordinator = AnalysisReviewCoordinator(operation: { _, _ in fixture.result },
                emit: { responses.append($0.response) }, record: { _, _, _ in })
            defer { coordinator.stop() }
            coordinator.start(request)
            try await waitUntil { responses.last?.state == "review" }
            let response = try XCTUnwrap(responses.last)
            XCTAssertTrue(response.cuts.isEmpty)
            XCTAssertFalse(response.canApply)
            XCTAssertTrue(response.message.contains(level == 0 ? "Whole-clip deletion is unavailable" : "No qualifying silence"))
        }
    }

    private enum FixtureError: LocalizedError {
        case exportFailed, waitTimedOut
        var errorDescription: String? {
            switch self {
            case .exportFailed: return "Dialogue export failed in the test operation."
            case .waitTimedOut: return "Timed out waiting for the review coordinator."
            }
        }
    }

    private final class OperationGate {
        private var continuation: CheckedContinuation<ReviewAnalysisResult, Error>?
        var isWaiting: Bool { continuation != nil }
        func wait() async throws -> ReviewAnalysisResult {
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func finish(_ result: ReviewAnalysisResult) {
            let waiting = continuation
            continuation = nil
            waiting?.resume(returning: result)
        }
    }

    private struct Fixture {
        let directory: URL
        let artifact: URL
        let result: ReviewAnalysisResult
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeRequest() throws -> AnalyzeRequest {
        try AnalyzeRequest(url: XCTUnwrap(URL(string:
            "cutdown://analyze?request=\(UUID())&threshold=-40&minimum=0.5&before=0.1&after=0.1")))
    }

    private func makeFixture(uniformLevel: Double? = nil, role: String = "dialogue", isolated: Bool = false) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CutdownReviewTest-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let artifact = directory.appendingPathComponent("owned-render.bin")
            try Data("cached measurements fixture".utf8).write(to: artifact)
            let xml = """
            <fcpxml version="1.14"><resources>
            <format id="r1" frameDuration="1/30s" width="1920" height="1080"/>
            <asset id="r2" name="Voice" start="0s" duration="7s" hasAudio="1" audioSources="1" audioChannels="1">
            <media-rep kind="original-media" src="\(artifact.absoluteString)"/></asset></resources>
            <library><event><project name="Review Fixture" uid="review-fixture"><sequence format="r1" duration="5s" tcStart="3600s">
            <spine><asset-clip ref="r2" name="Voice" offset="3600s" start="1s" duration="5s" audioRole="\(role)"/></spine>
            </sequence></project></event></library></fcpxml>
            """
            let document = try TimelineParser.parse(data: Data(xml.utf8))
            let target = try document.selectedTarget(.init(timelineRange: TimeRange(start: .zero, end: RationalTime(5))),
                requireExistingMedia: false)
            let windows = (0..<500).map { index in
                AudioLevelWindow(range: TimeRange(start: RationalTime(Int64(index), 100),
                    end: RationalTime(Int64(index + 1), 100)),
                    channelRMS: [uniformLevel ?? (((100..<200).contains(index) || (300..<400).contains(index)) ? 0 : 0.25)])
            }
            let audio = DialogueAudio(windows: windows, duration: RationalTime(5), sampleRate: 48_000, channelCount: 1)
            let analysis = try SilenceDetector.analyze(windows: windows, target: target.timelineRange,
                frameDuration: document.frameDuration)
            let context = try role != "dialogue" ? (isolated
                ? DialogueRenderContext.capturedIsolated(document: document, target: target, audioURL: artifact)
                : DialogueRenderContext(projectFingerprint: document.fingerprint, projectUID: document.projectUID, projectName: document.projectName, projectRange: document.projectRange, renderedRoles: [], audioURL: artifact, sourceRange: .init(start: target.sourceFileStart, end: try target.sourceFileStart.adding(target.timelineRange.duration)))) : DialogueRenderContext(projectFingerprint: document.fingerprint, projectUID: document.projectUID,
                projectName: document.projectName, projectRange: document.projectRange,
                renderedRoles: Set(document.dialogueRoles), audioURL: artifact)
            let review = try ReviewPlan(jobID: UUID(), document: document, target: target, analysis: analysis, requireDialogue: role == "dialogue")
            let analyzed = AnalyzedAudioProject(document: document, target: target, dialogueContext: context,
                audio: audio, settings: .defaults, analysis: analysis, review: review)
            return Fixture(directory: directory, artifact: artifact, result: ReviewAnalysisResult(analyzed: analyzed))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { throw FixtureError.waitTimedOut }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
