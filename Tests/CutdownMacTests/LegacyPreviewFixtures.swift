import AppKit
import ApplicationServices
import CutdownCore
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

@testable import CutdownMac

// Historical mask geometry; the live preview uses native window ordering.
extension FinalCutPreviewSurface {
    static func occlusions(in windows: [Self], projectPID: Int32, projectFrame: CGRect, helperPID: Int32) -> [CGRect]? {
        let matches = windows.indices.filter { index in
            let window = windows[index]
            return window.pid == projectPID && window.layer == 0 && window.alpha > 0 &&
                abs(window.frame.minX - projectFrame.minX) < 2 && abs(window.frame.minY - projectFrame.minY) < 2 &&
                abs(window.frame.width - projectFrame.width) < 2 && abs(window.frame.height - projectFrame.height) < 2
        }
        guard matches.count == 1, let projectIndex = matches.first else { return nil }
        return windows[..<projectIndex].filter { $0.pid != helperPID && $0.alpha > 0 && $0.layer >= 0 && $0.layer < CGWindowLevelForKey(.mainMenuWindow) }
            .map(\.frame)
    }
}
