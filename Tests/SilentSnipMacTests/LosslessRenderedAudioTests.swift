import Foundation
import SilentSnipCore
import XCTest
@testable import SilentSnipMac

final class LosslessRenderedAudioTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("SilentSnipLosslessAudio-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testDurableCopyPreservesPCMAndFormatAndMapsNonzeroTargetToFileZero() async throws {
        let source = try wave(frames: 4_800, channels: 2, bits: 24)
        let bytes = try Data(contentsOf: source)
        let digest = try MediaContentSnapshot.contentHash(at: source)
        let folder = destination()
        let asset = try await LosslessRenderedAudio.retain(from: source, expectedSHA256: digest,
            in: folder, timelineRange: .init(start: .init(3), end: .init(31, 10)))
        XCTAssertEqual(asset.sampleRate, 48_000)
        XCTAssertEqual(asset.channelCount, 2)
        XCTAssertEqual(asset.frameCount, 4_800)
        XCTAssertNotEqual(asset.sha256, digest, "Container identity metadata must distinguish the durable file")
        XCTAssertEqual(asset.nativeSourceSHA256, digest)
        let originalEvidence = try WAVMediaIdentity.evidence(at: source)
        XCTAssertEqual(asset.pcmDataSHA256, originalEvidence.pcmDataSHA256)
        XCTAssertEqual(asset.formatDataSHA256, originalEvidence.formatSHA256)
        XCTAssertNotNil(asset.mediaIdentity)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try asset.sourceRange(for: .init(start: .init(301, 100), end: .init(309, 100))),
            .init(start: .init(1, 100), end: .init(9, 100)))
        try asset.validate()
        let restored = try JSONDecoder().decode(LosslessRenderedAudio.self, from: JSONEncoder().encode(asset))
        XCTAssertEqual(restored, asset)
        try restored.validate()
    }

    func testInteger32AndFloatPCMRemainByteIdenticalWithoutFloat32Conversion() async throws {
        for (bits, float) in [(32, false), (32, true), (64, true)] {
            let source = try wave(frames: 480, channels: 1, bits: bits, float: float)
            let bytes = try Data(contentsOf: source)
            let asset = try await LosslessRenderedAudio.retain(from: source,
                expectedSHA256: MediaContentSnapshot.contentHash(at: source), in: destination(),
                timelineRange: .init(start: .zero, end: .init(1, 100)))
            let original = try WAVMediaIdentity.evidence(at: source)
            let retained = try WAVMediaIdentity.evidence(at: asset.url)
            XCTAssertEqual(retained.pcmDataSHA256, original.pcmDataSHA256,
                "Container identity must preserve low integer bits and floating-point representation")
            XCTAssertEqual(retained.formatSHA256, original.formatSHA256)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            try asset.validate()
        }
    }

    func testRepeatedNativeBytesGainDistinctMediaIdentitiesWithIdenticalPCMAndFormat() async throws {
        for padding in [false, true] {
            let source = try wave(frames: 480, channels: 2, bits: 24, padding: padding)
            let original = try Data(contentsOf: source)
            let sourceHash = try MediaContentSnapshot.contentHash(at: source)
            let first = try await LosslessRenderedAudio.retain(from: source, expectedSHA256: sourceHash,
                in: destination(), timelineRange: .init(start: .zero, end: .init(1, 100)))
            let second = try await LosslessRenderedAudio.retain(from: source, expectedSHA256: sourceHash,
                in: destination(), timelineRange: .init(start: .zero, end: .init(1, 100)))
            XCTAssertNotEqual(first.sha256, second.sha256)
            XCTAssertNotEqual(first.mediaIdentity, second.mediaIdentity)
            XCTAssertEqual(first.nativeSourceSHA256, sourceHash)
            XCTAssertEqual(second.nativeSourceSHA256, sourceHash)
            XCTAssertEqual(first.pcmDataSHA256, second.pcmDataSHA256)
            XCTAssertEqual(first.formatDataSHA256, second.formatDataSHA256)
            XCTAssertEqual(first.frameCount, second.frameCount)
            XCTAssertEqual(try Data(contentsOf: source), original)
            let before = try WAVMediaIdentity.layout(at: source, allowExistingIdentity: false)
            let after = try WAVMediaIdentity.layout(at: first.url, allowExistingIdentity: true)
            let metadataBytes = try Data(contentsOf: first.url)
            for item in after.chunks where ["iXML", "LIST"].contains(item.name) {
                let payload = metadataBytes.subdata(in: Int(item.offset + 8)..<Int(item.offset + 8 + item.size))
                XCTAssertNil(payload.range(of: Data("<NOTE>".utf8)),
                    "Final Cut promotes iXML NOTE text into connected timeline clip notes")
                XCTAssertNil(payload.range(of: Data("ICMT".utf8)),
                    "INFO comments must not create host-generated implementation notes")
            }
            if padding {
                XCTAssertEqual(after.size, before.size)
                XCTAssertEqual(after.chunks.first(where: { $0.name == "data" })?.offset,
                    before.chunks.first(where: { $0.name == "data" })?.offset)
            } else {
                XCTAssertGreaterThan(after.size, before.size)
            }
            try first.validate(); try second.validate()
        }
    }

    func testEncodedHashCannotHideWrongPCMFormatOrIdentityProof() async throws {
        let source = try wave(frames: 480, channels: 2, bits: 24)
        let asset = try await LosslessRenderedAudio.retain(from: source,
            expectedSHA256: MediaContentSnapshot.contentHash(at: source), in: destination(),
            timelineRange: .init(start: .zero, end: .init(1, 100)))
        for field in ["pcm", "format", "identity"] {
            let claimed = try LosslessRenderedAudio(url: asset.url, sha256: asset.sha256,
                sampleRate: asset.sampleRate, channelCount: asset.channelCount, frameCount: asset.frameCount,
                timelineRange: asset.timelineRange, scope: asset.scope, nativeSourceSHA256: asset.nativeSourceSHA256,
                pcmDataSHA256: field == "pcm" ? String(repeating: "0", count: 64) : asset.pcmDataSHA256,
                formatDataSHA256: field == "format" ? String(repeating: "0", count: 64) : asset.formatDataSHA256,
                mediaIdentity: field == "identity" ? UUID() : asset.mediaIdentity)
            XCTAssertThrowsError(try claimed.validate())
        }
    }

    func testProjectSliceKeepsLeadingProjectSamplesRatherThanUsingRawSourceTrim() async throws {
        let source = try wave(frames: 288_000, channels: 2, bits: 16)
        let asset = try await LosslessRenderedAudio.retain(from: source,
            expectedSHA256: MediaContentSnapshot.contentHash(at: source), in: destination(),
            timelineRange: .init(start: .zero, end: .init(6)))
        XCTAssertEqual(try asset.sourceRange(for: .init(start: .init(2), end: .init(5))),
            .init(start: .init(2), end: .init(5)))
    }

    func testProjectMixScopePersistsAndLegacyMetadataDefaultsToSelectedTarget() async throws {
        let source = try wave(frames: 480, channels: 2, bits: 24)
        let asset = try await LosslessRenderedAudio.retain(from: source,
            expectedSHA256: MediaContentSnapshot.contentHash(at: source), in: destination(),
            timelineRange: .init(start: .zero, end: .init(1, 100)), scope: .projectMix)
        XCTAssertEqual(asset.scope, .projectMix)
        let encoded = try JSONEncoder().encode(asset)
        XCTAssertEqual(try JSONDecoder().decode(LosslessRenderedAudio.self, from: encoded).scope, .projectMix)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["scope", "nativeSourceSHA256", "pcmDataSHA256", "formatDataSHA256", "mediaIdentity"] {
            object.removeValue(forKey: key)
        }
        let legacy = try JSONDecoder().decode(LosslessRenderedAudio.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.scope, .selectedTarget)
        XCTAssertNil(legacy.mediaIdentity)
        try legacy.validate()
    }

    func testFractionalProjectTailUsesOnlyVerifiedFloorPCMFrames() async throws {
        let source = try wave(frames: 480, channels: 2, bits: 24)
        let logicalEnd = RationalTime(2403, 240_000) // 480.6 samples.
        let asset = try await LosslessRenderedAudio.retain(from: source,
            expectedSHA256: MediaContentSnapshot.contentHash(at: source), in: destination(),
            timelineRange: .init(start: .zero, end: logicalEnd), scope: .projectMix)
        XCTAssertEqual(asset.physicalDuration, .init(1, 100))
        XCTAssertEqual(try asset.sourceRange(for: .init(start: .zero, end: logicalEnd)),
            .init(start: .zero, end: .init(1, 100)))
        XCTAssertThrowsError(try asset.sourceRange(for: .init(start: .init(1, 96_000), end: logicalEnd)),
            "A native tail exception must not round a fractional interior start")
        XCTAssertThrowsError(try asset.sourceRange(for: .init(start: .zero, end: .init(959, 96_000))),
            "Only the full logical project end can use the native physical tail")
        try asset.validate()
    }

    func testFractionalTailRejectsCeilTruncationAndSelectedTargetTolerance() async throws {
        let logicalEnd = RationalTime(2403, 240_000) // 480.6 samples.
        for frames in [479, 481] {
            let source = try wave(frames: frames, channels: 2, bits: 24)
            let folder = destination()
            do {
                _ = try await LosslessRenderedAudio.retain(from: source,
                    expectedSHA256: MediaContentSnapshot.contentHash(at: source), in: folder,
                    timelineRange: .init(start: .zero, end: logicalEnd), scope: .projectMix)
                XCTFail("The full native mix must end at exactly floor(T*rate), not a nearby frame count")
            } catch { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        }
        let source = try wave(frames: 480, channels: 2, bits: 24)
        let folder = destination()
        do {
            _ = try await LosslessRenderedAudio.retain(from: source,
                expectedSHA256: MediaContentSnapshot.contentHash(at: source), in: folder,
                timelineRange: .init(start: .zero, end: logicalEnd), scope: .selectedTarget)
            XCTFail("An isolated target must not borrow the full-project native tail exception")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testFractionalSampleAndUncoveredKeptRangesAreRejected() async throws {
        let source = try wave(frames: 480, channels: 1, bits: 16)
        let asset = try await LosslessRenderedAudio.retain(from: source,
            expectedSHA256: MediaContentSnapshot.contentHash(at: source), in: destination(),
            timelineRange: .init(start: .init(3), end: .init(301, 100)))
        for range in [TimeRange(start: .init(288_001, 96_000), end: .init(301, 100)),
                      .init(start: .init(2), end: .init(301, 100)),
                      .init(start: .init(3), end: .init(302, 100)),
                      .init(start: .init(3), end: .init(3))] {
            XCTAssertThrowsError(try asset.sourceRange(for: range))
        }
    }

    func testWrongHashOrOneSampleDurationMismatchLeavesNoDurableArtifact() async throws {
        let source = try wave(frames: 480, channels: 1, bits: 24)
        let bytes = try Data(contentsOf: source)
        for (hash, end) in [(String(repeating: "0", count: 64), RationalTime(1, 100)),
                            (try MediaContentSnapshot.contentHash(at: source), RationalTime(481, 48_000))] {
            let folder = destination()
            do {
                _ = try await LosslessRenderedAudio.retain(from: source, expectedSHA256: hash,
                    in: folder, timelineRange: .init(start: .zero, end: end))
                XCTFail("A durable result must not adopt unverified or misaligned audio")
            } catch { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func testCompressedAndTruncatedWAVAreRejectedWithoutCreatingResult() async throws {
        let compressed = try wave(frames: 480, channels: 1, bits: 8, formatCode: 6)
        let truncated = try wave(frames: 480, channels: 2, bits: 24)
        var partial = try Data(contentsOf: truncated)
        partial.removeLast(6)
        try partial.write(to: truncated)
        for source in [compressed, truncated] {
            let folder = destination()
            do {
                _ = try await LosslessRenderedAudio.retain(from: source,
                    expectedSHA256: MediaContentSnapshot.contentHash(at: source), in: folder,
                    timelineRange: .init(start: .zero, end: .init(1, 100)))
                XCTFail("Unsupported or incomplete renders must fail before XML can reference them")
            } catch { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        }
    }

    func testExistingDirectoryIsNeverOverwrittenOrRemoved() async throws {
        let source = try wave(frames: 480, channels: 1, bits: 16)
        let folder = destination()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let marker = folder.appendingPathComponent("Processed-Audio.wav")
        try Data("existing result".utf8).write(to: marker)
        do {
            _ = try await LosslessRenderedAudio.retain(from: source,
                expectedSHA256: MediaContentSnapshot.contentHash(at: source), in: folder,
                timelineRange: .init(start: .zero, end: .init(1, 100)))
            XCTFail("An earlier result must survive a repeated retention request")
        } catch { }
        XCTAssertEqual(try String(contentsOf: marker), "existing result")
    }

    func testChangedDurableAudioFailsValidationAndCleanupCannotRegisterIt() async throws {
        let source = try wave(frames: 480, channels: 1, bits: 16)
        let asset = try await LosslessRenderedAudio.retain(from: source,
            expectedSHA256: MediaContentSnapshot.contentHash(at: source), in: destination(),
            timelineRange: .init(start: .zero, end: .init(1, 100)))
        let storage = StorageCleanup(root: root, byteLimit: 0, maximumAge: 0)
        XCTAssertThrowsError(try storage.register(asset.url))
        XCTAssertEqual(storage.clean(manual: true).removedFiles, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.url.path))
        var bytes = try Data(contentsOf: asset.url)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: asset.url)
        XCTAssertThrowsError(try asset.validate())
    }

    func testAlreadyCancelledRetentionCreatesNoFiles() async throws {
        let source = try wave(frames: 480, channels: 1, bits: 16)
        let hash = try MediaContentSnapshot.contentHash(at: source)
        let folder = destination()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LosslessRenderedAudio.retain(from: source,
                expectedSHA256: hash, in: folder,
                timelineRange: .init(start: .zero, end: .init(1, 100)))
        }
        do { _ = try await task.value; XCTFail("Cancellation must stop before copying") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    private func destination() -> URL {
        root.appendingPathComponent("Processed Audio/\(UUID())", isDirectory: true)
    }

    private func wave(frames: Int, channels: Int, bits: Int, float: Bool = false,
                      formatCode: UInt16? = nil, padding: Bool = false) throws -> URL {
        let block = channels * bits / 8
        let count = frames * block
        var bytes = Data()
        func text(_ value: String) { bytes.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
        }
        text("RIFF"); number(UInt32(36 + count + (padding ? 4028 : 0))); text("WAVE")
        if padding { text("JUNK"); number(UInt32(28)); bytes.append(Data(repeating: 0, count: 28)) }
        text("fmt "); number(UInt32(16))
        number(formatCode ?? (float ? UInt16(3) : UInt16(1)))
        number(UInt16(channels)); number(UInt32(48_000)); number(UInt32(48_000 * block))
        number(UInt16(block)); number(UInt16(bits))
        if padding { text("FLLR"); number(UInt32(3984)); bytes.append(Data(repeating: 0, count: 3984)) }
        text("data"); number(UInt32(count))
        // Include low-order bytes that a decode/re-encode or precision change
        // could discard. Metadata inspection never interprets these samples.
        bytes.append(contentsOf: (0..<count).map { UInt8(($0 * 37 + 1) % 256) })
        let url = root.appendingPathComponent("Native-\(UUID()).wav")
        try bytes.write(to: url)
        return url
    }
}
