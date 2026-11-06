import CoreGraphics

/// A one-level lift can keep the preview above Final Cut's hover redraws,
/// but must not cover another normal window that already owns those pixels.
/// WindowServer surfaces arrive in front-to-back order.
enum PreviewWindowLevelPolicy {
    static func shouldElevate(hostPID: Int32, project: Int, overlay: Int,
                              frame: CGRect, surfaces: [FinalCutPreviewSurface]) -> Bool {
        guard hostPID > 0, project > 0, overlay > 0, !frame.isNull, !frame.isInfinite,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.size.width.isFinite, frame.size.height.isFinite,
              frame.size.width > 0, frame.size.height > 0,
              let projectIndex = surfaces.firstIndex(where: { $0.number == project }) else { return false }
        let projectSurface = surfaces[projectIndex]
        guard projectSurface.pid == hostPID, projectSurface.layer == 0, projectSurface.alpha > 0 else { return false }
        return !surfaces[..<projectIndex].contains { surface in
            guard surface.number != overlay, (surface.layer == 0 || surface.layer == 1), surface.alpha > 0 else {
                return false
            }
            let overlap = surface.frame.intersection(frame)
            return !overlap.isNull && overlap.width > 0 && overlap.height > 0
        }
    }
}
