import SilentSnipCore
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct ProjectRoundTripReport: Codable, Sendable {
    var verified: Bool
    var differences: [String]
    let expectedProjectUID: String?
    let actualProjectUID: String?
    let expectedFingerprint: String
    let actualFingerprint: String
    /// Separate from rendering verification: FCP can omit passthrough AU state.
    let controllerSettingsPreserved: Bool?
    /// False means a legacy result has no historical source-content evidence.
    var sourceMediaVerified: Bool? = nil
    /// New local audio assets have no pre-import host UID. Record only identities
    /// assigned to the same exact original-media URL, never an existing UID.
    var hostAssignedAudioAssetUIDs: [String: String]? = nil
}

enum ProjectRoundTripVerification {
    /// Local to a verification attempt. Never reuse a host snapshot after a
    /// restore or another export; the expected output bytes remain immutable.
    struct Snapshot {
        let document: TimelineDocument
        let settings: [String: AnalysisSettings]
        fileprivate let data: Data

        init(data: Data) throws {
            self.data = data
            let exclusions = TimelineFingerprintExclusions(controllerEffectUIDs: [AudioControllerSettings.effectUID])
            document = try TimelineParser.parse(data: data, exclusions: exclusions)
            settings = try AudioControllerSettings.settingsByPrimaryClip(projectData: data)
        }
    }

    struct Comparison {
        let expected: Snapshot
        let actual: Snapshot
        let report: ProjectRoundTripReport

        init(expected: Snapshot, actual: Snapshot, allowHostAssignedIdentity: Bool = false,
             expectedHostProjectUID: String? = nil, expectedHostAudioAssetUIDs: [String: String]? = nil) {
            self.expected = expected
            self.actual = actual
            report = ProjectRoundTripVerification.compare(expected: expected, actual: actual,
                allowHostAssignedIdentity: allowHostAssignedIdentity, expectedHostProjectUID: expectedHostProjectUID,
                expectedHostAudioAssetUIDs: expectedHostAudioAssetUIDs)
        }

        @discardableResult func verify(reportURL: URL) throws -> ProjectRoundTripReport {
            try ProjectRoundTripVerification.saveAndVerify(report, reportURL: reportURL)
        }
    }

    /// Compare complete semantic timelines. Resource IDs, bookmarks, numeric
    /// time spelling, and only the passthrough controller's private settings are
    /// normalized by the parser. Rendering effects are never excluded. For a
    /// lossless-render result, the expected XML explicitly contains its durable
    /// audio asset and trimmed occurrences; neither media substitution nor
    /// reintroduced DSP is hidden by a special render verification mode.
    static func compare(expected: Data, actual: Data, allowHostAssignedIdentity: Bool = false, expectedHostProjectUID: String? = nil,
                        expectedHostAudioAssetUIDs: [String: String]? = nil) throws -> ProjectRoundTripReport {
        try Comparison(expected: Snapshot(data: expected), actual: Snapshot(data: actual),
            allowHostAssignedIdentity: allowHostAssignedIdentity, expectedHostProjectUID: expectedHostProjectUID,
            expectedHostAudioAssetUIDs: expectedHostAudioAssetUIDs).report
    }

    private static func compare(expected: Snapshot, actual: Snapshot, allowHostAssignedIdentity: Bool,
                                expectedHostProjectUID: String?, expectedHostAudioAssetUIDs: [String: String]?) -> ProjectRoundTripReport {
        // A failure to establish these narrow host normalizations keeps the
        // original strict comparison; it never turns an unknown difference into
        // authorization. Timeline child order and rendering DSP stay untouched.
        let normalized = try? normalizedHostAudioAssets(expected: expected, actual: actual,
            allowHostAssignedIdentity: allowHostAssignedIdentity)
        let want = normalized?.expected.document ?? expected.document
        let got = normalized?.actual.document ?? actual.document
        var differences: [String] = []
        // Final Cut assigns a fresh project UUID on XML import. The first host
        // delivery may bind that UUID (including XML delivered with a render).
        // Comparisons against already bound host projects remain strict.
        if want.projectUID != got.projectUID && !allowHostAssignedIdentity { differences.append("project identity") }
        if allowHostAssignedIdentity && (got.projectUID?.isEmpty != false) { differences.append("missing imported project identity") }
        if let bound = expectedHostProjectUID, got.projectUID != bound { differences.append("imported project identity changed") }
        if let bound = expectedHostAudioAssetUIDs, (normalized?.assigned ?? [:]) != bound {
            differences.append("imported audio asset identity changed")
        }
        if want.projectName != got.projectName { differences.append("project name") }
        if want.projectRange != got.projectRange { differences.append("project duration") }
        if want.frameDuration != got.frameDuration { differences.append("frame rate") }
        if want.fingerprint != got.fingerprint { differences.append("timeline, media references, or effect settings") }
        let expectedSettings = expected.settings
        let actualSettings = actual.settings
        var settingsPreserved: Bool? = expectedSettings.isEmpty ? nil : true
        let returnedClips = Dictionary(grouping: got.clips, by: \.timelineRange)
        for clip in want.clips {
            guard let settings = expectedSettings[clip.id] else { continue }
            guard let returned = returnedClips[clip.timelineRange]?.first(where: { $0.sourceStart == clip.sourceStart }),
                  let actual = actualSettings[returned.id],
                  AudioControllerSettings.equivalent(actual, settings) else {
                settingsPreserved = false
                continue
            }
        }
        var report = ProjectRoundTripReport(verified: differences.isEmpty, differences: differences,
            expectedProjectUID: want.projectUID, actualProjectUID: got.projectUID,
            expectedFingerprint: want.fingerprint, actualFingerprint: got.fingerprint,
            controllerSettingsPreserved: settingsPreserved)
        if let assigned = normalized?.assigned, !assigned.isEmpty { report.hostAssignedAudioAssetUIDs = assigned }
        return report
    }

    private static func normalizedHostAudioAssets(expected: Snapshot, actual: Snapshot, allowHostAssignedIdentity: Bool) throws
        -> (expected: Snapshot, actual: Snapshot, assigned: [String: String]) {
        let want = try XMLDocument(data: expected.data, options: [.nodeLoadExternalEntitiesNever])
        let got = try XMLDocument(data: actual.data, options: [.nodeLoadExternalEntitiesNever])
        let wanted = try want.nodes(forXPath: "/fcpxml/resources/asset").compactMap { $0 as? XMLElement }
        let returned = try got.nodes(forXPath: "/fcpxml/resources/asset").compactMap { $0 as? XMLElement }
        func original(_ asset: XMLElement) -> XMLElement? {
            let representations = asset.elements(forName: "media-rep").filter {
                $0.attribute(forName: "kind")?.stringValue == "original-media"
            }
            return representations.count == 1 ? representations[0] : nil
        }
        func originalURL(_ asset: XMLElement) -> String? { original(asset)?.attribute(forName: "src")?.stringValue }
        func normalizeFullyMutedAVChannels(_ xml: XMLDocument, assets: [XMLElement]) throws -> Bool {
            var channels: [String: Int] = [:]
            for asset in assets where asset.attribute(forName: "hasVideo")?.stringValue == "1"
                && asset.attribute(forName: "hasAudio")?.stringValue == "1"
                && asset.attribute(forName: "audioSources")?.stringValue == "1" {
                guard let id = asset.attribute(forName: "id")?.stringValue,
                      let raw = asset.attribute(forName: "audioChannels")?.stringValue,
                      let count = Int(raw), (1...1024).contains(count) else { continue }
                channels[id] = count
            }
            var changed = false
            for clip in try xml.nodes(forXPath: "//asset-clip").compactMap({ $0 as? XMLElement }) {
                guard let ref = clip.attribute(forName: "ref")?.stringValue, let count = channels[ref] else { continue }
                let children = (clip.children ?? []).compactMap { $0 as? XMLElement }
                let indices = children.indices.filter { children[$0].name == "audio-channel-source" }
                guard let first = indices.first, let last = indices.last,
                      last - first + 1 == indices.count,
                      !children.contains(where: { $0.name == "audio-role-source" }) else { continue }
                var covered: Set<Int> = []
                var proven = true
                for index in indices {
                    let component = children[index]
                    let attributes = Set((component.attributes ?? []).compactMap(\.name))
                    guard component.attribute(forName: "enabled")?.stringValue == "0",
                          attributes.isSubset(of: ["srcCh", "enabled", "role"]),
                          (component.children ?? []).allSatisfy({ $0.kind == .text && ($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                          let raw = component.attribute(forName: "srcCh")?.stringValue else { proven = false; break }
                    let tokens = raw.split(separator: ",", omittingEmptySubsequences: false)
                    for token in tokens {
                        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty, value.allSatisfy(\.isNumber), let channel = Int(value),
                              (1...count).contains(channel), covered.insert(channel).inserted else { proven = false; break }
                    }
                    if !proven { break }
                }
                guard proven, covered == Set(1...count) else { continue }
                // Native Final Cut can assign default subrole names or merge
                // disabled channel groups. Their role spelling cannot affect
                // sound only after EVERY source channel is explicitly off.
                // Bare per-channel nodes preserve that exact mute coverage.
                let insertion = children[first].index
                for index in indices { children[index].detach() }
                for channel in (1...count).reversed() {
                    let component = XMLElement(name: "audio-channel-source")
                    component.addAttribute(XMLNode.attribute(withName: "srcCh", stringValue: String(channel)) as! XMLNode)
                    component.addAttribute(XMLNode.attribute(withName: "enabled", stringValue: "0") as! XMLNode)
                    clip.insertChild(component, at: insertion)
                }
                changed = true
            }
            return changed
        }
        func normalizeRedundantAudioFlags(_ xml: XMLDocument, assets: [XMLElement]) throws -> Bool {
            var changed = false
            var audioOnly: Set<String> = []
            for asset in assets where asset.attribute(forName: "hasAudio")?.stringValue == "1"
                && (asset.attribute(forName: "hasVideo")?.stringValue ?? "0") == "0" {
                if let redundant = asset.attribute(forName: "hasVideo") { redundant.detach(); changed = true }
                if let id = asset.attribute(forName: "id")?.stringValue { audioOnly.insert(id) }
            }
            for clip in try xml.nodes(forXPath: "//asset-clip").compactMap({ $0 as? XMLElement })
                where clip.attribute(forName: "srcEnable")?.stringValue == "audio"
                    && clip.attribute(forName: "ref").flatMap({ $0.stringValue }).map(audioOnly.contains) == true {
                // On an asset with no video stream, audio and the default all
                // select the same streams. AV/video selections remain strict.
                clip.attribute(forName: "srcEnable")?.detach()
                changed = true
            }
            return changed
        }
        var changed = try normalizeRedundantAudioFlags(want, assets: wanted)
        changed = try normalizeRedundantAudioFlags(got, assets: returned) || changed
        changed = try normalizeFullyMutedAVChannels(want, assets: wanted) || changed
        changed = try normalizeFullyMutedAVChannels(got, assets: returned) || changed
        var assigned: [String: String] = [:]
        for asset in wanted where asset.attribute(forName: "uid") == nil
            && asset.attribute(forName: "hasAudio")?.stringValue == "1"
            && asset.attribute(forName: "hasVideo") == nil && allowHostAssignedIdentity {
            guard let url = originalURL(asset), let wantedRepresentation = original(asset),
                  wantedRepresentation.attribute(forName: "sig") == nil,
                  wanted.filter({ originalURL($0) == url }).count == 1 else { continue }
            let matches = returned.filter { originalURL($0) == url }
            guard matches.count == 1, let native = matches.first, let representation = original(native),
                  let uid = native.attribute(forName: "uid")?.stringValue, uid.count == 32,
                  uid.allSatisfy(\.isHexDigit), representation.attribute(forName: "sig")?.stringValue == uid else { continue }
            // Only host identity is adopted. Media URL, name, time bounds,
            // format/channel metadata, and every other resource field remain in
            // the normal semantic fingerprint and must match exactly.
            native.attribute(forName: "uid")?.detach()
            representation.attribute(forName: "sig")?.detach()
            changed = true
            let wantedIngest = asset.elements(forName: "metadata").flatMap { $0.elements(forName: "md") }.filter {
                $0.attribute(forName: "key")?.stringValue == "com.apple.proapps.mio.ingestDate"
            }
            if wantedIngest.isEmpty {
                for metadata in native.elements(forName: "metadata") {
                    for md in metadata.elements(forName: "md") where md.attribute(forName: "key")?.stringValue == "com.apple.proapps.mio.ingestDate" {
                        md.detach()
                    }
                    if metadata.children?.allSatisfy({ $0.kind == .text && ($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) != false {
                        metadata.detach()
                    }
                }
            }
            assigned[url] = uid
        }
        return changed ? (try Snapshot(data: want.xmlData), try Snapshot(data: got.xmlData), assigned)
            : (expected, actual, assigned)
    }

    @discardableResult static func verify(expected: Data, actual: Data, reportURL: URL, allowHostAssignedIdentity: Bool = false, expectedHostProjectUID: String? = nil,
                                          expectedHostAudioAssetUIDs: [String: String]? = nil) throws -> ProjectRoundTripReport {
        let report = try compare(expected: expected, actual: actual, allowHostAssignedIdentity: allowHostAssignedIdentity, expectedHostProjectUID: expectedHostProjectUID,
            expectedHostAudioAssetUIDs: expectedHostAudioAssetUIDs)
        return try saveAndVerify(report, reportURL: reportURL)
    }

    private static func saveAndVerify(_ report: ProjectRoundTripReport, reportURL: URL) throws -> ProjectRoundTripReport {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL, options: .atomic)
        guard report.verified else {
            throw EditedProjectWriterError.verificationFailed("Final Cut's imported project differs in \(report.differences.joined(separator: ", ")). Verification report: \(reportURL.path)")
        }
        return report
    }
}
