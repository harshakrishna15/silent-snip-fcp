import CutdownCore
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct AnalysisCacheKey: Equatable {
    let fingerprint: String
    let projectUID: String?
    let projectName: String
    let targetID: String
    let media: MediaContentSnapshot
    let windowDuration: Double
    let hostSession: String

    static func make(data: Data, document: TimelineDocument, target: TimelineClip,
                     media: MediaContentSnapshot, windowDuration: Double, hostSession: String = "") throws -> Self? {
        let xml = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        guard let spine = try xml.nodes(forXPath: "//project/sequence/spine").first as? XMLElement,
              let index = Int(target.id.split(separator: "/").last ?? "") else { return nil }
        let clips = spine.children?.compactMap { $0 as? XMLElement } ?? []
        guard clips.indices.contains(index) else { return nil }
        let effects = try xml.nodes(forXPath: "/fcpxml/resources/effect").compactMap { $0 as? XMLElement }
        let allowed: Set<String> = ["filter-audio", "adjust-volume", "adjust-panner", "audio-channel-source",
            "audio", "fadeIn", "fadeOut", "marker", "chapter-marker", "keyword", "rating", "metadata", "note"]
        for child in clips[index].children?.compactMap({ $0 as? XMLElement }) ?? [] {
            guard allowed.contains(child.name ?? "") else { return nil }
        }
        for node in try clips[index].nodes(forXPath: ".//*").compactMap({ $0 as? XMLElement }) {
            if node.name?.hasPrefix("adjust-") == true && !allowed.contains(node.name!) { return nil }
            // Additional audio resources, retiming and nested mixes require a
            // fresh render; their complete inputs are not represented by this cache.
            if ["timeMap", "filter-video", "ref-clip", "sync-clip", "mc-clip"].contains(node.name ?? "") { return nil }
            if node.name == "audio", node.attribute(forName: "ref") != nil { return nil }
        }
        for filter in try clips[index].nodes(forXPath: ".//filter-audio").compactMap({ $0 as? XMLElement }) {
            let resource = effects.first { $0.attribute(forName: "id")?.stringValue == filter.attribute(forName: "ref")?.stringValue }
            guard let uid = resource?.attribute(forName: "uid")?.stringValue else { return nil }
            if uid == AudioControllerSettings.effectUID { continue }
            // A preset name alone cannot prove its current contents. External
            // or opaque third-party state is deliberately never cache eligible.
            guard filter.attribute(forName: "presetID") == nil else { return nil }
            switch uid {
            case "AudioUnit: 0x61756678000000b3454d4147": // Apple's Noise Gate: require the actual AU state
                guard filter.elements(forName: "data").contains(where: {
                    $0.attribute(forName: "key")?.stringValue == "effectState" &&
                    Data(base64Encoded: $0.stringValue ?? "", options: .ignoreUnknownCharacters)?.isEmpty == false
                }) else { return nil }
            // Native effects with only a parameter list are also conservative
            // misses: a partial list does not prove all processing state.
            default: return nil
            }
        }
        return Self(fingerprint: document.fingerprint, projectUID: document.projectUID,
            projectName: document.projectName, targetID: target.id, media: media, windowDuration: windowDuration, hostSession: hostSession)
    }
}

/// One verified entry per helper process. No cross-launch metadata-only cache.
/// Cached render copies are owned by this object; source files are never deleted.
@MainActor final class AnalysisCache {
    private struct Entry {
        let key: AnalysisCacheKey
        let analysis: AnalyzedAudioProject
        let ownedAudio: URL?
    }
    private var entry: Entry?
    var hasEntry: Bool { entry != nil }
    func clear() {
        if let url = entry?.ownedAudio { try? FileManager.default.removeItem(at: url) }
        entry = nil
    }
    func reuse(key: AnalysisCacheKey?, document: TimelineDocument, target: TimelineClip,
               settings: AnalysisSettings, jobID: UUID) async throws -> AnalyzedAudioProject? {
        guard let key, let entry, key == entry.key else { clear(); return nil }
        if let audio = entry.ownedAudio {
            let snapshot = try? await MediaContentSnapshot.capture([audio])
            guard snapshot?.hashes[audio] == entry.analysis.dialogueContext.audioSHA256 else { clear(); return nil }
        }
        try Task.checkCancellation()
        var refreshed = entry.analysis
        _ = try refreshed.recalculate(settings: settings)
        let review = try ReviewPlan(jobID: jobID, document: document, target: target,
            analysis: refreshed.analysis, requireDialogue: false)
        return AnalyzedAudioProject(document: document, target: target,
            dialogueContext: refreshed.dialogueContext, audio: refreshed.audio,
            settings: settings, analysis: refreshed.analysis, review: review)
    }
    func store(key: AnalysisCacheKey?, analysis: AnalyzedAudioProject, directory: URL) async throws {
        clear()
        guard let key, analysis.audio.windows.count <= 360_000,
              analysis.audio.channelCount <= 8 else { return }
        var retained = analysis
        var owned: URL?
        if analysis.dialogueContext.isolatedTargetID != nil {
            let destination = directory.appendingPathComponent("Cached-Processed-Audio.wav")
            let source = analysis.dialogueContext.audioURL
            let expected = analysis.dialogueContext.audioSHA256
            // Copy and content-check off the main actor. A cache miss/failure
            // must not invalidate an otherwise successful analysis.
            let copied = try await Self.copyRender(source, to: destination, expected: expected)
            guard copied else { return }
            owned = destination
            retained = analysis.retainingAudio(at: destination)
        }
        entry = Entry(key: key, analysis: retained, ownedAudio: owned)
    }
    private nonisolated static func copyRender(_ source: URL, to destination: URL, expected: String) async throws -> Bool {
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 256 * 1_024 * 1_024 else { return false }
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: destination) } }
        try Task.checkCancellation()
        try FileManager.default.copyItem(at: source, to: destination)
        guard try MediaContentSnapshot.contentHash(at: destination) == expected else { return false }
        try Task.checkCancellation()
        keep = true; return true
    }
}
