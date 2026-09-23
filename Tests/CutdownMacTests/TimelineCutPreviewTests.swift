import AppKit
import XCTest
@testable import CutdownMac

final class TimelineCutPreviewTests: XCTestCase {
    func testClickTimeReadGapsKeepPreviewButUnresponsiveHostExpires() {
        let now = Date(timeIntervalSince1970: 100)
        var visibility = PreviewVisibility()
        XCTAssertTrue(visibility.expired(at: now))
        visibility.verified(at: now)
        for delay in [0.03, 0.15, 0.5, 1.0] {
            XCTAssertFalse(visibility.expired(at: now.addingTimeInterval(delay)))
        }
        XCTAssertTrue(visibility.expired(at: now.addingTimeInterval(1.6)))
        visibility.verified(at: now.addingTimeInterval(2))
        XCTAssertFalse(visibility.expired(at: now.addingTimeInterval(2.1)))
        visibility.reset()
        XCTAssertTrue(visibility.expired(at: now.addingTimeInterval(2.1)))
    }

    func testClicksAndOtherWindowsDoNotReorderAlreadyVisiblePreview() {
        for order in [[4, 20, 10], [20, 4, 10], [20, 10, 4]] {
            XCTAssertFalse(PreviewVisibility.needsOrdering(visible: true, overlay: 20, project: 10, windowOrder: order))
        }
        XCTAssertTrue(PreviewVisibility.needsOrdering(visible: true, overlay: 20, project: 10, windowOrder: [4, 10, 20]))
        XCTAssertTrue(PreviewVisibility.needsOrdering(visible: false, overlay: 20, project: 10, windowOrder: [20, 10]))
    }

    private func inspection(cutdown: Bool = false, complete: Bool = true, scroll: Double = 1) -> PreviewEffectInspection {
        .init(viewport: CGRect(x: 0, y: 0, width: 300, height: 500),
            cutdown: cutdown ? CGRect(x: 20, y: 100, width: 20, height: 20) : nil,
            anchors: complete ? ["Effects": CGRect(x: 10, y: 30, width: 30, height: 20)] : [:],
            scrollPosition: scroll)
    }

    func testDeletingEffectDismissesPreviewAndUndoCannotReviveIt() {
        var lifetime = PreviewEffectLifetime()
        let now = Date()
        XCTAssertFalse(lifetime.observe(inspection(cutdown: true), at: now))
        XCTAssertFalse(lifetime.observe(inspection(), at: now.addingTimeInterval(0.4)))
        XCTAssertTrue(lifetime.observe(inspection(), at: now.addingTimeInterval(0.8)))
        XCTAssertTrue(lifetime.observe(inspection(cutdown: true), at: now.addingTimeInterval(1.2)))
        XCTAssertTrue(lifetime.observe(nil, at: now.addingTimeInterval(2)))
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
        XCTAssertFalse(lifetime.observe(inspection(cutdown: true), at: now))
        XCTAssertFalse(lifetime.observe(inspection(), at: now.addingTimeInterval(0.4)))
        // A collapsed Inspector, selection change or incomplete AX read clears
        // pending absence rather than confirming it with elapsed time.
        XCTAssertFalse(lifetime.observe(nil, at: now.addingTimeInterval(1)))
        XCTAssertFalse(lifetime.observe(inspection(complete: false, scroll: 1), at: now.addingTimeInterval(2)))
        XCTAssertFalse(lifetime.observe(inspection(complete: false, scroll: 1), at: now.addingTimeInterval(3)))
        let offscreen = PreviewEffectInspection(viewport: inspection().viewport, cutdown: nil,
            anchors: ["Effects": CGRect(x: 10, y: -600, width: 30, height: 20)], scrollPosition: 0.5)
        XCTAssertFalse(lifetime.observe(offscreen, at: now.addingTimeInterval(4)))
        XCTAssertFalse(lifetime.observe(offscreen, at: now.addingTimeInterval(5)))
    }

    func testGateAndLimiterCanBracketDeletedCutdownInLongEffectStack() {
        var lifetime = PreviewEffectLifetime()
        let now = Date()
        let anchors = ["noise gate check box": CGRect(x: 10, y: 30, width: 30, height: 20),
                       "limiter check box": CGRect(x: 10, y: 300, width: 30, height: 20)]
        let visible = PreviewEffectInspection(viewport: inspection().viewport, cutdown: inspection(cutdown: true).cutdown,
            anchors: anchors, scrollPosition: 0.5)
        let deleted = PreviewEffectInspection(viewport: visible.viewport, cutdown: nil, anchors: anchors, scrollPosition: 0.5)
        XCTAssertFalse(lifetime.observe(visible, at: now))
        XCTAssertFalse(lifetime.observe(deleted, at: now.addingTimeInterval(0.4)))
        XCTAssertTrue(lifetime.observe(deleted, at: now.addingTimeInterval(0.8)))
        var scrolled = PreviewEffectLifetime()
        XCTAssertFalse(scrolled.observe(visible, at: now))
        let partial = PreviewEffectInspection(viewport: visible.viewport, cutdown: nil, anchors: anchors, scrollPosition: 0.8)
        XCTAssertFalse(scrolled.observe(partial, at: now.addingTimeInterval(0.4)))
        XCTAssertFalse(scrolled.observe(partial, at: now.addingTimeInterval(0.8)))
    }

    func testDeletingLastEffectAlsoRemovesEffectsHeading() {
        var lifetime = PreviewEffectLifetime()
        let now = Date()
        let empty = PreviewEffectInspection(viewport: inspection().viewport, cutdown: nil,
            anchors: ["Pan": CGRect(x: 10, y: 30, width: 100, height: 20)], scrollPosition: 1)
        XCTAssertFalse(lifetime.observe(empty, at: now))
        XCTAssertTrue(lifetime.observe(empty, at: now.addingTimeInterval(0.4)))
    }

    func testLastEffectCanBeRemovedWithoutAnInspectorFooterOrScrollBar() {
        let now = Date()
        let viewport = inspection().viewport
        let heading = ["Effects": CGRect(x: 10, y: 30, width: 100, height: 20)]
        for scroll in [nil, 1.0] as [Double?] {
            var lifetime = PreviewEffectLifetime()
            let present = PreviewEffectInspection(viewport: viewport,
                cutdown: CGRect(x: 20, y: 100, width: 20, height: 20),
                anchors: heading, scrollPosition: scroll)
            let deleted = PreviewEffectInspection(viewport: viewport, cutdown: nil,
                anchors: heading, scrollPosition: scroll)
            XCTAssertFalse(lifetime.observe(present, at: now))
            XCTAssertFalse(lifetime.observe(deleted, at: now.addingTimeInterval(0.1)))
            XCTAssertTrue(lifetime.observe(deleted, at: now.addingTimeInterval(0.5)))
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
            cutdown: CGRect(x: 10, y: 300, width: 120, height: 20),
            anchors: anchors, scrollPosition: 1)
        let deleted = PreviewEffectInspection(viewport: viewport, cutdown: nil,
            anchors: anchors, scrollPosition: 1)
        var lifetime = PreviewEffectLifetime()
        XCTAssertFalse(lifetime.observe(present, at: now))
        XCTAssertFalse(lifetime.observe(deleted, at: now.addingTimeInterval(0.1)))
        XCTAssertTrue(lifetime.observe(deleted, at: now.addingTimeInterval(0.5)))

        var scrolled = PreviewEffectLifetime()
        XCTAssertFalse(scrolled.observe(present, at: now))
        let moved = PreviewEffectInspection(viewport: viewport, cutdown: nil,
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
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/cutdown-render-test.png"))
    }
}
