import Foundation
import SilentSnipCore
import XCTest
@testable import SilentSnipMac

final class WorkflowReviewOriginTests: XCTestCase {
    private let requestID = UUID()
    private let view = UUID()
    private let gesture = UUID()
    private let library = URL(fileURLWithPath: "/tmp/Workflow Origin/Cutdown Integration.fcpbundle", isDirectory: false)

    private func url(host: String = "workflow-analyze", changing: String? = nil, value: String? = nil,
                     extra: URLQueryItem? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "silentsnip"; components.host = host
        var items = ["request": requestID.uuidString, "threshold": "-36.25", "minimum": "0.7",
            "before": "0.08", "after": "0.2", "output": "gaps", "view": view.uuidString,
            "gesture": gesture.uuidString, "library": library.absoluteString,
            "project": "project-UID", "projectName": "Same project name"]
        if let changing { items[changing] = value }
        components.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        if let extra { components.queryItems?.append(extra) }
        return components.url!
    }

    private func project(uid: String = "project-UID", location: URL? = nil, name: String = "Same project name") -> Data {
        Data("""
        <fcpxml version="1.14"><resources><format id="f" frameDuration="1/30s"/>
        <asset id="a" start="0s" duration="10s" hasAudio="1"><media-rep kind="original-media" src="file:///tmp/Voice.wav"/></asset>
        </resources><library location="\((location ?? library).absoluteString)">
        <event name="Fixture" uid="BBBB0000-0000-4000-8000-000000000001">
        <project name="\(name)" uid="\(uid)"><sequence format="f" duration="10s" tcStart="0s"><spine>
        <asset-clip ref="a" name="Voice" offset="0s" start="0s" duration="10s" audioRole="dialogue"/>
        </spine></sequence></project></event></library></fcpxml>
        """.utf8)
    }

    func testWorkflowRequestBindsExplicitNativeViewGestureAndSDKIdentity() throws {
        let request = try AnalyzeRequest(url: url())
        XCTAssertEqual(request.id, requestID)
        XCTAssertEqual(request.settings.thresholdDBFS, -36.25)
        XCTAssertEqual(request.outputMode, .gaps)
        let origin = try XCTUnwrap(request.workflowOrigin)
        XCTAssertEqual(origin.view, view)
        XCTAssertEqual(origin.gesture, gesture)
        XCTAssertEqual(origin.libraryURL, library)
        XCTAssertEqual(origin.projectUID, "project-UID")
        XCTAssertEqual(origin.projectName, "Same project name")
        XCTAssertNoThrow(try origin.verify(projectData: project()))
        XCTAssertNil(AnalyzeRequest(id: requestID, settings: .defaults, outputMode: .remove).workflowOrigin)
    }

    func testWorkflowRequestRejectsMissingDuplicatedInvalidOrRemoteBinding() throws {
        for key in ["view", "gesture", "library", "project", "projectName", "output"] {
            XCTAssertThrowsError(try AnalyzeRequest(url: url(changing: key)))
            XCTAssertThrowsError(try AnalyzeRequest(url: url(extra: .init(name: key, value: "duplicate"))))
        }
        for (key, value) in [("view", "bad UUID"), ("gesture", "bad UUID"), ("project", ""),
            ("projectName", "  "), ("project", "uid\u{0}"), ("library", "https://example.org/A.fcpbundle"),
            ("library", "file://another-mac/A.fcpbundle"), ("library", "file:///tmp/A.fcpbundle#fragment"),
            ("library", "file:///tmp/A.fcpbundle?query=1"), ("library", "file:///tmp/A.txt")] {
            XCTAssertThrowsError(try AnalyzeRequest(url: url(changing: key, value: value)))
        }
        for (key, value) in [("threshold", "-81"), ("minimum", "0.00001"), ("minimum", "11"),
                             ("before", "2.1"), ("after", "2.1")] {
            XCTAssertThrowsError(try AnalyzeRequest(url: url(changing: key, value: value)))
        }
        XCTAssertThrowsError(try AnalyzeRequest(url: url(host: "analyze")))
        XCTAssertThrowsError(try AnalyzeRequest(url: url(extra: .init(name: "apply", value: "true"))))
    }

    func testSameNamedDifferentProjectOrLibraryCannotValidateWorkflowOrigin() throws {
        let origin = try XCTUnwrap(AnalyzeRequest(url: url()).workflowOrigin)
        XCTAssertThrowsError(try origin.verify(projectData: project(uid: "another-project")))
        XCTAssertThrowsError(try origin.verify(projectData: project(location:
            library.deletingLastPathComponent().appendingPathComponent("Other.fcpbundle"))))
        XCTAssertThrowsError(try origin.verify(projectData: project(name: "Renamed")))
        let missingUID = Data(String(decoding: project(), as: UTF8.self)
            .replacingOccurrences(of: " uid=\"project-UID\"", with: "").utf8)
        XCTAssertThrowsError(try origin.verify(projectData: missingUID))
    }

    func testWorkflowNativeGestureRequiresUniqueFocusedActiveViewAndDisabledFreshAction() {
        let identifier = "silentsnip.workflow.analyze.requested.\(gesture.uuidString)"
        XCTAssertTrue(WorkflowReviewGesture.authorizes(uniqueWindows: 1, focusedMatches: true, hostIsActive: true,
            identifier: identifier, enabled: false, gesture: gesture, action: "analyze"))
        for count in [0, 2] {
            XCTAssertFalse(WorkflowReviewGesture.authorizes(uniqueWindows: count, focusedMatches: true, hostIsActive: true,
                identifier: identifier, enabled: false, gesture: gesture, action: "analyze"))
        }
        XCTAssertFalse(WorkflowReviewGesture.authorizes(uniqueWindows: 1, focusedMatches: false, hostIsActive: true,
            identifier: identifier, enabled: false, gesture: gesture, action: "analyze"))
        XCTAssertFalse(WorkflowReviewGesture.authorizes(uniqueWindows: 1, focusedMatches: true, hostIsActive: false,
            identifier: identifier, enabled: false, gesture: gesture, action: "analyze"))
        let invalidEnabledStates: [Bool?] = [true, nil]
        for enabled in invalidEnabledStates {
            XCTAssertFalse(WorkflowReviewGesture.pending(identifier: identifier, enabled: enabled, gesture: gesture, action: "analyze"))
        }
        XCTAssertFalse(WorkflowReviewGesture.pending(identifier: identifier, enabled: false, gesture: UUID(), action: "analyze"))
        XCTAssertFalse(WorkflowReviewGesture.pending(identifier: identifier, enabled: false, gesture: gesture, action: "apply"))
        XCTAssertFalse(WorkflowReviewGesture.pending(identifier: "silentsnip.apply.requested.\(gesture.uuidString)",
            enabled: false, gesture: gesture, action: "apply"))
        XCTAssertTrue(WorkflowReviewGesture.pending(identifier: "silentsnip.workflow.apply.requested.\(gesture.uuidString)",
            enabled: false, gesture: gesture, action: "apply"))
        for action in ["update", "verify"] {
            let marker = "silentsnip.workflow.\(action).requested.\(gesture.uuidString)"
            XCTAssertTrue(WorkflowReviewGesture.pending(identifier: marker, enabled: false, gesture: gesture, action: action))
            XCTAssertFalse(WorkflowReviewGesture.pending(identifier: marker, enabled: true, gesture: gesture, action: action))
            XCTAssertFalse(WorkflowReviewGesture.pending(identifier: marker, enabled: false, gesture: UUID(), action: action))
        }
    }

    func testAnalyzeDiagnosticsRetainEveryNativeAuthorizationCondition() {
        func observation(count: Int = 1, focused: Bool? = true, active: Bool = true,
                         found: Bool = true, pending: Bool = true, enabled: Bool? = false) -> WorkflowAnalyzeObservation {
            .init(matchingWindows: count, focusedMatches: focused, hostIsActive: active,
                buttonFound: found, pendingIDMatches: pending, buttonEnabled: enabled)
        }
        XCTAssertNil(observation().failureReason)
        let rejected = [observation(count: 0), observation(count: 2), observation(focused: nil),
            observation(focused: false), observation(active: false), observation(found: false),
            observation(pending: false), observation(enabled: nil), observation(enabled: true)]
        XCTAssertEqual(Set(rejected.compactMap(\.failureReason)).count, rejected.count)
        for rejected in rejected {
            XCTAssertNotNil(rejected.failureReason)
            XCTAssertLessThan(rejected.diagnostic.utf8.count, 512)
            XCTAssertTrue(rejected.diagnostic.contains("matches="))
            XCTAssertTrue(rejected.diagnostic.contains("hostActive="))
            XCTAssertTrue(rejected.diagnostic.contains("enabled="))
            XCTAssertFalse(rejected.diagnostic.contains(library.path))
        }
    }

    func testNativeWindowDeduplicationCollapsesOnlyEqualReferences() {
        let duplicates = WorkflowReviewWindowIdentity.distinct([10, 10, 10], equals: ==)
        XCTAssertEqual(duplicates, [10])
        let distinct = WorkflowReviewWindowIdentity.distinct([10, 10, 20, 20], equals: ==)
        XCTAssertEqual(distinct, [10, 20])
        let ambiguous = WorkflowAnalyzeObservation(matchingWindows: distinct.count, focusedMatches: true,
            hostIsActive: true, buttonFound: true, pendingIDMatches: true, buttonEnabled: false)
        XCTAssertNotNil(ambiguous.failureReason)
    }

    func testOnlyPinnedHostOrExactWorkerCanOwnWorkflowURLHandoff() {
        XCTAssertTrue(WorkflowForegroundOwnership.permits(foregroundPID: 10, hostPID: 10, helperPID: 20))
        XCTAssertTrue(WorkflowForegroundOwnership.permits(foregroundPID: 20, hostPID: 10, helperPID: 20))
        let unrelatedForegrounds: [Int32?] = [nil, 30, 21]
        for foreground in unrelatedForegrounds {
            XCTAssertFalse(WorkflowForegroundOwnership.permits(foregroundPID: foreground, hostPID: 10, helperPID: 20))
        }
        XCTAssertFalse(WorkflowForegroundOwnership.permits(foregroundPID: 20, hostPID: 0, helperPID: 20))
        XCTAssertFalse(WorkflowForegroundOwnership.permits(foregroundPID: 10, hostPID: 10, helperPID: 0))
        let handoff = WorkflowAnalyzeObservation(matchingWindows: 1, focusedMatches: true, hostIsActive: false,
            buttonFound: true, pendingIDMatches: true, buttonEnabled: false, helperIsActive: true)
        XCTAssertNil(handoff.failureReason)
        XCTAssertTrue(handoff.diagnostic.contains("helperActive=1"))
        let pendingID = "silentsnip.workflow.analyze.requested.\(gesture.uuidString)"
        XCTAssertTrue(WorkflowReviewGesture.authorizes(uniqueWindows: 1, focusedMatches: true,
            hostIsActive: false, helperIsActive: true, identifier: pendingID, enabled: false, gesture: gesture, action: "analyze"))
        for (count, focused, identifier, enabled) in [
            (2, true, pendingID, false), (1, false, pendingID, false),
            (1, true, "missing gesture", false), (1, true, pendingID, true)
        ] {
            XCTAssertFalse(WorkflowReviewGesture.authorizes(uniqueWindows: count, focusedMatches: focused,
                hostIsActive: false, helperIsActive: true, identifier: identifier, enabled: enabled, gesture: gesture, action: "analyze"))
        }
    }

    func testUnknownForegroundOwnerIsRejectedWithBoundedSanitizedDiagnostic() {
        let owner = "unexpected.service.\n" + String(repeating: "x", count: 300)
        let observation = WorkflowAnalyzeObservation(matchingWindows: 1, focusedMatches: true, hostIsActive: false,
            buttonFound: true, pendingIDMatches: true, buttonEnabled: false,
            helperIsActive: false, foregroundBundleIdentifier: owner)
        XCTAssertNotNil(observation.failureReason)
        let diagnostic = observation.diagnostic
        XCTAssertTrue(diagnostic.contains("helperActive=0"))
        let reportedOwner = diagnostic.components(separatedBy: "foregroundBundle=").last ?? ""
        XCTAssertEqual(reportedOwner.count, 200)
        XCTAssertFalse(reportedOwner.contains("\n"))
        XCTAssertTrue(reportedOwner.hasPrefix("unexpected.service."))
    }

    func testAvailabilityHandshakeAcceptsOnlyBoundedVersionedUUIDQueryAndEchoesNonce() throws {
        let query = WorkflowAvailability.Query(version: 1, view: view, nonce: gesture)
        let object = try ReviewWire.encode(query)
        let decoded = try XCTUnwrap(WorkflowAvailability.decode(object))
        XCTAssertEqual(decoded.view, view)
        XCTAssertEqual(decoded.nonce, gesture)
        let reply = try ReviewWire.encode(WorkflowAvailability.Reply(query: decoded))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["version", "view", "nonce", "protocol"])
        XCTAssertEqual(fields["protocol"] as? Int, 1)
        XCTAssertEqual(fields["view"] as? String, view.uuidString)
        XCTAssertEqual(fields["nonce"] as? String, gesture.uuidString)
        XCTAssertEqual(WorkflowAvailability.responseName(view: view), "local.silentsnip.workflow.capabilities.v1.\(view.uuidString)")
        for invalid in ["{}", object.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
                        String(repeating: "x", count: 2049), "{\"version\":1,\"view\":\"bad\",\"nonce\":\"bad\"}"] {
            XCTAssertNil(WorkflowAvailability.decode(invalid))
        }
        var extra: [String: Any] = ["version": 1, "view": view.uuidString, "nonce": gesture.uuidString]
        extra["result"] = "file:///tmp/Unexpected.fcpxml"
        XCTAssertNil(WorkflowAvailability.decode(String(decoding: try JSONSerialization.data(withJSONObject: extra), as: UTF8.self)))
    }

    func testOnlyCompleteWorkerBundleAdvertisesWorkflowAvailability() {
        XCTAssertTrue(WorkflowAvailability.isAdvertised(bundleIdentifier: "local.silentsnip.app", protocolVersion: NSNumber(value: 1)))
        for identifier in [nil, "local.silentsnip.helper.candidate", "local.silentsnip.workflowprototype"] {
            XCTAssertFalse(WorkflowAvailability.isAdvertised(bundleIdentifier: identifier, protocolVersion: NSNumber(value: 1)))
        }
        let invalidVersions: [Any?] = [nil, NSNumber(value: true), NSNumber(value: 2), "1", NSNumber(value: 1.0)]
        for version in invalidVersions {
            XCTAssertFalse(WorkflowAvailability.isAdvertised(bundleIdentifier: "local.silentsnip.app", protocolVersion: version))
        }
    }

    func testTargetClipNameIsOptionalAndSurvivesWirePublication() throws {
        let response = ReviewResponse(request: requestID, revision: 2, state: "review", message: "Ready",
            targetClipName: "Actual selected camera occurrence")
        let publication = try ReviewPublication(response)
        let decoded = try JSONDecoder().decode(ReviewResponse.self, from: Data(publication.object.utf8))
        XCTAssertEqual(decoded.targetClipName, "Actual selected camera occurrence")
        let legacy = ReviewResponse(request: requestID, revision: 1, state: "review", message: "Ready")
        XCTAssertNil(try JSONDecoder().decode(ReviewResponse.self, from: Data(ReviewWire.encode(legacy).utf8)).targetClipName)
    }
}
