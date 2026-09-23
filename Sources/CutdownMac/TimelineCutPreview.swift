import AppKit
import CutdownCore
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

    mutating func reset() { nextRead = .distantPast; activeUntil = .distantPast }
    mutating func wake(at now: Date) { activeUntil = max(activeUntil, now.addingTimeInterval(0.5)) }
    func isDue(at now: Date) -> Bool { now >= nextRead }
    mutating func didStartRead(at now: Date) {
        nextRead = now.addingTimeInterval(now < activeUntil ? 1.0 / 15 : 0.15)
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
    private var lastOrderedWindowOrder: [Int]?
    private var readTimes: [Double] = []
    private var paintTimes: [Double] = []
    private var diagnosticEnabled = false
    private var diagnosticRequested = false
    private var lastStatus = ""
    private var diagnosticDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cutdown/Integration")
    }

    func show(review: ReviewPlan, session: FinalCutAXSession) {
        // Re-adding an effect or toggling a stale review cannot resurrect lines
        // belonging to the removed controller. A fresh Analyze gets a new session.
        guard removedEffectSession !== session else { return }
        let duration = review.target.timelineRange.duration.seconds
        guard duration > 0, !review.selectedCuts.isEmpty else { hide(); return }
        drawing.boundaries = review.selectedCuts.enumerated().flatMap { index, cut in
            [(cut.range.start, true), (cut.range.end, false)].map { time, isStart in
                CutBoundaryView.Boundary(fraction: (time.seconds - review.target.timelineRange.start.seconds) / duration,
                                         isStart: isStart, number: index + 1)
            }
        }
        if self.session !== session || reader == nil {
            hide()
            self.session = session
            guard let reader = session.makePreviewReader() else { return }
            self.reader = reader
            diagnosticEnabled = FileManager.default.fileExists(atPath: diagnosticDirectory.appendingPathComponent("EnablePreviewDiagnostics").path)
            diagnosticRequested = diagnosticEnabled
            lastStatus = ""
            readTimes = []; paintTimes = []
            observer = PreviewChangeObserver(reader: reader) { [weak self] in self?.wake() }
        }
        wake()
        if timer == nil {
            timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer!, forMode: .common)
        }
        tick()
    }

    func hide() {
        gate.reset(); observer?.stop(); observer = nil
        timer?.invalidate(); timer = nil; reader = nil; session = nil
        pacer.reset()
        panel?.orderOut(nil); lastGeometry = nil; lastOrderedWindowOrder = nil; visibility.reset()
    }
    private func wake() { pacer.wake(at: Date()) }

    private func tick() {
        let now = Date()
        // A slow/unresponsive host must not leave an old rectangle over edits.
        if visibility.expired(at: now), panel?.isVisible == true { panel?.orderOut(nil) }
        guard let reader, pacer.isDue(at: now), let token = gate.begin() else { return }
        pacer.didStartRead(at: now)
        reader.sample { [weak self] result, duration in
            Task { @MainActor in
                guard let self, self.gate.finish(token) else { return }
                if self.diagnosticEnabled { self.readTimes.append(duration) }
                switch result {
                case .success(let geometry):
                    let start = Date()
                    self.present(geometry)
                    if self.diagnosticEnabled { self.paintTimes.append(Date().timeIntervalSince(start)) }
                case .failure(let error):
                    if case FinalCutPreviewError.effectRemoved = error {
                        self.removedEffectSession = self.session
                        self.hide()
                        self.record("Dismissed: Cutdown effect removed")
                    } else if case FinalCutPreviewError.transient = error {
                        if self.visibility.expired(at: Date()) { self.panel?.orderOut(nil) }
                    } else {
                        self.panel?.orderOut(nil)
                        self.record("Hidden: " + error.localizedDescription)
                    }
                }
                self.finishDiagnosticsIfNeeded()
            }
        }
    }

    private func present(_ geometry: PreviewGeometry) {
        let changed = geometry.frame != lastGeometry?.frame || geometry.visibleFrame != lastGeometry?.visibleFrame
        if changed { pacer.wake(at: Date()) }
        visibility.verified(at: Date())
        let window = panel ?? makePanel()
        let visible = geometry.visibleFrame
        let targetFrame = CGRect(x: visible.minX, y: CGDisplayBounds(CGMainDisplayID()).height - visible.maxY,
                                 width: visible.width, height: visible.height)
        if window.frame != targetFrame { window.setFrame(targetFrame, display: false) }
        drawing.frame = CGRect(origin: .zero, size: visible.size)
        drawing.clipWidth = geometry.frame.width
        drawing.clipOriginX = geometry.frame.minX - visible.minX
        drawing.occlusions = geometry.occlusions.map {
            CGRect(x: $0.minX - visible.minX, y: visible.maxY - $0.maxY, width: $0.width, height: $0.height)
        }
        drawing.updateLayer()
        if PreviewVisibility.needsOrdering(visible: window.isVisible, overlay: window.windowNumber,
            project: geometry.projectWindowNumber, windowOrder: geometry.windowOrder) {
            guard geometry.projectWindowNumber > 0 else { window.orderOut(nil); return }
            // A window snapshot is reused across geometry reads. Order once
            // for that snapshot instead of repeatedly raising the same panel.
            if !window.isVisible || lastOrderedWindowOrder != geometry.windowOrder {
                window.order(.above, relativeTo: geometry.projectWindowNumber)
                lastOrderedWindowOrder = geometry.windowOrder
            }
        }
        lastGeometry = geometry
        if diagnosticEnabled { record("Visible: clip=\(geometry.frame), panel=\(window.frame), vector boundaries=\(drawing.boundaries.count)") }
    }

    // Explicit, bounded integration diagnostics. No PNGs or logs on the normal path.
    private func record(_ text: String) {
        guard diagnosticRequested, text != lastStatus else { return }; lastStatus = text
        try? text.write(to: diagnosticDirectory.appendingPathComponent("TimelinePreview.txt"), atomically: true, encoding: .utf8)
    }
    private func finishDiagnosticsIfNeeded() {
        guard diagnosticEnabled, readTimes.count >= 120 else { return }
        let report: [String: Any] = ["samples": readTimes.count, "readSeconds": readTimes,
            "paintSeconds": paintTimes, "observerRegistrations": observer?.registrations ?? 0,
            "vectorLayerCount": drawing.vectorLayerCount, "drawing": drawing.diagnosticState,
            "surfaces": lastGeometry?.diagnosticSurfaces ?? [], "state": lastStatus]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted) {
            try? data.write(to: diagnosticDirectory.appendingPathComponent("PreviewPerformance.json"), options: .atomic)
        }
        if let bitmap = drawing.renderBitmap() {
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
        return window
    }
}

@MainActor final class CutBoundaryView: NSView {
    struct Boundary: Equatable { let fraction: Double; let isStart: Bool; let number: Int }
    private struct State: Equatable {
        let bounds: CGRect; let width: CGFloat; let origin: CGFloat
        let boundaries: [Boundary]; let occlusions: [CGRect]; let scale: CGFloat
    }
    var clipWidth: CGFloat = 0
    var clipOriginX: CGFloat = 0
    var boundaries: [Boundary] = []
    var occlusions: [CGRect] = []
    private let content = CALayer()
    private let clipping = CAShapeLayer()
    private var lines: [CAShapeLayer] = []
    private var labels: [CATextLayer] = []
    private var labelWidths: [CGFloat] = []
    private var previous: State?
    var vectorLayerCount: Int { lines.count }
    var lineLayerIdentities: [ObjectIdentifier] { lines.map(ObjectIdentifier.init) }
    var diagnosticState: [String: Any] {
        ["attached": layer != nil && content.superlayer === layer,
         "bounds": NSStringFromRect(bounds), "contentFrame": NSStringFromRect(content.frame),
         "clipWidth": clipWidth, "clipOriginX": clipOriginX,
         "occlusions": occlusions.map(NSStringFromRect),
         "fractions": boundaries.map(\.fraction),
         "hiddenLines": lines.map(\.isHidden)]
    }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 1
        let state = State(bounds: bounds, width: clipWidth, origin: clipOriginX, boundaries: boundaries, occlusions: occlusions, scale: scale)
        // AppKit may replace a view's backing layer while attaching or changing
        // its window. Geometry equality does not prove the retained drawing is
        // still connected to the layer that is actually being displayed.
        let needsAttachment = content.superlayer !== layer
        guard state != previous || needsAttachment else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if needsAttachment { layer.addSublayer(content); content.mask = clipping; content.masksToBounds = true }
        content.frame = bounds
        while lines.count > boundaries.count { lines.removeLast().removeFromSuperlayer(); labels.removeLast().removeFromSuperlayer(); labelWidths.removeLast() }
        while lines.count < boundaries.count {
            let line = CAShapeLayer(); line.fillColor = nil; line.lineWidth = 2
            let label = CATextLayer(); label.fontSize = 10; label.font = NSFont.boldSystemFont(ofSize: 10)
            label.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
            content.addSublayer(line); content.addSublayer(label)
            lines.append(line); labels.append(label); labelWidths.append(0)
        }
        let boundariesChanged = previous?.boundaries != boundaries
        for (index, boundary) in boundaries.enumerated() {
            let line = lines[index], label = labels[index]
            let x = clipOriginX + boundary.fraction * clipWidth
            let hidden = boundary.fraction < 0 || boundary.fraction > 1 || x < 0 || x > bounds.width
            line.isHidden = hidden; label.isHidden = hidden
            if boundariesChanged {
                let color = boundary.isStart ? NSColor.systemGreen : NSColor.systemOrange
                line.strokeColor = color.cgColor; line.lineDashPattern = boundary.isStart ? [2, 4] : [6, 4]
                let text = "\(boundary.number) \(boundary.isStart ? "START" : "END")"
                label.string = text; label.foregroundColor = color.cgColor
                labelWidths[index] = (text as NSString).size(withAttributes: [.font: NSFont.boldSystemFont(ofSize: 10)]).width + 2
            }
            guard !hidden else { continue }
            let path = CGMutablePath(); path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: bounds.height))
            line.path = path
            label.contentsScale = scale
            let width = labelWidths[index]
            let labelX = boundary.isStart ? min(x + 3, bounds.width - width) : max(0, x - width - 3)
            label.frame = CGRect(x: labelX, y: boundary.isStart ? bounds.height - 16 : 2, width: width, height: 14)
        }
        let maskPath = CGMutablePath()
        for rect in Self.uncoveredRegions(bounds: bounds, occlusions: occlusions) { maskPath.addRect(rect) }
        clipping.frame = bounds; clipping.path = maskPath; clipping.fillColor = NSColor.white.cgColor
        previous = state
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
    func renderBitmap() -> NSBitmapImageRep? {
        guard let layer, bounds.width > 0, bounds.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(bounds.width)), pixelsHigh: Int(ceil(bounds.height)),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        context.cgContext.clear(bounds); layer.render(in: context.cgContext)
        return bitmap
    }
}
