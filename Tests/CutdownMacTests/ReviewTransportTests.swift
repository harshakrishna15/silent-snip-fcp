import XCTest
@testable import CutdownMac

final class ReviewTransportTests: XCTestCase {
    func testRecreatedViewHandshakeIsBoundedAndCarriesExactSettings() throws {
        let view = UUID()
        let query = try ReviewWire.encode(ReviewReconnectQuery(version: 1, view: view))
        XCTAssertEqual(ReviewReconnectQuery.decode(query)?.view, view)
        for object: Any in ["{}", "[]", "true", "{\"version\":true,\"view\":\"\(view)\"}",
            try ReviewWire.encode(ReviewReconnectQuery(version: 2, view: view)), String(repeating: "x", count: 1025)] {
            XCTAssertNil(ReviewReconnectQuery.decode(object))
        }
        let request = try AnalyzeRequest(url: XCTUnwrap(URL(string: "cutdown://analyze?request=\(UUID())&threshold=-42&minimum=8&before=1.5&after=2&output=gaps")))
        let reply = try ReviewWire.encode(ReviewReconnectReply(view: view, request: request))
        let packet = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        XCTAssertEqual(packet["view"] as? String, view.uuidString)
        XCTAssertEqual(packet["request"] as? String, request.id.uuidString)
        XCTAssertEqual(packet["output"] as? String, "gaps")
        XCTAssertEqual((packet["settings"] as? [String: Double])?["minimum"], 8)
    }

    func testSavedResultURLRejectsAmbiguousOrNonlocalDestinations() throws {
        let base = "cutdown://verify?view=\(UUID())&result=file:///tmp/Cutdown.fcpxml"
        XCTAssertEqual(try ReviewVerificationRequest(url: XCTUnwrap(URL(string: base))).result.path, "/tmp/Cutdown.fcpxml")
        for url in [base + "&view=\(UUID())", base + "#fragment", base.replacingOccurrences(of: "file:///", with: "https://example.org/"),
                    base.replacingOccurrences(of: "Cutdown.fcpxml", with: "Other.fcpxml"), base.replacingOccurrences(of: "file:///", with: "file://remote/")] {
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
        let include = ReviewCommand(request: request, command: .include, cutID: "cut-2", included: false)
        let object = try ReviewWire.encode(include)
        XCTAssertEqual(try ReviewWire.decodeCommand(object), include)
        XCTAssertEqual(ReviewWire.responseName(for: request), "local.cutdown.review.response.v1.\(request.uuidString)")
    }

    func testMalformedOrOversizedMessagesCannotBecomeCommands() {
        let request = UUID().uuidString
        let objects: [Any] = [
            ["command": "apply"],
            "{\"version\":2,\"request\":\"\(request)\",\"command\":\"apply\"}",
            "{\"version\":1,\"request\":\"\(request)\",\"command\":\"include\",\"cutID\":\"cut-1\"}",
            "{\"version\":1,\"request\":\"\(request)\",\"command\":\"highlight\",\"cutID\":\"\"}",
            "{\"version\":1,\"request\":\"bad-id\",\"command\":\"status\"}",
            String(repeating: "x", count: ReviewWire.maximumBytes + 1)
        ]
        for object in objects {
            XCTAssertThrowsError(try ReviewWire.decodeCommand(object))
        }
    }

    func testInvalidInspectorSettingsCannotTriggerRecalculation() throws {
        let command = ReviewCommand(request: UUID(), command: .settings,
            settings: ReviewWireSettings(threshold: -40, minimum: -0.5, before: 0.1, after: 0.1))
        XCTAssertThrowsError(try ReviewWire.decodeCommand(ReviewWire.encode(command)))
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
