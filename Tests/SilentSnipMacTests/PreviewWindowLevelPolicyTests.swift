import CoreGraphics
import XCTest
@testable import SilentSnipMac

final class PreviewWindowLevelPolicyTests: XCTestCase {
    private let hostPID: Int32 = 101
    private let project = 10
    private let overlay = 20
    private let clip = CGRect(x: 100, y: 500, width: 500, height: 100)

    private func surface(_ number: Int, pid: Int32 = 101, layer: Int = 0,
                         alpha: Double = 1, frame: CGRect? = nil) -> FinalCutPreviewSurface {
        .init(pid: pid, frame: frame ?? CGRect(x: 0, y: 0, width: 1000, height: 800),
              layer: layer, alpha: alpha, number: number)
    }
    private func elevated(_ surfaces: [FinalCutPreviewSurface], frame: CGRect? = nil) -> Bool {
        PreviewWindowLevelPolicy.shouldElevate(hostPID: hostPID,
            project: project, overlay: overlay, frame: frame ?? clip, surfaces: surfaces)
    }

    func testVerifiedUncoveredProjectCanElevateAndExactPreviewWindowDoesNotBlockItself() {
        let windows = [surface(overlay, pid: 202, layer: 1, frame: clip), surface(project)]
        XCTAssertTrue(elevated(windows))
        XCTAssertTrue(elevated([surface(project)]), "A covered preview may be absent from the on-screen list")
        XCTAssertFalse(PreviewWindowLevelPolicy.shouldElevate(hostPID: 0, project: project, overlay: overlay,
            frame: clip, surfaces: windows))
        XCTAssertFalse(PreviewWindowLevelPolicy.shouldElevate(hostPID: hostPID, project: 0, overlay: overlay,
            frame: clip, surfaces: windows))
        XCTAssertFalse(PreviewWindowLevelPolicy.shouldElevate(hostPID: hostPID, project: project, overlay: 0,
            frame: clip, surfaces: windows))
    }

    func testOverlappingNormalWindowsFromOtherAppsKeepTheirPixelsAboveThePreview() {
        for level in [0, 1] {
            let otherWindow = surface(30, pid: 303, layer: level,
                frame: CGRect(x: clip.maxX - 1, y: clip.minY, width: 200, height: 100))
            XCTAssertFalse(elevated([otherWindow, surface(overlay, pid: 202), surface(project)]),
                           "Even a positive one-point overlap must retain normal window compositing")
        }
        let touching = surface(30, pid: 303, frame: CGRect(x: clip.maxX, y: clip.minY, width: 200, height: 100))
        XCTAssertTrue(elevated([touching, surface(project)]), "Touching edges have no covered pixels")
    }

    func testNormalFinalCutEditorsBlockElevationWhileHigherFloatingPanelsRemainAboveIt() {
        for level in [0, 1] {
            XCTAssertFalse(elevated([surface(30, layer: level, frame: clip), surface(project)]))
        }
        for level in [2, 3, 25] {
            XCTAssertTrue(elevated([surface(30, layer: level, frame: clip), surface(project)]),
                          "A normal+1 preview remains below these floating panels")
        }
    }

    func testBelowProjectOffClipAndTransparentSurfacesDoNotBlockElevation() {
        let offClip = surface(30, pid: 303, frame: CGRect(x: 0, y: 0, width: 80, height: 400))
        let transparent = surface(31, pid: 303, alpha: 0, frame: clip)
        let behindProject = surface(32, pid: 303, frame: clip)
        XCTAssertTrue(elevated([offClip, transparent, surface(project), behindProject]))
    }

    func testMissingWrongOwnerNonNormalOrInvisibleProjectAndInvalidFramesAreRejected() {
        XCTAssertFalse(elevated([]))
        XCTAssertFalse(elevated([surface(99)]))
        XCTAssertFalse(elevated([surface(project, pid: 303)]))
        XCTAssertFalse(elevated([surface(project, layer: 1)]))
        XCTAssertFalse(elevated([surface(project, alpha: 0)]))
        for frame in [CGRect.zero, .null, .infinite,
                      CGRect(x: CGFloat.nan, y: 0, width: 50, height: 50),
                      CGRect(x: 0, y: 0, width: -50, height: 50)] {
            XCTAssertFalse(elevated([surface(project)], frame: frame))
        }
    }
}
