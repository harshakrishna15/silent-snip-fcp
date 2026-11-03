import AudioToolbox
import Darwin
import Foundation
import SilentSnipCore

/// Durable native PCM, copied without decoding, resampling, or changing its
/// sample representation. File zero maps to `timelineRange.start` in the
/// captured project's normalized timeline, never to the raw media source trim.
public struct LosslessRenderedAudio: Sendable, Codable, Equatable {
    public enum Scope: String, Sendable, Codable { case selectedTarget, projectMix }
    public let url: URL
    public let sha256: String
    public let sampleRate: Int64
    public let channelCount: Int
    public let frameCount: Int64
    public let timelineRange: TimeRange
    public let scope: Scope
    /// Native render and durable container differ only in media-identity
    /// metadata. These hashes retain the original encoded/PCM/format evidence.
    public let nativeSourceSHA256: String?
    public let pcmDataSHA256: String?
    public let formatDataSHA256: String?
    public let mediaIdentity: UUID?
    /// Native WAV length. A fractional video-project tail can extend less than
    /// one sample beyond this physical end; no extra sample is manufactured.
    public var physicalDuration: RationalTime { RationalTime(frameCount, sampleRate) }

    public init(url: URL, sha256: String, sampleRate: Int64, channelCount: Int,
                frameCount: Int64, timelineRange: TimeRange, scope: Scope = .selectedTarget,
                nativeSourceSHA256: String? = nil, pcmDataSHA256: String? = nil,
                formatDataSHA256: String? = nil, mediaIdentity: UUID? = nil) throws {
        self.url = url
        self.sha256 = sha256.lowercased()
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.timelineRange = timelineRange
        self.scope = scope
        self.nativeSourceSHA256 = nativeSourceSHA256?.lowercased()
        self.pcmDataSHA256 = pcmDataSHA256?.lowercased()
        self.formatDataSHA256 = formatDataSHA256?.lowercased()
        self.mediaIdentity = mediaIdentity
        try validateMapping()
    }

    private enum CodingKeys: String, CodingKey {
        case url, sha256, sampleRate, channelCount, frameCount, timelineRange, scope
        case nativeSourceSHA256, pcmDataSHA256, formatDataSHA256, mediaIdentity
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(url: values.decode(URL.self, forKey: .url),
            sha256: values.decode(String.self, forKey: .sha256),
            sampleRate: values.decode(Int64.self, forKey: .sampleRate),
            channelCount: values.decode(Int.self, forKey: .channelCount),
            frameCount: values.decode(Int64.self, forKey: .frameCount),
            timelineRange: values.decode(TimeRange.self, forKey: .timelineRange),
            scope: values.decodeIfPresent(Scope.self, forKey: .scope) ?? .selectedTarget,
            nativeSourceSHA256: values.decodeIfPresent(String.self, forKey: .nativeSourceSHA256),
            pcmDataSHA256: values.decodeIfPresent(String.self, forKey: .pcmDataSHA256),
            formatDataSHA256: values.decodeIfPresent(String.self, forKey: .formatDataSHA256),
            mediaIdentity: values.decodeIfPresent(UUID.self, forKey: .mediaIdentity))
    }

    /// Map a kept project interval onto the original, continuously rendered
    /// file. Interior boundaries must be exact samples. Only the native
    /// full-project tail can stop at the verified physical WAV end.
    public func sourceRange(for originalProjectRange: TimeRange) throws -> TimeRange {
        try validateMapping()
        guard !originalProjectRange.isEmpty, originalProjectRange.start >= timelineRange.start,
              originalProjectRange.end <= timelineRange.end else { throw Failure.invalidRange }
        let start = try originalProjectRange.start.subtracting(timelineRange.start)
        let logicalEnd = try originalProjectRange.end.subtracting(timelineRange.start)
        let end = scope == .projectMix && originalProjectRange.end == timelineRange.end
            ? physicalDuration : logicalEnd
        _ = try exactFrame(start)
        _ = try exactFrame(end)
        guard end > start else { throw Failure.invalidRange }
        return TimeRange(start: start, end: end)
    }

    /// Recheck disk contents immediately before generating/importing XML.
    /// The caller should run file work away from the UI actor where possible.
    public func validate() throws {
        try validateMapping()
        let guardRead = try MediaContentSnapshot.prepareRead([url])
        let metadata = try Self.inspect(url)
        guard metadata.rate == sampleRate, metadata.channels == channelCount,
              metadata.frames == frameCount else { throw Failure.changedAudio }
        if let mediaIdentity {
            let proof = try WAVMediaIdentity.evidence(at: url)
            guard proof.encodedSHA256 == sha256, proof.pcmDataSHA256 == pcmDataSHA256,
                  proof.formatSHA256 == formatDataSHA256, proof.mediaIdentity == mediaIdentity else {
                throw Failure.changedAudio
            }
        } else {
            guard try MediaContentSnapshot.contentHash(at: url) == sha256 else { throw Failure.changedAudio }
        }
        try guardRead.validate()
    }

    /// Creates a new durable request directory. Once this returns, the file is
    /// result media: keep it after cancellation or uncertain import, and never
    /// register it with StorageCleanup's disposable audio inventory.
    public static func retain(from source: URL, expectedSHA256: String, in directory: URL,
                              timelineRange: TimeRange, scope: Scope = .selectedTarget) async throws -> Self {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try retainSynchronously(from: source, expectedSHA256: expectedSHA256, in: directory,
                timelineRange: timelineRange, scope: scope)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value },
            onCancel: { worker.cancel() })
    }

    private static func retainSynchronously(from source: URL, expectedSHA256: String, in directory: URL,
                                            timelineRange: TimeRange, scope: Scope) throws -> Self {
        try Task.checkCancellation()
        guard source.isFileURL, directory.isFileURL else { throw Failure.invalidLocation }
        let source = try MediaContentSnapshot.canonical(source)
        let directory = StorageCleanup.canonicalLocation(directory)
        let destination = directory.appendingPathComponent("Processed-Audio.wav")
        guard !FileManager.default.fileExists(atPath: directory.path),
              source != destination else { throw Failure.invalidLocation }
        let guardRead = try MediaContentSnapshot.prepareRead([source])
        let metadata = try inspect(source)
        _ = try Self(url: destination, sha256: expectedSHA256, sampleRate: metadata.rate,
            channelCount: metadata.channels, frameCount: metadata.frames, timelineRange: timelineRange, scope: scope)
        let layout = try WAVMediaIdentity.layout(at: source, allowExistingIdentity: false)
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var complete = false
        var createdFile = false
        defer {
            // The private request directory was made by this call and has not
            // been returned to an importer. Remove only this exact new file.
            if !complete {
                if createdFile { _ = unlink(destination.path) }
                _ = rmdir(directory.path)
            }
        }
        guard directory.resolvingSymlinksInPath() == directory else { throw Failure.invalidLocation }
        let sourceFD = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard sourceFD >= 0 else { throw Failure.invalidLocation }
        let input = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: true)
        defer { try? input.close() }
        let destinationFD = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard destinationFD >= 0 else { throw Failure.invalidLocation }
        createdFile = true
        let output = FileHandle(fileDescriptor: destinationFD, closeOnDealloc: true)
        defer { try? output.close() }
        let identity = UUID()
        let copied = try WAVMediaIdentity.copy(input: input, output: output, layout: layout, identity: identity)
        try Task.checkCancellation()
        try output.synchronize()
        try output.close()
        guard copied.nativeSourceSHA256 == expectedSHA256.lowercased() else { throw Failure.changedAudio }
        let result = try Self(url: destination, sha256: copied.evidence.encodedSHA256,
            sampleRate: metadata.rate, channelCount: metadata.channels, frameCount: metadata.frames,
            timelineRange: timelineRange, scope: scope, nativeSourceSHA256: copied.nativeSourceSHA256,
            pcmDataSHA256: copied.evidence.pcmDataSHA256, formatDataSHA256: layout.formatSHA256,
            mediaIdentity: identity)
        try guardRead.validate()
        try result.validate()
        try guardRead.validate()
        try Task.checkCancellation()
        complete = true
        return result
    }

    private func exactFrame(_ time: RationalTime) throws -> Int64 {
        let count = try time.multiplied(by: RationalTime(sampleRate))
        guard count.denominator == 1, count.numerator >= 0, count.numerator <= frameCount else {
            throw Failure.invalidRange
        }
        return count.numerator
    }

    private func validateMapping() throws {
        guard url.isFileURL, sampleRate > 0, sampleRate <= 768_000,
              (1...64).contains(channelCount), frameCount > 0,
              Self.validHash(sha256),
              !timelineRange.isEmpty else {
            throw Failure.invalidRange
        }
        let logicalFrames = try timelineRange.checkedDuration().multiplied(by: RationalTime(sampleRate))
        // Final Cut's verified 29.97/48 kHz native WAV stops at floor(T*rate).
        // Accept only that observed physical end, never a full missing sample,
        // a rounded interior cut, or an unbound arbitrary duration tolerance.
        guard frameCount == logicalFrames.numerator / logicalFrames.denominator,
              scope == .projectMix || logicalFrames.denominator == 1 else { throw Failure.invalidRange }
        let proofFields = [nativeSourceSHA256 != nil, pcmDataSHA256 != nil,
            formatDataSHA256 != nil, mediaIdentity != nil].filter { $0 }.count
        guard proofFields == 0 || (proofFields == 4 && Self.validHash(nativeSourceSHA256!)
            && Self.validHash(pcmDataSHA256!) && Self.validHash(formatDataSHA256!)) else { throw Failure.invalidRange }
    }

    private static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    }

    private static func inspect(_ url: URL) throws -> (rate: Int64, channels: Int, frames: Int64) {
        try Task.checkCancellation()
        var info = stat()
        guard url.isFileURL, lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            throw Failure.invalidLocation
        }
        var audio: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &audio) == noErr, let audio else {
            throw Failure.unsupportedFormat
        }
        defer { AudioFileClose(audio) }
        func read<T>(_ key: AudioFilePropertyID, into value: inout T) throws {
            var size = UInt32(MemoryLayout<T>.size)
            let status = withUnsafeMutableBytes(of: &value) { bytes in
                AudioFileGetProperty(audio, key, &size, bytes.baseAddress!)
            }
            guard status == noErr,
                  size == UInt32(MemoryLayout<T>.size) else { throw Failure.unsupportedFormat }
        }
        var type: AudioFileTypeID = 0
        var format = AudioStreamBasicDescription()
        var bytes: UInt64 = 0, packets: UInt64 = 0
        var offset: Int64 = 0
        try read(kAudioFilePropertyFileFormat, into: &type)
        try read(kAudioFilePropertyDataFormat, into: &format)
        try read(kAudioFilePropertyAudioDataByteCount, into: &bytes)
        try read(kAudioFilePropertyAudioDataPacketCount, into: &packets)
        try read(kAudioFilePropertyDataOffset, into: &offset)
        let float = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = format.mBitsPerChannel
        guard type == kAudioFileWAVEType, format.mFormatID == kAudioFormatLinearPCM,
              format.mSampleRate.isFinite, format.mSampleRate >= 1, format.mSampleRate <= 768_000,
              format.mSampleRate.rounded() == format.mSampleRate,
              (1...64).contains(format.mChannelsPerFrame),
              float ? [32, 64].contains(bits) : [8, 16, 24, 32].contains(bits),
              format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              format.mFramesPerPacket == 1, format.mBytesPerFrame > 0,
              format.mBytesPerPacket == format.mBytesPerFrame,
              UInt64(format.mBytesPerFrame) >= UInt64(format.mChannelsPerFrame) * UInt64((bits + 7) / 8),
              packets > 0, packets <= UInt64(Int64.max), offset >= 0,
              bytes / UInt64(format.mBytesPerFrame) == packets,
              bytes % UInt64(format.mBytesPerFrame) == 0,
              UInt64(offset) <= UInt64(info.st_size), bytes <= UInt64(info.st_size) - UInt64(offset) else {
            throw Failure.unsupportedFormat
        }
        return (Int64(format.mSampleRate), Int(format.mChannelsPerFrame), Int64(packets))
    }

    public enum Failure: LocalizedError {
        case invalidLocation, unsupportedFormat, invalidRange, changedAudio
        public var errorDescription: String? {
            switch self {
            case .invalidLocation: return "The processed audio needs a new, local durable media folder."
            case .unsupportedFormat: return "Preserving sound requires a complete, uncompressed PCM WAV render from Final Cut."
            case .invalidRange: return "The processed audio and retained ranges must match exactly at audio sample boundaries."
            case .changedAudio: return "The verified processed audio changed before it could be preserved. Analyze again."
            }
        }
    }
}
