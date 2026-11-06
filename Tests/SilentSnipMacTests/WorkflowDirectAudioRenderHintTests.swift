import Foundation
import SilentSnipCore
import XCTest
@testable import SilentSnipMac

final class WorkflowDirectAudioRenderHintTests: XCTestCase {
    private var directory: URL!
    private var library: URL!
    private var source: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("WorkflowRenderHint-\(UUID())", isDirectory: true)
        library = directory.appendingPathComponent("Original.fcpbundle")
        source = directory.appendingPathComponent("Original.wav")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("original source".utf8).write(to: source)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func origin(libraryURL: URL? = nil, uid: String = "project-UID", name: String = "Original") throws -> WorkflowReviewOrigin {
        try .init(view: UUID(), gesture: UUID(), libraryURL: libraryURL ?? library,
            projectUID: uid, projectName: name)
    }

    private func snapshot(project: String = "Original", duration: String = "00:00:05:00") throws -> FinalCutSelectionSnapshot {
        func node(_ role: String, _ description: String, _ value: String,
                  selected: Bool? = nil, children: [AccessibilityNode] = []) -> AccessibilityNode {
            .init(role: role, identifier: nil, title: nil, description: description,
                value: value, selected: selected, enabled: true, children: children)
        }
        return try FinalCutSelectionSnapshot(projectName: project,
            timeline: node("AXLayoutArea", "Project Timeline", "", children: [
                node("AXLayoutItem", "Audio-Clip:Interview", duration, selected: true, children: [
                    node("AXTextField", "Title", "Interview"),
                    node("AXHandle", "Leading Edge", "02:00:00:00"),
                    node("AXHandle", "Trailing Edge", "02:00:05:00")])]))
    }

    private func hint(_ origin: WorkflowReviewOrigin) throws -> DirectAudioRenderHint {
        try .init(selection: snapshot(), sourceURLs: [source], scope: .fullProjectTarget,
            workflowIdentity: .init(origin: origin))
    }

    private func project(libraryURL: URL? = nil, uid: String = "project-UID", name: String = "Original",
                         sourceURL: URL? = nil, duration: Int = 5, preset: String = "opaque.preset") -> Data {
        Data("""
        <fcpxml version="1.14"><resources><format id="f" frameDuration="1/30s"/>
        <asset id="a" start="3600s" duration="30s" hasAudio="1"><media-rep kind="original-media" src="\((sourceURL ?? source).absoluteString)"/></asset>
        <effect id="fx" uid="opaque-third-party"/></resources><library location="\((libraryURL ?? library).absoluteString)">
        <event name="Fixture" uid="BBBB0000-0000-4000-8000-000000000001"><project name="\(name)" uid="\(uid)">
        <sequence format="f" duration="\(duration)s" tcStart="7200s"><spine>
        <asset-clip name="Interview" ref="a" offset="7200s" start="3602s" duration="5s" audioRole="dialogue">
        <filter-audio ref="fx" presetID="\(preset)"/></asset-clip></spine></sequence></project></event></library></fcpxml>
        """.utf8)
    }

    func testCurrentRequestIdentityAndExactAXSelectionGateSourceReadsBeforeShare() throws {
        let original = try origin()
        let candidate = try hint(original)
        let selected = try snapshot()
        let mismatches: [(FinalCutSelectionSnapshot, WorkflowReviewOrigin?)] = [
            (selected, try origin(uid: "same-name-different-project")),
            (selected, try origin(libraryURL: directory.appendingPathComponent("Other.fcpbundle"))),
            (selected, try origin(name: "Renamed")),
            (try snapshot(duration: "00:00:04:00"), original),
            (try snapshot(project: "Another project"), original),
            (selected, nil)
        ]
        for (selection, current) in mismatches {
            let prepared = try candidate.prepareSourceRead(matching: selection, workflowOrigin: current, prepare: { _ in
                XCTFail("A mismatched hint must choose ordinary XML before any source read or Share")
                throw ProjectAnalysisError.changedRenderArtifact
            })
            XCTAssertNil(prepared)
        }
        let current = try origin()
        XCTAssertNotEqual(current.gesture, original.gesture)
        XCTAssertNotEqual(current.view, original.view)
        XCTAssertNotNil(try candidate.prepareSourceRead(matching: selected, workflowOrigin: current))
        // The routing identity is reusable; native authorization still requires
        // the current gesture rather than the previous button identifier.
        XCTAssertFalse(WorkflowReviewGesture.pending(
            identifier: "silentsnip.workflow.analyze.requested.\(original.gesture.uuidString)",
            enabled: false, gesture: current.gesture, action: "analyze"))
    }

    func testLegacyUnboundHintsNeverSeedWorkflowAndWorkflowHintsNeverSeedAU() throws {
        let selected = try snapshot()
        let unbound = DirectAudioRenderHint(selection: selected, sourceURLs: [source], scope: .fullProjectTarget)
        let current = try origin()
        XCTAssertTrue(unbound.matches(selected))
        XCTAssertNil(try unbound.prepareSourceRead(matching: selected, workflowOrigin: current))
        XCTAssertFalse(try hint(current).matches(selected))
    }

    func testAliasRequestsFallBackButCanonicalRequestsCanUseCanonicallyStoredIdentity() async throws {
        let alias = directory.appendingPathComponent("Alias.fcpbundle")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: library)
        let aliasOrigin = try origin(libraryURL: alias)
        let candidate = try hint(aliasOrigin)
        XCTAssertEqual(candidate.workflowIdentity?.libraryURL.path, library.path)
        let canonicalOrigin = try origin()
        XCTAssertNotNil(try candidate.prepareSourceRead(matching: snapshot(), workflowOrigin: canonicalOrigin))
        XCTAssertNil(try candidate.prepareSourceRead(matching: snapshot(), workflowOrigin: aliasOrigin, prepare: { _ in
            XCTFail("Alias requests must use ordinary XML before source reads or Share")
            throw ProjectAnalysisError.changedRenderArtifact
        }))
        let media = try await MediaContentSnapshot.capture([source])
        let selection = TimelineSelection(timelineRange: .init(start: .zero, end: .init(5)))
        XCTAssertTrue(try candidate.accepts(projectData: project(), selection: selection,
            media: media, workflowOrigin: canonicalOrigin))
        let other = directory.appendingPathComponent("Other.fcpbundle")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: other)
        XCTAssertNil(try candidate.prepareSourceRead(matching: snapshot(), workflowOrigin: aliasOrigin, prepare: { _ in
            XCTFail("A retargeted library alias must not read sources or dispatch Share")
            throw ProjectAnalysisError.changedRenderArtifact
        }))
    }

    func testFreshXMLStillMustProveWorkflowIdentityScopeAndSources() async throws {
        let current = try origin()
        let candidate = try hint(current)
        let media = try await MediaContentSnapshot.capture([source])
        let selection = TimelineSelection(timelineRange: .init(start: .zero, end: .init(5)))
        XCTAssertTrue(try candidate.accepts(projectData: project(preset: "changed.opaque.state"),
            selection: selection, media: media, workflowOrigin: current))
        for data in [project(uid: "same-name-different-project"),
                     project(libraryURL: directory.appendingPathComponent("Other.fcpbundle")), project(name: "Renamed")] {
            XCTAssertThrowsError(try candidate.accepts(projectData: data, selection: selection,
                media: media, workflowOrigin: current), "Post-dispatch identity failures must stop, never retry Share")
        }
        XCTAssertFalse(try candidate.accepts(projectData: project(sourceURL: directory.appendingPathComponent("Other.wav")),
            selection: selection, media: media, workflowOrigin: current))
        XCTAssertFalse(try candidate.accepts(projectData: project(duration: 11), selection: selection,
            media: media, workflowOrigin: current))
        XCTAssertThrowsError(try candidate.accepts(projectData: project(), selection: selection, media: media))
    }

    func testRestartSerializationContainsOnlyRoutingIdentityAndConsumesOnce() async throws {
        let original = try origin()
        let candidate = try hint(original)
        let store = DirectAudioRenderHintStore(root: directory)
        let saved = await store.save(candidate)
        XCTAssertTrue(saved)
        let file = directory.appendingPathComponent(DirectAudioRenderHintStore.fileName)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(record["version"] as? Int, 2)
        let fields = try XCTUnwrap(record["hint"] as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["selection", "sourceURLs", "scope", "workflowIdentity"])
        let identity = try XCTUnwrap(fields["workflowIdentity"] as? [String: Any])
        XCTAssertEqual(Set(identity.keys), ["libraryURL", "projectUID", "projectName"])
        let consumed = await DirectAudioRenderHintStore(root: directory).consume()
        let recovered = try XCTUnwrap(consumed)
        XCTAssertEqual(recovered, candidate)
        XCTAssertNotNil(try recovered.prepareSourceRead(matching: snapshot(), workflowOrigin: origin()))
        let repeated = await DirectAudioRenderHintStore(root: directory).consume()
        XCTAssertNil(repeated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testVersionOneRecordsRemainUnboundAndCannotSmuggleWorkflowIdentity() async throws {
        let store = DirectAudioRenderHintStore(root: directory)
        let file = directory.appendingPathComponent(DirectAudioRenderHintStore.fileName)
        let current = try origin()
        let saved = await store.save(try hint(current))
        XCTAssertTrue(saved)
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        record["version"] = 1
        try JSONSerialization.data(withJSONObject: record).write(to: file)
        let smuggled = await store.consume()
        XCTAssertNil(smuggled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        var fields = try XCTUnwrap(record["hint"] as? [String: Any])
        fields.removeValue(forKey: "workflowIdentity")
        record["hint"] = fields
        try JSONSerialization.data(withJSONObject: record).write(to: file)
        let consumed = await store.consume()
        let legacy = try XCTUnwrap(consumed)
        XCTAssertTrue(legacy.matches(try snapshot()))
        XCTAssertNil(try legacy.prepareSourceRead(matching: snapshot(), workflowOrigin: current))
    }

    func testMalformedPersistedWorkflowIdentitiesAreConsumedWithoutSeedingCapture() async throws {
        let store = DirectAudioRenderHintStore(root: directory)
        let file = directory.appendingPathComponent(DirectAudioRenderHintStore.fileName)
        let saved = await store.save(try hint(origin()))
        XCTAssertTrue(saved)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let fields = try XCTUnwrap(record["hint"] as? [String: Any])
        let identity = try XCTUnwrap(fields["workflowIdentity"] as? [String: Any])
        let alias = directory.appendingPathComponent("Alias.fcpbundle")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: library)
        for (key, value) in [("libraryURL", "file://remote/Original.fcpbundle"),
                             ("libraryURL", alias.absoluteString), ("projectUID", ""),
                             ("projectName", "Different AX project")] {
            var invalidIdentity = identity; invalidIdentity[key] = value
            var invalidFields = fields; invalidFields["workflowIdentity"] = invalidIdentity
            var invalidRecord = record; invalidRecord["hint"] = invalidFields
            try JSONSerialization.data(withJSONObject: invalidRecord).write(to: file)
            let consumed = await store.consume()
            XCTAssertNil(consumed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testMissingWorkflowSourcesFallBackBeforeDispatchAndCancellationStaysCancellation() throws {
        let current = try origin()
        let candidate = try hint(current)
        do {
            _ = try candidate.prepareSourceRead(matching: snapshot(), workflowOrigin: current, prepare: { _ in
                throw CancellationError()
            })
            XCTFail("Cancellation must not become an XML fallback")
        } catch is CancellationError { }
        try FileManager.default.removeItem(at: source)
        XCTAssertNil(try candidate.prepareSourceRead(matching: snapshot(), workflowOrigin: current, prepare: { _ in
            XCTFail("A missing optional source must fall back before any source read or Share")
            throw ProjectAnalysisError.changedRenderArtifact
        }))
    }

    @MainActor func testCancelledWorkflowCaptureCleansDeliveredReceiptWithoutRetryOrHintReplay() async throws {
        let current = try origin()
        let store = DirectAudioRenderHintStore(root: directory)
        let saved = await store.save(try hint(current))
        XCTAssertTrue(saved)
        let consumed = await store.consume()
        let candidate = try XCTUnwrap(consumed)
        let prepared = try XCTUnwrap(candidate.prepareSourceRead(matching: snapshot(), workflowOrigin: current))
        let receiptURL = directory.appendingPathComponent("Owned-Render.wav")
        var renders = 0, cleanups = 0
        let operation = Task { @MainActor in
            try await DirectAudioRenderCapture.perform(prepared: prepared, render: {
                renders += 1
                try Data("rendered audio".utf8).write(to: receiptURL)
                withUnsafeCurrentTask { $0?.cancel() }
                return receiptURL
            }, cleanup: { receipt in
                cleanups += 1
                try? FileManager.default.removeItem(at: receipt)
            })
        }
        do { _ = try await operation.value; XCTFail("Cancellation must stop capture") }
        catch is CancellationError { }
        XCTAssertEqual(renders, 1)
        XCTAssertEqual(cleanups, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("original source".utf8))
        let replayed = await DirectAudioRenderHintStore(root: directory).consume()
        XCTAssertNil(replayed)
    }
}
