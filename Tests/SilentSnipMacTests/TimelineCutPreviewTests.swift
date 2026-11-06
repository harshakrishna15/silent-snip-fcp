import AppKit
import XCTest
@testable import SilentSnipMac

final class TimelineCutPreviewTests: XCTestCase {
    private final class ScalingPanel: NSPanel {
        var testScale: CGFloat = 1
        override var backingScaleFactor: CGFloat { testScale }
    }

    @MainActor func testRemovalTintRequiresOneValidIncludedBoundaryPair() {
        let boundaries: [CutBoundaryView.Boundary] = [
            .init(fraction: 0.1, isStart: true, number: 2), .init(fraction: 0.2, isStart: false, number: 2),
            .init(fraction: 0.6, isStart: true, number: 7), .init(fraction: 0.9, isStart: false, number: 7),
            .init(fraction: 0.3, isStart: true, number: 3), // No end.
            .init(fraction: 0.4, isStart: true, number: 4), .init(fraction: 0.5, isStart: false, number: 4),
            .init(fraction: 0.45, isStart: true, number: 4), // Ambiguous duplicate.
            .init(fraction: 0.8, isStart: true, number: 5), .init(fraction: 0.7, isStart: false, number: 5),
            .init(fraction: .nan, isStart: true, number: 6), .init(fraction: 0.7, isStart: false, number: 6)
        ]
        XCTAssertEqual(CutBoundaryView.removalRanges(from: boundaries), [
            .init(start: 0.1, end: 0.2, number: 2), .init(start: 0.6, end: 0.9, number: 7)
        ])
    }

    @MainActor func testRangeSpanningViewportIsShadedWithoutEitherBoundaryOnscreen() {
        let range = CutBoundaryView.RemovalRange(start: 0.2, end: 0.8, number: 12)
        let index = CutBoundaryView.RangeIndex([range, .init(start: 0.05, end: 0.4, number: 1),
                                              .init(start: 0.5, end: 0.6, number: 2)])
        let visible = index.visible(origin: -400, clipWidth: 1000, viewportWidth: 100)
        XCTAssertEqual(visible, [range], "Touching a viewport edge alone does not create a tinted interval")
        XCTAssertEqual(CutBoundaryView.visibleRangeRect(range, origin: -400, clipWidth: 1000,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 80)), CGRect(x: 0, y: 0, width: 100, height: 80))
        let endpoints: [CutBoundaryView.Boundary] = [.init(fraction: 0.2, isStart: true, number: 12),
                                                   .init(fraction: 0.8, isStart: false, number: 12)]
        XCTAssertTrue(CutBoundaryView.visibleBoundaries(endpoints, origin: -400, clipWidth: 1000, viewportWidth: 100).isEmpty)
    }

    @MainActor func testRangeIndexSkipsThousandsOfOffscreenRangesIncludingLongSpanningRange() {
        var ranges = (0..<10_000).map { CutBoundaryView.RemovalRange(start: Double($0) / 10_000,
            end: (Double($0) + 0.5) / 10_000, number: $0 + 1) }
        ranges.append(.init(start: 0.1, end: 0.9, number: 20_000))
        let index = CutBoundaryView.RangeIndex(ranges)
        var visits = 0
        let visible = index.visible(origin: -50_000, clipWidth: 100_000, viewportWidth: 500, visited: { visits += 1 })
        XCTAssertEqual(visible.count, 51)
        XCTAssertEqual(Set(visible.map(\.number)), Set(Array(5001...5050) + [20_000]))
        XCTAssertLessThan(visits, 150, "A spanning range must not force a scan through every preceding cut")
    }

    @MainActor func testNumberBadgesStayInsideViewportAndOmitCrowdedNeighbors() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 80)
        let frames = CutBoundaryView.labelFrames([
            .init(number: 2, visibleRange: CGRect(x: 0, y: 0, width: 4, height: 80), width: 18),
            .init(number: 5, visibleRange: CGRect(x: 9, y: 0, width: 2, height: 80), width: 18),
            .init(number: 9, visibleRange: CGRect(x: 297, y: 0, width: 3, height: 80), width: 18)
        ], bounds: bounds, scale: 2)
        XCTAssertEqual(Set(frames.keys), [2, 9])
        for frame in frames.values {
            XCTAssertTrue(bounds.contains(frame))
            XCTAssertEqual(frame.minX * 2, (frame.minX * 2).rounded())
        }
        XCTAssertGreaterThanOrEqual(frames[9]!.minX - frames[2]!.maxX, 4)
        XCTAssertTrue(CutBoundaryView.labelFrames([.init(number: 2, visibleRange: bounds, width: 18)],
            bounds: CGRect(x: 0, y: 0, width: 12, height: 80), scale: 1).isEmpty)
    }

    @MainActor func testThinStrokesAlignTheirEdgesAtEachBackingScale() {
        for scale in [CGFloat(1), 2, 3] {
            for exact in [CGFloat(0), 1.2, 59.4683, 200, 499.9] {
                let stroke = CutBoundaryView.alignedStroke(at: exact, scale: scale)
                XCTAssertEqual((stroke.position - stroke.width / 2) * scale,
                    ((stroke.position - stroke.width / 2) * scale).rounded(), accuracy: 0.000001)
                XCTAssertEqual(stroke.width * scale, (stroke.width * scale).rounded(), accuracy: 0.000001)
                XCTAssertLessThanOrEqual(abs(stroke.position - exact), 0.5 / scale + 0.000001)
                XCTAssertEqual(stroke.width, 1)
            }
        }
    }

    @MainActor func testExactViewportEdgesRetainDotsAtOneAndTwoTimesScale() throws {
        let panel = ScalingPanel(contentRect: CGRect(x: 0, y: 0, width: 100, height: 120),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let view = CutBoundaryView(frame: CGRect(x: 0, y: 0, width: 100, height: 120))
        view.wantsLayer = true; panel.contentView = view; view.clipWidth = 100
        view.boundaries = [.init(fraction: 0, isStart: true, number: 1), .init(fraction: 1, isStart: false, number: 1)]
        for scale in [CGFloat(1), 2] {
            panel.testScale = scale; view.viewDidChangeBackingProperties()
            let bitmap = try XCTUnwrap(view.renderBitmap(scale: scale))
            for x in [0, bitmap.pixelsWide - 1] {
                let alphas = (Int(20 * scale)..<Int(100 * scale)).compactMap { bitmap.colorAt(x: x, y: $0)?.alphaComponent }
                XCTAssertGreaterThan(alphas.filter { $0 > 0.2 }.count, Int(5 * scale), "Exact endpoints must not be clipped away")
                XCTAssertGreaterThan(alphas.filter { $0 < 0.12 }.count, Int(10 * scale))
            }
        }
    }

    @MainActor func testScaleChangesReuseDrawingLayersAndRenderRetinaPixels() throws {
        let panel = ScalingPanel(contentRect: CGRect(x: 0, y: 0, width: 300, height: 120),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let view = CutBoundaryView(frame: CGRect(x: 0, y: 0, width: 300, height: 120))
        view.wantsLayer = true; panel.contentView = view; view.clipWidth = 300
        view.boundaries = [.init(fraction: 0.2, isStart: true, number: 4), .init(fraction: 0.8, isStart: false, number: 4)]
        view.updateLayer()
        let identities = view.lineLayerIdentities
        XCTAssertTrue(view.managedLayerScales.allSatisfy { $0 == 1 })
        panel.testScale = 2; view.viewDidChangeBackingProperties()
        XCTAssertTrue(view.managedLayerScales.allSatisfy { $0 == 2 })
        XCTAssertEqual(view.lineLayerIdentities, identities)
        let bitmap = try XCTUnwrap(view.renderBitmap(scale: 2))
        XCTAssertEqual(bitmap.pixelsWide, 600); XCTAssertEqual(bitmap.pixelsHigh, 240)
        view.layer = CALayer(); view.updateLayer()
        XCTAssertEqual(view.lineLayerIdentities, identities)
        XCTAssertTrue(view.managedLayerScales.allSatisfy { $0 == 2 })
        XCTAssertGreaterThan(try XCTUnwrap(view.renderBitmap(scale: 2)?.colorAt(x: 300, y: 120)?.alphaComponent), 0.03)
    }

    @MainActor func testSpanningTintAndBadgeAreClippedByTheSharedOcclusionMask() throws {
        let view = CutBoundaryView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        view.wantsLayer = true; view.clipWidth = 1000; view.clipOriginX = -400
        view.boundaries = [.init(fraction: 0.2, isStart: true, number: 12), .init(fraction: 0.8, isStart: false, number: 12)]
        view.updateLayer()
        XCTAssertEqual(view.vectorLayerCount, 0)
        XCTAssertEqual(view.renderedRanges.map(\.number), [12])
        XCTAssertEqual(Set(view.renderedLabelFrames.keys), [12])
        let initial = try XCTUnwrap(view.renderBitmap())
        XCTAssertGreaterThan(try XCTUnwrap(initial.colorAt(x: 50, y: 50)?.alphaComponent), 0.03)
        view.occlusions = [CGRect(x: 100, y: 0, width: 100, height: 100)]; view.updateLayer()
        let covered = try XCTUnwrap(view.renderBitmap())
        XCTAssertEqual(covered.colorAt(x: 150, y: 50)?.alphaComponent, 0)
        XCTAssertGreaterThan(try XCTUnwrap(covered.colorAt(x: 50, y: 50)?.alphaComponent), 0.03)
        view.occlusions = [view.bounds]; view.updateLayer()
        let hidden = try XCTUnwrap(view.renderBitmap())
        for y in 0..<100 { for x in 0..<200 { XCTAssertEqual(hidden.colorAt(x: x, y: y)?.alphaComponent, 0) } }
    }

    @MainActor func testHiddenPooledBoundariesReceiveNewHeightAndDotPhaseWhenVisibleAgain() throws {
        let panel = ScalingPanel(contentRect: CGRect(x: 0, y: 0, width: 500, height: 120),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let view = CutBoundaryView(frame: CGRect(x: 0, y: 0, width: 500, height: 120))
        view.wantsLayer = true; panel.contentView = view; view.clipWidth = 500
        view.boundaries = [0.1, 0.3, 0.5, 0.7, 0.9].enumerated().map {
            .init(fraction: $0.element, isStart: true, number: $0.offset + 1)
        }
        view.updateLayer()
        let identities = view.lineLayerIdentities
        XCTAssertEqual(identities.count, 5)
        view.clipWidth = 2000; view.updateLayer()
        XCTAssertEqual(view.vectorLayerCount, 1)
        panel.testScale = 2; view.setFrameSize(CGSize(width: 500, height: 210))
        view.viewDidChangeBackingProperties()
        view.clipWidth = 500; view.updateLayer()
        XCTAssertEqual(view.lineLayerIdentities, identities)
        XCTAssertTrue(view.managedLayerScales.allSatisfy { $0 == 2 })
        let bitmap = try XCTUnwrap(view.renderBitmap(scale: 2))
        let rows = 60..<180
        let reference = rows.map { bitmap.colorAt(x: 100, y: $0)?.alphaComponent ?? 0 }
        XCTAssertGreaterThan(reference.filter { $0 > 0.2 }.count, 10)
        for x in [300, 500, 700, 900] {
            let revived = rows.map { bitmap.colorAt(x: x, y: $0)?.alphaComponent ?? 0 }
            XCTAssertEqual(revived, reference, "Every revived layer must use the current full-height path and dot phase")
        }
    }

    @MainActor func testCompactRangePreviewProducesSeparatedRoundDotsAtOneAndTwoTimesScale() throws {
        let panel = ScalingPanel(contentRect: CGRect(x: 0, y: 0, width: 1151, height: 210),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let view = CutBoundaryView(frame: CGRect(x: 0, y: 0, width: 1151, height: 210))
        view.wantsLayer = true; panel.contentView = view; view.clipWidth = 1151
        view.boundaries = [.init(fraction: 3.1 / 60, isStart: true, number: 1), .init(fraction: 13.4 / 60, isStart: false, number: 1)]
        for number in 2...18 {
            let start = 15.6 + Double(number - 2) * 2.5
            view.boundaries += [.init(fraction: start / 60, isStart: true, number: number),
                                .init(fraction: (start + 0.3) / 60, isStart: false, number: number)]
        }
        for scale in [CGFloat(1), 2] {
            panel.testScale = scale; view.viewDidChangeBackingProperties()
            let bitmap = try XCTUnwrap(view.renderBitmap(scale: scale))
            XCTAssertEqual(view.vectorLayerCount, 36)
            XCTAssertEqual(view.renderedLabelFrames.count, 18)
            let position = CutBoundaryView.alignedStroke(at: 3.1 / 60 * 1151, scale: scale).position
            let x = Int(floor(position * scale))
            let alphas = (Int(25 * scale)..<Int(185 * scale)).compactMap { bitmap.colorAt(x: x, y: $0)?.alphaComponent }
            XCTAssertGreaterThan(alphas.filter { $0 > 0.2 }.count, Int(20 * scale), "Round dots must reach the backing layer")
            XCTAssertGreaterThan(alphas.filter { $0 < 0.12 }.count, Int(50 * scale), "The thin stroke must retain visible gaps")
            if let path = ProcessInfo.processInfo.environment["SILENT_SNIP_PREVIEW_RENDER_OUTPUT"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("Preview-\(Int(scale))x.png"))
            }
        }
    }

    @MainActor func testZoomedPreviewAllocatesOnlyVisibleBoundariesAndRetainsGlobalNumbers() {
        let view = CutBoundaryView(frame: CGRect(x: 0, y: 0, width: 500, height: 120))
        view.wantsLayer = true
        view.clipWidth = 100_000
        view.clipOriginX = -50_000
        view.boundaries = (0...10_000).map { .init(fraction: Double($0) / 10_000, isStart: true, number: $0 + 1) }
        view.updateLayer()
        XCTAssertEqual(view.vectorLayerCount, 51, "Offscreen cuts must not allocate thousands of layers")
        let visible = CutBoundaryView.visibleBoundaries(view.boundaries, origin: view.clipOriginX,
            clipWidth: view.clipWidth, viewportWidth: view.bounds.width)
        XCTAssertEqual(visible.first?.number, 5001)
        XCTAssertEqual(visible.last?.number, 5051)
        let identities = view.lineLayerIdentities
        view.clipOriginX = -60_000
        view.updateLayer()
        XCTAssertEqual(view.lineLayerIdentities, identities)
        view.clipWidth = 500; view.clipOriginX = 0; view.updateLayer()
        XCTAssertEqual(view.vectorLayerCount, 10_001, "Zooming out must restore every boundary")
    }

    func testPositionPollingDoesNotDependOnNotificationsOrAccelerateWithoutBound() {
        let start = Date(timeIntervalSince1970: 100)
        var pacer = PreviewSamplePacer()
        XCTAssertTrue(pacer.isDue(at: start))
        pacer.didStartRead(at: start)
        XCTAssertFalse(pacer.isDue(at: start.addingTimeInterval(0.02)))
        XCTAssertTrue(pacer.isDue(at: start.addingTimeInterval(0.034)))
        for step in 1...10 { pacer.wake(at: start.addingTimeInterval(Double(step) / 1000)) }
        XCTAssertFalse(pacer.isDue(at: start.addingTimeInterval(0.015)))
        XCTAssertTrue(pacer.isDue(at: start.addingTimeInterval(0.017)),
            "Activity must shorten an idle wait without exceeding 60 requests/second.")
        pacer.didStartRead(at: start.addingTimeInterval(0.017))
        for step in 18...30 { pacer.wake(at: start.addingTimeInterval(Double(step) / 1000)) }
        XCTAssertFalse(pacer.isDue(at: start.addingTimeInterval(0.032)))
        XCTAssertTrue(pacer.isDue(at: start.addingTimeInterval(0.034)))
        pacer.didStartRead(at: start.addingTimeInterval(1))
        XCTAssertFalse(pacer.isDue(at: start.addingTimeInterval(1.02)))
        XCTAssertTrue(pacer.isDue(at: start.addingTimeInterval(1.034)),
            "Polling continues at 30 Hz when Final Cut sends no notifications.")
        pacer.reset()
        XCTAssertTrue(pacer.isDue(at: start))
    }

    func testClickTimeReadGapsNeverExpireVerifiedPreview() {
        let now = Date(timeIntervalSince1970: 100)
        var visibility = PreviewVisibility()
        visibility.verified()
        visibility.transientFailure()
        XCTAssertFalse(visibility.confirmedUnavailable("Clip outside viewport", at: now))
        XCTAssertFalse(visibility.confirmedUnavailable("Clip outside viewport", at: now.addingTimeInterval(2.4)))
        visibility.transientFailure()
        XCTAssertFalse(visibility.confirmedUnavailable("Clip outside viewport", at: now.addingTimeInterval(10)))
        XCTAssertTrue(visibility.confirmedUnavailable("Clip outside viewport", at: now.addingTimeInterval(12.6)))
        visibility.verified()
        XCTAssertFalse(visibility.confirmedUnavailable("Project changed", at: now.addingTimeInterval(13)))
        visibility.reset()
        XCTAssertFalse(visibility.confirmedUnavailable("Project changed", at: now.addingTimeInterval(20)))
    }

    func testHoverReadFailureKeepsVerifiedClipWithoutRepeatedIdentityScans() {
        let start = Date(timeIntervalSince1970: 100)
        var lease = PreviewIdentityLease()
        XCTAssertFalse(lease.usable(at: start))
        lease.verified(at: start)
        XCTAssertFalse(lease.beginRevalidation(at: start.addingTimeInterval(0.8)))
        XCTAssertTrue(lease.beginRevalidation(at: start.addingTimeInterval(1.0)))
        // The attempted AX scan failed during a hover transition. Keep the
        // old verified clip while short geometry reads continue.
        XCTAssertTrue(lease.usable(at: start.addingTimeInterval(1.2)))
        XCTAssertFalse(lease.beginRevalidation(at: start.addingTimeInterval(1.2)))
        XCTAssertTrue(lease.beginRevalidation(at: start.addingTimeInterval(2.0)))
        lease.verified(at: start.addingTimeInterval(2.1))
        XCTAssertTrue(lease.usable(at: start.addingTimeInterval(6.9)))
        XCTAssertFalse(lease.usable(at: start.addingTimeInterval(7.2)))
        lease.invalidate()
        XCTAssertFalse(lease.usable(at: start.addingTimeInterval(2.2)))
    }

    func testClicksAndOtherWindowsDoNotReorderAlreadyVisiblePreview() {
        for order in [[4, 20, 10], [20, 4, 10], [20, 10, 4]] {
            XCTAssertFalse(PreviewVisibility.needsOrdering(visible: true, overlay: 20, project: 10, windowOrder: order))
        }
        XCTAssertTrue(PreviewVisibility.needsOrdering(visible: true, overlay: 20, project: 10, windowOrder: [4, 10, 20]))
        XCTAssertTrue(PreviewVisibility.needsOrdering(visible: false, overlay: 20, project: 10, windowOrder: [20, 10]))
        // A covered overlay can vanish from the on-screen list; repeated
        // identical lists must not suppress attempts to bring it back.
        XCTAssertTrue(PreviewVisibility.needsOrdering(visible: true, overlay: 20, project: 10,
            windowOrder: [4, 10]))
        XCTAssertFalse(PreviewVisibility.needsOrdering(visible: true, overlay: 20, project: 10,
            windowOrder: [4, 20]))
    }

    private func inspection(silentsnip: Bool = false, complete: Bool = true, scroll: Double = 1) -> PreviewEffectInspection {
        .init(viewport: CGRect(x: 0, y: 0, width: 300, height: 500),
            silentsnip: silentsnip ? CGRect(x: 20, y: 100, width: 20, height: 20) : nil,
            anchors: complete ? ["Effects": CGRect(x: 10, y: 30, width: 30, height: 20)] : [:],
            scrollPosition: scroll)
    }

    func testDeletingEffectDismissesPreviewAndUndoCannotReviveIt() {
        var lifetime = PreviewEffectLifetime()
        let now = Date()
        XCTAssertFalse(lifetime.observe(inspection(silentsnip: true), at: now))
        XCTAssertFalse(lifetime.observe(inspection(), at: now.addingTimeInterval(0.4)))
        XCTAssertFalse(lifetime.observe(inspection(), at: now.addingTimeInterval(0.8)))
        XCTAssertFalse(lifetime.observe(inspection(), at: now.addingTimeInterval(2.8)))
        XCTAssertTrue(lifetime.observe(inspection(), at: now.addingTimeInterval(3.0)))
        XCTAssertTrue(lifetime.observe(inspection(silentsnip: true), at: now.addingTimeInterval(3.2)))
        XCTAssertTrue(lifetime.observe(nil, at: now.addingTimeInterval(4)))
    }

    func testMissingSilentSnipRowBeforeFirstVerifiedAppearanceCannotDismissPreview() {
        var lifetime = PreviewEffectLifetime()
        let now = Date()
        for offset in [0.0, 1.0, 3.0, 6.0] {
            XCTAssertFalse(lifetime.observe(inspection(), at: now.addingTimeInterval(offset)))
        }
        XCTAssertFalse(lifetime.observe(inspection(silentsnip: true), at: now.addingTimeInterval(7)))
        XCTAssertFalse(lifetime.observe(inspection(), at: now.addingTimeInterval(8)))
        XCTAssertFalse(lifetime.observe(inspection(), at: now.addingTimeInterval(8.4)))
        XCTAssertFalse(lifetime.observe(inspection(silentsnip: true), at: now.addingTimeInterval(8.5)))
    }

    func testDeletionBeforeFirstVerifiedInspectorAppearanceEventuallyDismissesPreview() {
        var lifetime = PreviewEffectLifetime()
        let now = Date()
        for offset in [0.0, 1.0, 3.0, 5.0] {
            XCTAssertFalse(lifetime.observe(inspection(), at: now.addingTimeInterval(offset)))
        }
        XCTAssertTrue(lifetime.observe(inspection(), at: now.addingTimeInterval(6.1)))
    }

    func testIncompleteHiddenOrScrolledInspectorIsNotEffectRemoval() {
        XCTAssertFalse(PreviewEffectInspection.effectsExpanded(value: "off", title: "Show"))
        XCTAssertFalse(PreviewEffectInspection.effectsExpanded(value: nil, title: nil))
        XCTAssertFalse(PreviewEffectInspection.effectsExpanded(value: "1", title: "Show"))
        XCTAssertTrue(PreviewEffectInspection.effectsExpanded(value: "on", title: nil))
        XCTAssertTrue(PreviewEffectInspection.effectsExpanded(value: nil, title: "Hide"))
        XCTAssertNil(PreviewEffectInspection.scrollPosition(value: 0, enabled: false))
        XCTAssertEqual(PreviewEffectInspection.scrollPosition(value: 0, enabled: true), 0)
        var lifetime = PreviewEffectLifetime()
        let now = Date()
        XCTAssertFalse(lifetime.observe(inspection(silentsnip: true), at: now))
        XCTAssertFalse(lifetime.observe(inspection(), at: now.addingTimeInterval(0.4)))
        // A collapsed Inspector, selection change or incomplete AX read clears
        // pending absence rather than confirming it with elapsed time.
        XCTAssertFalse(lifetime.observe(nil, at: now.addingTimeInterval(1)))
        XCTAssertFalse(lifetime.observe(inspection(complete: false, scroll: 1), at: now.addingTimeInterval(2)))
        XCTAssertFalse(lifetime.observe(inspection(complete: false, scroll: 1), at: now.addingTimeInterval(3)))
        let offscreen = PreviewEffectInspection(viewport: inspection().viewport, silentsnip: nil,
            anchors: ["Effects": CGRect(x: 10, y: -600, width: 30, height: 20)], scrollPosition: 0.5)
        XCTAssertFalse(lifetime.observe(offscreen, at: now.addingTimeInterval(4)))
        XCTAssertFalse(lifetime.observe(offscreen, at: now.addingTimeInterval(5)))
    }

    func testGateAndLimiterCanBracketDeletedSilentSnipInLongEffectStack() {
        var lifetime = PreviewEffectLifetime()
        let now = Date()
        let anchors = ["noise gate check box": CGRect(x: 10, y: 30, width: 30, height: 20),
                       "limiter check box": CGRect(x: 10, y: 300, width: 30, height: 20)]
        let visible = PreviewEffectInspection(viewport: inspection().viewport, silentsnip: inspection(silentsnip: true).silentsnip,
            anchors: anchors, scrollPosition: 0.5)
        let deleted = PreviewEffectInspection(viewport: visible.viewport, silentsnip: nil, anchors: anchors, scrollPosition: 0.5)
        XCTAssertFalse(lifetime.observe(visible, at: now))
        XCTAssertFalse(lifetime.observe(deleted, at: now.addingTimeInterval(0.4)))
        XCTAssertFalse(lifetime.observe(deleted, at: now.addingTimeInterval(0.8)))
        XCTAssertTrue(lifetime.observe(deleted, at: now.addingTimeInterval(3.0)))
        var scrolled = PreviewEffectLifetime()
        XCTAssertFalse(scrolled.observe(visible, at: now))
        let partial = PreviewEffectInspection(viewport: visible.viewport, silentsnip: nil, anchors: anchors, scrollPosition: 0.8)
        XCTAssertFalse(scrolled.observe(partial, at: now.addingTimeInterval(0.4)))
        XCTAssertFalse(scrolled.observe(partial, at: now.addingTimeInterval(0.8)))
    }

    func testDeletingLastEffectAlsoRemovesEffectsHeading() {
        var lifetime = PreviewEffectLifetime()
        let now = Date()
        XCTAssertFalse(lifetime.observe(inspection(silentsnip: true), at: now))
        let empty = PreviewEffectInspection(viewport: inspection().viewport, silentsnip: nil,
            anchors: ["Pan": CGRect(x: 10, y: 30, width: 100, height: 20)], scrollPosition: 1)
        XCTAssertFalse(lifetime.observe(empty, at: now.addingTimeInterval(0.1)))
        XCTAssertFalse(lifetime.observe(empty, at: now.addingTimeInterval(0.4)))
        XCTAssertTrue(lifetime.observe(empty, at: now.addingTimeInterval(2.7)))
    }

    func testLastEffectCanBeRemovedWithoutAnInspectorFooterOrScrollBar() {
        let now = Date()
        let viewport = inspection().viewport
        let heading = ["Effects": CGRect(x: 10, y: 30, width: 100, height: 20)]
        for scroll in [nil, 1.0] as [Double?] {
            var lifetime = PreviewEffectLifetime()
            let present = PreviewEffectInspection(viewport: viewport,
                silentsnip: CGRect(x: 20, y: 100, width: 20, height: 20),
                anchors: heading, scrollPosition: scroll)
            let deleted = PreviewEffectInspection(viewport: viewport, silentsnip: nil,
                anchors: heading, scrollPosition: scroll)
            XCTAssertFalse(lifetime.observe(present, at: now))
            XCTAssertFalse(lifetime.observe(deleted, at: now.addingTimeInterval(0.1)))
            XCTAssertFalse(lifetime.observe(deleted, at: now.addingTimeInterval(0.5)))
            XCTAssertTrue(lifetime.observe(deleted, at: now.addingTimeInterval(2.7)))
        }
    }

    func testPartialEffectsSectionCannotProveRemovalWithoutNeighborWitnesses() {
        var lifetime = PreviewEffectLifetime()
        let now = Date()
        let partial = inspection(scroll: 0.5)
        XCTAssertFalse(lifetime.observe(partial, at: now))
        XCTAssertFalse(lifetime.observe(partial, at: now.addingTimeInterval(1)))
    }

    func testDeletingLastEffectInLongStackUsesPrecedingEffectAtScrollEnd() {
        let now = Date()
        let viewport = inspection().viewport
        let anchors = ["limiter check box": CGRect(x: 10, y: 100, width: 120, height: 20)]
        let present = PreviewEffectInspection(viewport: viewport,
            silentsnip: CGRect(x: 10, y: 300, width: 120, height: 20),
            anchors: anchors, scrollPosition: 1)
        let deleted = PreviewEffectInspection(viewport: viewport, silentsnip: nil,
            anchors: anchors, scrollPosition: 1)
        var lifetime = PreviewEffectLifetime()
        XCTAssertFalse(lifetime.observe(present, at: now))
        XCTAssertFalse(lifetime.observe(deleted, at: now.addingTimeInterval(0.1)))
        XCTAssertFalse(lifetime.observe(deleted, at: now.addingTimeInterval(0.5)))
        XCTAssertTrue(lifetime.observe(deleted, at: now.addingTimeInterval(2.7)))

        var scrolled = PreviewEffectLifetime()
        XCTAssertFalse(scrolled.observe(present, at: now))
        let moved = PreviewEffectInspection(viewport: viewport, silentsnip: nil,
            anchors: anchors, scrollPosition: 0.5)
        XCTAssertFalse(scrolled.observe(moved, at: now.addingTimeInterval(0.5)))
        XCTAssertFalse(scrolled.observe(moved, at: now.addingTimeInterval(1)))
    }

    @MainActor func testBoundaryLayersSurviveBackingLayerReplacement() throws {
        let view = CutBoundaryView(frame: CGRect(x: 0, y: 0, width: 500, height: 120))
        view.wantsLayer = true
        view.clipWidth = 500
        view.boundaries = [.init(fraction: 0.4, isStart: true, number: 1)]
        view.updateLayer()
        view.layer = CALayer()
        view.updateLayer()
        let bitmap = try XCTUnwrap(view.renderBitmap())
        XCTAssertTrue((0..<120).contains { y in
            (bitmap.colorAt(x: 200, y: y)?.alphaComponent ?? 0) > 0.1
        }, "An unchanged preview must reattach its drawing when AppKit replaces the backing layer.")
    }

    @MainActor func testHostedPreviewProducesBoundaryPixels() throws {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 500, height: 120),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false; panel.backgroundColor = .clear
        let view = CutBoundaryView(frame: .zero)
        view.wantsLayer = true
        panel.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 500, height: 120)
        view.clipWidth = 500
        view.boundaries = [.init(fraction: 0.4, isStart: true, number: 1)]
        view.updateLayer()
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.renderBitmap())
        XCTAssertTrue((0..<120).contains { y in
            (bitmap.colorAt(x: 200, y: y)?.alphaComponent ?? 0) > 0.1
        }, "A preview attached to its real panel must contain boundary pixels.")
    }

    func testLateGeometryCannotReviveDismissedPreviewOrOverlapRequests() {
        var gate = PreviewRequestGate()
        let old = gate.begin()!
        XCTAssertNil(gate.begin())
        gate.reset()
        let fresh = gate.begin()!
        XCTAssertFalse(gate.finish(old))
        XCTAssertNil(gate.begin())
        XCTAssertTrue(gate.finish(fresh))
        XCTAssertNotNil(gate.begin())
    }

    @MainActor func testVectorLayersAreReusedAndCoveredPixelsDisappear() throws {
        let view = CutBoundaryView(frame: CGRect(x: 0, y: 0, width: 500, height: 120))
        view.wantsLayer = true; view.clipWidth = 500
        view.boundaries = [.init(fraction: 0.4, isStart: true, number: 1)]
        view.updateLayer()
        let identities = view.lineLayerIdentities
        view.clipOriginX = 10; view.updateLayer()
        XCTAssertEqual(view.lineLayerIdentities, identities)
        view.occlusions = [view.bounds]; view.updateLayer()
        let bitmap = try XCTUnwrap(view.renderBitmap())
        for y in 0..<120 { XCTAssertEqual(bitmap.colorAt(x: 210, y: y)?.alphaComponent, 0) }
        XCTAssertTrue(CutBoundaryView.uncoveredRegions(bounds: view.bounds, occlusions: [view.bounds, view.bounds]).isEmpty)
        view.occlusions = []; view.updateLayer()
        XCTAssertEqual(view.lineLayerIdentities, identities)
    }

    @MainActor func testBoundaryPixelsSurvivePartialOcclusion() throws {
        let view = CutBoundaryView(frame: NSRect(x: 0, y: 0, width: 500, height: 120))
        view.clipWidth = 500
        view.boundaries = [.init(fraction: 0.2, isStart: true, number: 1), .init(fraction: 0.4, isStart: false, number: 1)]
        view.occlusions = [CGRect(x: 300, y: 0, width: 200, height: 120), CGRect(x: -10, y: 400, width: 800, height: 1)]
        view.wantsLayer = true
        view.updateLayer()
        let bitmap = try XCTUnwrap(view.renderBitmap())
        XCTAssertEqual(view.vectorLayerCount, 2)
        var colored = 0
        for y in 0..<120 { for x in 0..<500 {
            if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.1,
               max(color.redComponent, color.greenComponent) > 0.2 { colored += 1 }
        }}
        XCTAssertGreaterThan(colored, 100, "Start and end boundaries must produce real pixels")
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/silentsnip-render-test.png"))
    }
}
