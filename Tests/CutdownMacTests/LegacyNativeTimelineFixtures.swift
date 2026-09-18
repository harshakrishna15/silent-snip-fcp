import CutdownCore
@testable import CutdownMac
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Narrow timeline items can omit Title/trim handles even though Final Cut
/// still exposes their exact Item position, duration, and audio-clip name.
enum NativeTimelineItemMatch {
    static func matches(_ item: AccessibilityNode, name: String, start: String,
                        end: String, duration: String, allowCompactAudio: Bool, allowCompactGap: Bool = false) -> Bool {
        guard item.role == "AXLayoutItem" else { return false }
        let expected = [("Title", name), ("Leading Edge", start), ("Trailing Edge", end)]
        for (label, value) in expected {
            let fields = item.children.filter { $0.description == label }
            guard fields.count <= 1, fields.allSatisfy({ $0.value == value }) else { return false }
        }
        if expected.allSatisfy({ label, _ in item.children.contains { $0.description == label } }) {
            return true
        }
        guard ((allowCompactAudio && item.description == "Audio-Clip:" + name) ||
               (allowCompactGap && name == "Gap" && item.description == "Gap:Gap")),
              item.value == duration else { return false }
        let positions = item.children.filter { $0.role == "AXHandle" && $0.description == "Item" }
        return positions.count == 1 && positions[0].value == start
    }
}

public struct NativeTimelineApplyError: LocalizedError {
    public let completed: Int
    public let attempted: Int
    public let recoveryURL: URL
    public let reason: String
    public var errorDescription: String? {
        "Stopped after \(completed) verified cuts (\(attempted) range-edit commands attempted). \(reason) Recovery snapshot: \(recoveryURL.path). Open this XML in Final Cut to recover the before-cuts project."
    }
}

/// Immutable expected states and a separately named XML recovery snapshot.
/// XML generation never authorizes a native edit by itself.
enum NativeTimelineEdit {
    static func recovery(data: Data, name: String) throws -> Data {
        try ProjectRecoverySnapshot.recovery(data: data, name: name)
    }

    static func expected(data: Data, selection: TimelineSelection, removals: [TimeRange],
                         exclusions: TimelineFingerprintExclusions, gapDuration: RationalTime? = nil,
                         preservingGap: TimeRange? = nil) throws -> TimelineDocument {
        if removals.isEmpty { return try TimelineParser.parse(data: data, exclusions: exclusions) }
        var gaps: [TimeRange: RationalTime] = [:]
        if let gapDuration {
            for range in removals { gaps[range] = range == preservingGap ? try range.checkedDuration() : gapDuration }
        }
        let edited = try EditedProjectWriter.write(projectData: data, selection: selection,
                                                   selectedRanges: removals, outputName: "Cutdown verification", replacementGaps: gaps)
        return try TimelineParser.parse(data: edited.xmlData, exclusions: exclusions)
    }

    static func verify(_ actual: TimelineDocument, expected: TimelineDocument,
                       original: TimelineDocument) throws {
        guard actual.projectName == original.projectName, actual.projectUID == original.projectUID,
              actual.projectRange == expected.projectRange, actual.frameDuration == expected.frameDuration,
              actual.fingerprint == expected.fingerprint else {
            throw EditedProjectWriterError.verificationFailed("the timeline does not exactly match the expected native edits")
        }
    }
}
