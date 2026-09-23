import AppKit
import ApplicationServices
import CutdownCore

struct PreviewGeometry: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect
    let occlusions: [CGRect]
    var projectWindowNumber: Int = 0
    var windowOrder: [Int] = []
    var diagnosticSurfaces: [String] = []
}

/// All mutable state and AX reads belong to this one serial queue. AX handles
/// are retained references, not AppKit views; no window drawing occurs here.
final class FinalCutPreviewReader: @unchecked Sendable {
    let observationTargets: [AXUIElement]
    let pid: pid_t
    let root: AXUIElement
    let mainWindow: AXUIElement
    private let projectName: String
    private let expected: FinalCutSelectionSnapshot
    private let queue = DispatchQueue(label: "local.cutdown.preview.geometry", qos: .userInteractive)
    private var timeline: AXUIElement?
    private var clip: AXUIElement?
    private var projectControl: AXUIElement?
    private var scrollAncestors: [AXUIElement] = []
    private var regularApplications: [pid_t: Bool] = [:]
    private var validationDate = Date.distantPast
    private var dialogDate = Date.distantPast
    private var effectDate = Date.distantPast
    private var effectLifetime = PreviewEffectLifetime()
    private struct EffectInspectionProgress {
        let inspector: AXUIElement
        let viewport: CGRect
        let controls: [AXUIElement]
        var index = 0
        var cutdown: CGRect?
        var anchors: [String: CGRect] = [:]
        var duplicateAnchors: Set<String> = []
        var scrollPosition: Double?
        var effectsHeading = false
        var effectsExpanded = false
    }
    private var effectInspectionProgress: EffectInspectionProgress?
    private var nextDeadline = Date.distantFuture
    private let diagnostics = FileManager.default.fileExists(atPath:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cutdown/Integration/EnablePreviewDiagnostics").path)

    init(pid: pid_t, root: AXUIElement, mainWindow: AXUIElement, projectName: String, expected: FinalCutSelectionSnapshot) {
        self.pid = pid; self.root = root; self.mainWindow = mainWindow
        self.projectName = projectName; self.expected = expected
        let timeline = Self.search(mainWindow, role: kAXLayoutAreaRole, description: "Project Timeline", containersOnly: true)
        let scroll = timeline.flatMap { Self.elementAttribute($0, kAXParentAttribute) }
        let controls = scroll.flatMap { Self.rawAttribute($0, kAXChildrenAttribute) as? [AXUIElement] } ?? []
        observationTargets = [root, mainWindow] + [timeline, scroll].compactMap { $0 } + controls.filter { Self.rawAttribute($0, kAXRoleAttribute) as? String == kAXScrollBarRole }
    }

    func sample(completion: @escaping @Sendable (Result<PreviewGeometry, Error>, Double) -> Void) {
        queue.async {
            let start = Date()
            self.nextDeadline = start.addingTimeInterval(0.25)
            let result = Result { try self.read() }
            // Retry validation without discarding good handles on a single
            // transient read failure during host layout/selection updates.
            if case .failure = result { self.validationDate = .distantPast }
            completion(result, Date().timeIntervalSince(start))
        }
    }

    func invalidate() { queue.async { self.validationDate = .distantPast; self.dialogDate = .distantPast } }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        guard Date() < nextDeadline else { return nil }
        return Self.rawAttribute(element, name)
    }
    private func string(_ element: AXUIElement, _ name: String) -> String? {
        let value = attribute(element, name)
        return (value as? String) ?? (value as? NSNumber)?.stringValue
    }
    private func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    private static func rawAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = rawAttribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    private func find(in element: AXUIElement, role: String? = nil, identifier: String? = nil, title: String? = nil,
                      description: String? = nil, maxDepth: Int = 12, maxNodes: Int = 350) -> AXUIElement? {
        Self.search(element, role: role, identifier: identifier, title: title, description: description, maxDepth: maxDepth, maxNodes: maxNodes)
    }
    private func isRegularApplication(_ pid: pid_t) -> Bool {
        if let value = regularApplications[pid] { return value }
        let value = NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
        regularApplications[pid] = value
        return value
    }

    private func validate() throws {
        guard let timeline = Self.search(mainWindow, role: kAXLayoutAreaRole, description: "Project Timeline", containersOnly: true),
              let project = Self.search(mainWindow, identifier: "editor/timelineContainer/toolbar/projectNamePopUpButton", containersOnly: true),
              let title = string(project, kAXTitleAttribute) else { throw FinalCutPreviewError.transient("Project or timeline is unavailable") }
        guard title == projectName else { throw FinalCutPreviewError.unavailable("Project changed") }
        let items = children(timeline)
        let matches = items.filter { item in
            guard string(item, kAXRoleAttribute) == kAXLayoutItemRole,
                  string(item, kAXValueAttribute) == expected.durationTimecode else { return false }
            let parts = children(item)
            func value(_ role: String, _ description: String) -> String? {
                let found = parts.filter { string($0, kAXRoleAttribute) == role && string($0, kAXDescriptionAttribute) == description }
                return found.count == 1 ? string(found[0], kAXValueAttribute) : nil
            }
            return value(kAXTextFieldRole, "Title") == expected.clipName &&
                value("AXHandle", "Leading Edge") == expected.leadingTimecode &&
                value("AXHandle", "Trailing Edge") == expected.trailingTimecode
        }
        guard matches.count == 1, let clip = matches.first else { throw FinalCutPreviewError.transient("Analyzed clip identity is unavailable") }
        // Inspector children are virtualized and can be offscreen behind other
        // effects. They cannot prove that Cutdown was removed. Geometry must
        // also stay independent of a potentially expensive effect-control tree.
        var ancestors: [AXUIElement] = []
        var ancestor = Self.elementAttribute(timeline, kAXParentAttribute)
        var seen: [AXUIElement] = []
        for _ in 0..<16 {
            guard let current = ancestor, !seen.contains(where: { CFEqual($0, current) }) else { break }
            seen.append(current)
            if string(current, kAXRoleAttribute) == kAXScrollAreaRole { ancestors.append(current) }
            if CFEqual(current, mainWindow) { break }
            ancestor = Self.elementAttribute(current, kAXParentAttribute)
        }
        guard !ancestors.isEmpty else { throw FinalCutPreviewError.transient("Timeline scroll viewport is unavailable") }
        self.timeline = timeline; self.clip = clip; projectControl = project; scrollAncestors = ancestors
        validationDate = Date()
        regularApplications.removeAll(keepingCapacity: true)
    }

    private func validateDialogs() throws {
        let windows = (attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []).prefix(32)
        for window in windows {
            guard (attribute(window, "AXSheets") as? [AXUIElement] ?? []).isEmpty,
                  !children(window).contains(where: { string($0, kAXRoleAttribute) == kAXSheetRole }) else {
                throw FinalCutPreviewError.unavailable("Final Cut has an open sheet")
            }
            if CFEqual(window, mainWindow) { continue }
            let role = string(window, kAXRoleAttribute), subrole = string(window, kAXSubroleAttribute)
            let modal = (attribute(window, kAXModalAttribute) as? NSNumber)?.boolValue
            if role == kAXSheetRole || modal == true || subrole == kAXDialogSubrole {
                let review = modal == nil && isCutdownReviewWindow(window)
                if FinalCutWindowPolicy.blocksPreview(role: role, subrole: subrole, modal: modal, containsCutdownReview: review) {
                    throw FinalCutPreviewError.unavailable("Final Cut has an open modal dialog")
                }
            }
        }
        dialogDate = Date()
    }

    private func read() throws -> PreviewGeometry {
        dispatchPrecondition(condition: .onQueue(queue))
        if effectLifetime.removed { throw FinalCutPreviewError.effectRemoved }
        if timeline == nil || clip == nil || Date().timeIntervalSince(validationDate) >= 0.5 { try validate() }
        guard let timeline, let clip, let projectControl,
              let title = string(projectControl, kAXTitleAttribute) else { throw FinalCutPreviewError.transient("Project is unavailable") }
        guard title == projectName else { throw FinalCutPreviewError.unavailable("Project changed") }
        if Date().timeIntervalSince(dialogDate) >= 0.2 { try validateDialogs() }
        guard let frame = rect(clip), let viewport = rect(timeline) else {
            throw FinalCutPreviewError.transient("Final Cut did not supply clip or viewport geometry")
        }
        // The layout area's frame can extend under Final Cut's docked Effects
        // and Transitions browsers. Its enclosing scroll area defines the actual
        // viewport. Clip through all scroll ancestors, but retain the full clip
        // frame for time-to-position mapping.
        let scrollViewports = try scrollAncestors.map { element -> CGRect in
            guard let bounds = rect(element) else { throw FinalCutPreviewError.transient("Timeline scroll viewport is unavailable") }
            return bounds
        }
        guard let visibleFrame = FinalCutPreviewGeometry.visibleFrame(clip: frame, timeline: viewport, scrollViewports: scrollViewports) else {
            throw FinalCutPreviewError.unavailable("Analyzed clip is outside the verified timeline scroll viewport")
        }
        // Mask only the covered portion instead of hiding every boundary when
        // the review window overlaps any part of the clip.
        guard let projectWindowFrame = rect(mainWindow),
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw FinalCutPreviewError.transient("Visible Final Cut window could not be verified")
        }
        let surfaces = windows.compactMap { info -> FinalCutPreviewSurface? in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            // Screen-wide utility/system surfaces can report alpha 1 despite
            // having transparent content. They must not erase the whole preview.
            guard pid == self.pid || pid == ProcessInfo.processInfo.processIdentifier || isRegularApplication(pid) else { return nil }
            return FinalCutPreviewSurface(pid: pid, frame: frame,
                layer: info[kCGWindowLayer as String] as? Int ?? 0,
                alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
                number: info[kCGWindowNumber as String] as? Int ?? 0)
        }
        guard let projectWindowNumber = FinalCutPreviewSurface.projectWindowNumber(in: surfaces,
            projectPID: pid, projectFrame: projectWindowFrame), projectWindowNumber > 0 else {
            throw FinalCutPreviewError.unavailable("Final Cut project window is minimized, offscreen, or on another Space")
        }
        // WindowServer composites the overlay immediately above the project.
        // Rectangles are not opacity masks: transparent host/utility surfaces
        // often cover the entire display, despite containing no visible pixels.
        var geometry = PreviewGeometry(frame: frame, visibleFrame: visibleFrame, occlusions: [],
            projectWindowNumber: projectWindowNumber,
            windowOrder: windows.compactMap { $0[kCGWindowNumber as String] as? Int })
        if Date().timeIntervalSince(effectDate) >= (effectInspectionProgress == nil ? 0.4 : 0.15) {
            // A separate budget: Inspector work cannot turn valid geometry into
            // a timeout. Partial snapshots are unknown, never effect absence.
            nextDeadline = Date().addingTimeInterval(0.8)
            let inspection = inspectEffect(timeline: timeline, clip: clip)
            effectDate = Date()
            if let inspection, effectLifetime.observe(inspection, at: effectDate) {
                throw FinalCutPreviewError.effectRemoved
            }
        }
        if diagnostics {
            geometry.diagnosticSurfaces = windows.prefix(40).map { info in
                "owner=\(info[kCGWindowOwnerName as String] ?? "unknown") pid=\(info[kCGWindowOwnerPID as String] ?? 0) layer=\(info[kCGWindowLayer as String] ?? 0) alpha=\(info[kCGWindowAlpha as String] ?? 1) bounds=\(info[kCGWindowBounds as String] ?? [:])"
            }
        }
        return geometry
    }

    private func inspectEffect(timeline: AXUIElement, clip: AXUIElement) -> PreviewEffectInspection? {
        func selectedTarget() -> Bool {
            // Final Cut versions differ in whether the layout area provides
            // SelectedChildren or only Selected on its layout items.
            let selected: [AXUIElement]
            if let reported = attribute(timeline, kAXSelectedChildrenAttribute) as? [AXUIElement] { selected = reported }
            else {
                guard let items = attribute(timeline, kAXChildrenAttribute) as? [AXUIElement] else { return false }
                var values: [AXUIElement] = []
                for item in items {
                    guard let role = string(item, kAXRoleAttribute) else { return false }
                    if role == kAXLayoutItemRole {
                        guard let value = attribute(item, kAXSelectedAttribute) as? NSNumber else { return false }
                        if value.boolValue { values.append(item) }
                    }
                }
                selected = values
            }
            return selected.count == 1 && CFEqual(selected[0], clip)
        }
        if effectInspectionProgress == nil {
            guard selectedTarget() else { return nil }
            guard let inspector = Self.search(mainWindow, role: kAXScrollAreaRole, description: "inspector", containersOnly: true) else { return nil }
            guard let viewport = rect(inspector) else { return nil }
            guard let controls = attribute(inspector, kAXChildrenAttribute) as? [AXUIElement], controls.count <= 300 else { return nil }
            effectInspectionProgress = EffectInspectionProgress(inspector: inspector, viewport: viewport, controls: controls)
        }
        guard var progress = effectInspectionProgress else { return nil }
        while progress.index < progress.controls.count {
            let control = progress.controls[progress.index]
            guard Date() < nextDeadline else { effectInspectionProgress = progress; return nil }
            guard let role = string(control, kAXRoleAttribute) else {
                effectInspectionProgress = Date() >= nextDeadline ? progress : nil
                return nil
            }
            var candidate = progress
            var key: String?
            if [kAXCheckBoxRole, kAXButtonRole, kAXDisclosureTriangleRole, "AXToggleButton"].contains(role) {
                let description = string(control, kAXDescriptionAttribute)
                    ?? string(control, kAXHelpAttribute) ?? ""
                if description.lowercased() == "cutdown audio check box" {
                    guard candidate.cutdown == nil, let frame = rect(control) else {
                        effectInspectionProgress = Date() >= nextDeadline ? progress : nil
                        return nil
                    }
                    candidate.cutdown = frame
                } else if description == "toggle Effects" {
                    guard PreviewEffectInspection.effectsExpanded(value: string(control, kAXValueAttribute),
                        title: string(control, kAXTitleAttribute)) else {
                        effectInspectionProgress = Date() >= nextDeadline ? progress : nil
                        return nil
                    }
                    candidate.effectsExpanded = true
                    key = "Effects"
                } else if description.lowercased().hasSuffix(" check box") { key = description }
            } else if role == kAXStaticTextRole {
                let value = string(control, kAXValueAttribute) ?? string(control, kAXTitleAttribute)
                if value == "Effects" { candidate.effectsHeading = true }
                if let value, ["Volume", "Audio Enhancements", "Pan", "Audio Configuration"].contains(value) { key = value }
            } else if role == kAXScrollBarRole {
                guard let value = attribute(control, kAXValueAttribute) as? NSNumber,
                      let enabled = attribute(control, kAXEnabledAttribute) as? NSNumber else {
                    effectInspectionProgress = Date() >= nextDeadline ? progress : nil
                    return nil
                }
                candidate.scrollPosition = PreviewEffectInspection.scrollPosition(value: value.doubleValue, enabled: enabled.boolValue)
            }
            if let key {
                guard let frame = rect(control) else {
                    effectInspectionProgress = Date() >= nextDeadline ? progress : nil
                    return nil
                }
                if candidate.anchors.updateValue(frame, forKey: key) != nil { candidate.duplicateAnchors.insert(key) }
            }
            candidate.index += 1
            progress = candidate
        }
        for key in progress.duplicateAnchors { progress.anchors.removeValue(forKey: key) }
        guard !progress.effectsHeading || progress.effectsExpanded else { effectInspectionProgress = nil; return nil }
        // The Inspector may have rebuilt or the selection may have changed
        // during reads. Accept only a complete, stable list on this occurrence.
        guard Date() < nextDeadline, selectedTarget(),
              let after = attribute(progress.inspector, kAXChildrenAttribute) as? [AXUIElement],
              progress.controls.count == after.count,
              zip(progress.controls, after).allSatisfy({ CFEqual($0, $1) }) else {
            effectInspectionProgress = Date() >= nextDeadline ? progress : nil
            return nil
        }
        effectInspectionProgress = nil
        return .init(viewport: progress.viewport, cutdown: progress.cutdown,
                     anchors: progress.anchors, scrollPosition: progress.scrollPosition)
    }
    private func rect(_ element: AXUIElement) -> CGRect? {
            guard let p = attribute(element, kAXPositionAttribute),
                  let s = attribute(element, kAXSizeAttribute),
                  CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var origin = CGPoint.zero; var size = CGSize.zero
            guard AXValueGetValue(p as! AXValue, .cgPoint, &origin),
                  AXValueGetValue(s as! AXValue, .cgSize, &size),
                  size.width > 2, size.height > 2 else { return nil }
            return CGRect(origin: origin, size: size)
        }
    private static func search(_ root: AXUIElement, role: String? = nil, identifier: String? = nil,
                               title: String? = nil, description: String? = nil,
                               maxDepth: Int = 24, maxNodes: Int = 600, containersOnly: Bool = false) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var cursor = 0
        let deadline = Date().addingTimeInterval(0.2)
        let containers: Set<String> = [kAXWindowRole, kAXGroupRole, kAXSplitGroupRole, kAXScrollAreaRole]
        while cursor < queue.count && cursor < maxNodes && Date() < deadline {
            let (element, depth) = queue[cursor]
            cursor += 1
            let actualRole = rawAttribute(element, kAXRoleAttribute) as? String
            let actualIdentifier = rawAttribute(element, kAXIdentifierAttribute) as? String
            if (role == nil || actualRole == role), (identifier == nil || actualIdentifier == identifier),
               (title == nil || rawAttribute(element, kAXTitleAttribute) as? String == title),
               (description == nil || rawAttribute(element, kAXDescriptionAttribute) as? String == description) {
                return element
            }
            guard depth < maxDepth else { continue }
            if containersOnly {
                guard containers.contains(actualRole ?? ""), !(actualIdentifier?.lowercased().contains("inspector") ?? false) else { continue }
            }
            for child in (rawAttribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(maxNodes - cursor) {
                if queue.count < maxNodes { queue.append((child, depth + 1)) }
            }
        }
        return nil
    }

    private func isCutdownReviewWindow(_ window: AXUIElement) -> Bool {
        guard string(window, kAXRoleAttribute) != kAXSheetRole,
              string(window, kAXSubroleAttribute) == kAXDialogSubrole,
              (attribute(window, kAXModalAttribute) as? NSNumber)?.boolValue != true else { return false }
        return (find(in: window, role: kAXTableRole, identifier: "cutdown.review.cuts", maxDepth: 16, maxNodes: 250) != nil
            || find(in: window, role: kAXTextAreaRole, identifier: "cutdown.review.results", maxDepth: 16, maxNodes: 250) != nil)
            && (find(in: window, role: kAXButtonRole, title: "Analyze", maxDepth: 16, maxNodes: 250) != nil
                || find(in: window, role: kAXButtonRole, title: "Analyze Again", maxDepth: 16, maxNodes: 250) != nil)
    }

}
