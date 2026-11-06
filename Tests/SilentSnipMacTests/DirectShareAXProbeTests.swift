import ApplicationServices
import Darwin
import XCTest
@testable import SilentSnipMac

final class DirectShareAXProbeTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("DirectShareAX-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func configuration(in root: URL) -> DirectShareAXConfiguration {
        .init(libraryURL: URL(fileURLWithPath: root.appendingPathComponent("Fixture.fcpbundle").path),
            projectUID: "PROJECT-123", projectName: "Disposable")
    }
    private func origin(_ configuration: DirectShareAXConfiguration, uid: String? = nil, name: String? = nil,
                        library: URL? = nil) throws -> WorkflowReviewOrigin {
        try WorkflowReviewOrigin(view: UUID(), gesture: UUID(), libraryURL: library ?? configuration.libraryURL,
            projectUID: uid ?? configuration.projectUID, projectName: name ?? configuration.projectName)
    }

    func testExactCanonicalRequestPinLoadsAndDoesNotPersistGestureAuthority() throws {
        let root = try directory(), pin = configuration(in: root), request = try origin(pin)
        let data = try JSONEncoder().encode(pin)
        XCTAssertEqual(try DirectShareAXConfiguration.decode(data, origin: request), pin)
        XCTAssertNoThrow(try pin.verify(origin(pin)), "A later fresh gesture for the same request identity is allowed")
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("gesture")); XCTAssertFalse(text.contains("view"))
        XCTAssertNil(try DirectShareAXConfiguration.load(directory: root, origin: request))
        try data.write(to: root.appendingPathComponent(DirectShareAXConfiguration.flagName))
        XCTAssertEqual(try DirectShareAXConfiguration.load(directory: root, origin: request), pin)
    }

    func testMissingOriginSameNameOtherProjectOrOtherLibraryCannotEnableProbe() throws {
        let root = try directory(), pin = configuration(in: root)
        XCTAssertThrowsError(try pin.verify(nil))
        XCTAssertThrowsError(try pin.verify(origin(pin, uid: "OTHER-PROJECT")))
        XCTAssertThrowsError(try pin.verify(origin(pin, name: "Other")))
        XCTAssertThrowsError(try pin.verify(origin(pin, library: root.appendingPathComponent("Other.fcpbundle"))))
        XCTAssertThrowsError(try DirectShareAXConfiguration.decode(Data(repeating: 32, count: DirectShareAXConfiguration.maximumBytes + 1), origin: origin(pin)))
        XCTAssertThrowsError(try DirectShareAXConfiguration.decode(Data("{}".utf8), origin: origin(pin)))
    }

    func testSymlinkLibraryOrOriginAndUnsafeFlagFilesAreRejected() throws {
        let root = try directory(), pin = configuration(in: root)
        try FileManager.default.createDirectory(at: pin.libraryURL, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("Alias.fcpbundle")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: pin.libraryURL)
        XCTAssertThrowsError(try pin.verify(origin(pin, library: alias)))
        let aliasedPin = DirectShareAXConfiguration(libraryURL: alias, projectUID: pin.projectUID, projectName: pin.projectName)
        XCTAssertThrowsError(try aliasedPin.verify(origin(aliasedPin)))
        let actual = root.appendingPathComponent("real.json")
        try JSONEncoder().encode(pin).write(to: actual)
        let flag = root.appendingPathComponent(DirectShareAXConfiguration.flagName)
        try FileManager.default.createSymbolicLink(at: flag, withDestinationURL: actual)
        XCTAssertThrowsError(try DirectShareAXConfiguration.load(directory: root, origin: origin(pin)))
        try FileManager.default.removeItem(at: flag)
        XCTAssertEqual(mkfifo(flag.path, 0o600), 0)
        XCTAssertThrowsError(try DirectShareAXConfiguration.load(directory: root, origin: origin(pin)), "A FIFO must not block the probe")
        try FileManager.default.removeItem(at: flag)
        XCTAssertEqual(link(actual.path, flag.path), 0)
        XCTAssertThrowsError(try DirectShareAXConfiguration.load(directory: root, origin: origin(pin)))
    }

    @MainActor func testOneAttemptLedgerRetainsAnUncertainAXResultAndRejectsAnotherAction() throws {
        let root = try directory(), pin = configuration(in: root)
        let probe = DirectShareAXProbe(configuration: pin, directory: root, request: UUID(), phase: "share.xml")
        var calls = 0
        try probe.dispatch(action: kAXPickAction) { calls += 1; return AXError.cannotComplete.rawValue }
        XCTAssertEqual(probe.report.attemptCount, 1)
        XCTAssertEqual(probe.report.axResult, AXError.cannotComplete.rawValue)
        XCTAssertThrowsError(try probe.dispatch(action: kAXPressAction) { calls += 1; return 0 })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(probe.report.fallbackCount, 0)
    }

    @MainActor func testFreshPreflightReportReplacesPriorSuccessBeforeAnyAction() throws {
        let root = try directory(), pin = configuration(in: root), firstRequest = UUID(), currentRequest = UUID()
        let previous = DirectShareAXProbe(configuration: pin, directory: root, request: firstRequest, phase: "share.xml")
        previous.update { $0.observedOwnedPanel = true }
        previous.finish(foreground: 101, project: pin.projectName)
        let current = DirectShareAXProbe(configuration: pin, directory: root, request: currentRequest, phase: "share.xml")
        current.finish(error: DirectShareAXError.preflight("project changed"), foreground: 101, project: "Other")
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("DirectShareAX.json"))) as? [String: Any])
        XCTAssertEqual(report["request"] as? String, currentRequest.uuidString)
        XCTAssertEqual(report["attemptCount"] as? Int, 0)
        XCTAssertEqual(report["outcome"] as? String, "preflightRejected")
        XCTAssertEqual(report["observedOwnedPanel"] as? Bool, false)
    }

    @MainActor func testMissingDiagnosticDirectoryOrUnsupportedActionSendsNoNativeCall() throws {
        let root = try directory(), pin = configuration(in: root)
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        let probe = DirectShareAXProbe(configuration: pin, directory: missing, request: UUID(), phase: "share.xml")
        var calls = 0
        XCTAssertThrowsError(try probe.dispatch(action: kAXPickAction) { calls += 1; return 0 })
        XCTAssertEqual(calls, 0); XCTAssertEqual(probe.report.attemptCount, 0)
        let other = DirectShareAXProbe(configuration: pin, directory: root, request: UUID(), phase: "share.xml")
        XCTAssertThrowsError(try other.dispatch(action: "AXShowMenu") { calls += 1; return 0 })
        XCTAssertEqual(calls, 0); XCTAssertEqual(other.report.attemptCount, 0)
    }

    @MainActor func testCancellationBeforeDispatchSendsNoAction() async throws {
        let root = try directory(), pin = configuration(in: root)
        let probe = DirectShareAXProbe(configuration: pin, directory: root, request: UUID(), phase: "share.xml")
        var calls = 0
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try probe.dispatch(action: kAXPickAction) { calls += 1; return 0 }
        }
        do { try await task.value; XCTFail("Cancelled probe must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 0); XCTAssertEqual(probe.report.attemptCount, 0)
    }

    @MainActor func testCancellationAfterAttemptDoesNotEraseItsUncertainResultOrPermitRetry() async throws {
        let root = try directory(), pin = configuration(in: root)
        let probe = DirectShareAXProbe(configuration: pin, directory: root, request: UUID(), phase: "share.render")
        var calls = 0
        let task = Task { @MainActor in
            try probe.dispatch(action: kAXPressAction) { calls += 1; withUnsafeCurrentTask { $0?.cancel() }; return 0 }
            try Task.checkCancellation()
        }
        do { try await task.value; XCTFail("Cancelled observation must fail") }
        catch { probe.finish(error: error, foreground: 101, project: pin.projectName) }
        XCTAssertEqual(calls, 1); XCTAssertEqual(probe.report.attemptCount, 1)
        XCTAssertEqual(probe.report.axResult, 0)
        XCTAssertThrowsError(try probe.dispatch(action: kAXPickAction) { calls += 1; return 0 })
        XCTAssertEqual(calls, 1)
    }

    func testOnlyNewOwnedExactPanelProvesCompletion() {
        func valid(existed: Bool = false, owned: Bool = true, title: String? = "Silent Snip", next: Bool = true,
                   project: Bool = true, foreground: Bool = true) -> Bool {
            DirectShareAXPanelObservation(existedBeforeDispatch: existed, ownedByPinnedHost: owned, title: title,
                enabledNextFound: next, projectMatches: project, foregroundIsHostOrHelper: foreground).provesCompletion
        }
        XCTAssertTrue(valid())
        XCTAssertFalse(valid(existed: true)); XCTAssertFalse(valid(owned: false)); XCTAssertFalse(valid(title: "Export File"))
        XCTAssertFalse(valid(next: false)); XCTAssertFalse(valid(project: false)); XCTAssertFalse(valid(foreground: false))
    }
}
