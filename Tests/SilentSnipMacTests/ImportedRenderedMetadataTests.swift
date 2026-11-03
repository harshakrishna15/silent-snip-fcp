import Darwin
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import SilentSnipCore
import XCTest
@testable import SilentSnipMac

final class ImportedRenderedMetadataTests: XCTestCase {
    private struct Fixture {
        let raw: URL
        let audio: LosslessRenderedAudio
        let historical: MediaContentSnapshot
        let expected: Data
        let output: URL
    }
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("SilentSnipImportedMetadata-\(UUID())")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Fixture.fcpbundle"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    @MainActor func testOldReceiptDerivesBoundProofAndAllowsOnlyPriorRenderCTimeChange() async throws {
        let f = try await fixture()
        let verification = try makeVerification(f)
        try verification.savePending()
        let receiptURL = f.output.deletingLastPathComponent().appendingPathComponent("Verification-Receipt.json")
        var receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
        receipt.removeValue(forKey: "renderedAudio") // The build-41 receipt format.
        try JSONSerialization.data(withJSONObject: receipt).write(to: receiptURL)
        let before = try MediaContentSnapshot.FileStamp(f.audio.url)
        try touchMetadata(f.audio.url)
        let after = try MediaContentSnapshot.FileStamp(f.audio.url)
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(before.inode, after.inode)
        XCTAssertEqual(before.modifiedSeconds, after.modifiedSeconds)
        XCTAssertEqual(before.modifiedNanoseconds, after.modifiedNanoseconds)
        let loaded = try ImportedResultVerification.load(outputURL: f.output)
        let report = try await loaded.verify(capture: { try self.hostCopy(f.expected) },
            restore: { _, _ in XCTFail("Frozen output has no controller recovery writes") })
        XCTAssertTrue(report.verified)
        XCTAssertEqual(report.sourceMediaVerified, true)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
        XCTAssertNotNil(saved["renderedAudio"])
        let persisted = try JSONDecoder().decode(MediaContentSnapshot.self,
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(saved["sourceMedia"])))
        XCTAssertEqual(persisted, f.historical, "Never replace historical stamps with the current-phase snapshot")
        do { try await persisted.validate(); XCTFail("The generic validator must retain strict ctime semantics") }
        catch ProjectAnalysisError.changedRenderArtifact { }
    }

    @MainActor func testCurrentCaptureCTimeMutationStillFailsAfterPriorImportMetadataChange() async throws {
        let f = try await fixture()
        let verification = try makeVerification(f)
        try touchMetadata(f.audio.url) // Prior host import phase: allowed.
        do {
            _ = try await verification.verify(capture: {
                try self.touchMetadata(f.audio.url) // Current verification phase: forbidden.
                return try self.hostCopy(f.expected)
            }, restore: { _, _ in XCTFail("A current-phase mutation cannot authorize writes") })
            XCTFail("The current-phase guard must include ctime even for the new render")
        } catch { }
        XCTAssertFalse(try report(for: f).verified)
    }

    @MainActor func testRawMetadataChangeStillFailsBeforeHostAccess() async throws {
        let f = try await fixture()
        let verification = try makeVerification(f)
        try touchMetadata(f.raw)
        do {
            _ = try await verification.verify(capture: {
                XCTFail("Original sources retain every historical stamp check")
                return Data()
            }, restore: { _, _ in XCTFail("Changed originals cannot authorize writes") })
            XCTFail("Only the proven new render can have a prior-phase ctime difference")
        } catch { }
        XCTAssertFalse(try report(for: f).verified)
    }

    func testRenderChangedBytesRestoredMTimeReplacementSizeAndMTimeReject() async throws {
        for mutation in ["bytes", "inode", "size", "mtime"] {
            let f = try await fixture()
            let attributes = try FileManager.default.attributesOfItem(atPath: f.audio.url.path)
            let bytes = try Data(contentsOf: f.audio.url)
            switch mutation {
            case "bytes":
                let layout = try WAVMediaIdentity.layout(at: f.audio.url, allowExistingIdentity: true)
                let data = try XCTUnwrap(layout.chunks.first { $0.name == "data" })
                let file = try FileHandle(forWritingTo: f.audio.url)
                try file.seek(toOffset: data.offset + 8)
                try file.write(contentsOf: Data([bytes[Int(data.offset + 8)] ^ 0x01]))
                try file.close()
                try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: f.audio.url.path)
            case "inode":
                let before = try MediaContentSnapshot.FileStamp(f.audio.url)
                try bytes.write(to: f.audio.url, options: .atomic)
                try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: f.audio.url.path)
                XCTAssertNotEqual(before.inode, try MediaContentSnapshot.FileStamp(f.audio.url).inode)
            case "size":
                let file = try FileHandle(forWritingTo: f.audio.url)
                try file.seekToEnd(); try file.write(contentsOf: Data([0])); try file.close()
            default:
                let date = try XCTUnwrap(attributes[.modificationDate] as? Date)
                try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(1)], ofItemAtPath: f.audio.url.path)
            }
            do {
                _ = try await f.historical.validatedForImport(renderedAudio: f.audio)
                XCTFail("Typed PCM proof must not hide a \(mutation) change")
            } catch { }
        }
    }

    func testLegacyRenderAndHashOnlyHistoryCannotGrantCTimeException() async throws {
        let f = try await fixture()
        try touchMetadata(f.audio.url)
        let legacy = try LosslessRenderedAudio(url: f.audio.url, sha256: f.audio.sha256,
            sampleRate: f.audio.sampleRate, channelCount: f.audio.channelCount, frameCount: f.audio.frameCount,
            timelineRange: f.audio.timelineRange, scope: .projectMix)
        let proofs: [LosslessRenderedAudio?] = [nil, legacy]
        for proof in proofs {
            do {
                _ = try await f.historical.validatedForImport(renderedAudio: proof)
                XCTFail("Legacy data has no complete native PCM identity proof")
            } catch { }
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(f.historical)) as? [String: Any])
        object.removeValue(forKey: "stamps")
        let hashOnly = try JSONDecoder().decode(MediaContentSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        do {
            _ = try await hashOnly.validatedForImport(renderedAudio: f.audio)
            XCTFail("A new exception requires original inode/size/mtime evidence too")
        } catch { }
    }

    @MainActor func testExistingUIDWrongFormatOrAlternateRepresentationCannotBindRenderException() async throws {
        let f = try await fixture()
        for change in ["uid", "rate", "proxy"] {
            let xml = try XMLDocument(data: f.expected)
            let asset = try XCTUnwrap(xml.nodes(forXPath: "//asset[media-rep/@src='\(f.audio.url.absoluteString)']").first as? XMLElement)
            if change == "uid" {
                asset.addAttribute(XMLNode.attribute(withName: "uid", stringValue: "existing-host-asset") as! XMLNode)
            } else if change == "rate" {
                asset.attribute(forName: "audioRate")?.stringValue = "44100"
            } else {
                let proxy = XMLElement(name: "media-rep")
                proxy.addAttribute(XMLNode.attribute(withName: "kind", stringValue: "proxy-media") as! XMLNode)
                proxy.addAttribute(XMLNode.attribute(withName: "src", stringValue: f.raw.absoluteString) as! XMLNode)
                asset.addChild(proxy)
            }
            XCTAssertThrowsError(try ImportedResultVerification(expected: xml.xmlData, outputURL: f.output,
                originalProjectName: "Original", request: .init(id: UUID(), settings: .defaults, outputMode: .remove),
                sourceMedia: f.historical, renderedAudio: f.audio))
        }
    }

    @MainActor private func makeVerification(_ f: Fixture) throws -> ImportedResultVerification {
        try ImportedResultVerification(expected: f.expected, outputURL: f.output,
            originalProjectName: "Original", request: .init(id: UUID(), settings: .defaults, outputMode: .remove), sourceMedia: f.historical)
    }
    @MainActor private func report(for f: Fixture) throws -> ProjectRoundTripReport {
        try JSONDecoder().decode(ProjectRoundTripReport.self,
            from: Data(contentsOf: f.output.deletingLastPathComponent().appendingPathComponent("Import-Verification.json")))
    }
    private func hostCopy(_ expected: Data) throws -> Data {
        let xml = try XMLDocument(data: expected)
        try XCTUnwrap(xml.nodes(forXPath: "//project/@uid").first).stringValue = "host-project"
        return xml.xmlData
    }
    private func touchMetadata(_ url: URL) throws {
        let value = Data(UUID().uuidString.utf8)
        let result = value.withUnsafeBytes { bytes in
            setxattr(url.path, "com.silentsnip.test-import-metadata", bytes.baseAddress, bytes.count, 0, 0)
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    private func fixture() async throws -> Fixture {
        let directory = folder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let raw = directory.appendingPathComponent("Original.wav")
        let frames = 48_000, bytes = frames * 4
        var wave = Data("RIFF".utf8)
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wave.append(contentsOf: $0) }
        }
        number(UInt32(bytes + 36)); wave.append(Data("WAVEfmt ".utf8)); number(UInt32(16))
        number(UInt16(1)); number(UInt16(2)); number(UInt32(48_000)); number(UInt32(192_000))
        number(UInt16(4)); number(UInt16(16)); wave.append(Data("data".utf8)); number(UInt32(bytes))
        wave.append(Data(repeating: 0x13, count: bytes)); try wave.write(to: raw)
        let audio = try await LosslessRenderedAudio.retain(from: raw, expectedSHA256: MediaContentSnapshot.contentHash(at: raw),
            in: directory.appendingPathComponent("Durable"), timelineRange: .init(start: .zero, end: .init(1)), scope: .projectMix)
        let input = Data("""
        <fcpxml version="1.14"><resources><format id="f" frameDuration="1/30s"/>
        <asset id="a" name="Original" start="0s" duration="1s" hasAudio="1" audioSources="1" audioChannels="2" audioRate="48000"><media-rep kind="original-media" src="\(raw.absoluteString)"/></asset>
        </resources><library location="\(folder.appendingPathComponent("Fixture.fcpbundle").absoluteString)"><event name="Fixture" uid="A2476BA7-3CBD-433E-A01B-E73A903F6328"><project name="Original" uid="original-project"><sequence format="f" duration="1s" tcStart="0s"><spine>
        <asset-clip ref="a" name="Original" offset="0s" start="0s" duration="1s" audioRole="dialogue"/>
        </spine></sequence></project></event></library></fcpxml>
        """.utf8)
        let output = try EditedProjectWriter.write(projectData: input, selection: .init(timelineRange: .init(start: .zero, end: .init(1))),
            selectedRanges: [.init(start: .init(1, 5), end: .init(2, 5))], outputName: "Cleaned",
            useOriginalEvent: true, omitController: true, losslessAudio: audio)
        let result = directory.appendingPathComponent("Result")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
        let url = result.appendingPathComponent("Silent Snip.fcpxml")
        try output.xmlData.write(to: url)
        try JSONEncoder().encode(output.report).write(to: result.appendingPathComponent("Edit-Report.json"))
        return Fixture(raw: raw, audio: audio, historical: try await MediaContentSnapshot.capture([raw, audio.url]), expected: output.xmlData, output: url)
    }
}
