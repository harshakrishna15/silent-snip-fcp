import Foundation
import SilentSnipCore
import XCTest
@testable import SilentSnipMac

/// Explicitly opted-in, read-only validation of already-exported native XML.
/// It does not open Final Cut, export, import, or touch the native library.
final class NativeProjectRoundTripVerificationTests: XCTestCase {
    @MainActor func testOptInNativeFrozenProjectRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let expectedPath = env["SILENTSNIP_NATIVE_VERIFY_EXPECTED_XML"],
              let actualPath = env["SILENTSNIP_NATIVE_VERIFY_ACTUAL_XML"],
              let reportPath = env["SILENTSNIP_NATIVE_VERIFY_REPORT_OUTPUT"] else {
            throw XCTSkip("Set explicit expected/actual native XML and fresh JSON report paths for opt-in round-trip verification")
        }
        let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
        let evidenceRoot = workspace.appendingPathComponent("build/Throughput/StatefulQuality", isDirectory: true)
        let library = workspace.appendingPathComponent("Cutdown Integration.fcpbundle").standardizedFileURL
        func evidenceURL(_ path: String) throws -> URL {
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(evidenceRoot.path + "/") else {
                throw EditedProjectWriterError.unsupported("native verification accepts explicitly retained StatefulQuality evidence only")
            }
            return url
        }
        let expectedURL = try evidenceURL(expectedPath), actualURL = try evidenceURL(actualPath)
        let reportURL = try evidenceURL(reportPath)
        guard reportURL.pathExtension.lowercased() == "json", !FileManager.default.fileExists(atPath: reportURL.path) else {
            throw EditedProjectWriterError.unsupported("choose a fresh native verification JSON report; existing evidence is never overwritten")
        }
        let directory = expectedURL.deletingLastPathComponent()
        let manifestURL = directory.appendingPathComponent("Manifest.json")
        let sourceReceiptURL = directory.appendingPathComponent("Source-Media-Snapshot.json")
        let editURL = directory.appendingPathComponent("Edit-Report.json")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        func recordedURL(_ key: String) throws -> URL {
            try evidenceURL(XCTUnwrap(manifest[key] as? String, "Missing native fixture provenance: \(key)"))
        }
        func checkDigest(_ url: URL, key: String) throws {
            let expected = try XCTUnwrap(manifest[key] as? String, "Missing native fixture digest: \(key)")
            guard try MediaContentSnapshot.contentHash(at: url) == expected else {
                throw EditedProjectWriterError.verificationFailed("native fixture dependency changed: \(url.path)")
            }
        }
        let sourceXML = try recordedURL("sourceXML"), nativeWAV = try recordedURL("nativeWAV")
        guard try recordedURL("outputXML") == expectedURL else {
            throw EditedProjectWriterError.verificationFailed("the expected XML does not match its native fixture manifest")
        }
        try checkDigest(expectedURL, key: "outputXML_SHA256")
        try checkDigest(sourceXML, key: "sourceXML_SHA256")
        try checkDigest(nativeWAV, key: "nativeWAV_SHA256")
        let edit = try JSONDecoder().decode(EditedProjectReport.self, from: Data(contentsOf: editURL))
        let audio = try XCTUnwrap(edit.losslessAudio, "native frozen verification requires saved lossless render provenance")
        guard audio.scope == .projectMix, audio.url == (try recordedURL("durableNativePCM")),
              audio.sha256 == manifest["durableNativePCM_SHA256"] as? String else {
            throw EditedProjectWriterError.verificationFailed("native frozen render provenance does not match its manifest")
        }
        try audio.validate()
        let historical = try JSONDecoder().decode(MediaContentSnapshot.self, from: Data(contentsOf: sourceReceiptURL))
        let sourceDocument = try TimelineParser.parse(url: sourceXML)
        guard historical.covers(sourceDocument.clips.compactMap(\.mediaURL)),
              audio.timelineRange == sourceDocument.projectRange else {
            throw EditedProjectWriterError.verificationFailed("native fixture lacks complete historical source or full-project render evidence")
        }
        try await historical.validate()
        let expected = try Data(contentsOf: expectedURL), actual = try Data(contentsOf: actualURL)
        let output = try TimelineParser.parse(data: expected)
        let covered = Set(historical.sourceURLs + [audio.url])
        guard Set(output.clips.compactMap(\.mediaURL)).isSubset(of: covered) else {
            throw EditedProjectWriterError.verificationFailed("the frozen output references media outside its historical sources and durable render")
        }
        let dependencies = try await MediaContentSnapshot.capture(historical.sourceURLs + [audio.url, sourceXML, nativeWAV,
            expectedURL, actualURL, sourceReceiptURL, editURL, manifestURL])
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let first = try ProjectRoundTripVerification.verify(expected: expected, actual: actual,
                reportURL: reportURL, allowHostAssignedIdentity: true)
            let expectedDestination = try XMLReplacementTarget(projectData: expected)
            let actualDestination = try XMLReplacementTarget(projectData: actual)
            guard expectedDestination.libraryURL == library, actualDestination.libraryURL == library,
                  actualDestination.eventUID == expectedDestination.eventUID,
                  actualDestination.eventName == expectedDestination.eventName,
                  actualDestination.projectName == expectedDestination.projectName else {
                throw EditedProjectWriterError.verificationFailed("native result is not in its exact intended workspace event and library")
            }
            let boundUID = try XCTUnwrap(first.actualProjectUID)
            var bound = try ProjectRoundTripVerification.verify(expected: expected, actual: actual,
                reportURL: reportURL, allowHostAssignedIdentity: true, expectedHostProjectUID: boundUID,
                expectedHostAudioAssetUIDs: first.hostAssignedAudioAssetUIDs)
            try await historical.validate()
            try audio.validate()
            try await dependencies.validate()
            bound.sourceMediaVerified = true
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(bound).write(to: reportURL, options: .atomic)
            XCTAssertTrue(bound.verified)
            XCTAssertEqual(bound.actualProjectUID, boundUID)
            print("Native frozen project round-trip verified: \(reportURL.path)")
        } catch {
            if var failed = try? JSONDecoder().decode(ProjectRoundTripReport.self, from: Data(contentsOf: reportURL)) {
                failed.verified = false
                failed.sourceMediaVerified = false
                if !failed.differences.contains(error.localizedDescription) { failed.differences.append(error.localizedDescription) }
                try? JSONEncoder().encode(failed).write(to: reportURL, options: .atomic)
            }
            throw error
        }
    }
}
