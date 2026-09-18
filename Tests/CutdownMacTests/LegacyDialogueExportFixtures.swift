import AVFoundation
import CutdownCore
import Darwin
import Foundation
@testable import CutdownMac

/// Historical full-project export tests. The live route uses Share receipts
/// and isolated renders; these helpers are not part of the shipping module.
enum LegacyDialogueExport {
    static func removeEmptyJobDirectory(at directory: URL) throws {
        guard directory.isFileURL else { throw ExportError.invalidWorkspace }
        let result = directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.rmdir(path)
        }
        guard result != 0 else { return }
        let code = errno
        guard code != ENOENT, code != ENOTEMPTY, code != EEXIST else { return }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    static func validateDialogueOnlyProject(_ document: TimelineDocument, xmlURL: URL) throws {
        guard !document.dialogueRoles.isEmpty else { throw ExportError.noDialogue }
        guard !document.clips.contains(where: { $0.enabled && $0.hasAudio && $0.dialogueRoles.isEmpty }) else {
            throw ExportError.mixedAudioRoles
        }
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: xmlURL.path, isDirectory: &isDirectory)
        let file = isDirectory.boolValue ? xmlURL.appendingPathComponent("Info.fcpxml") : xmlURL
        let xml = try XMLDocument(contentsOf: file, options: [.nodeLoadExternalEntitiesNever])
        guard let root = xml.rootElement() else { throw ExportError.noDialogue }
        var nodes = [root]
        while let node = nodes.popLast() {
            var roles: [String] = []
            if let role = node.attribute(forName: "audioRole")?.stringValue { roles.append(role) }
            if ["audio", "audio-channel-source"].contains(node.name ?? ""),
               let role = node.attribute(forName: "role")?.stringValue { roles.append(role) }
            for role in roles {
                let value = role.lowercased()
                guard value == "dialogue" || value.hasPrefix("dialogue.") else { throw ExportError.mixedAudioRoles }
            }
            nodes.append(contentsOf: (node.children ?? []).compactMap { $0 as? XMLElement })
        }
    }

    static func waitForCompletedPCM(at url: URL, expected: RationalTime,
                                               timeout: TimeInterval, cancellationEnabled: Bool) async throws {
        guard url.isFileURL, expected > .zero, timeout.isFinite, timeout > 0 else {
            throw ExportError.incompleteExport
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var stableSince: TimeInterval?
        var priorSize: UInt64?
        var priorDate: Date?
        while ProcessInfo.processInfo.systemUptime < deadline {
            if cancellationEnabled { try Task.checkCancellation() }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? UInt64, size > 44,
               let date = attributes[.modificationDate] as? Date {
                if priorSize == size && priorDate == date {
                    if stableSince == nil { stableSince = ProcessInfo.processInfo.systemUptime }
                } else {
                    priorSize = size; priorDate = date; stableSince = nil
                }
                if let stableSince, ProcessInfo.processInfo.systemUptime - stableSince >= 1,
                   let file = try? AVAudioFile(forReading: url) {
                    let format = file.fileFormat
                    let rate = format.sampleRate
                    if format.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM,
                       rate.isFinite, rate >= 1, rate <= 768_000, rate.rounded() == rate,
                       format.channelCount > 0, format.channelCount <= 64, file.length > 0,
                       abs(Double(file.length) / rate - expected.seconds) <= 1.1 / rate,
                       let sample = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1) {
                        // A provisional WAV header can advertise the full size
                        // before its samples exist. Verify the final frame too.
                        file.framePosition = file.length - 1
                        if (try? file.read(into: sample, frameCount: 1)) != nil, sample.frameLength == 1 {
                            return
                        }
                    }
                }
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw ExportError.incompleteExport
    }
    enum ExportError: Error { case invalidWorkspace, noDialogue, mixedAudioRoles, incompleteExport }
}
