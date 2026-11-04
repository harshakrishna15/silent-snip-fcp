import Foundation
import XCTest
@testable import SilentSnipWorkflowModel

final class WorkflowModelTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkflowModel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func identity(library: String = "Library.fcpbundle", project: String = "project-A") throws -> WorkflowProjectIdentity {
        try WorkflowProjectIdentity(libraryURL: root.appendingPathComponent(library), projectUID: project)
    }

    func testIdentityNormalizesOnlyTheLexicalLibraryLocation() throws {
        let direct = try identity()
        let indirect = try WorkflowProjectIdentity(
            libraryURL: root.appendingPathComponent("Unused/../Library.fcpbundle"), projectUID: "project-A")
        XCTAssertEqual(direct, indirect)

        let original = root.appendingPathComponent("Library.fcpbundle", isDirectory: true)
        let alias = root.appendingPathComponent("Library Alias.fcpbundle")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        let aliased = try WorkflowProjectIdentity(libraryURL: alias, projectUID: "project-A")
        XCTAssertNotEqual(aliased, direct)
        XCTAssertEqual(aliased.libraryURL.path, alias.path)

        let reopened = try JSONDecoder().decode(WorkflowProjectIdentity.self,
            from: JSONEncoder().encode(direct))
        XCTAssertEqual(reopened, direct)
    }

    func testIdentityRejectsMissingUIDAndNonlocalOrAmbiguousLibraryURLs() throws {
        for uid in ["", " \n ", "project\u{0}A"] {
            XCTAssertThrowsError(try WorkflowProjectIdentity(
                libraryURL: root.appendingPathComponent("Library.fcpbundle"), projectUID: uid))
        }
        for address in [
            "https://example.com/Library.fcpbundle",
            "file://another-mac/Library.fcpbundle",
            "file:///Library.fcpbundle?unverified=1",
            "file:///Library.fcpbundle#project",
            "file:///"
        ] {
            XCTAssertThrowsError(try WorkflowProjectIdentity(
                libraryURL: XCTUnwrap(URL(string: address)), projectUID: "project-A"))
        }
        // Opaque UIDs are not normalized by display-name rules.
        XCTAssertNotEqual(try identity(project: "Project-A"), try identity(project: "project-a"))
    }

    func testHostObservationDoesNotBindAProjectFromItsNameOrPlayhead() throws {
        let observed = try WorkflowHostSnapshot(hostName: "Final Cut Pro", hostVersion: "12.4",
            project: .init(name: "Interview"), playheadSeconds: 12.5)
        XCTAssertEqual(observed.project?.name, "Interview")
        XCTAssertEqual(observed.playheadSeconds, 12.5)
        XCTAssertFalse(observed.isProjectBound)
        XCTAssertFalse(try WorkflowHostSnapshot().isProjectBound)

        let bound = try WorkflowHostSnapshot(hostName: "Final Cut Pro",
            project: .init(name: "Interview", identity: identity()), playheadSeconds: 0)
        XCTAssertTrue(bound.isProjectBound)
        for position in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(try WorkflowHostSnapshot(playheadSeconds: position))
        }
    }

    func testSettingsValidateAllControlsAtTheirSupportedBoundaries() throws {
        XCTAssertEqual(try WorkflowSettings(), WorkflowSettings.defaults)
        XCTAssertNoThrow(try WorkflowSettings(thresholdDBFS: -80, minimumSilenceDuration: 0.0001,
            beforeSpeechPadding: 0, afterSpeechPadding: 2, outputMode: .gaps))
        XCTAssertNoThrow(try WorkflowSettings(thresholdDBFS: 0, minimumSilenceDuration: 10,
            beforeSpeechPadding: 2, afterSpeechPadding: 0))

        for value in [-80.0001, 0.0001, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(try WorkflowSettings(thresholdDBFS: value))
        }
        for value in [0, 0.000099, 10.0001, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try WorkflowSettings(minimumSilenceDuration: value))
        }
        for value in [-0.0001, 2.0001, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try WorkflowSettings(beforeSpeechPadding: value))
            XCTAssertThrowsError(try WorkflowSettings(afterSpeechPadding: value))
        }
    }

    func testSettingsDecodingDoesNotBypassValidationOrGuessUnknownOutput() throws {
        let settings = try WorkflowSettings(thresholdDBFS: -31.25, minimumSilenceDuration: 0.7123,
            beforeSpeechPadding: 0.23, afterSpeechPadding: 0.41, outputMode: .gaps)
        let encoded = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(WorkflowSettings.self, from: encoded), settings)

        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for (field, value) in [("thresholdDBFS", -81.0), ("minimumSilenceDuration", 0.0),
                               ("beforeSpeechPadding", -1.0), ("afterSpeechPadding", 2.1)] {
            var damaged = valid
            damaged[field] = value
            let data = try JSONSerialization.data(withJSONObject: damaged)
            XCTAssertThrowsError(try JSONDecoder().decode(WorkflowSettings.self, from: data))
        }
        var unknownOutput = valid
        unknownOutput["outputMode"] = "unrecognized"
        XCTAssertThrowsError(try JSONDecoder().decode(WorkflowSettings.self,
            from: JSONSerialization.data(withJSONObject: unknownOutput)))
        var missing = valid
        missing.removeValue(forKey: "beforeSpeechPadding")
        XCTAssertThrowsError(try JSONDecoder().decode(WorkflowSettings.self,
            from: JSONSerialization.data(withJSONObject: missing)))
    }
}
