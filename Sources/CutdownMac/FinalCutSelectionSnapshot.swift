import CutdownCore
import ApplicationServices
import Foundation

struct FinalCutSelectionSnapshot: Equatable {
    let projectName: String
    let clipName: String
    let leadingTimecode: String
    let trailingTimecode: String
    let durationTimecode: String

    init(projectName: String, timeline: AccessibilityNode) throws {
        guard timeline.role == kAXLayoutAreaRole, timeline.description == "Project Timeline" else {
            throw FinalCutCaptureError.invalidSelection("The project timeline is not accessible.")
        }
        let selected = timeline.children.filter { $0.role == kAXLayoutItemRole && $0.selected == true }
        guard selected.count == 1, let clip = selected.first, clip.enabled != false else {
            throw FinalCutCaptureError.invalidSelection("Final Cut must report exactly one enabled selected audio-only timeline clip.")
        }
        func handle(_ description: String) -> String? {
            let matches = clip.children.filter { $0.role == "AXHandle" && $0.description == description }
            return matches.count == 1 ? matches[0].value : nil
        }
        let names = clip.children.filter { $0.role == kAXTextFieldRole && $0.description == "Title" }
        guard names.count == 1, let name = names.first?.value, !name.isEmpty,
              let leading = handle("Leading Edge"), let trailing = handle("Trailing Edge"),
              let duration = clip.value, !projectName.isEmpty else {
            throw FinalCutCaptureError.invalidSelection("Clip name, edge positions, or duration are unavailable.")
        }
        self.projectName = projectName
        self.clipName = name
        self.leadingTimecode = leading
        self.trailingTimecode = trailing
        self.durationTimecode = duration
    }

    func resolve(in document: TimelineDocument, requireExistingMedia: Bool = true) throws -> (TimelineSelection, TimelineClip) {
        guard projectName == document.projectName else { throw FinalCutCaptureError.changedProject }
        let start = try FinalCutTimecode.time(leadingTimecode, frameDuration: document.frameDuration)
            .subtracting(document.projectTimecodeStart)
        let end = try FinalCutTimecode.time(trailingTimecode, frameDuration: document.frameDuration)
            .subtracting(document.projectTimecodeStart)
        guard start >= .zero, end > start, end <= document.projectRange.end else {
            throw FinalCutCaptureError.invalidSelection("The visible clip edges do not match this project's timecode.")
        }
        // Duration is a count of frames, so a colon label is required even in a
        // drop-frame project. Do not infer whether a semicolon duration is a count.
        guard !durationTimecode.contains(";") else { throw FinalCutCaptureError.unsupportedTimecode(durationTimecode) }
        let duration = try FinalCutTimecode.time(durationTimecode, frameDuration: document.frameDuration)
        guard duration == (try end.subtracting(start)) else {
            throw FinalCutCaptureError.invalidSelection("A partial range or inconsistent clip duration is selected.")
        }
        let bounds = TimelineSelection(timelineRange: TimeRange(start: start, end: end))
        guard document.clips.filter({ $0.name == clipName && $0.timelineRange == bounds.timelineRange }).count == 1 else {
            throw FinalCutCaptureError.invalidSelection("More than one timeline item has this name and these edges.")
        }
        let target = try document.selectedTarget(bounds, requireExistingMedia: requireExistingMedia)
        guard target.name == clipName else { throw FinalCutCaptureError.invalidSelection("The selected clip changed during export.") }
        return (TimelineSelection(timelineRange: bounds.timelineRange, sourceURL: target.mediaURL,
                                  sourceStart: target.sourceStart), target)
    }
}
