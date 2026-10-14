import CoreGraphics

/// Coordinate math. "AppKit global" = points, origin at the bottom-left of the primary screen, y up.
/// "CG global" = points, origin at the top-left of the primary screen, y down (Quartz / ScreenCaptureKit).
public enum Geometry {
    /// AppKit global ↔ CG global. The same function converts both ways.
    /// `primaryHeight` is the height of the primary display (`NSScreen.screens[0]`), in points.
    public static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A rect in AppKit global points → the pixel rect inside that display's captured image
    /// (origin top-left). `displayFrame` is the display's `NSScreen.frame` (AppKit global points).
    /// Each edge is rounded to the nearest whole pixel, then the rect is clamped to the image.
    /// Returns `.zero` when the rect doesn't overlap the image.
    public static func pixelRect(for globalRect: CGRect, displayFrame: CGRect, scale: CGFloat, imageSize: CGSize) -> CGRect {
        let r = globalRect.standardized
        let x0 = ((r.minX - displayFrame.minX) * scale).rounded()
        let x1 = ((r.maxX - displayFrame.minX) * scale).rounded()
        let y0 = ((displayFrame.maxY - r.maxY) * scale).rounded()
        let y1 = ((displayFrame.maxY - r.minY) * scale).rounded()
        let clamped = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            .intersection(CGRect(origin: .zero, size: imageSize))
        return clamped.isNull ? .zero : clamped
    }

    /// Nearest candidate within `threshold` of `value`, or nil. Ties go to the earlier candidate.
    public static func snapValue(_ value: CGFloat, to candidates: [CGFloat], threshold: CGFloat = 8) -> CGFloat? {
        var best: CGFloat?
        var bestDistance = CGFloat.infinity
        for c in candidates {
            let d = abs(c - value)
            if d <= threshold, d < bestDistance { best = c; bestDistance = d }
        }
        return best
    }

    /// Snap a point (e.g. the dragged corner) to the nearest window edges within `threshold`.
    /// A window's left/right edges only count when the point is level with that window (its y within the
    /// window's span, ± threshold), and its top/bottom edges only when the point is within its x span,
    /// so a far-away window doesn't pull the selection. Point and frames must use the same coordinates.
    /// Returns the snapped point and which axes snapped.
    public static func snap(_ point: CGPoint, to windowFrames: [CGRect], threshold: CGFloat = 8) -> (point: CGPoint, snappedX: Bool, snappedY: Bool) {
        let xs = windowFrames
            .filter { point.y >= $0.minY - threshold && point.y <= $0.maxY + threshold }
            .flatMap { [$0.minX, $0.maxX] }
        let ys = windowFrames
            .filter { point.x >= $0.minX - threshold && point.x <= $0.maxX + threshold }
            .flatMap { [$0.minY, $0.maxY] }
        let sx = snapValue(point.x, to: xs, threshold: threshold)
        let sy = snapValue(point.y, to: ys, threshold: threshold)
        return (CGPoint(x: sx ?? point.x, y: sy ?? point.y), sx != nil, sy != nil)
    }

    /// `snap(_:to:threshold:)` for a point that must stay inside `bounds` (its display): a window hanging past
    /// the display's edge would otherwise pull it off. The result is clamped to `bounds`, and an axis that had
    /// to be clamped back doesn't count as snapped.
    public static func snap(_ point: CGPoint, to windowFrames: [CGRect], within bounds: CGRect, threshold: CGFloat = 8) -> (point: CGPoint, snappedX: Bool, snappedY: Bool) {
        let s = snap(point, to: windowFrames, threshold: threshold)
        let x = min(max(s.point.x, bounds.minX), bounds.maxX)
        let y = min(max(s.point.y, bounds.minY), bounds.maxY)
        return (CGPoint(x: x, y: y), s.snappedX && x == s.point.x, s.snappedY && y == s.point.y)
    }
}
