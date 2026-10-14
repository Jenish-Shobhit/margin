import CoreGraphics

/// Coordinate math. "AppKit global" = points, origin at the bottom-left of the primary screen, y up.
/// "CG global" = points, origin at the top-left of the primary screen, y down (Quartz / ScreenCaptureKit).
public enum Geometry {
    /// AppKit global ↔ CG global. The same function converts both ways.
    public static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A rect in AppKit global points → the pixel rect inside that display's captured image
    /// (origin top-left). Each edge is rounded to the nearest whole pixel, then clamped to the image.
    public static func pixelRect(for globalRect: CGRect, displayFrame: CGRect, scale: CGFloat, imageSize: CGSize) -> CGRect {
        let x0 = ((globalRect.minX - displayFrame.minX) * scale).rounded()
        let x1 = ((globalRect.maxX - displayFrame.minX) * scale).rounded()
        let y0 = ((displayFrame.maxY - globalRect.maxY) * scale).rounded()
        let y1 = ((displayFrame.maxY - globalRect.minY) * scale).rounded()
        let r = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        return r.intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// Nearest candidate within `threshold` of `value`, or nil.
    public static func snapValue(_ value: CGFloat, to candidates: [CGFloat], threshold: CGFloat = 8) -> CGFloat? {
        var best: CGFloat?
        var bestDistance = threshold + 1
        for c in candidates {
            let d = abs(c - value)
            if d <= threshold, d < bestDistance { best = c; bestDistance = d }
        }
        return best
    }

    /// Snap a point (e.g. the dragged corner) to the nearest window edges within `threshold`.
    /// Returns the snapped point and which axes snapped.
    public static func snap(_ point: CGPoint, to windowFrames: [CGRect], threshold: CGFloat = 8) -> (point: CGPoint, snappedX: Bool, snappedY: Bool) {
        let xs = windowFrames.flatMap { [$0.minX, $0.maxX] }
        let ys = windowFrames.flatMap { [$0.minY, $0.maxY] }
        let sx = snapValue(point.x, to: xs, threshold: threshold)
        let sy = snapValue(point.y, to: ys, threshold: threshold)
        return (CGPoint(x: sx ?? point.x, y: sy ?? point.y), sx != nil, sy != nil)
    }
}
