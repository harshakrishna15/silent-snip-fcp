import CoreGraphics
import Foundation
import XCTest
@testable import SilentSnipMac

final class PreviewEffectRemovalPolicyTests: XCTestCase {
    private var missingController: PreviewEffectInspection {
        .init(viewport: CGRect(x: 0, y: 0, width: 300, height: 200), silentsnip: nil,
              anchors: ["Effects": CGRect(x: 10, y: 20, width: 80, height: 20)], scrollPosition: 1)
    }

    func testWorkflowDoesNotReadInspectorOrDismissForMissingAUAfterSixSeconds() {
        let policy = PreviewEffectRemovalPolicy.workflowExtension
        var lifetime = PreviewEffectLifetime()
        var inspectorReads = 0
        let start = Date(timeIntervalSince1970: 100)
        for elapsed in 0...20 {
            if let inspection = policy.inspectIfRequired({ inspectorReads += 1; return missingController }) {
                _ = lifetime.observe(inspection, at: start.addingTimeInterval(Double(elapsed)))
            }
            XCTAssertFalse(lifetime.removed)
        }
        XCTAssertFalse(policy.requiresAudioUnit)
        XCTAssertEqual(inspectorReads, 0, "A button review must not traverse an unrelated Audio Inspector")
    }

    func testLegacyFrontendStillReadsInspectorAndDismissesEarlyControllerDeletion() {
        let policy = PreviewEffectRemovalPolicy.legacyAudioUnit
        var lifetime = PreviewEffectLifetime()
        var inspectorReads = 0
        let start = Date(timeIntervalSince1970: 100)
        for elapsed in 0...6 {
            let inspection = policy.inspectIfRequired { inspectorReads += 1; return missingController }
            _ = lifetime.observe(inspection, at: start.addingTimeInterval(Double(elapsed)))
            if elapsed < 6 { XCTAssertFalse(lifetime.removed) }
        }
        XCTAssertTrue(policy.requiresAudioUnit)
        XCTAssertEqual(inspectorReads, 7)
        XCTAssertTrue(lifetime.removed, "Removing the AU before its first observed Inspector row retains legacy cleanup")
    }

    func testLegacyPreviouslyObservedControllerStillDismissesAfterStableRemoval() {
        let policy = PreviewEffectRemovalPolicy.legacyAudioUnit
        var lifetime = PreviewEffectLifetime()
        let start = Date(timeIntervalSince1970: 100)
        let missing = missingController
        let present = PreviewEffectInspection(viewport: missing.viewport,
            silentsnip: CGRect(x: 20, y: 60, width: 80, height: 20), anchors: missing.anchors, scrollPosition: 1)
        XCTAssertFalse(lifetime.observe(policy.inspectIfRequired { present }, at: start))
        for elapsed in [1.0, 2.0, 3.0] {
            XCTAssertFalse(lifetime.observe(policy.inspectIfRequired { missingController }, at: start.addingTimeInterval(elapsed)))
        }
        XCTAssertTrue(lifetime.observe(policy.inspectIfRequired { missingController }, at: start.addingTimeInterval(3.6)))
    }
}
