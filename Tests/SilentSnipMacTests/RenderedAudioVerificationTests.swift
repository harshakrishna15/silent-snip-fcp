import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import SilentSnipCore
import XCTest
@testable import SilentSnipMac

final class RenderedAudioVerificationTests: XCTestCase {
    private var folder: URL!
    private var raw: URL { folder.appendingPathComponent("Original.mov") }
    private var rendered: URL { folder.appendingPathComponent("Processed-Audio.wav") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SilentSnipRenderedVerification-\(UUID())")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Fixture.fcpbundle"), withIntermediateDirectories: true)
        try Data("original media bytes".utf8).write(to: raw)
        try Data("durable processed audio bytes".utf8).write(to: rendered)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    /// The audio-only result no longer references the raw file. Its historical
    /// integrity still belongs to the receipt, alongside the adopted render.
    @MainActor func testAudioOnlyReceiptRetainsRawAndRenderedIntegrityAcrossRestart() async throws {
        let expected = frozenXML(linkedVideo: false)
        let evidence = try await MediaContentSnapshot.capture([raw, rendered])
        XCTAssertFalse(evidence.covers([rendered]), "Exact analysis coverage must retain its original semantics")
        XCTAssertTrue(evidence.containsReferences([rendered]))
        let verification = try makeVerification(expected: expected, media: evidence)
        try verification.savePending()
        let loaded = try ImportedResultVerification.load(outputURL: verification.outputURL)
        let report = try await loaded.verify(capture: { try self.hostCopy(expected) }, restore: { _, _ in
            XCTFail("Rendered output contains no live controller state to restore")
        })
        XCTAssertTrue(report.verified)
        XCTAssertEqual(report.sourceMediaVerified, true)
        XCTAssertNil(report.controllerSettingsPreserved)
    }

    @MainActor func testReceiptWithoutDurableRenderEvidenceRejectsBeforeHostAccess() async throws {
        let verification = try makeVerification(expected: frozenXML(linkedVideo: false),
            media: try await MediaContentSnapshot.capture([raw]))
        do {
            _ = try await verification.verify(capture: {
                XCTFail("Every output reference must be covered before host access")
                return Data()
            }, restore: { _, _ in XCTFail("Missing render evidence must not allow writes") })
            XCTFail("Raw-source evidence cannot authorize a new rendered asset")
        } catch { }
        XCTAssertFalse(try verificationReport(for: verification).verified)
    }

    @MainActor func testChangedRawOrRenderedFileCannotVerifyEvenWhenRawIsNoLongerReferenced() async throws {
        let expected = frozenXML(linkedVideo: false)
        for changed in [raw, rendered] {
            let original = try Data(contentsOf: changed)
            let verification = try makeVerification(expected: expected,
                media: try await MediaContentSnapshot.capture([raw, rendered]))
            try Data(repeating: 0x7f, count: original.count).write(to: changed)
            do {
                _ = try await verification.verify(capture: {
                    XCTFail("Changed historical raw or adopted render must fail before host access")
                    return Data()
                }, restore: { _, _ in XCTFail("Changed media must never permit recovery writes") })
                XCTFail("Both raw and rendered historical contents remain authoritative")
            } catch { }
            let report = try verificationReport(for: verification)
            XCTAssertFalse(report.verified)
            XCTAssertEqual(report.sourceMediaVerified, false)
            try original.write(to: changed)
        }
    }

    @MainActor func testRestoredRawMutationDuringCaptureInvalidatesRenderedResult() async throws {
        let expected = frozenXML(linkedVideo: false)
        let verification = try makeVerification(expected: expected,
            media: try await MediaContentSnapshot.capture([raw, rendered]))
        let original = try Data(contentsOf: raw)
        do {
            _ = try await verification.verify(capture: {
                try Data(repeating: 0, count: original.count).write(to: self.raw)
                try original.write(to: self.raw)
                return try self.hostCopy(expected)
            }, restore: { _, _ in XCTFail("Capture-time mutation must stop before any host writes") })
            XCTFail("The guard must span the historical raw file even though output references only the render")
        } catch { }
        XCTAssertFalse(try verificationReport(for: verification).verified)
    }

    func testLinkedVideoAndRenderedAudioUseStrictWholeProjectComparison() throws {
        let expected = frozenXML(linkedVideo: true)
        XCTAssertTrue(try ProjectRoundTripVerification.compare(expected: expected, actual: hostCopy(expected),
            allowHostAssignedIdentity: true).verified)
        let changes = [
            ("//asset[@id='rendered']/media-rep/@src", raw.absoluteString),
            ("//asset[@id='raw']/media-rep/@src", rendered.absoluteString),
            ("//asset[@id='rendered']/@audioChannels", "1"),
            ("//asset[@id='rendered']/@audioRate", "44100"),
            ("//asset-clip[@ref='rendered']/@start", "1/48000s"),
            ("//asset-clip[@ref='rendered']/@offset", "101s"),
            ("//asset-clip[@ref='raw']/@srcEnable", "all"),
            ("//adjust-transform/@position", "5 0")
        ]
        for (path, value) in changes {
            let changed = try XMLDocument(data: expected)
            try XCTUnwrap(changed.nodes(forXPath: path).first).stringValue = value
            let report = try ProjectRoundTripVerification.compare(expected: expected, actual: changed.xmlData)
            XCTAssertFalse(report.verified, "A rendered-output verification must not hide \(path)")
        }
        let gained = try XMLDocument(data: expected)
        let audio = try XCTUnwrap(gained.nodes(forXPath: "//asset-clip[@ref='rendered']").first as? XMLElement)
        audio.addChild(try XMLElement(xmlString: "<adjust-volume amount='-3dB'/>"))
        XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: expected, actual: gained.xmlData).verified,
            "Applying gain again would change the frozen samples")
        for child in audio.children ?? [] { child.detach() }
        audio.addChild(try XMLElement(xmlString: "<filter-audio ref='gate'/>"))
        XCTAssertFalse(try ProjectRoundTripVerification.compare(expected: expected, actual: gained.xmlData).verified,
            "Reintroduced processing effects must remain visible to the semantic fingerprint")
    }

    @MainActor private func makeVerification(expected: Data, media: MediaContentSnapshot) throws -> ImportedResultVerification {
        let result = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
        let output = result.appendingPathComponent("Silent Snip.fcpxml")
        try expected.write(to: output)
        return try ImportedResultVerification(expected: expected, outputURL: output,
            originalProjectName: "Original", request: .init(id: UUID(), settings: .defaults, outputMode: .remove),
            sourceMedia: media)
    }

    @MainActor private func verificationReport(for verification: ImportedResultVerification) throws -> ProjectRoundTripReport {
        try JSONDecoder().decode(ProjectRoundTripReport.self,
            from: Data(contentsOf: verification.outputURL.deletingLastPathComponent().appendingPathComponent("Import-Verification.json")))
    }

    private func hostCopy(_ data: Data) throws -> Data {
        let xml = try XMLDocument(data: data)
        try XCTUnwrap(xml.nodes(forXPath: "//project/@uid").first).stringValue = "host-project"
        return xml.xmlData
    }

    private func frozenXML(linkedVideo: Bool) -> Data {
        let segments: String
        if linkedVideo {
            segments = """
            <asset-clip ref="raw" name="Camera" offset="0s" start="100s" duration="4s" srcEnable="video">
              <adjust-transform position="0 0"/>
              <asset-clip ref="rendered" name="Processed audio" lane="-1" offset="100s" start="0s" duration="4s" audioRole="dialogue"/>
            </asset-clip>
            <asset-clip ref="raw" name="Camera" offset="4s" start="106s" duration="4s" srcEnable="video">
              <adjust-transform position="0 0"/>
              <asset-clip ref="rendered" name="Processed audio" lane="-1" offset="106s" start="6s" duration="4s" audioRole="dialogue"/>
            </asset-clip>
            """
        } else {
            segments = """
            <asset-clip ref="rendered" name="Processed audio" offset="0s" start="0s" duration="4s" audioRole="dialogue"/>
            <asset-clip ref="rendered" name="Processed audio" offset="4s" start="6s" duration="4s" audioRole="dialogue"/>
            """
        }
        return Data("""
        <fcpxml version="1.11"><resources>
          <format id="f" frameDuration="1/30s"/>
          <asset id="raw" name="Camera" start="100s" duration="10s" hasVideo="1" hasAudio="1"><media-rep kind="original-media" src="\(raw.absoluteString)"/></asset>
          <asset id="rendered" name="Processed audio" start="0s" duration="10s" hasAudio="1" audioSources="1" audioChannels="2" audioRate="48000"><media-rep kind="original-media" src="\(rendered.absoluteString)"/></asset>
          <effect id="gate" name="Gate" uid="native-gate"/>
        </resources><library location="\(folder.appendingPathComponent("Fixture.fcpbundle").absoluteString)"><event name="Fixture" uid="A2476BA7-3CBD-433E-A01B-E73A903F6328">
          <project name="Edited" uid="generated-project"><sequence format="f" duration="8s" tcStart="0s"><spine>\(segments)</spine></sequence></project>
        </event></library></fcpxml>
        """.utf8)
    }
}
