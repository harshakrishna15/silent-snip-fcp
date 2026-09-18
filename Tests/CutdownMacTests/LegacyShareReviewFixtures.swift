// Retired Share review retained only as regression fixtures. The app uses AnalysisReviewCoordinator.
@testable import CutdownMac
import AppKit
import Combine
import CryptoKit
import CutdownCore
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct SharedCutRow: Identifiable {
    public let id: String
    public let range: TimeRange
    public let reason: String?
    public var eligible: Bool { reason == nil }
}

/// Reviews a completed share snapshot. This route never reads or edits Final
/// Cut's live selection; the returned project is always a separate project.
@MainActor public final class ShareReviewSession: ObservableObject {
    @Published public private(set) var document: TimelineDocument?
    @Published public private(set) var dropFrame = false
    @Published public private(set) var targets: [TimelineClip] = []
    @Published public var targetID = "" { didSet { if oldValue != targetID { recalculate() } } }
    @Published public var threshold = -40.0 { didSet { settingsChanged() } }
    @Published public var minimum = 0.5 { didSet { settingsChanged() } }
    @Published public var before = 0.1 { didSet { settingsChanged() } }
    @Published public var after = 0.1 { didSet { settingsChanged() } }
    @Published public private(set) var rows: [SharedCutRow] = []
    @Published public private(set) var included: Set<String> = []
    @Published public private(set) var busy = false
    @Published public private(set) var recalculating = false
    @Published public private(set) var message = "In Final Cut Pro, choose Share → Cutdown to send the project and its Dialogue audio."
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var outputURL: URL?
    @Published public private(set) var outputBlock: String?
    @Published public var destinationLibrary: URL?
    @Published public var outputName = ""
    private var projectData: Data?
    private var audio: DialogueAudio?
    private var operation: Task<Void, Never>?
    private var pendingRecalculation: Task<Void, Never>?
    private var generation = UUID()
    private var jobID = UUID()
    private var readySettings = false

    public init() {
        let saved = UserDefaults.standard
        threshold = saved.object(forKey: "share.threshold") as? Double ?? -40
        minimum = saved.object(forKey: "share.minimum") as? Double ?? 0.5
        before = saved.object(forKey: "share.before") as? Double ?? 0.1
        after = saved.object(forKey: "share.after") as? Double ?? 0.1
        readySettings = true
    }

    public var target: TimelineClip? { targets.first { $0.id == targetID } }
    public var selectedRanges: [TimeRange] { rows.filter { $0.eligible && included.contains($0.id) }.map(\.range) }
    public var removedSeconds: Double { selectedRanges.reduce(0) { $0 + $1.duration.seconds } }
    public var canCreate: Bool { !busy && !recalculating && outputURL == nil && !selectedRanges.isEmpty && outputBlock == nil && target != nil }
    public var hasCachedAudio: Bool { audio != nil }

    public func setStatus(_ status: String) { message = status }
    public func fail(_ error: Error) { message = error.localizedDescription }

    public func useSettings(_ settings: AnalysisSettings) {
        readySettings = false
        threshold = settings.thresholdDBFS; minimum = settings.minimumSilenceDuration
        before = settings.beforeSpeechPadding; after = settings.afterSpeechPadding
        readySettings = true
        settingsChanged()
    }

    /// A caller supplies completed files from one share. A single Dialogue mix
    /// is required. Mixed-role exports need explicit role-selection verification.
    public func receive(xmlURL: URL, mediaURLs: [URL], onDecoded: (() throws -> Void)? = nil) {
        guard !busy else { message = "Another share is being analyzed. Wait for it to finish, then open this share again."; return }
        cancel()
        jobID = UUID(); generation = UUID()
        let token = generation
        busy = true; progress = 0; message = "Reading the shared project…"
        rows = []; included = []; outputURL = nil; outputBlock = nil; audio = nil
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard generation == token else { return }
                let file = xmlURL.pathExtension.lowercased() == "fcpxmld" ? xmlURL.appendingPathComponent("Info.fcpxml") : xmlURL
                let data = try Data(contentsOf: file)
                let parsed = try TimelineParser.parse(data: data)
                guard mediaURLs.count == 1, ["wav", "aif", "aiff", "caf"].contains(mediaURLs[0].pathExtension.lowercased()) else { throw ShareReviewError.singleDialogueMix }
                try LegacyDialogueExport.validateDialogueOnlyProject(parsed, xmlURL: file)
                let choices = parsed.clips.filter { clip in
                    (try? parsed.selectedTarget(.init(timelineRange: clip.timelineRange,
                        sourceURL: clip.mediaURL, sourceStart: clip.sourceStart)))?.id == clip.id
                }
                guard !choices.isEmpty else { throw ShareReviewError.noAudioTarget }
                projectData = data; document = parsed; targets = choices
                let xml = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
                dropFrame = try xml.nodes(forXPath: "//project/sequence/@tcFormat").first?.stringValue == "DF"
                // An occurrence path, position and source trim distinguish repeats.
                targetID = choices[0].id
                outputName = parsed.projectName + " — Cutdown " + Self.timestamp()
                destinationLibrary = try Self.originatingLibrary(data)
                message = "Measuring the shared Dialogue audio…"
                let media = mediaURLs[0]
                let reportProgress: @Sendable (Double) -> Void = { [weak self] value in
                    guard let self else { return }
                    Task { @MainActor in
                        guard self.generation == token else { return }
                        self.progress = value
                    }
                }
                let decoder = Task.detached(priority: .userInitiated) {
                    let beforeHash = try Self.hashFile(media)
                    let decoded = try await DialogueAudioReader.read(url: media, expectedDuration: parsed.projectRange.duration,
                        frameDuration: parsed.frameDuration, progress: reportProgress)
                    guard try Self.hashFile(media) == beforeHash else { throw ProjectAnalysisError.changedRenderArtifact }
                    return decoded
                }
                let decoded = try await withTaskCancellationHandler { try await decoder.value } onCancel: { decoder.cancel() }
                try Task.checkCancellation()
                guard generation == token else { return }
                guard abs(decoded.duration.seconds - parsed.projectRange.duration.seconds) <= 1.1 / decoded.sampleRate else {
                    throw ProjectAnalysisError.incompleteRender
                }
                // The files belong to one completed share; detect replacement
                // during decoding before accepting any removal plan.
                guard try Data(contentsOf: file) == data else { throw ProjectAnalysisError.staleRender }
                try onDecoded?()
                audio = decoded; busy = false; progress = 1
                recalculate()
            } catch {
                guard generation == token else { return }
                busy = false; audio = nil; rows = []; included = []
                message = error is CancellationError ? "Analysis cancelled." : error.localizedDescription
            }
            if generation == token { operation = nil }
        }
    }

    public func include(_ id: String, _ value: Bool) {
        guard !busy, !recalculating, outputURL == nil, let row = rows.first(where: { $0.id == id }), row.eligible else { return }
        if value { included.insert(id) } else { included.remove(id) }
        validateOutput()
    }

    public func selectAll(_ value: Bool) {
        guard !busy, !recalculating, outputURL == nil else { return }
        included = value ? Set(rows.filter(\.eligible).map(\.id)) : []
        validateOutput()
    }

    public func cancel() {
        generation = UUID(); operation?.cancel(); operation = nil
        pendingRecalculation?.cancel(); pendingRecalculation = nil
        busy = false; recalculating = false
        audio = nil; rows = []; included = []; outputBlock = nil
        document = nil; targets = []; projectData = nil; targetID = ""
    }

    public func recalculate() {
        defer { recalculating = false }
        guard !busy, let data = projectData, let document, let target, let audio else { return }
        outputURL = nil
        do {
            let settings = try AnalysisSettings(thresholdDBFS: threshold, minimumSilenceDuration: minimum,
                beforeSpeechPadding: before, afterSpeechPadding: after)
            let detection = try SilenceDetector.analyze(windows: audio.windows, target: target.timelineRange,
                frameDuration: document.frameDuration, settings: settings)
            let review = try ReviewPlan(jobID: jobID, document: document, target: target, analysis: detection)
            let previous = rows.map(\.range)
            rows = review.cuts.map { cut in
                var reason = cut.unavailableReason
                if reason == nil {
                    do { _ = try EditedProjectWriter.write(projectData: data, selection: Self.selection(target),
                        selectedRanges: [cut.range], outputName: "Cutdown validation") }
                    catch { reason = error.localizedDescription }
                }
                return SharedCutRow(id: cut.id, range: cut.range, reason: reason)
            }
            let eligible = Set(rows.filter(\.eligible).map(\.id))
            included = previous == rows.map(\.range) ? included.intersection(eligible) : eligible
            switch detection.disposition {
            case .cuts: message = "Review the cuts below. The result will be a new project based on the shared snapshot."
            case .noSilence: message = "No qualifying silence was found. No edits are needed."
            case .entirelySilent: message = "The selected audio is entirely below the threshold. Whole-clip deletion is unavailable."
            }
            validateOutput()
        } catch { rows = []; included = []; outputBlock = error.localizedDescription; message = error.localizedDescription }
    }

    /// Writes first, then a separate UI action asks Final Cut to import the file.
    /// A failed import leaves the reviewable FCPXML available for retry.
    public func createOutput(in directory: URL? = nil) throws -> URL {
        guard canCreate, let projectData, let target else { throw ShareReviewError.notReady }
        if let destinationLibrary {
            guard destinationLibrary.isFileURL, destinationLibrary.pathExtension == "fcpbundle",
                  FileManager.default.fileExists(atPath: destinationLibrary.path) else { throw ShareReviewError.invalidLibrary }
        }
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cutdown/Results/\(jobID.uuidString)", isDirectory: true)
        let output = try EditedProjectWriter.write(projectData: projectData, selection: Self.selection(target),
            selectedRanges: selectedRanges, outputName: outputName, destinationLibrary: destinationLibrary)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Cutdown-\(UUID().uuidString).fcpxml")
        try output.xmlData.write(to: url, options: .withoutOverwriting)
        // The input is a small metadata snapshot, not copied source media.
        try projectData.write(to: folder.appendingPathComponent("Before-Cutdown.fcpxml"), options: .atomic)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(output.report).write(to: folder.appendingPathComponent("Edit-Report.json"), options: .atomic)
        outputURL = url
        message = "Edited project created. Open it in Final Cut Pro to import the retained audio segments."
        return url
    }

    private func validateOutput() {
        outputBlock = nil
        guard let data = projectData, let target, !selectedRanges.isEmpty else { return }
        do { _ = try EditedProjectWriter.write(projectData: data, selection: Self.selection(target),
            selectedRanges: selectedRanges, outputName: "Cutdown validation") }
        catch { outputBlock = error.localizedDescription }
    }

    private func settingsChanged() {
        guard readySettings else { return }
        let defaults = UserDefaults.standard
        defaults.set(threshold, forKey: "share.threshold"); defaults.set(minimum, forKey: "share.minimum")
        defaults.set(before, forKey: "share.before"); defaults.set(after, forKey: "share.after")
        recalculating = true
        outputBlock = "Updating cuts…"
        pendingRecalculation?.cancel()
        pendingRecalculation = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation() }
            catch { return }
            self?.recalculate()
        }
    }

    nonisolated private static func hashFile(_ url: URL) throws -> SHA256.Digest {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize()
    }

    private static func selection(_ clip: TimelineClip) -> TimelineSelection {
        .init(timelineRange: clip.timelineRange, sourceURL: clip.mediaURL, sourceStart: clip.sourceStart)
    }
    private static func timestamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"; return f.string(from: Date())
    }
    private static func originatingLibrary(_ data: Data) throws -> URL? {
        let xml = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        let path = try xml.nodes(forXPath: "/fcpxml/library/@location").first?.stringValue
            ?? xml.nodes(forXPath: "/fcpxml/import-options/option[@key='library location']/@value").first?.stringValue
        guard let path, let url = URL(string: path), url.isFileURL,
              url.pathExtension == "fcpbundle", FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

public enum ShareReviewError: LocalizedError {
    case singleDialogueMix, noAudioTarget, notReady, invalidLibrary
    public var errorDescription: String? {
        switch self {
        case .singleDialogueMix: return "Share one combined, full-project Dialogue WAV. Separate role files and video exports are not supported by this review yet."
        case .noAudioTarget: return "The shared project has no supported, available audio-only primary-storyline clip."
        case .notReady: return "Select at least one eligible cut before creating the edited project."
        case .invalidLibrary: return "Choose an existing Final Cut library (.fcpbundle)."
        }
    }
}
