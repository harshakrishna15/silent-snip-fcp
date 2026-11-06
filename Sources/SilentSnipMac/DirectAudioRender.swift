import Foundation
import Darwin
import SilentSnipCore
#if canImport(FoundationXML)
import FoundationXML
#endif

/// An optional routing hint, never an authorization or effects cache. The
/// next manual Analyze must prove scope again using its new rendered XML.
struct DirectAudioRenderHint: Codable, Sendable, Equatable {
    /// Routing identity only. A current Workflow request must still pass the
    /// native gesture check before this record can start any host operation.
    /// View and gesture UUIDs deliberately never enter the persisted hint.
    struct WorkflowIdentity: Codable, Sendable, Equatable {
        let libraryURL: URL
        let projectUID: String
        let projectName: String

        init(origin: WorkflowReviewOrigin) {
            libraryURL = URL(fileURLWithPath: origin.libraryURL.standardizedFileURL.resolvingSymlinksInPath().path,
                isDirectory: false)
            projectUID = origin.projectUID
            projectName = origin.projectName
        }

        private static func validName(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && value.utf8.count <= 4_096 && value.rangeOfCharacter(from: .controlCharacters) == nil
        }

        private static func canonicalLibrary(_ url: URL) -> URL? {
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
                  url.path.hasPrefix("/"), url.query == nil, url.fragment == nil,
                  url.user == nil, url.password == nil, url.port == nil,
                  url.pathExtension.lowercased() == "fcpbundle", validName(url.path) else { return nil }
            let canonical = URL(fileURLWithPath: url.path, isDirectory: false)
                .standardizedFileURL.resolvingSymlinksInPath()
            return URL(fileURLWithPath: canonical.path, isDirectory: false)
        }

        var isValid: Bool {
            Self.validName(projectUID) && Self.validName(projectName)
                && Self.canonicalLibrary(libraryURL) == libraryURL
        }

        func matches(_ origin: WorkflowReviewOrigin) -> Bool {
            guard isValid, let canonical = Self.canonicalLibrary(origin.libraryURL),
                  // Fresh XML origin verification deliberately compares the
                  // SDK's literal library path. Do not speculate through an
                  // alias that could deliver a canonical, nonmatching path.
                  origin.libraryURL.path == canonical.path else { return false }
            return canonical == libraryURL && origin.projectUID == projectUID && origin.projectName == projectName
        }

        func verify(projectData: Data) throws {
            let actual = try XMLReplacementTarget(projectData: projectData)
            guard isValid, Self.canonicalLibrary(actual.libraryURL) == libraryURL,
                  actual.originalProjectUID == projectUID, actual.projectName == projectName else {
                throw FinalCutCaptureError.changedProject
            }
        }
    }

    let selection: FinalCutSelectionSnapshot
    let sourceURLs: [URL]
    let scope: DirectAudioRender.Scope
    let workflowIdentity: WorkflowIdentity?

    init(selection: FinalCutSelectionSnapshot, sourceURLs: [URL], scope: DirectAudioRender.Scope,
         workflowIdentity: WorkflowIdentity? = nil) {
        self.selection = selection
        self.sourceURLs = sourceURLs
        self.scope = scope
        self.workflowIdentity = workflowIdentity
    }

    func matches(_ current: FinalCutSelectionSnapshot, workflowOrigin: WorkflowReviewOrigin? = nil) -> Bool {
        guard current == selection else { return false }
        switch (workflowIdentity, workflowOrigin) {
        case (nil, nil): return true
        case let (identity?, origin?): return identity.matches(origin) && origin.projectName == selection.projectName
        default: return false // Legacy AU hints never seed Workflow capture, or vice versa.
        }
    }

    /// Called only after the current request's native gesture is authorized.
    /// Identity/selection misses are ordinary XML capture before dispatch.
    func prepareSourceRead(matching current: FinalCutSelectionSnapshot, workflowOrigin: WorkflowReviewOrigin?,
                           prepare: ([URL]) throws -> MediaContentSnapshot.ReadGuard = MediaContentSnapshot.prepareRead) throws -> MediaContentSnapshot.ReadGuard? {
        try Task.checkCancellation()
        guard matches(current, workflowOrigin: workflowOrigin) else { return nil }
        return try prepareSourceRead(prepare: prepare)
    }

    /// A hint can outlive its sources. Failure before any host dispatch selects
    /// the ordinary XML capture, never a retry of a render that may have started.
    func prepareSourceRead(prepare: ([URL]) throws -> MediaContentSnapshot.ReadGuard = MediaContentSnapshot.prepareRead) throws -> MediaContentSnapshot.ReadGuard? {
        try Task.checkCancellation()
        guard isValidRoutingHint, sourceByteCount() != nil else { return nil }
        // Pin identities and all mutation stamps synchronously. Full content
        // reads start only as structured child work overlapping the host render.
        do {
            let prepared = try prepare(sourceURLs)
            // A canonical local path must remain canonical while its metadata
            // is pinned; a concurrently introduced alias is an optional miss.
            guard prepared.originals == prepared.canonicalURLs else { return nil }
            try prepared.validate()
            return prepared
        }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            return nil
        }
    }

    /// Do not open a FIFO, device or directory supplied by an optional hint.
    /// This checks metadata only; even large camera originals retain a fresh
    /// full-content scan overlapping the host render, without a size exclusion.
    func sourceByteCount() -> Int64? {
        var total: Int64 = 0
        for url in Set(sourceURLs) {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(info.st_size)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }

    /// Bound optional cache inputs before reading any source. Canonical local
    /// paths also prevent a persisted alias from following a different target.
    var isValidRoutingHint: Bool {
        func name(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 1_024 && !value.contains("\0")
        }
        func timecode(_ value: String, permitsDropFrame: Bool) -> Bool {
            guard value.utf8.count == 11 else { return false }
            let bytes = Array(value.utf8)
            return bytes.enumerated().allSatisfy { index, byte in
                if index == 2 || index == 5 { return byte == 58 }
                if index == 8 { return byte == 58 || (permitsDropFrame && byte == 59) }
                return (48...57).contains(byte)
            }
        }
        guard name(selection.projectName), name(selection.clipName),
              timecode(selection.leadingTimecode, permitsDropFrame: true),
              timecode(selection.trailingTimecode, permitsDropFrame: true),
              timecode(selection.durationTimecode, permitsDropFrame: false),
              !sourceURLs.isEmpty, sourceURLs.count <= 256 else { return false }
        if let workflowIdentity {
            guard workflowIdentity.isValid, workflowIdentity.projectName == selection.projectName else { return false }
        }
        return sourceURLs.allSatisfy { url in
            url.isFileURL && (url.host == nil || url.host == "") && url.query == nil && url.fragment == nil
                && url.user == nil && url.password == nil && url.path.hasPrefix("/")
                && url.absoluteString.utf8.count <= 4_096 && !url.path.contains("\0")
                && url.standardizedFileURL == url && url.resolvingSymlinksInPath() == url
        }
    }

    func accepts(projectData: Data, selection: TimelineSelection, media: MediaContentSnapshot,
                 workflowOrigin: WorkflowReviewOrigin? = nil) throws -> Bool {
        if let identity = workflowIdentity {
            guard let origin = workflowOrigin, identity.matches(origin) else { throw FinalCutCaptureError.changedProject }
            // An identity failure after Share is terminal, never another Share.
            try origin.verify(projectData: projectData)
            try identity.verify(projectData: projectData)
        } else if workflowOrigin != nil { throw FinalCutCaptureError.changedProject }
        let document = try TimelineParser.parse(data: projectData)
        guard media.covers(document.clips.filter(\.enabled).compactMap(\.mediaURL)) else { return false }
        return try DirectAudioRender.scope(projectData: projectData, selection: selection) == scope
    }
}

/// One structured exchange. The pre-render guard covers BOTH the host render
/// and concurrent full hashes; source reads never survive this operation's
/// scope. A delivered receipt stays owned here until every source check passes.
enum DirectAudioRenderCapture {
    @MainActor static func perform<Receipt>(prepared: MediaContentSnapshot.ReadGuard,
        captureSources: @Sendable (MediaContentSnapshot.ReadGuard) async throws -> MediaContentSnapshot = {
            try await MediaContentSnapshot.capture(prepared: $0)
        }, render: () async throws -> Receipt,
        cleanup: (Receipt) -> Void) async throws -> (receipt: Receipt, media: MediaContentSnapshot) {
        try Task.checkCancellation()
        try prepared.validate()
        async let pendingMedia = captureSources(prepared)
        let receipt = try await render()
        var transferred = false
        defer { if !transferred { cleanup(receipt) } }
        let media = try await pendingMedia
        try Task.checkCancellation()
        // The hash can finish before Share. Recheck the original guard AFTER
        // both complete, including ctime, to reject transient/restored changes.
        try prepared.validate()
        transferred = true
        return (receipt, media)
    }
}

/// An exact selected-range Dialogue render supplies the target when no other
/// enabled Dialogue overlaps it. Normal asset bounds gate earlier DSP tails.
/// This is a scope proof, independent of effect-cache eligibility: Final Cut
/// still renders every effect, including opaque third-party Audio Units.
enum DirectAudioRender {
    enum Scope: String, Codable, Sendable { case fullProjectTarget, projectSlice, selectedRange }

    static func isEligible(projectData: Data, selection: TimelineSelection) throws -> Bool {
        try scope(projectData: projectData, selection: selection) != nil
    }

    static func scope(projectData: Data, selection: TimelineSelection) throws -> Scope? {
        let document = try TimelineParser.parse(data: projectData)
        let target = try document.selectedTarget(selection, requireExistingMedia: false)
        guard !target.dialogueRoles.isEmpty else { return nil }
        // Reject nested routing, transitions, expanded audio and unknown timing.
        // Only a direct range render can avoid exporting the rest of an edit.
        guard document.clips.allSatisfy({ clip in
            !clip.hasUnresolvedTiming && (clip.isPrimaryStoryline
                ? (clip.kind == "gap" || (clip.kind == "asset-clip" && clip.unsupportedReasons.allSatisfy {
                    ["the clip is disabled", "enabled source audio is required"].contains($0)
                }))
                : (document.canRippleConnection(clip) && clip.unsupportedReasons.allSatisfy {
                    ["connected or nested targets are not supported", "the clip is disabled", "enabled source audio is required"].contains($0)
                }))
        }) else { return nil }
        let xml = try XMLDocument(data: projectData, options: [.nodeLoadExternalEntitiesNever])
        guard let spine = try xml.nodes(forXPath: "//project/sequence/spine").first as? XMLElement else { return nil }
        let items = (spine.children ?? []).compactMap { $0 as? XMLElement }
        guard items.count == document.clips.filter(\.isPrimaryStoryline).count,
              items.allSatisfy({ ["asset-clip", "gap"].contains($0.name ?? "") }) else { return nil }
        func element(_ clip: TimelineClip) -> XMLElement? {
            let path = clip.id.split(separator: "/").dropFirst().compactMap { Int($0) }
            guard let root = path.first, items.indices.contains(root) else { return nil }
            if path.count == 1 { return items[root] }
            let nested = (items[root].children ?? []).compactMap { $0 as? XMLElement }
            guard path.count == 2, nested.indices.contains(path[1]) else { return nil }
            return nested[path[1]]
        }
        func isDialogue(_ value: String?) -> Bool {
            guard let value = value?.lowercased() else { return false }
            return value == "dialogue" || value.hasPrefix("dialogue.")
        }
        func roles(_ node: XMLElement, satisfy predicate: (String?) -> Bool) -> Bool {
            let components = node.elements(forName: "audio-channel-source") + node.elements(forName: "audio-role-source")
            if components.isEmpty {
                return predicate(node.attribute(forName: "audioRole")?.stringValue ?? node.attribute(forName: "role")?.stringValue)
            }
            return components.filter {
                $0.attribute(forName: "enabled")?.stringValue != "0" && $0.attribute(forName: "active")?.stringValue != "0"
            }.allSatisfy {
                predicate($0.attribute(forName: "role")?.stringValue ?? node.attribute(forName: "audioRole")?.stringValue)
            }
        }
        guard let targetNode = element(target), roles(targetNode, satisfy: isDialogue) else { return nil }
        var hasEarlierDialogue = false
        for clip in document.clips where clip.id != target.id && clip.enabled && clip.hasAudio {
            guard let node = element(clip) else { return nil }
            let excluded = roles(node) { value in
                // A verified Dialogue-only Share excludes every other explicit
                // role group, including custom roles. Missing/blank roles are
                // unknown, not proof that the clip is absent from Dialogue.
                guard let role = value, !role.isEmpty,
                      role.trimmingCharacters(in: .whitespacesAndNewlines) == role,
                      role.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                      role.components(separatedBy: ".").allSatisfy({ !$0.isEmpty }) else { return false }
                return !isDialogue(role)
            }
            if !excluded {
                if clip.timelineRange.intersection(target.timelineRange) != nil { return nil }
                if clip.timelineRange.start < target.timelineRange.start { hasEarlierDialogue = true }
            }
        }
        if target.timelineRange == document.projectRange { return .fullProjectTarget }
        let extra = try document.projectRange.checkedDuration().subtracting(target.timelineRange.checkedDuration())
        if !hasEarlierDialogue, extra >= .zero, extra <= RationalTime(30), extra <= target.timelineRange.duration {
            return .projectSlice
        }
        return .selectedRange
    }
}
