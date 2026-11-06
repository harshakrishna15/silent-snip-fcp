import AppKit
import SilentSnipCore
import QuartzCore

/// One geometry request at a time; an old result cannot revive a dismissed job.
struct PreviewRequestGate {
    private(set) var generation = 0
    private var active: Int?
    mutating func reset() { generation += 1; active = nil }
    mutating func begin() -> Int? {
        guard active == nil else { return nil }
        active = generation; return generation
    }
    mutating func finish(_ token: Int) -> Bool {
        guard token == generation, active == token else { return false }
        active = nil; return true
    }
}

/// Notifications are hints; the periodic read still discovers host scrolling
/// and zooming when Final Cut does not emit one. Repeated hints cannot force
/// unbounded accessibility requests during scrubbing.
struct PreviewSamplePacer {
    private(set) var nextRead = Date.distantPast
    private var activeUntil = Date.distantPast
    private var lastRead = Date.distantPast

    mutating func reset() { nextRead = .distantPast; activeUntil = .distantPast; lastRead = .distantPast }
    mutating func wake(at now: Date) {
        activeUntil = max(activeUntil, now.addingTimeInterval(0.5))
        nextRead = min(nextRead, max(now, lastRead.addingTimeInterval(1.0 / 60)))
    }
    func isDue(at now: Date) -> Bool { now >= nextRead }
    mutating func didStartRead(at now: Date) {
        lastRead = now
        nextRead = now.addingTimeInterval(now < activeUntil ? 1.0 / 60 : 1.0 / 30)
    }
}

@MainActor final class PreviewChangeObserver {
    private var observer: AXObserver?
    private let changed: () -> Void
    private(set) var registrations = 0
    init(reader: FinalCutPreviewReader, changed: @escaping () -> Void) {
        self.changed = changed
        var result: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<PreviewChangeObserver>.fromOpaque(context).takeUnretainedValue().changed()
            }
        }
        guard AXObserverCreate(reader.pid, callback, &result) == .success, let result else { return }
        observer = result
        let context = Unmanaged.passUnretained(self).toOpaque()
        for element in reader.observationTargets {
            let valueChanges = reader.scrollBarTargets.contains { CFEqual($0, element) }
            for name in [kAXMovedNotification, kAXResizedNotification,
                         kAXSelectedChildrenChangedNotification, kAXLayoutChangedNotification,
                         kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                         kAXUIElementDestroyedNotification] + (valueChanges ? [kAXValueChangedNotification] : []) {
                if AXObserverAddNotification(result, element, name as CFString, context) == .success { registrations += 1 }
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(result), .commonModes)
    }
    func stop() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
    }
    deinit { if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) } }
}

/// Drawing stays on the main thread; all repeated Final Cut reads run off it.
@MainActor final class TimelineCutPreview {
    private var panel: NSPanel?
    private let drawing = CutBoundaryView(frame: .zero)
    private var timer: Timer?
    private var session: FinalCutAXSession?
    private var reader: FinalCutPreviewReader?
    private var observer: PreviewChangeObserver?
    private var gate = PreviewRequestGate()
    private var pacer = PreviewSamplePacer()
    private var visibility = PreviewVisibility()
    private weak var removedEffectSession: FinalCutAXSession?
    private var lastGeometry: PreviewGeometry?
    private var presentationPacer = PreviewPresentationPacer()
    private var presentationObserver: NSObjectProtocol?
    private let workspaceNotifications = NSWorkspace.shared.notificationCenter
    private var activationObserver: NSObjectProtocol?
    private var deactivationObserver: NSObjectProtocol?
    private var foregroundSuspended = false
    private var suspendingForeground = false
    private var foregroundEpoch = 0
    private var readTimes = PreviewDiagnosticBuffer<Double>(capacity: 1_800)
    private var paintTimes = PreviewDiagnosticBuffer<Double>(capacity: 1_800)
    private var diagnosticEnabled = false
    private var diagnosticRequested = false
    private var diagnosticTargetSamples = 120
    private var diagnosticContinuous = false
    private var diagnosticStartedAt = 0.0
    private var diagnosticEvents = PreviewDiagnosticBuffer<[String: Any]>(capacity: 2_000)
    private var diagnosticCounters: [String: Int] = [:]
    private var diagnosticDroppedEvents = 0
    private var diagnosticObserverRegistrations = 0
    private var diagnosticLastLayer: String?
    private var diagnosticLastAttachment: Bool?
    private static let diagnosticEventLimit = 2_000
    private var lastStatus = ""
    private var diagnosticDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Silent Snip/Integration")
    }

    func show(review: ReviewPlan, session: FinalCutAXSession) {
        // Re-adding an effect or toggling a stale review cannot resurrect lines
        // belonging to the removed controller. A fresh Analyze gets a new session.
        guard removedEffectSession !== session else { return }
        let duration = review.target.timelineRange.duration.seconds
        guard duration > 0, !review.selectedCuts.isEmpty else { hide(reason: "emptyReview"); return }
        drawing.boundaries = Self.boundaries(for: review)
        if self.session !== session || reader == nil {
            hide(reason: "newSession")
            self.session = session
            guard let reader = session.makePreviewReader() else { return }
            self.reader = reader
            let diagnosticFlag = diagnosticDirectory.appendingPathComponent("EnablePreviewDiagnostics")
            diagnosticEnabled = FileManager.default.fileExists(atPath: diagnosticFlag.path)
            diagnosticRequested = diagnosticEnabled
            lastStatus = ""
            readTimes.removeAll(); paintTimes.removeAll()
            diagnosticEvents.removeAll(); diagnosticCounters = [:]; diagnosticDroppedEvents = 0
            diagnosticLastLayer = nil; diagnosticLastAttachment = nil
            diagnosticObserverRegistrations = 0
            if diagnosticEnabled {
                let configuration = Self.diagnosticConfiguration(at: diagnosticFlag)
                diagnosticTargetSamples = configuration.samples
                diagnosticContinuous = configuration.continuous
                diagnosticStartedAt = ProcessInfo.processInfo.systemUptime
                trace("sessionStarted", ["targetSamples": diagnosticTargetSamples,
                    "eventLimit": Self.diagnosticEventLimit, "continuous": diagnosticContinuous])
            }
            observer = PreviewChangeObserver(reader: reader) { [weak self] in self?.wake() }
            if diagnosticEnabled { diagnosticObserverRegistrations = observer?.registrations ?? 0 }
        }
        observeForegroundChanges()
        wake()
        if timer == nil {
            timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer!, forMode: .common)
        }
        tick()
    }

    static func boundaries(for review: ReviewPlan) -> [CutBoundaryView.Boundary] {
        let duration = review.target.timelineRange.duration.seconds
        guard duration > 0 else { return [] }
        // Use the complete review order so excluding cut 1 cannot renumber cut 2.
        return review.cuts.enumerated().flatMap { index, cut -> [CutBoundaryView.Boundary] in
            guard cut.included && cut.isEligible else { return [] }
            return [(cut.range.start, true), (cut.range.end, false)].map { time, isStart in
                CutBoundaryView.Boundary(fraction: (time.seconds - review.target.timelineRange.start.seconds) / duration,
                                         isStart: isStart, number: index + 1)
            }
        }
    }

    func hide(reason: String = "explicit") {
        if diagnosticEnabled {
            trace("hide", ["reason": reason, "panelBefore": diagnosticPanelState(panel),
                "drawing": diagnosticLayerState()])
        }
        gate.reset(); observer?.stop(); observer = nil
        timer?.invalidate(); timer = nil; reader = nil; session = nil
        pacer.reset()
        panel?.level = .normal
        panel?.orderOut(nil)
        if diagnosticEnabled {
            trace("hideCompleted", ["reason": reason, "panelAfter": diagnosticPanelState(panel)])
            finishDiagnosticsIfNeeded(reason: "hide:\(reason)", force: true)
        }
        lastGeometry = nil; visibility.reset()
        presentationPacer.reset()
        foregroundSuspended = false
    }
    private func wake() { pacer.wake(at: Date()) }

    /// Suspend presentation without discarding the review, its geometry reader
    /// or its outstanding request. The epoch makes that old request unpaintable.
    private func suspendForForeground(reason: String) {
        guard !suspendingForeground else { return }
        guard !foregroundSuspended || panel?.isVisible == true else { return }
        suspendingForeground = true
        defer { suspendingForeground = false }
        if !foregroundSuspended {
            foregroundSuspended = true
            foregroundEpoch &+= 1
            lastGeometry = nil
            if diagnosticEnabled {
                trace("foregroundSuspended", ["reason": reason, "epoch": foregroundEpoch,
                    "panelBefore": diagnosticPanelState(panel)])
            }
        }
        panel?.level = .normal
        panel?.orderOut(nil)
        if diagnosticEnabled { trace("foregroundYieldCompleted", ["panelAfter": diagnosticPanelState(panel)]) }
    }

    /// Check both activation sources: the frontmost PID can briefly retain the
    /// old host during deactivation, and activation notifications can be stale.
    private func permitsForegroundPresentation() -> Bool {
        guard !suspendingForeground, let application = session?.application else { return false }
        let allowed = PreviewForegroundPolicy.permits(hostPID: application.processIdentifier,
            hostIsActive: application.isActive,
            foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        guard allowed else {
            suspendForForeground(reason: "foregroundState")
            return false
        }
        if foregroundSuspended {
            foregroundSuspended = false
            reader?.invalidate()
            pacer.reset()
            if diagnosticEnabled { trace("foregroundResumed", ["epoch": foregroundEpoch]) }
        }
        return true
    }

    private func observeForegroundChanges() {
        if activationObserver == nil {
            activationObserver = workspaceNotifications.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.session != nil else { return }
                        if self.diagnosticEnabled { self.trace("foregroundActivationNotification") }
                        guard self.permitsForegroundPresentation() else { return }
                        self.wake()
                        self.tick()
                    }
                }
        }
        if deactivationObserver == nil {
            deactivationObserver = workspaceNotifications.addObserver(
                forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self, let host = self.session?.application,
                              let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                              application.processIdentifier == host.processIdentifier else { return }
                        self.suspendForForeground(reason: "hostDeactivated")
                    }
                }
        }
    }

    private func tick() {
        guard permitsForegroundPresentation() else { return }
        maintainPresentation()
        let now = Date()
        guard let reader, pacer.isDue(at: now), let token = gate.begin() else { return }
        pacer.didStartRead(at: now)
        let epoch = foregroundEpoch
        reader.sample { [weak self] result, duration in
            Task { @MainActor in
                guard let self, self.gate.finish(token) else { return }
                guard epoch == self.foregroundEpoch else {
                    if self.diagnosticEnabled { self.trace("foregroundDiscardedRead", ["epoch": epoch]) }
                    return
                }
                guard self.permitsForegroundPresentation() else { return }
                if self.diagnosticEnabled { self.readTimes.append(duration) }
                switch result {
                case .success(let geometry):
                    let start = Date()
                    self.present(geometry)
                    if self.diagnosticEnabled { self.paintTimes.append(Date().timeIntervalSince(start)) }
                case .failure(let error):
                    if self.diagnosticEnabled {
                        let category: String
                        if case FinalCutPreviewError.effectRemoved = error { category = "effectRemoved" }
                        else if case FinalCutPreviewError.transient = error { category = "transient" }
                        else if case FinalCutPreviewError.unavailable = error { category = "unavailable" }
                        else { category = "other" }
                        self.trace("readFailure", ["category": category,
                            "reason": String(error.localizedDescription.prefix(240)),
                            "panel": self.diagnosticPanelState(self.panel)])
                        self.diagnosticCounters["readFailure.\(category)", default: 0] += 1
                    }
                    if case FinalCutPreviewError.effectRemoved = error {
                        self.removedEffectSession = self.session
                        self.hide(reason: "effectRemoved")
                        self.record("Dismissed: Silent Snip effect removed")
                    } else if case FinalCutPreviewError.transient = error {
                        self.visibility.transientFailure()
                    } else {
                        if self.visibility.confirmedUnavailable(error.localizedDescription, at: Date()) {
                            if self.diagnosticEnabled {
                                self.trace("orderOut", ["reason": "confirmedUnavailable",
                                    "detail": String(error.localizedDescription.prefix(240)),
                                    "panelBefore": self.diagnosticPanelState(self.panel)])
                            }
                            self.panel?.orderOut(nil)
                            self.record("Hidden: " + error.localizedDescription)
                        }
                    }
                }
                self.finishDiagnosticsIfNeeded()
            }
        }
    }

    /// Final Cut can raise its project without an AX notification. Correct
    /// panel order on the display timer rather than waiting for a geometry
    /// read, which can be busy validating the Inspector during a scrub.
    private func maintainPresentation(urgent: Bool = false) {
        guard permitsForegroundPresentation() else { return }
        let epoch = foregroundEpoch
        guard presentationPacer.begin(at: Date(), urgent: urgent) else { return }
        defer { presentationPacer.finish() }
        guard let window = panel, window.isVisible, let geometry = lastGeometry,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID) as? [[String: Any]] else { return }
        let order = windows.compactMap { $0[kCGWindowNumber as String] as? Int }
        let level = updatePresentationLevel(window, geometry: geometry, windows: windows)
        guard epoch == foregroundEpoch, !foregroundSuspended else { return }
        guard order.contains(geometry.projectWindowNumber) else {
            if diagnosticEnabled { trace("orderOut", ["reason": "maintenance:projectWindowMissing"]) }
            window.orderOut(nil)
            return
        }
        let needsOrdering = !level.elevated && order.contains(geometry.projectWindowNumber) &&
            (level.changed ||
            PreviewVisibility.needsOrdering(visible: true, overlay: window.windowNumber,
                project: geometry.projectWindowNumber, windowOrder: order))
        if diagnosticEnabled {
            trace("maintenance", ["urgent": urgent, "panel": diagnosticPanelState(window),
                "drawingBefore": diagnosticLayerState(), "needsOrdering": needsOrdering,
                "windowOrder": diagnosticWindowOrder(order, project: geometry.projectWindowNumber,
                    overlay: window.windowNumber)])
        }
        if needsOrdering {
            guard epoch == foregroundEpoch, !foregroundSuspended else { return }
            if diagnosticEnabled {
                trace("orderAbove", ["reason": urgent ? "occlusion:overlayMissingOrBehindProject" : "maintenance:overlayMissingOrBehindProject",
                    "windowOrderBefore": diagnosticWindowOrder(order, project: geometry.projectWindowNumber,
                        overlay: window.windowNumber), "panelBefore": diagnosticPanelState(window)])
            }
            window.order(.above, relativeTo: geometry.projectWindowNumber)
            if diagnosticEnabled {
                trace("orderAboveCompleted", ["reason": "maintenance", "panelAfter": diagnosticPanelState(window),
                    "windowOrderAfter": diagnosticWindowOrder(project: geometry.projectWindowNumber,
                        overlay: window.windowNumber), "drawing": diagnosticLayerState()])
            }
        }
        // Ordering or resizing can replace AppKit's backing layer after the
        // last geometry paint. The drawing checks attachment before returning.
        drawing.updateLayer()
        if diagnosticEnabled { _ = diagnosticLayerState() }
    }

    private func present(_ geometry: PreviewGeometry) {
        guard permitsForegroundPresentation() else { return }
        let epoch = foregroundEpoch
        guard presentationPacer.begin(at: Date(), urgent: true) else { return }
        defer { presentationPacer.finish() }
        let changed = geometry.frame != lastGeometry?.frame || geometry.visibleFrame != lastGeometry?.visibleFrame
        if changed { pacer.wake(at: Date()) }
        visibility.verified()
        let window = panel ?? makePanel()
        let visible = geometry.visibleFrame
        let targetFrame = CGRect(x: visible.minX, y: CGDisplayBounds(CGMainDisplayID()).height - visible.maxY,
                                 width: visible.width, height: visible.height)
        let setFrame = window.frame != targetFrame
        let panelBefore = diagnosticEnabled ? diagnosticPanelState(window) : [:]
        let drawingBefore = diagnosticEnabled ? diagnosticLayerState() : [:]
        if setFrame { window.setFrame(targetFrame, display: false) }
        drawing.frame = CGRect(origin: .zero, size: visible.size)
        drawing.clipWidth = geometry.frame.width
        drawing.clipOriginX = geometry.frame.minX - visible.minX
        drawing.occlusions = geometry.occlusions.map {
            CGRect(x: $0.minX - visible.minX, y: visible.maxY - $0.maxY, width: $0.width, height: $0.height)
        }
        drawing.updateLayer()
        let currentWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]] ?? []
        let level = updatePresentationLevel(window, geometry: geometry, windows: currentWindows)
        guard epoch == foregroundEpoch, !foregroundSuspended else { return }
        guard currentWindows.contains(where: { $0[kCGWindowNumber as String] as? Int == geometry.projectWindowNumber }) else {
            if diagnosticEnabled { trace("orderOut", ["reason": "present:projectWindowMissing"]) }
            window.orderOut(nil)
            return
        }
        if diagnosticEnabled {
            if setFrame { diagnosticCounters["setFrameIssued", default: 0] += 1 }
            if changed { diagnosticCounters["geometryChanged", default: 0] += 1 }
            trace("present", ["rawClipFrame": NSStringFromRect(geometry.frame),
                "rawVisibleFrame": NSStringFromRect(geometry.visibleFrame),
                "rawOcclusions": geometry.occlusions.prefix(32).map(NSStringFromRect),
                "targetPanelFrame": NSStringFromRect(targetFrame), "setFrameIssued": setFrame,
                "geometryChanged": changed, "panelBefore": panelBefore,
                "panelAfter": diagnosticPanelState(window), "drawingBefore": drawingBefore,
                "drawingAfter": diagnosticLayerState(),
                "readerWindowOrder": diagnosticWindowOrder(geometry.windowOrder,
                    project: geometry.projectWindowNumber, overlay: window.windowNumber),
                "currentWindowOrder": diagnosticWindowOrder(project: geometry.projectWindowNumber,
                    overlay: window.windowNumber)])
        }
        if !level.elevated && (level.changed || PreviewVisibility.needsOrdering(visible: window.isVisible, overlay: window.windowNumber,
            project: geometry.projectWindowNumber, windowOrder: currentWindows.compactMap { $0[kCGWindowNumber as String] as? Int })) {
            guard epoch == foregroundEpoch, !foregroundSuspended else { return }
            guard geometry.projectWindowNumber > 0 else {
                if diagnosticEnabled { trace("orderOut", ["reason": "present:invalidProjectWindow"]) }
                window.orderOut(nil); return
            }
            if diagnosticEnabled {
                trace("orderAbove", ["reason": window.isVisible ? "present:readerOverlayMissingOrBehindProject" : "present:panelNotVisible",
                    "panelBefore": diagnosticPanelState(window),
                    "windowOrderBefore": diagnosticWindowOrder(project: geometry.projectWindowNumber,
                        overlay: window.windowNumber)])
            }
            window.order(.above, relativeTo: geometry.projectWindowNumber)
            if diagnosticEnabled {
                trace("orderAboveCompleted", ["reason": "present", "panelAfter": diagnosticPanelState(window),
                    "windowOrderAfter": diagnosticWindowOrder(project: geometry.projectWindowNumber,
                        overlay: window.windowNumber), "drawing": diagnosticLayerState()])
            }
        }
        guard epoch == foregroundEpoch, !foregroundSuspended else { return }
        lastGeometry = geometry
        if diagnosticEnabled { record("Visible: clip=\(geometry.frame), panel=\(window.frame), vector boundaries=\(drawing.boundaries.count)") }
    }

    /// Final Cut repeatedly raises its normal-level project during skimming.
    /// Hold the preview one level above it only while the verified clip is
    /// uncovered at normal window levels. Floating editors/menus stay above
    /// this level. A covering normal window restores project-relative ordering.
    private func updatePresentationLevel(_ window: NSPanel, geometry: PreviewGeometry,
                                         windows: [[String: Any]]) -> (elevated: Bool, changed: Bool) {
        guard permitsForegroundPresentation() else { return (false, false) }
        let epoch = foregroundEpoch
        let surfaces = windows.compactMap { info -> FinalCutPreviewSurface? in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return FinalCutPreviewSurface(pid: pid, frame: frame,
                layer: info[kCGWindowLayer as String] as? Int ?? 0,
                alpha: info[kCGWindowAlpha as String] as? Double ?? 1, number: number)
        }
        let elevated = PreviewWindowLevelPolicy.shouldElevate(
            hostPID: session?.application.processIdentifier ?? -1,
            project: geometry.projectWindowNumber, overlay: window.windowNumber,
            frame: geometry.visibleFrame, surfaces: surfaces)
        let target = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + (elevated ? 1 : 0))
        guard epoch == foregroundEpoch, !foregroundSuspended else { return (false, false) }
        let changed = window.level != target
        if changed {
            if diagnosticEnabled {
                trace("presentationLevelChanged", ["before": window.level.rawValue, "after": target.rawValue,
                    "foregroundPID": NSWorkspace.shared.frontmostApplication.map { $0.processIdentifier as Any } ?? NSNull(),
                    "panel": diagnosticPanelState(window)])
            }
            window.level = target
        }
        if elevated && (changed || !window.isVisible) {
            guard epoch == foregroundEpoch, !foregroundSuspended else { return (false, changed) }
            // Ordering relative to another level must not undo the separation
            // that prevents the host's repeated normal-level raises.
            if diagnosticEnabled { trace("orderLevelFront", ["panelBefore": diagnosticPanelState(window)]) }
            window.order(.above, relativeTo: 0)
        }
        return (elevated, changed)
    }

    // Explicit, bounded integration diagnostics. No PNGs or logs on the normal path.
    private func record(_ text: String) {
        guard diagnosticRequested, text != lastStatus else { return }; lastStatus = text
        try? text.write(to: diagnosticDirectory.appendingPathComponent("TimelinePreview.txt"), atomically: true, encoding: .utf8)
    }
    private static func diagnosticConfiguration(at flag: URL) -> (samples: Int, continuous: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: flag) else { return (120, false) }
        defer { try? handle.close() }
        // A diagnostic flag is configuration, not an unbounded input file.
        guard let data = try? handle.read(upToCount: 64), let text = String(data: data, encoding: .utf8) else { return (120, false) }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased() == "live" { return (1_800, true) }
        guard let requested = Int(value) else { return (120, false) }
        return (min(1_800, max(120, requested)), false)
    }

    private func trace(_ kind: String, _ details: [String: Any] = [:]) {
        guard diagnosticEnabled else { return }
        diagnosticCounters["events.\(kind)", default: 0] += 1
        if diagnosticEvents.count == Self.diagnosticEventLimit { diagnosticDroppedEvents += 1 }
        var event = details
        event["kind"] = kind
        event["seconds"] = ProcessInfo.processInfo.systemUptime - diagnosticStartedAt
        event["sample"] = readTimes.totalAppended
        diagnosticEvents.append(event)
    }

    private func diagnosticPanelState(_ window: NSPanel?) -> [String: Any] {
        guard let window else { return ["exists": false] }
        return ["exists": true, "frame": NSStringFromRect(window.frame), "visible": window.isVisible,
            "windowNumber": window.windowNumber, "backingScale": window.backingScaleFactor,
            "miniaturized": window.isMiniaturized, "occlusionState": window.occlusionState.rawValue,
            "alpha": window.alphaValue, "level": window.level.rawValue]
    }

    private func diagnosticLayerState() -> [String: Any] {
        let state = drawing.presentationDiagnosticState
        let identity = state["backingLayerIdentity"] as? String ?? "none"
        let attached = state["contentAttached"] as? Bool ?? false
        if let previous = diagnosticLastLayer, previous != identity {
            diagnosticCounters["backingLayerChanges", default: 0] += 1
            trace("backingLayerChanged", ["before": previous, "after": identity, "drawing": state])
        }
        if let previous = diagnosticLastAttachment, previous != attached {
            diagnosticCounters["contentAttachmentChanges", default: 0] += 1
            trace("contentAttachmentChanged", ["before": previous, "after": attached, "drawing": state])
        }
        diagnosticLastLayer = identity; diagnosticLastAttachment = attached
        return state
    }

    private func diagnosticWindowOrder(_ supplied: [Int]? = nil, project: Int, overlay: Int) -> [String: Any] {
        let order: [Int]
        var hostSurfaces: [[String: Any]] = []
        if let supplied { order = supplied }
        else {
            guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID) as? [[String: Any]] else { return ["available": false] }
            order = windows.compactMap { $0[kCGWindowNumber as String] as? Int }
            let hostPID = session?.application.processIdentifier
            for info in windows.prefix(64) {
                guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                      pid == hostPID || pid == ProcessInfo.processInfo.processIdentifier,
                      let number = info[kCGWindowNumber as String] as? Int,
                      let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                      let frame = CGRect(dictionaryRepresentation: bounds) else { continue }
                hostSurfaces.append(["window": number, "pid": pid, "frame": NSStringFromRect(frame),
                    "level": info[kCGWindowLayer as String] as? Int ?? 0])
                if hostSurfaces.count == 16 { break }
            }
        }
        let projectIndex = order.firstIndex(of: project), overlayIndex = order.firstIndex(of: overlay)
        var indices = Set(order.indices.prefix(16))
        for index in [projectIndex, overlayIndex].compactMap({ $0 }) {
            for neighbor in max(0, index - 2)...min(order.count - 1, index + 2) { indices.insert(neighbor) }
        }
        // Retain just ordering numbers near the two surfaces, never window
        // titles or another application's full surface inventory.
        return ["available": true, "count": order.count, "project": project, "overlay": overlay,
            "projectIndex": projectIndex.map { $0 as Any } ?? NSNull(),
            "overlayIndex": overlayIndex.map { $0 as Any } ?? NSNull(),
            "hostSurfaces": hostSurfaces,
            "neighbors": indices.sorted().map { ["index": $0, "window": order[$0]] }]
    }

    private func finishDiagnosticsIfNeeded(reason: String = "sampleTarget", force: Bool = false) {
        guard diagnosticEnabled, force || (!diagnosticContinuous && readTimes.totalAppended >= diagnosticTargetSamples) else { return }
        let report: [String: Any] = ["samples": readTimes.totalAppended, "readSeconds": readTimes.values,
            "paintSeconds": paintTimes.values, "observerRegistrations": observer?.registrations ?? diagnosticObserverRegistrations,
            "vectorLayerCount": drawing.vectorLayerCount, "drawing": drawing.diagnosticState,
            "surfaces": lastGeometry?.diagnosticSurfaces ?? [], "state": lastStatus,
            "targetSamples": diagnosticTargetSamples, "completedSampleTarget": readTimes.totalAppended >= diagnosticTargetSamples,
            "continuous": diagnosticContinuous, "retainedReadSamples": readTimes.count,
            "finishReason": reason, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - diagnosticStartedAt,
            "events": diagnosticEvents.values, "counters": diagnosticCounters,
            "eventLimit": Self.diagnosticEventLimit, "droppedEvents": diagnosticDroppedEvents]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted) {
            try? data.write(to: diagnosticDirectory.appendingPathComponent("PreviewPerformance.json"), options: .atomic)
        }
        if let bitmap = drawing.renderBitmap(scale: drawing.window?.backingScaleFactor ?? 1) {
            try? bitmap.representation(using: .png, properties: [:])?.write(to: diagnosticDirectory.appendingPathComponent("TimelinePreviewDrawing.png"), options: .atomic)
        }
        diagnosticEnabled = false
    }
    private func makePanel() -> NSPanel {
        let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.ignoresMouseEvents = true; window.hidesOnDeactivate = false; window.level = .normal
        window.collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        drawing.wantsLayer = true; window.contentView = drawing; panel = window
        // Final Cut can cover its preview while skimming without changing any
        // AX geometry. Repair the existing relative order as soon as AppKit
        // reports an occlusion change; unrelated covering apps retain their
        // normal position because the fresh WindowServer order is still used.
        presentationObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.maintainPresentation(urgent: true) }
            }
        return window
    }

    deinit {
        if let presentationObserver { NotificationCenter.default.removeObserver(presentationObserver) }
        if let activationObserver { workspaceNotifications.removeObserver(activationObserver) }
        if let deactivationObserver { workspaceNotifications.removeObserver(deactivationObserver) }
    }
}

@MainActor final class CutBoundaryView: NSView {
    struct Boundary: Equatable { let fraction: Double; let isStart: Bool; let number: Int }
    struct RemovalRange: Equatable { let start: Double; let end: Double; let number: Int }
    struct LabelCandidate { let number: Int; let visibleRange: CGRect; let width: CGFloat }

    /// Built once per review. A subtree's maximum end permits skipping ranges
    /// left of the viewport, including when an earlier range spans the view.
    struct RangeIndex {
        private struct Node {
            let range: RemovalRange
            let left: Int?; let right: Int?
            let minimumStart: Double; let maximumEnd: Double
        }
        private var nodes: [Node] = []
        private var root: Int?

        init(_ ranges: [RemovalRange] = []) {
            let sorted = ranges.sorted { $0.start == $1.start ? $0.number < $1.number : $0.start < $1.start }
            root = append(sorted, lower: 0, upper: sorted.count)
        }
        private mutating func append(_ sorted: [RemovalRange], lower: Int, upper: Int) -> Int? {
            guard lower < upper else { return nil }
            let middle = (lower + upper) / 2
            let left = append(sorted, lower: lower, upper: middle)
            let right = append(sorted, lower: middle + 1, upper: upper)
            let index = nodes.count
            let maximumEnd = max(sorted[middle].end, max(left.map { nodes[$0].maximumEnd } ?? -.infinity,
                                                       right.map { nodes[$0].maximumEnd } ?? -.infinity))
            nodes.append(Node(range: sorted[middle], left: left, right: right,
                              minimumStart: sorted[lower].start, maximumEnd: maximumEnd))
            return index
        }
        func visible(origin: CGFloat, clipWidth: CGFloat, viewportWidth: CGFloat,
                     visited: () -> Void = {}) -> [RemovalRange] {
            guard clipWidth > 0, viewportWidth > 0, clipWidth.isFinite, origin.isFinite else { return [] }
            let lower = max(0, -origin / clipWidth)
            let upper = min(1, (viewportWidth - origin) / clipWidth)
            guard lower < upper else { return [] }
            var result: [RemovalRange] = []
            func visit(_ index: Int?) {
                guard let index else { return }
                visited()
                let node = nodes[index]
                guard node.maximumEnd > lower, node.minimumStart < upper else { return }
                visit(node.left)
                if node.range.end > lower, node.range.start < upper { result.append(node.range) }
                visit(node.right)
            }
            visit(root)
            return result
        }
    }
    private struct State: Equatable {
        let bounds: CGRect; let width: CGFloat; let origin: CGFloat
        let revision: Int; let occlusions: [CGRect]; let scale: CGFloat
    }
    private struct DotState: Equatable { let height: CGFloat; let diameter: CGFloat; let scale: CGFloat }
    var clipWidth: CGFloat = 0
    var clipOriginX: CGFloat = 0
    var boundaries: [Boundary] = [] {
        didSet {
            guard boundaries != oldValue else { return }
            boundaryRevision &+= 1
            indexedBoundaries = boundaries.filter { $0.fraction.isFinite && (0...1).contains($0.fraction) }
                .sorted { $0.fraction < $1.fraction }
            let ranges = Self.removalRanges(from: boundaries)
            rangeIndex = RangeIndex(ranges)
            labelWidths = Dictionary(uniqueKeysWithValues: ranges.map {
                ($0.number, max(16, ceil((String($0.number) as NSString)
                    .size(withAttributes: [.font: Self.labelFont]).width) + 8))
            })
        }
    }
    private var boundaryRevision = 0
    private var indexedBoundaries: [Boundary] = []
    private var previousVisible: [Boundary] = []
    private var rangeIndex = RangeIndex()
    var occlusions: [CGRect] = []
    private let content = CALayer()
    private let clipping = CAShapeLayer()
    private let tint = CAShapeLayer()
    private let boundaryContent = CALayer()
    private let labelContent = CALayer()
    private let startCaps = CAShapeLayer()
    private let endCaps = CAShapeLayer()
    private var lines: [CAShapeLayer] = []
    private var linePathRevisions: [Int] = []
    private var labels: [CATextLayer] = []
    private var labelWidths: [Int: CGFloat] = [:]
    private var activeLineCount = 0
    private var activeLabelCount = 0
    private var dotState: DotState?
    private var dotPath: CGPath?
    private var dotRevision = 0
    private(set) var renderedRanges: [RemovalRange] = []
    private(set) var renderedLabelFrames: [Int: CGRect] = [:]
    private var previous: State?
    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    var vectorLayerCount: Int { activeLineCount }
    var lineLayerIdentities: [ObjectIdentifier] { lines.prefix(activeLineCount).map(ObjectIdentifier.init) }
    var managedLayerScales: [CGFloat] {
        [content, clipping, tint, boundaryContent, labelContent, startCaps, endCaps].map(\.contentsScale) +
            lines.prefix(activeLineCount).map(\.contentsScale) + labels.prefix(activeLabelCount).map(\.contentsScale)
    }
    /// Constant-size surface metadata for opt-in presentation tracing. Avoid
    /// walking every reviewed boundary or retained layer on each sample.
    var presentationDiagnosticState: [String: Any] {
        ["backingLayerIdentity": layer.map { String(describing: ObjectIdentifier($0)) } ?? "none",
         "contentIdentity": String(describing: ObjectIdentifier(content)),
         "contentSuperlayerIdentity": content.superlayer.map { String(describing: ObjectIdentifier($0)) } ?? "none",
         "contentAttached": layer != nil && content.superlayer === layer,
         "viewFrame": NSStringFromRect(frame), "viewBounds": NSStringFromRect(bounds),
         "contentFrame": NSStringFromRect(content.frame), "activeLines": activeLineCount,
         "activeLabels": activeLabelCount, "linePoolCount": lines.count,
         "dotPathRevision": dotRevision, "renderScale": previous?.scale ?? 1]
    }
    var diagnosticState: [String: Any] {
        ["attached": layer != nil && content.superlayer === layer,
         "bounds": NSStringFromRect(bounds), "contentFrame": NSStringFromRect(content.frame),
         "clipWidth": clipWidth, "clipOriginX": clipOriginX,
         "occlusions": occlusions.map(NSStringFromRect),
         "fractions": boundaries.map(\.fraction),
         "hiddenLines": lines.prefix(activeLineCount).map(\.isHidden),
         "renderScale": previous?.scale ?? 1,
         "managedLayerScales": managedLayerScales,
         "visibleRangeNumbers": renderedRanges.map(\.number),
         "visibleLabelNumbers": renderedLabelFrames.keys.sorted()]
    }
    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateLayer()
    }

    override func updateLayer() {
        guard let layer, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 1
        let state = State(bounds: bounds, width: clipWidth, origin: clipOriginX, revision: boundaryRevision, occlusions: occlusions, scale: scale)
        // AppKit may replace a view's backing layer while attaching or changing
        // its window. Geometry equality does not prove the retained drawing is
        // still connected to the layer that is actually being displayed.
        let needsAttachment = content.superlayer !== layer
        guard state != previous || needsAttachment else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if needsAttachment {
            layer.addSublayer(content); content.mask = clipping; content.masksToBounds = true
            if tint.superlayer == nil {
                content.addSublayer(tint); content.addSublayer(boundaryContent)
                content.addSublayer(startCaps); content.addSublayer(endCaps); content.addSublayer(labelContent)
            }
        }
        content.frame = bounds
        for managed in [content, clipping, tint, boundaryContent, labelContent, startCaps, endCaps] {
            managed.contentsScale = scale
        }
        boundaryContent.frame = bounds; labelContent.frame = bounds
        tint.frame = bounds; tint.fillColor = NSColor.white.withAlphaComponent(0.075).cgColor
        tint.strokeColor = nil
        let visible = Self.visibleBoundaries(indexedBoundaries, origin: clipOriginX, clipWidth: clipWidth,
                                             viewportWidth: bounds.width)
        if activeLineCount > visible.count {
            for index in visible.count..<activeLineCount { lines[index].isHidden = true }
        }
        while lines.count < visible.count {
            let line = CAShapeLayer(); line.strokeColor = nil
            line.anchorPoint = CGPoint(x: 0.5, y: 0)
            boundaryContent.addSublayer(line); lines.append(line); linePathRevisions.append(-1)
        }
        activeLineCount = visible.count
        let boundariesChanged = previousVisible != visible
        let startCapPath = CGMutablePath(), endCapPath = CGMutablePath()
        let strokeWidth = Self.alignedStroke(at: 0, scale: scale).width
        let nextDotState = DotState(height: bounds.height, diameter: strokeWidth, scale: scale)
        let dotsChanged = dotState != nextDotState
        if dotsChanged {
            // A shared local path avoids platform-dependent zero-length dash
            // rasterization. Align circles along both axes and rebuild only
            // for height/scale changes; horizontal scrolling moves layers.
            let path = CGMutablePath(), radius = strokeWidth / 2
            var y = Self.alignedStroke(at: 2, width: strokeWidth, scale: scale).position
            while y <= bounds.height - 2 {
                path.addEllipse(in: CGRect(x: -radius, y: y - radius, width: strokeWidth, height: strokeWidth))
                y += 4
            }
            dotPath = path; dotState = nextDotState; dotRevision &+= 1
        }
        for (index, boundary) in visible.enumerated() {
            let line = lines[index]
            let exactX = clipOriginX + boundary.fraction * clipWidth
            let stroke = Self.alignedStroke(at: exactX, scale: scale, viewportWidth: bounds.width)
            let hidden = exactX < 0 || exactX > bounds.width
            line.isHidden = hidden
            line.contentsScale = scale
            if boundariesChanged {
                let color = boundary.isStart ? NSColor.systemGreen : NSColor.systemOrange
                line.fillColor = color.withAlphaComponent(0.95).cgColor
            }
            guard !hidden else { continue }
            let x = stroke.position
            line.bounds = CGRect(x: -stroke.width / 2, y: 0, width: stroke.width, height: bounds.height)
            line.position = CGPoint(x: x, y: 0)
            if linePathRevisions[index] != dotRevision {
                line.path = dotPath; linePathRevisions[index] = dotRevision
            }
            if bounds.height >= 10 {
                let cap = boundary.isStart ? startCapPath : endCapPath
                let y = Self.alignedStroke(at: boundary.isStart ? bounds.height - 3 : 3, scale: scale).position
                cap.move(to: CGPoint(x: x, y: y + (boundary.isStart ? -3 : 3)))
                cap.addLine(to: CGPoint(x: x, y: y))
                cap.addLine(to: CGPoint(x: x + (boundary.isStart ? 4 : -4), y: y))
            }
        }
        for (cap, path, color) in [(startCaps, startCapPath, NSColor.systemGreen), (endCaps, endCapPath, NSColor.systemOrange)] {
            cap.frame = bounds; cap.path = path; cap.fillColor = nil
            cap.strokeColor = color.withAlphaComponent(0.95).cgColor
            cap.lineWidth = strokeWidth; cap.lineCap = .round; cap.lineJoin = .round
        }
        renderedRanges = rangeIndex.visible(origin: clipOriginX, clipWidth: clipWidth, viewportWidth: bounds.width)
        let tintPath = CGMutablePath()
        var candidates: [LabelCandidate] = []
        for range in renderedRanges {
            let rect = Self.visibleRangeRect(range, origin: clipOriginX, clipWidth: clipWidth, bounds: bounds)
            guard !rect.isNull, rect.width > 0 else { continue }
            tintPath.addRect(rect)
            candidates.append(LabelCandidate(number: range.number, visibleRange: rect, width: labelWidths[range.number] ?? 16))
        }
        tint.path = tintPath
        renderedLabelFrames = Self.labelFrames(candidates, bounds: bounds, scale: scale)
        let visibleLabels = candidates.filter { renderedLabelFrames[$0.number] != nil }
        if activeLabelCount > visibleLabels.count {
            for index in visibleLabels.count..<activeLabelCount { labels[index].isHidden = true }
        }
        while labels.count < visibleLabels.count {
            let label = CATextLayer(); label.fontSize = Self.labelFont.pointSize; label.font = Self.labelFont
            label.alignmentMode = .center; label.foregroundColor = NSColor.white.withAlphaComponent(0.95).cgColor
            label.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
            label.cornerRadius = 3; label.masksToBounds = true
            labelContent.addSublayer(label); labels.append(label)
        }
        activeLabelCount = visibleLabels.count
        for (index, candidate) in visibleLabels.enumerated() {
            let label = labels[index]
            label.isHidden = false; label.contentsScale = scale
            label.string = String(candidate.number); label.frame = renderedLabelFrames[candidate.number]!
            label.borderWidth = 1 / scale; label.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        }
        let maskPath = CGMutablePath()
        for rect in Self.uncoveredRegions(bounds: bounds, occlusions: occlusions) { maskPath.addRect(rect) }
        clipping.frame = bounds; clipping.path = maskPath; clipping.fillColor = NSColor.white.cgColor
        previous = state
        previousVisible = visible
    }

    static func removalRanges(from boundaries: [Boundary]) -> [RemovalRange] {
        Dictionary(grouping: boundaries, by: \.number).compactMap { number, pair in
            guard number > 0, pair.count == 2,
                  let start = pair.first(where: \.isStart), let end = pair.first(where: { !$0.isStart }),
                  start.fraction.isFinite, end.fraction.isFinite,
                  start.fraction >= 0, end.fraction <= 1, start.fraction < end.fraction else { return nil }
            return RemovalRange(start: start.fraction, end: end.fraction, number: number)
        }.sorted { $0.start == $1.start ? $0.number < $1.number : $0.start < $1.start }
    }

    /// Move by at most half a device pixel. Odd-width strokes straddle pixel
    /// centers; even-width strokes straddle pixel edges, avoiding gray fringes.
    static func alignedStroke(at position: CGFloat, width: CGFloat = 1, scale: CGFloat,
                              viewportWidth: CGFloat? = nil) -> (position: CGFloat, width: CGFloat) {
        let scale = scale.isFinite && scale > 0 ? scale : 1
        let pixels = max(1, (width * scale).rounded())
        let strokeWidth = pixels / scale
        var aligned = ((position * scale - pixels / 2).rounded() + pixels / 2) / scale
        // At 1x, rounding an exact viewport edge outwards can put the entire
        // odd-width stroke outside the mask. Pick the adjacent inward pixel
        // center only then; a 2x stroke centered on the edge stays half visible.
        if let viewportWidth, viewportWidth > 0 {
            if aligned + strokeWidth / 2 <= 0 { aligned += strokeWidth }
            else if aligned - strokeWidth / 2 >= viewportWidth { aligned -= strokeWidth }
        }
        return (aligned, strokeWidth)
    }

    static func visibleRangeRect(_ range: RemovalRange, origin: CGFloat, clipWidth: CGFloat, bounds: CGRect) -> CGRect {
        guard clipWidth > 0, clipWidth.isFinite, origin.isFinite, bounds.width > 0, bounds.height > 0 else { return .null }
        let start = max(bounds.minX, origin + range.start * clipWidth)
        let end = min(bounds.maxX, origin + range.end * clipWidth)
        guard start < end else { return .null }
        return CGRect(x: start, y: bounds.minY, width: end - start, height: bounds.height)
    }

    /// Keep each badge centered on its own visible range. When zoomed-out
    /// ranges crowd together, omit a badge rather than place it over a neighbor.
    static func labelFrames(_ candidates: [LabelCandidate], bounds: CGRect, scale: CGFloat) -> [Int: CGRect] {
        guard bounds.height >= 19 else { return [:] }
        let scale = scale.isFinite && scale > 0 ? scale : 1
        let inset: CGFloat = 2, gap: CGFloat = 4, height: CGFloat = 15
        var frames: [Int: CGRect] = [:]
        var lastMaxX = -CGFloat.infinity
        for candidate in candidates {
            guard candidate.width > 0, candidate.width <= bounds.width - inset * 2 else { continue }
            let x = min(max(candidate.visibleRange.midX - candidate.width / 2, bounds.minX + inset),
                        bounds.maxX - inset - candidate.width)
            let rect = CGRect(x: (x * scale).rounded() / scale,
                              y: ((bounds.maxY - height - 3) * scale).rounded() / scale,
                              width: candidate.width, height: height)
            guard rect.minX >= lastMaxX + gap else { continue }
            frames[candidate.number] = rect; lastMaxX = rect.maxX
        }
        return frames
    }

    /// Search the sorted index instead of creating and touching layers for all
    /// offscreen cuts on every scroll or zoom. Endpoints remain inclusive.
    static func visibleBoundaries(_ sorted: [Boundary], origin: CGFloat, clipWidth: CGFloat,
                                  viewportWidth: CGFloat) -> [Boundary] {
        guard clipWidth > 0, viewportWidth > 0, origin.isFinite, clipWidth.isFinite else { return [] }
        let lower = max(0, -origin / clipWidth)
        let upper = min(1, (viewportWidth - origin) / clipWidth)
        guard lower <= upper else { return [] }
        func index(_ value: Double, after: Bool) -> Int {
            var low = 0, high = sorted.count
            while low < high {
                let middle = low + (high - low) / 2
                if sorted[middle].fraction < value || (after && sorted[middle].fraction == value) { low = middle + 1 }
                else { high = middle }
            }
            return low
        }
        return Array(sorted[index(lower, after: false)..<index(upper, after: true)])
    }

    /// Subtract rectangles independently: overlapping occluders cannot reopen a hole.
    static func uncoveredRegions(bounds: CGRect, occlusions: [CGRect]) -> [CGRect] {
        occlusions.reduce([bounds]) { regions, cover in
            regions.flatMap { rect -> [CGRect] in
                let overlap = rect.intersection(cover)
                guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return [rect] }
                return [CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
                    CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
                    CGRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
                    CGRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height)]
                    .filter { $0.width > 0 && $0.height > 0 }
            }
        }
    }

    /// Test/explicit diagnostic snapshot only. Production keeps reusable vector layers.
    func renderBitmap(scale: CGFloat = 1) -> NSBitmapImageRep? {
        guard let layer, bounds.width > 0, bounds.height > 0, scale.isFinite, scale > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(bounds.width * scale)), pixelsHigh: Int(ceil(bounds.height * scale)),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        context.cgContext.scaleBy(x: scale, y: scale)
        context.cgContext.clear(bounds); layer.render(in: context.cgContext)
        return bitmap
    }
}
