import Foundation
import SilentSnipCore
#if canImport(FoundationXML)
import FoundationXML
#endif
import XCTest
@testable import SilentSnipMac

/// An explicitly opted-in artifact generator. It does not open Final Cut or
/// import anything. Native exported-result PCM comparison remains separate.
final class NativeLosslessWriterFixtureTests: XCTestCase {
    @MainActor func testOptInNativeFrozenProjectFixture() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let sourcePath = env["SILENTSNIP_NATIVE_MIX_SOURCE_XML"],
              let wavePath = env["SILENTSNIP_NATIVE_MIX_WAV"],
              let cutsPath = env["SILENTSNIP_NATIVE_MIX_CUT_REPORT"],
              let outputPath = env["SILENTSNIP_NATIVE_MIX_FIXTURE_OUTPUT"] else {
            throw XCTSkip("Opt-in generated/native fixture writer; requires explicit source XML, native WAV, cuts and fresh output paths")
        }
        let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
        let library = workspace.appendingPathComponent("Cutdown Integration.fcpbundle")
        let allowed = workspace.appendingPathComponent("build/Throughput/StatefulQuality", isDirectory: true)
        let output = URL(fileURLWithPath: outputPath).standardizedFileURL.resolvingSymlinksInPath()
        XCTAssertTrue(output.path.hasPrefix(allowed.path + "/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        guard output.path.hasPrefix(allowed.path + "/"), !FileManager.default.fileExists(atPath: output.path) else {
            throw EditedProjectWriterError.unsupported("native evidence output must be a new StatefulQuality folder")
        }
        let source = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath()
        let wave = URL(fileURLWithPath: wavePath).resolvingSymlinksInPath()
        let sourceBytes = try Data(contentsOf: source)
        let sourceHash = try MediaContentSnapshot.contentHash(at: source)
        let waveHash = try MediaContentSnapshot.contentHash(at: wave)
        let document = try TimelineParser.parse(data: sourceBytes)
        let tree = try XMLDocument(data: sourceBytes, options: [.nodeLoadExternalEntitiesNever])
        let locations = try tree.nodes(forXPath: "/fcpxml/library/@location").compactMap(\.stringValue)
        XCTAssertEqual(locations.count, 1)
        guard locations.count == 1, URL(string: locations[0])?.resolvingSymlinksInPath().standardizedFileURL.path == library.path else {
            throw EditedProjectWriterError.unsupported("native fixture source must identify the exact workspace library")
        }
        let targets = document.clips.filter { $0.isPrimaryStoryline && $0.enabled && $0.hasAudio }
        guard targets.count == 1, let target = targets.first else {
            throw EditedProjectWriterError.unsupported("supply a generated fixture with one primary audio target")
        }
        guard target.timelineRange == document.projectRange else {
            throw EditedProjectWriterError.unsupported("this native probe requires a declared full-project target; offset targets need independently supplied cut coordinates")
        }
        let rawURLs = document.clips.compactMap(\.mediaURL)
        for url in rawURLs {
            guard url.path.hasPrefix(workspace.appendingPathComponent("build").path + "/"),
                  url.lastPathComponent.hasPrefix("Generated ") else {
                throw EditedProjectWriterError.unsupported("native fixture accepts explicitly generated source media only")
            }
        }
        let rawSnapshot = try await MediaContentSnapshot.capture(rawURLs)
        let cutData = try Data(contentsOf: URL(fileURLWithPath: cutsPath))
        let cutObject = try JSONSerialization.jsonObject(with: cutData) as? [String: Any]
        guard let selected = cutObject?["selectedRanges"] else {
            throw EditedProjectWriterError.invalidRange
        }
        let ranges = try JSONDecoder().decode([TimeRange].self,
            from: JSONSerialization.data(withJSONObject: selected))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let sourceSnapshotURL = output.appendingPathComponent("Source-Media-Snapshot.json")
        let snapshotEncoder = JSONEncoder()
        snapshotEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try snapshotEncoder.encode(rawSnapshot).write(to: sourceSnapshotURL, options: .withoutOverwriting)
        let retained = try await LosslessRenderedAudio.retain(from: wave, expectedSHA256: waveHash,
            in: output.appendingPathComponent("Native PCM", isDirectory: true),
            timelineRange: document.projectRange, scope: .projectMix)
        let name = "Disposable Native Frozen " + String(UUID().uuidString.prefix(8))
        let result = try EditedProjectWriter.write(projectData: sourceBytes,
            selection: .init(timelineRange: target.timelineRange, sourceURL: target.mediaURL, sourceStart: target.sourceStart),
            selectedRanges: ranges, outputName: name, destinationLibrary: library,
            useOriginalEvent: true, omitController: true, losslessAudio: retained)
        let xml = output.appendingPathComponent("Frozen-Writer.fcpxml")
        try result.xmlData.write(to: xml, options: .withoutOverwriting)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result.report).write(to: output.appendingPathComponent("Edit-Report.json"), options: .withoutOverwriting)
        let dtd = URL(fileURLWithPath: "/Applications/Final Cut Pro.app/Contents/Frameworks/Interchange.framework/Versions/A/Resources/FCPXMLv1_14.dtd")
        let validation = Process()
        validation.executableURL = URL(fileURLWithPath: "/usr/bin/xmllint")
        validation.arguments = ["--noout", "--nonet", "--dtdvalid", dtd.absoluteString, xml.path]
        let diagnosticURL = output.appendingPathComponent("DTD-Validation.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: diagnosticURL.path, contents: nil))
        let diagnostics = try FileHandle(forWritingTo: diagnosticURL)
        validation.standardError = diagnostics
        try validation.run()
        validation.waitUntilExit()
        try diagnostics.close()
        let diagnosticText = String(decoding: try Data(contentsOf: diagnosticURL), as: UTF8.self)
        XCTAssertEqual(validation.terminationStatus, 0, diagnosticText)
        guard validation.terminationStatus == 0 else {
            throw EditedProjectWriterError.verificationFailed("native fixture DTD: " + diagnosticText)
        }
        try await rawSnapshot.validate()
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(try MediaContentSnapshot.contentHash(at: wave), waveHash)
        try retained.validate()
        let manifest: [String: Any] = ["experimentalOnly": true, "imported": false,
            "nativeResultPCMEqualityEstablished": false, "projectName": name,
            "projectUID": result.report.projectUID.uuidString, "library": library.path,
            "sourceXML": source.path, "sourceXML_SHA256": sourceHash,
            "nativeWAV": wave.path, "nativeWAV_SHA256": waveHash,
            "cutRangesInput": cutsPath, "outputXML": xml.path,
            "sourceMediaSnapshot": sourceSnapshotURL.path,
            "outputXML_SHA256": try MediaContentSnapshot.contentHash(at: xml),
            "durableNativePCM": retained.url.path, "durableNativePCM_SHA256": retained.sha256,
            "retainedTargetSegments": result.report.retainedSegments.count,
            "installedDTDValidated": dtd.path,
            "scope": "REAL compiled production writer with projectMix provenance; original generated source media and native render unchanged; no import or host actions"]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("Manifest.json"), options: .withoutOverwriting)
        print("Native frozen fixture: \(xml.path) — \(name)")
    }
}
