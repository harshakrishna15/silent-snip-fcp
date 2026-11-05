import XCTest
@testable import SilentSnipMac

final class ReviewTransportTests: XCTestCase {
    func testWorkflowSavedResultRequestBindsFreshNativeGestureAndSDKIdentity() throws {
        let view = UUID(), gesture = UUID()
        let fields = ["view": view.uuidString, "gesture": gesture.uuidString,
            "library": "file:///tmp/Cutdown%20Integration.fcpbundle", "project": "source-UID",
            "projectName": "Source project", "result": "file:///tmp/Result/Silent%20Snip.fcpxml"]
        func url(_ fields: [String: String]) -> URL {
            var url = URLComponents(); url.scheme = "silentsnip"; url.host = "workflow-verify"
            url.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
            return url.url!
        }
        let request = try ReviewVerificationRequest(url: url(fields))
        XCTAssertEqual(request.view, view)
        XCTAssertEqual(request.workflowOrigin?.gesture, gesture)
        XCTAssertEqual(request.workflowOrigin?.projectUID, "source-UID")
        XCTAssertEqual(request.result.path, "/tmp/Result/Silent Snip.fcpxml")
        for key in fields.keys {
            var missing = fields; missing.removeValue(forKey: key)
            XCTAssertThrowsError(try ReviewVerificationRequest(url: url(missing)))
        }
        for (key, value) in [("gesture", "invalid"), ("view", "invalid"), ("project", ""),
            ("library", "file://remote/Cutdown.fcpbundle"), ("result", "file://remote/Silent%20Snip.fcpxml"),
            ("result", "file:///tmp/Silent%20Snip.fcpxml?query=1"), ("unexpected", "value")] {
            var invalid = fields; invalid[key] = value
            XCTAssertThrowsError(try ReviewVerificationRequest(url: url(invalid)))
        }
        var duplicate = URLComponents(url: url(fields), resolvingAgainstBaseURL: false)!
        duplicate.queryItems?.append(.init(name: "gesture", value: gesture.uuidString))
        XCTAssertThrowsError(try ReviewVerificationRequest(url: duplicate.url!))
    }
    func testWorkflowResponseGestureRoundTripsAndLegacyRepliesStayCompatible() throws {
        let gesture = UUID()
        let response = ReviewResponse(request: UUID(), revision: 2, state: "verifying", message: "Checking saved result",
            workflowGesture: gesture)
        let wire = try ReviewWire.encode(response)
        let packet = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(wire.utf8)) as? [String: Any])
        XCTAssertEqual(packet["workflowGesture"] as? String, gesture.uuidString)
        XCTAssertEqual(try JSONDecoder().decode(ReviewResponse.self, from: Data(wire.utf8)), response)
        let legacy = ReviewResponse(request: UUID(), revision: 1, state: "completed", message: "Done")
        let legacyWire = try ReviewWire.encode(legacy)
        let legacyPacket = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(legacyWire.utf8)) as? [String: Any])
        XCTAssertNil(legacyPacket["workflowGesture"])
        XCTAssertNil(try JSONDecoder().decode(ReviewResponse.self, from: Data(legacyWire.utf8)).workflowGesture)
    }

    func testSettingsPreviewRequiresViewOrderingTokenValidSettingsAndOutput() throws {
        let request = UUID(), view = UUID(), edit = UUID()
        let settings = ReviewWireSettings(threshold: -35, minimum: 0.5, before: 0.1, after: 0.2)
        let command = ReviewCommand(request: request, command: .recalculate, expectedRevision: 4, view: view,
            settings: settings, output: "remove", settingsEdit: edit, settingsSequence: 1, verifySettings: true)
        XCTAssertEqual(try ReviewWire.decodeCommand(ReviewWire.encode(command)), command)
        for invalid in [
            ReviewCommand(request: request, command: .recalculate),
            ReviewCommand(request: request, command: .recalculate, expectedRevision: 4, view: view,
                settings: settings, output: "remove", settingsEdit: edit, settingsSequence: 0, verifySettings: true),
            ReviewCommand(request: request, command: .recalculate, expectedRevision: 4, view: view,
                settings: .init(threshold: -35, minimum: -1, before: 0.1, after: 0.2), output: "remove", settingsEdit: edit, settingsSequence: 1, verifySettings: true),
            ReviewCommand(request: request, command: .recalculate, expectedRevision: 4, view: view,
                settings: settings, output: "unknown", settingsEdit: edit, settingsSequence: 1, verifySettings: true)
        ] { XCTAssertThrowsError(try ReviewWire.decodeCommand(ReviewWire.encode(invalid))) }
    }

    func testRecreatedViewHandshakeIsBoundedAndCarriesExactSettings() throws {
        let view = UUID()
        let query = try ReviewWire.encode(ReviewReconnectQuery(version: 1, view: view))
        XCTAssertEqual(ReviewReconnectQuery.decode(query)?.view, view)
        for object: Any in ["{}", "[]", "true", "{\"version\":true,\"view\":\"\(view)\"}",
            try ReviewWire.encode(ReviewReconnectQuery(version: 2, view: view)), String(repeating: "x", count: 1025)] {
            XCTAssertNil(ReviewReconnectQuery.decode(object))
        }
        let request = try AnalyzeRequest(url: XCTUnwrap(URL(string: "silentsnip://analyze?request=\(UUID())&threshold=-42&minimum=8&before=1.5&after=2&output=gaps")))
        let reply = try ReviewWire.encode(ReviewReconnectReply(view: view, request: request))
        let packet = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        XCTAssertEqual(packet["view"] as? String, view.uuidString)
        XCTAssertEqual(packet["request"] as? String, request.id.uuidString)
        XCTAssertEqual(packet["output"] as? String, "gaps")
        XCTAssertEqual((packet["settings"] as? [String: Double])?["minimum"], 8)
        XCTAssertNil(packet["gesture"])
        let recoveryGesture = UUID()
        let recovery = try ReviewWire.encode(ReviewReconnectReply(view: view, request: request, gesture: recoveryGesture))
        let recoveryPacket = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(recovery.utf8)) as? [String: Any])
        XCTAssertEqual(recoveryPacket["gesture"] as? String, recoveryGesture.uuidString)
        XCTAssertEqual(recoveryPacket["request"] as? String, request.id.uuidString)
    }

    func testSavedResultURLRejectsAmbiguousOrNonlocalDestinations() throws {
        let base = "silentsnip://verify?view=\(UUID())&result=file:///tmp/Silent Snip.fcpxml"
        XCTAssertEqual(try ReviewVerificationRequest(url: XCTUnwrap(URL(string: base))).result.path, "/tmp/Silent Snip.fcpxml")
        for url in [base + "&view=\(UUID())", base + "#fragment", base.replacingOccurrences(of: "file:///", with: "https://example.org/"),
                    base.replacingOccurrences(of: "Silent Snip.fcpxml", with: "Other.fcpxml"), base.replacingOccurrences(of: "file:///", with: "file://remote/")] {
            XCTAssertThrowsError(try ReviewVerificationRequest(url: XCTUnwrap(URL(string: url))))
        }
    }

    func testStatePolicyMatchesSharedPluginContract() throws {
        struct Entry: Decodable { let state: String; let busy: Bool; let terminal: Bool; let retry: Bool }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: root.appendingPathComponent("AudioPlugin/Tests/review-states.json")))
        XCTAssertEqual(Set(entries.map(\.state)), Set(ReviewState.allCases.map(\.rawValue)))
        for entry in entries {
            let state = try XCTUnwrap(ReviewState(rawValue: entry.state))
            XCTAssertEqual(state.isBusy, entry.busy)
            XCTAssertEqual(state.isTerminal, entry.terminal)
            XCTAssertEqual(state.canRetryVerification, entry.retry)
        }
    }

    func testRemoteRetryRevisionSurvivesWireRoundTripAndRejectsNegativeRevision() throws {
        let command = ReviewCommand(request: UUID(), command: .retryVerification, expectedRevision: 42)
        XCTAssertEqual(try ReviewWire.decodeCommand(ReviewWire.encode(command)), command)
        XCTAssertThrowsError(try ReviewWire.decodeCommand(ReviewWire.encode(
            ReviewCommand(request: command.request, command: .retryVerification, expectedRevision: -1))))
    }

    func testPublicationValidatesBeforeCachingWireBytes() throws {
        let response = ReviewResponse(request: UUID(), revision: 1, state: "review", message: "Ready", progress: 1)
        let publication = try ReviewPublication(response)
        XCTAssertEqual(try JSONDecoder().decode(ReviewResponse.self, from: Data(publication.object.utf8)), response)
        XCTAssertEqual(publication.response, response)
        for progress in [Double.nan, .infinity, -0.1, 1.1] {
            XCTAssertThrowsError(try ReviewPublication(ReviewResponse(request: UUID(), revision: 1,
                state: "analyzing", message: "Invalid", progress: progress)))
        }
        XCTAssertThrowsError(try ReviewPublication(ReviewResponse(request: UUID(), revision: -1, state: "review", message: "Invalid")))
        XCTAssertThrowsError(try ReviewPublication(ReviewResponse(request: UUID(), revision: 1, state: "review",
            message: String(repeating: "x", count: ReviewWire.maximumBytes))))
    }

    func testSandboxEnvelopeUsesStringAndRoundTripsCommands() throws {
        let request = UUID()
        let include = ReviewCommand(request: request, command: .include, cutID: "cut-2", included: false, expectedRevision: 7)
        let object = try ReviewWire.encode(include)
        XCTAssertEqual(try ReviewWire.decodeCommand(object), include)
        XCTAssertEqual(ReviewWire.responseName(for: request), "local.silentsnip.review.response.v1.\(request.uuidString)")
    }

    func testMutationsRequireCurrentRevisionAndApplyRequiresViewGesture() throws {
        let request = UUID(), view = UUID(), gesture = UUID()
        for command in [ReviewCommand.Kind.include, .selectAll, .deselectAll, .preview, .highlight, .apply] {
            let packet = ReviewCommand(request: request, command: command, cutID: "cut-1", included: true)
            XCTAssertThrowsError(try ReviewWire.decodeCommand(ReviewWire.encode(packet)))
        }
        let incomplete = ReviewCommand(request: request, command: .apply, expectedRevision: 4)
        XCTAssertThrowsError(try ReviewWire.decodeCommand(ReviewWire.encode(incomplete)))
        let apply = ReviewCommand(request: request, command: .apply, expectedRevision: 4,
            view: view, applyGesture: gesture)
        XCTAssertEqual(try ReviewWire.decodeCommand(ReviewWire.encode(apply)), apply)
        let stale = ReviewCommand(request: request, command: .include, cutID: "cut-1",
            included: false, expectedRevision: -1)
        XCTAssertThrowsError(try ReviewWire.decodeCommand(ReviewWire.encode(stale)))
    }

    func testMalformedOrOversizedMessagesCannotBecomeCommands() {
        let request = UUID().uuidString
        let objects: [Any] = [
            ["command": "apply"],
            "{\"version\":2,\"request\":\"\(request)\",\"command\":\"apply\"}",
            "{\"version\":1,\"request\":\"\(request)\",\"command\":\"include\",\"cutID\":\"cut-1\"}",
            "{\"version\":1,\"request\":\"\(request)\",\"command\":\"highlight\",\"cutID\":\"\"}",
            "{\"version\":1,\"request\":\"\(request)\",\"command\":\"settings\"}",
            "{\"version\":1,\"request\":\"bad-id\",\"command\":\"status\"}",
            String(repeating: "x", count: ReviewWire.maximumBytes + 1)
        ]
        for object in objects {
            XCTAssertThrowsError(try ReviewWire.decodeCommand(object))
        }
    }

    func testResponsesDefaultToNoTimelineMutationCapabilities() throws {
        let response = ReviewResponse(request: UUID(), revision: 2, state: "review", message: "Analysis complete.",
            cuts: [ReviewCutResponse(id: "cut-1", start: "00:00:01:03", end: "00:00:02:00", duration: "0.9 s",
                                    included: true, eligible: false, reason: "Intersects another dialogue clip.")])
        XCTAssertFalse(response.canApply)
        XCTAssertFalse(response.canHighlight)
        XCTAssertFalse(response.canChangeSelection)
        let data = try XCTUnwrap(ReviewWire.encode(response).data(using: .utf8))
        XCTAssertEqual(try JSONDecoder().decode(ReviewResponse.self, from: data), response)
    }
}
