import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Gives a native WAV a distinct container identity so Final Cut does not
/// substitute an older, byte-identical file at another URL. PCM and `fmt `
/// payloads are copied verbatim; there is no decoding or sample conversion.
enum WAVMediaIdentity {
    struct Evidence {
        let encodedSHA256: String
        let pcmDataSHA256: String
        let formatSHA256: String
        let mediaIdentity: UUID?
    }
    struct Chunk {
        let name: String
        let offset: UInt64
        let size: UInt64
        var totalSize: UInt64 { 8 + size + size % 2 }
    }
    struct Layout {
        let header: Data
        let size: UInt64
        let chunks: [Chunk]
        let formatSHA256: String
        let mediaIdentity: UUID?
    }
    struct CopyResult {
        let nativeSourceSHA256: String
        let evidence: Evidence
    }

    static func layout(at url: URL, allowExistingIdentity: Bool) throws -> Layout {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        try input.seek(toOffset: 0)
        let header = try read(input, count: 12)
        guard String(decoding: header.prefix(4), as: UTF8.self) == "RIFF",
              String(decoding: header.suffix(4), as: UTF8.self) == "WAVE",
              UInt64(number(header, at: 4)) + 8 == size else { throw Failure.unsupportedContainer }
        var chunks: [Chunk] = []
        var offset: UInt64 = 12
        var format: String?
        var identity: UUID?
        var dataCount = 0, xmlCount = 0
        while offset < size {
            try Task.checkCancellation()
            guard size - offset >= 8, chunks.count < 4096 else { throw Failure.unsupportedContainer }
            try input.seek(toOffset: offset)
            let bytes = try read(input, count: 8)
            let chunk = Chunk(name: String(decoding: bytes.prefix(4), as: UTF8.self),
                offset: offset, size: UInt64(number(bytes, at: 4)))
            guard chunk.totalSize <= size - offset else { throw Failure.unsupportedContainer }
            if chunk.name == "fmt " {
                guard format == nil, (16...4096).contains(chunk.size) else { throw Failure.unsupportedContainer }
                format = digest(try read(input, count: Int(chunk.size)))
            } else if chunk.name == "data" {
                dataCount += 1
                guard chunk.size > 0 else { throw Failure.unsupportedContainer }
            } else if chunk.name == "iXML" {
                xmlCount += 1
                guard allowExistingIdentity, xmlCount == 1, chunk.size <= 65_536 else {
                    throw Failure.unsupportedContainer
                }
                let payload = try read(input, count: Int(chunk.size))
                let text = String(decoding: payload, as: UTF8.self)
                guard text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
                      text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { throw Failure.unsupportedContainer }
                let xml = try XMLDocument(data: payload, options: [.nodeLoadExternalEntitiesNever])
                let values = xml.rootElement()?.elements(forName: "FILE_UID") ?? []
                guard values.count == 1, let value = values[0].stringValue else { throw Failure.unsupportedContainer }
                identity = uuid(value)
                guard identity != nil else { throw Failure.unsupportedContainer }
            }
            chunks.append(chunk)
            offset += chunk.totalSize
        }
        guard offset == size, dataCount == 1, let format else { throw Failure.unsupportedContainer }
        return Layout(header: header, size: size, chunks: chunks, formatSHA256: format, mediaIdentity: identity)
    }

    /// Input/output handles belong to the retaining operation. Work and memory
    /// stay bounded even for a multi-gigabyte native PCM payload.
    static func copy(input: FileHandle, output: FileHandle, layout: Layout, identity: UUID) throws -> CopyResult {
        let metadata = metadataChunks(identity)
        let junk = layout.chunks.firstIndex { $0.name == "JUNK" && $0.size == 28 }
        let filler = layout.chunks.firstIndex { $0.name == "FLLR" && $0.totalSize >= UInt64(metadata.count + 8) }
        // Native Final Cut WAV has both padding chunks: use the exact layout
        // validated in the host. Plain PCM WAV gains bounded metadata before
        // its existing chunks while its format/audio payloads remain intact.
        let reusePadding = junk != nil && filler != nil
        let prefix = reusePadding ? Data() : chunk("JUNK", payload: identityPayload(identity)) + metadata
        let newSize = layout.size + UInt64(prefix.count)
        guard newSize >= 8, newSize - 8 <= UInt64(UInt32.max) else { throw Failure.unsupportedContainer }
        var nativeHash = SHA256(), durableHash = SHA256(), pcmHash = SHA256()
        func original(_ count: Int) throws -> Data {
            let bytes = try read(input, count: count)
            nativeHash.update(data: bytes)
            return bytes
        }
        func write(_ bytes: Data) throws {
            try Task.checkCancellation()
            try output.write(contentsOf: bytes)
            durableHash.update(data: bytes)
        }
        try input.seek(toOffset: 0)
        guard try original(12) == layout.header else { throw Failure.changedSource }
        var header = Data("RIFF".utf8)
        append(UInt32(newSize - 8), to: &header)
        header.append(contentsOf: "WAVE".utf8)
        try write(header)
        try write(prefix)
        for (index, item) in layout.chunks.enumerated() {
            try Task.checkCancellation()
            let oldHeader = try original(8)
            guard String(decoding: oldHeader.prefix(4), as: UTF8.self) == item.name,
                  UInt64(number(oldHeader, at: 4)) == item.size else { throw Failure.changedSource }
            let replaced = reusePadding && (index == junk || index == filler)
            if !replaced { try write(oldHeader) }
            var remaining = item.size
            while remaining > 0 {
                let bytes = try original(Int(min(1_048_576, remaining)))
                if item.name == "data" { pcmHash.update(data: bytes) }
                if !replaced { try write(bytes) }
                remaining -= UInt64(bytes.count)
            }
            if item.size % 2 != 0 {
                let pad = try original(1)
                if !replaced { try write(pad) }
            }
            if replaced, index == junk {
                try write(chunk("JUNK", payload: identityPayload(identity)))
            } else if replaced, index == filler {
                try write(metadata)
                let padding = item.totalSize - UInt64(metadata.count) - 8
                guard padding <= UInt64(UInt32.max), padding % 2 == 0 else { throw Failure.unsupportedContainer }
                var paddingHeader = Data("JUNK".utf8)
                append(UInt32(padding), to: &paddingHeader)
                try write(paddingHeader)
                var left = padding
                while left > 0 {
                    let count = Int(min(left, 1_048_576))
                    try write(Data(repeating: 0, count: count))
                    left -= UInt64(count)
                }
            }
        }
        guard try input.offset() == layout.size, try output.offset() == newSize else { throw Failure.changedSource }
        return CopyResult(nativeSourceSHA256: finish(nativeHash), evidence: .init(
            encodedSHA256: finish(durableHash), pcmDataSHA256: finish(pcmHash),
            formatSHA256: layout.formatSHA256, mediaIdentity: identity))
    }

    /// Independently reads the completed file, including every encoded byte
    /// and every raw audio-payload byte. No Float32 precision reduction occurs.
    static func evidence(at url: URL) throws -> Evidence {
        let layout = try layout(at: url, allowExistingIdentity: true)
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var encoded = SHA256(), pcm = SHA256()
        encoded.update(data: try read(input, count: 12))
        for item in layout.chunks {
            encoded.update(data: try read(input, count: 8))
            var remaining = item.size
            while remaining > 0 {
                let bytes = try read(input, count: Int(min(remaining, 1_048_576)))
                encoded.update(data: bytes)
                if item.name == "data" { pcm.update(data: bytes) }
                remaining -= UInt64(bytes.count)
            }
            if item.size % 2 != 0 { encoded.update(data: try read(input, count: 1)) }
        }
        guard try input.offset() == layout.size else { throw Failure.changedSource }
        return Evidence(encodedSHA256: finish(encoded), pcmDataSHA256: finish(pcm),
            formatSHA256: layout.formatSHA256, mediaIdentity: layout.mediaIdentity)
    }

    private static func read(_ input: FileHandle, count: Int) throws -> Data {
        try Task.checkCancellation()
        var bytes = Data()
        while bytes.count < count {
            guard let next = try input.read(upToCount: count - bytes.count), !next.isEmpty else {
                throw Failure.unsupportedContainer
            }
            bytes.append(next)
        }
        return bytes
    }
    private static func metadataChunks(_ identity: UUID) -> Data {
        let uid = identity.uuidString.replacingOccurrences(of: "-", with: "")
        // Final Cut promotes iXML NOTE / INFO ICMT to timeline clip notes.
        // Identity metadata must not add implementation text to user edits.
        let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><BWFXML><FILE_UID>\(uid)</FILE_UID><PROJECT>Silent Snip</PROJECT></BWFXML>"
        var info = Data("INFO".utf8)
        info.append(chunk("INAM", payload: Data(("Silent Snip PCM " + String(uid.prefix(8)) + "\0").utf8)))
        return chunk("iXML", payload: Data(xml.utf8)) + chunk("LIST", payload: info)
    }
    private static func identityPayload(_ identity: UUID) -> Data {
        var value = identity.uuid
        return withUnsafeBytes(of: &value) { Data($0) } + Data("SilentSnip01".utf8)
    }
    private static func chunk(_ name: String, payload: Data) -> Data {
        var bytes = Data(name.utf8)
        append(UInt32(payload.count), to: &bytes)
        bytes.append(payload)
        if payload.count % 2 != 0 { bytes.append(0) }
        return bytes
    }
    private static func append(_ value: UInt32, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    private static func number(_ bytes: Data, at index: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[index + $1]) << UInt32($1 * 8) }
    }
    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private static func finish(_ hash: SHA256) -> String { hash.finalize().map { String(format: "%02x", $0) }.joined() }
    private static func uuid(_ text: String) -> UUID? {
        let value = text.replacingOccurrences(of: "-", with: "")
        guard value.utf8.count == 32, value.utf8.allSatisfy({ (48...57).contains($0)
            || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        let parts = [8, 4, 4, 4, 12]
        var start = value.startIndex
        let standard = parts.map { length -> String in
            let end = value.index(start, offsetBy: length)
            defer { start = end }
            return String(value[start..<end])
        }.joined(separator: "-")
        return UUID(uuidString: standard)
    }
    enum Failure: LocalizedError {
        case unsupportedContainer, changedSource
        var errorDescription: String? {
            switch self {
            case .unsupportedContainer: return "This native WAV container cannot be given a safe media identity. A complete RIFF PCM WAV below 4 GB without existing iXML identity is required."
            case .changedSource: return "The native processed WAV changed while its media identity was being preserved."
            }
        }
    }
}
