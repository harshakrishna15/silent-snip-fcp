import ApplicationServices
import XCTest
@testable import SilentSnipMac

final class ProductionDirectShareAXTests: XCTestCase {
    private func origin(library: URL? = nil, projectUID: String = "ORIGINAL-UID",
                        projectName: String = "Disposable") throws -> WorkflowReviewOrigin {
        try WorkflowReviewOrigin(view: UUID(), gesture: UUID(), libraryURL: library
            ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("Production-\(UUID().uuidString).fcpbundle"),
            projectUID: projectUID, projectName: projectName)
    }

    private func pin(purpose: DirectShareAXPurpose = .analyze) throws -> DirectShareAXConfiguration {
        let origin = try origin()
        return try XCTUnwrap(DirectShareAXConfiguration.production(origin: origin, purpose: purpose,
            projectName: origin.projectName))
    }

    func testAnalyzePinComesFromThisWorkflowIdentityRatherThanGlobalConfiguration() throws {
        let current = try origin()
        let configuration = try XCTUnwrap(DirectShareAXConfiguration.production(origin: current,
            purpose: .analyze, projectName: current.projectName))
        XCTAssertEqual(configuration.libraryURL, current.libraryURL)
        XCTAssertEqual(configuration.projectUID, current.projectUID)
        XCTAssertEqual(configuration.projectName, current.projectName)
        XCTAssertThrowsError(try configuration.verify(origin(library: current.libraryURL,
            projectUID: "OTHER-UID", projectName: current.projectName)))
        XCTAssertThrowsError(try configuration.verify(origin(projectUID: current.projectUID,
            projectName: current.projectName)))
    }

    func testOriginalProjectApplyPinComesFromItsOwnWorkflowIdentity() throws {
        let current = try origin()
        let configuration = try XCTUnwrap(DirectShareAXConfiguration.production(origin: current,
            purpose: .apply, projectName: current.projectName))
        XCTAssertEqual(configuration.libraryURL, current.libraryURL)
        XCTAssertEqual(configuration.projectUID, current.projectUID)
        XCTAssertEqual(configuration.projectName, current.projectName)
        XCTAssertNoThrow(try configuration.verify(current))
        XCTAssertThrowsError(try configuration.verify(nil))
        XCTAssertThrowsError(try configuration.verify(origin(library: current.libraryURL,
            projectUID: "OTHER-UID", projectName: current.projectName)))
        XCTAssertThrowsError(try configuration.verify(origin(projectUID: current.projectUID,
            projectName: current.projectName)))
        XCTAssertThrowsError(try configuration.verify(origin(library: current.libraryURL,
            projectUID: current.projectUID, projectName: "Other Project")))
    }

    func testOrdinaryVerificationAndOtherProjectsCannotUseProductionPin() throws {
        let current = try origin()
        for purpose: DirectShareAXPurpose in [.ordinary, .verification] {
            XCTAssertNil(DirectShareAXConfiguration.production(origin: current, purpose: purpose,
                projectName: current.projectName))
        }
        for purpose: DirectShareAXPurpose in [.analyze, .apply] {
            XCTAssertNil(DirectShareAXConfiguration.production(origin: nil, purpose: purpose,
                projectName: current.projectName))
            for otherProject in ["Imported Result", current.projectName + " — Cleaned", "Isolated Target"] {
                XCTAssertNil(DirectShareAXConfiguration.production(origin: current, purpose: purpose,
                    projectName: otherProject))
            }
        }
    }

    func testSymlinkLibraryCannotAuthorizeProductionDispatch() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Production-AX-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("Actual.fcpbundle")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("Alias.fcpbundle")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let aliasedOrigin = try origin(library: alias)
        for purpose: DirectShareAXPurpose in [.analyze, .apply] {
            XCTAssertNil(DirectShareAXConfiguration.production(origin: aliasedOrigin, purpose: purpose,
                projectName: aliasedOrigin.projectName))
        }
    }

    @MainActor func testApplyRenderAndFinalXMLKeepOneAttemptAndNoUncertainFallback() throws {
        for phase in ["share.render", "share.xml"] {
            for nativeResult in [AXError.success, .cannotComplete, .actionUnsupported] {
                let probe = DirectShareAXProbe(configuration: try pin(purpose: .apply),
                    request: UUID(), phase: phase, mode: .production)
                var calls = 0
                XCTAssertThrowsError(try probe.dispatch(action: kAXPickAction) { calls += 1; return 0 })
                XCTAssertEqual(calls, 0)
                try probe.dispatch(action: kAXPressAction) { calls += 1; return nativeResult.rawValue }
                XCTAssertFalse(probe.selectOrdinaryFallback(for: DirectShareAXError.uncertain("No fresh owned panel")))
                XCTAssertThrowsError(try probe.dispatch(action: kAXPressAction) { calls += 1; return 0 })
                XCTAssertEqual(calls, 1)
                XCTAssertEqual(probe.report.phase, phase)
                XCTAssertEqual(probe.report.attemptCount, 1)
                XCTAssertEqual(probe.report.axResult, nativeResult.rawValue)
                XCTAssertEqual(probe.report.fallbackCount, 0)
            }
        }
    }

    @MainActor func testApplyCannotTreatOldUnownedOrMismatchedPanelAsCompletion() throws {
        let probe = DirectShareAXProbe(configuration: try pin(purpose: .apply),
            request: UUID(), phase: "share.render", mode: .production)
        try probe.dispatch(action: kAXPressAction) { AXError.cannotComplete.rawValue }
        let valid = DirectShareAXPanelObservation(existedBeforeDispatch: false, ownedByPinnedHost: true,
            title: "Silent Snip", enabledNextFound: true, projectMatches: true, foregroundIsHostOrHelper: true)
        XCTAssertTrue(valid.provesCompletion)
        for invalid in [
            DirectShareAXPanelObservation(existedBeforeDispatch: true, ownedByPinnedHost: true,
                title: "Silent Snip", enabledNextFound: true, projectMatches: true, foregroundIsHostOrHelper: true),
            DirectShareAXPanelObservation(existedBeforeDispatch: false, ownedByPinnedHost: false,
                title: "Silent Snip", enabledNextFound: true, projectMatches: true, foregroundIsHostOrHelper: true),
            DirectShareAXPanelObservation(existedBeforeDispatch: false, ownedByPinnedHost: true,
                title: "Other Share", enabledNextFound: true, projectMatches: true, foregroundIsHostOrHelper: true),
            DirectShareAXPanelObservation(existedBeforeDispatch: false, ownedByPinnedHost: true,
                title: "Silent Snip", enabledNextFound: false, projectMatches: true, foregroundIsHostOrHelper: true),
            DirectShareAXPanelObservation(existedBeforeDispatch: false, ownedByPinnedHost: true,
                title: "Silent Snip", enabledNextFound: true, projectMatches: false, foregroundIsHostOrHelper: true),
            DirectShareAXPanelObservation(existedBeforeDispatch: false, ownedByPinnedHost: true,
                title: "Silent Snip", enabledNextFound: true, projectMatches: true, foregroundIsHostOrHelper: false)
        ] {
            XCTAssertFalse(invalid.provesCompletion)
        }
        XCTAssertFalse(probe.report.observedOwnedPanel)
        XCTAssertFalse(probe.selectOrdinaryFallback(for: DirectShareAXError.uncertain("Completion not proven")))
    }

    @MainActor func testProductionDoesNotDependOnDiagnosticDirectoryAndRejectsPickBeforeInput() throws {
        let probe = DirectShareAXProbe(configuration: try pin(), request: UUID(), phase: "share.xml", mode: .production)
        var calls = 0
        XCTAssertThrowsError(try probe.dispatch(action: kAXPickAction) { calls += 1; return 0 })
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(probe.report.attemptCount, 0)
        try probe.dispatch(action: kAXPressAction) { calls += 1; return AXError.success.rawValue }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(probe.report.attemptCount, 1)
        XCTAssertEqual(probe.report.mode, "production")
    }

    @MainActor func testPreflightMissCanChooseOrdinaryExactlyOnceAndCannotThenDispatchDirectly() throws {
        let probe = DirectShareAXProbe(configuration: try pin(), request: UUID(), phase: "share.xml", mode: .production)
        XCTAssertTrue(probe.selectOrdinaryFallback(for: DirectShareAXError.preflight("Missing command")))
        XCTAssertFalse(probe.selectOrdinaryFallback(for: DirectShareAXError.preflight("Another miss")))
        var calls = 0
        XCTAssertThrowsError(try probe.dispatch(action: kAXPressAction) { calls += 1; return 0 })
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(probe.report.attemptCount, 0)
        XCTAssertEqual(probe.report.fallbackCount, 1)
    }

    @MainActor func testFallbackCompletionAndFailureCannotBeReportedAsDirectPanelProof() throws {
        for fails in [false, true] {
            let probe = DirectShareAXProbe(configuration: try pin(), request: UUID(), phase: "share.xml", mode: .production)
            XCTAssertTrue(probe.selectOrdinaryFallback(for: DirectShareAXError.preflight("Missing command")))
            probe.finish(error: fails ? DirectShareAXError.uncertain("Ordinary menu did not complete") : nil,
                foreground: 101, project: "Disposable")
            XCTAssertEqual(probe.report.outcome, fails ? "ordinaryRouteFailed" : "ordinaryRouteCompleted")
            XCTAssertFalse(probe.report.observedOwnedPanel)
            XCTAssertEqual(probe.report.attemptCount, 0)
            XCTAssertEqual(probe.report.fallbackCount, 1)
            XCTAssertTrue(probe.report.preflightFallbackReason?.contains("Missing command") == true)
        }
    }

    @MainActor func testEveryNativeResultConsumesAttemptAndCannotAuthorizeFallbackOrRetry() throws {
        for result in [AXError.success, .cannotComplete, .actionUnsupported, .invalidUIElement, .failure] {
            let probe = DirectShareAXProbe(configuration: try pin(), request: UUID(), phase: "share.render", mode: .production)
            var calls = 0
            try probe.dispatch(action: kAXPressAction) { calls += 1; return result.rawValue }
            XCTAssertFalse(probe.selectOrdinaryFallback(for: DirectShareAXError.uncertain("Panel not yet observed")))
            XCTAssertThrowsError(try probe.dispatch(action: kAXPressAction) { calls += 1; return 0 })
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(probe.report.attemptCount, 1)
            XCTAssertEqual(probe.report.axResult, result.rawValue)
            XCTAssertEqual(probe.report.fallbackCount, 0)
        }
    }

    @MainActor func testErrorButExecutedCanBeProvenOnlyByFreshPanelObservation() throws {
        let probe = DirectShareAXProbe(configuration: try pin(), request: UUID(), phase: "share.render", mode: .production)
        try probe.dispatch(action: kAXPressAction) { AXError.cannotComplete.rawValue }
        XCTAssertFalse(probe.report.observedOwnedPanel)
        let valid = DirectShareAXPanelObservation(existedBeforeDispatch: false, ownedByPinnedHost: true,
            title: "Silent Snip", enabledNextFound: true, projectMatches: true, foregroundIsHostOrHelper: true)
        XCTAssertTrue(valid.provesCompletion)
        probe.update { $0.observedOwnedPanel = valid.provesCompletion }
        probe.finish(foreground: 101, project: "Disposable")
        XCTAssertEqual(probe.report.outcome, "ownedPanelObserved")
        XCTAssertEqual(probe.report.axResult, AXError.cannotComplete.rawValue)
        XCTAssertFalse(probe.selectOrdinaryFallback(for: DirectShareAXError.uncertain("Native error")))
    }

    @MainActor func testCancellationCannotChooseOrdinaryOrSendInput() async throws {
        let before = DirectShareAXProbe(configuration: try pin(), request: UUID(), phase: "share.xml", mode: .production)
        XCTAssertFalse(before.selectOrdinaryFallback(for: CancellationError()))
        let during = DirectShareAXProbe(configuration: try pin(), request: UUID(), phase: "share.xml", mode: .production)
        var calls = 0
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertFalse(during.selectOrdinaryFallback(for: DirectShareAXError.preflight("Missing command")))
            try during.dispatch(action: kAXPressAction) { calls += 1; return 0 }
        }
        do { try await task.value; XCTFail("Cancellation must stop before native input") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(during.report.attemptCount, 0)
        XCTAssertEqual(during.report.fallbackCount, 0)
    }

    @MainActor func testDiagnosticModeNeverSilentlySelectsOrdinaryInput() throws {
        let diagnostic = DirectShareAXProbe(configuration: try pin(), request: UUID(), phase: "share.xml")
        XCTAssertFalse(diagnostic.selectOrdinaryFallback(for: DirectShareAXError.preflight("Missing command")))
        XCTAssertEqual(diagnostic.report.fallbackCount, 0)
    }

    @MainActor func testCountersDistinguishDispatchedAndPreflightFallbackWithoutDiagnosticFiles() throws {
        let dispatched = DirectShareAXProbe(configuration: try pin(), request: UUID(), phase: "share.render", mode: .production)
        try dispatched.dispatch(action: kAXPressAction) { AXError.cannotComplete.rawValue }
        let timing = AnalysisTiming(request: UUID())
        dispatched.record(timing: timing, prefix: "share.render")
        let first = timing.report(outcome: "in progress").counters
        XCTAssertEqual(first["share.render.directAX.production"], 1)
        XCTAssertEqual(first["share.render.directAX.attempts"], 1)
        XCTAssertEqual(first["share.render.directAX.fallbacks"], 0)
        XCTAssertEqual(first["share.render.directAX.axResult"], Int(AXError.cannotComplete.rawValue))
        let fallback = DirectShareAXProbe(configuration: try pin(), request: UUID(), phase: "share.xml", mode: .production)
        XCTAssertTrue(fallback.selectOrdinaryFallback(for: DirectShareAXError.preflight("Missing command")))
        fallback.record(timing: timing, prefix: "share.xml")
        let second = timing.report(outcome: "in progress").counters
        XCTAssertEqual(second["share.xml.directAX.attempts"], 0)
        XCTAssertEqual(second["share.xml.directAX.fallbacks"], 1)
    }
}
