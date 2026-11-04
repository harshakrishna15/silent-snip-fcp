import Foundation
import XCTest
@testable import SilentSnipWorkflowModel

final class WorkflowSettingsStoreTests: XCTestCase {
    private var root: URL!
    private var file: URL {
        root.appendingPathComponent("Application Support/Workflow Prototype/Project Settings.json")
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkflowSettings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func identity(library: String = "Library A.fcpbundle", project: String = "project-A") throws -> WorkflowProjectIdentity {
        try WorkflowProjectIdentity(libraryURL: root.appendingPathComponent(library), projectUID: project)
    }

    private func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    private func record(identity: WorkflowProjectIdentity, settings: WorkflowSettings = .defaults) throws -> [String: Any] {
        ["identity": try JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)),
         "settings": try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))]
    }

    private func assertRejectedWithoutOverwrite(_ data: Data, identity: WorkflowProjectIdentity,
                                               file testFile: StaticString = #filePath, line: UInt = #line) async throws {
        try write(data)
        let store = try WorkflowSettingsStore(fileURL: file)
        do {
            _ = try await store.settings(for: identity)
            XCTFail("An invalid archive must not supply project settings", file: testFile, line: line)
        } catch { }
        do {
            try await store.save(.defaults, for: identity)
            XCTFail("Saving must not replace an invalid existing archive", file: testFile, line: line)
        } catch { }
        XCTAssertEqual(try Data(contentsOf: file), data, file: testFile, line: line)
    }

    func testPersistenceSurvivesReopenAndChangesOnlyTheBoundProject() async throws {
        let first = try identity()
        let second = try identity(project: "project-B")
        let settings = try WorkflowSettings(thresholdDBFS: -35.75, minimumSilenceDuration: 0.85,
            beforeSpeechPadding: 0.2, afterSpeechPadding: 0.3, outputMode: .gaps)
        let store = try WorkflowSettingsStore(fileURL: file)
        let missing = try await store.settings(for: first)
        XCTAssertNil(missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        try await store.save(settings, for: first)
        try await store.save(.defaults, for: second)

        let reopened = try WorkflowSettingsStore(fileURL: file)
        let firstSettings = try await reopened.settings(for: first)
        let secondSettings = try await reopened.settings(for: second)
        XCTAssertEqual(firstSettings, settings)
        XCTAssertEqual(secondSettings, .defaults)
        try await reopened.save(.defaults, for: first)
        let updated = try await reopened.settings(for: first)
        let unchanged = try await reopened.settings(for: second)
        XCTAssertEqual(updated, .defaults)
        XCTAssertEqual(unchanged, .defaults)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["schemaVersion", "projects"])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual((json["projects"] as? [Any])?.count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path),
                       [file.lastPathComponent])
    }

    func testSameNamedProjectsAndLibrariesRemainIsolatedByTheirExactBindings() async throws {
        let contexts = [
            WorkflowProjectContext(name: "Interview", identity: try identity()),
            WorkflowProjectContext(name: "Interview", identity: try identity(project: "project-B")),
            WorkflowProjectContext(name: "Interview", identity: try identity(library: "Library B.fcpbundle"))
        ]
        let store = try WorkflowSettingsStore(fileURL: file)
        for (index, context) in contexts.enumerated() {
            try await store.save(WorkflowSettings(thresholdDBFS: -Double(30 + index)), for: context.identity)
        }
        let reopened = try WorkflowSettingsStore(fileURL: file)
        for (index, context) in contexts.enumerated() {
            let loaded = try await reopened.settings(for: context.identity)
            XCTAssertEqual(loaded?.thresholdDBFS, -Double(30 + index))
        }
        let renamed = WorkflowProjectContext(name: "Renamed Interview", identity: contexts[0].identity)
        let renamedSettings = try await reopened.settings(for: renamed.identity)
        XCTAssertEqual(renamedSettings?.thresholdDBFS, -30)
        let unboundSameName = try await reopened.settings(for: WorkflowProjectContext(name: "Interview").identity)
        XCTAssertNil(unboundSameName)
    }

    func testNoIdentityCannotSaveOrCreateAStoreAndCannotReusePriorProject() async throws {
        let store = try WorkflowSettingsStore(fileURL: file)
        let unbound = try WorkflowHostSnapshot(project: .init(name: "Interview"), playheadSeconds: 3)
        XCTAssertFalse(unbound.isProjectBound)
        do {
            try await store.save(.defaults, for: unbound.project?.identity)
            XCTFail("An observed name is not a stable identity")
        } catch {
            XCTAssertEqual(error as? WorkflowModelError, .unboundProject)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))

        let bound = try identity()
        try await store.save(WorkflowSettings(thresholdDBFS: -33), for: bound)
        let before = try Data(contentsOf: file)
        do {
            try await store.save(.defaults, for: nil)
            XCTFail("A previous project must not supply a missing identity")
        } catch {
            XCTAssertEqual(error as? WorkflowModelError, .unboundProject)
        }
        let unboundSettings = try await store.settings(for: nil)
        XCTAssertNil(unboundSettings)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testCorruptAndTruncatedArchivesAreKeptInsteadOfBeingReset() async throws {
        let bound = try identity()
        for data in [Data("not JSON".utf8), Data("{\"schemaVersion\":1,\"projects\":[".utf8), Data()] {
            try await assertRejectedWithoutOverwrite(data, identity: bound)
        }
    }

    func testFutureSchemaCannotBeOverwritten() async throws {
        let bound = try identity()
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "projects": [record(identity: bound)]])
        try await assertRejectedWithoutOverwrite(data, identity: bound)
        let store = try WorkflowSettingsStore(fileURL: file)
        do {
            _ = try await store.settings(for: bound)
            XCTFail("Future schemas must require a supported migration")
        } catch {
            XCTAssertEqual(error as? WorkflowModelError, .unsupportedSchema(2))
        }
    }

    func testInvalidSavedSettingsRejectTheWholeArchiveWithoutPartialRecovery() async throws {
        let bound = try identity()
        var damaged = try record(identity: identity(project: "project-B"))
        var fields = try XCTUnwrap(damaged["settings"] as? [String: Any])
        fields["minimumSilenceDuration"] = 0
        damaged["settings"] = fields
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "projects": [record(identity: bound), damaged]
        ])
        // Even a request for the other valid entry must fail: partial adoption
        // would let the following save silently discard the damaged record.
        try await assertRejectedWithoutOverwrite(data, identity: bound)
    }

    func testDuplicateBindingsAndInvalidIdentityFailClosed() async throws {
        let bound = try identity()
        let valid = try record(identity: bound)
        let duplicate = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "projects": [valid, valid]
        ])
        try await assertRejectedWithoutOverwrite(duplicate, identity: bound)

        var damaged = valid
        damaged["identity"] = ["libraryURL": "https://example.com/Library.fcpbundle", "projectUID": "project-A"]
        let invalidIdentity = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "projects": [damaged]
        ])
        try await assertRejectedWithoutOverwrite(invalidIdentity, identity: bound)
    }

    func testSerializedSavesKeepAllProjectsAndLeaveOtherPreferencesUntouched() async throws {
        let preferences = root.appendingPathComponent("Library/Preferences/com.apple.FinalCut.plist")
        try FileManager.default.createDirectory(at: preferences.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sentinel = Data("existing user preference bytes".utf8)
        try sentinel.write(to: preferences)
        let identities = try (0..<12).map { try identity(project: "project-\($0)") }
        let store = try WorkflowSettingsStore(fileURL: file)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, identity) in identities.enumerated() {
                group.addTask {
                    try await store.save(WorkflowSettings(thresholdDBFS: -Double(30 + index)), for: identity)
                }
            }
            try await group.waitForAll()
        }
        let reopened = try WorkflowSettingsStore(fileURL: file)
        for (index, identity) in identities.enumerated() {
            let settings = try await reopened.settings(for: identity)
            XCTAssertEqual(settings?.thresholdDBFS, -Double(30 + index))
        }
        XCTAssertEqual(try Data(contentsOf: preferences), sentinel)
    }

    func testStoreRejectsNonlocalURLsAndPreservesUnreadableLocations() async throws {
        for address in ["https://example.com/settings.json", "file://another-mac/settings.json", "file:///settings.json?x=1"] {
            XCTAssertThrowsError(try WorkflowSettingsStore(fileURL: XCTUnwrap(URL(string: address))))
        }
        let directory = root.appendingPathComponent("Not A Settings File", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertThrowsError(try WorkflowSettingsStore(fileURL: directory))

        // The URL itself is a valid file location, but an existing regular
        // file blocks its parent directory. Saving must report the failure
        // while preserving that file, rather than replacing it with a folder.
        let blockedParent = root.appendingPathComponent("Parent Is A File", isDirectory: false)
        let sentinel = Data("keep".utf8)
        try sentinel.write(to: blockedParent)
        let blockedFile = blockedParent.appendingPathComponent("Project Settings.json", isDirectory: false)
        let store = try WorkflowSettingsStore(fileURL: blockedFile)
        do {
            try await store.save(.defaults, for: identity())
            XCTFail("An invalid parent must not be replaced to create a settings store")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: blockedParent), sentinel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blockedFile.path))
    }
}
