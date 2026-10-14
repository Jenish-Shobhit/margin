import CoreGraphics
import MarginKit

/// The eight resize handles. AppKit coordinates: "top" is maxY.
enum Handle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    func point(in r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: r.minX, y: r.maxY)
        case .top: CGPoint(x: r.midX, y: r.maxY)
        case .topRight: CGPoint(x: r.maxX, y: r.maxY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.minY)
        case .bottom: CGPoint(x: r.midX, y: r.minY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.minY)
        case .left: CGPoint(x: r.minX, y: r.midY)
        }
    }

    var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }
    var movesX: Bool { self != .top && self != .bottom }
    var movesY: Bool { self != .left && self != .right }
}

/// Pure selection geometry. All rects and points are AppKit global points.
enum SelectionMath {
    /// Rounds a coordinate to the display's pixel grid.
    static func align(_ v: CGFloat, origin: CGFloat, scale: CGFloat) -> CGFloat {
        origin + ((v - origin) * scale).rounded() / scale
    }

    static func align(_ p: CGPoint, in display: CGRect, scale: CGFloat) -> CGPoint {
        CGPoint(x: align(p.x, origin: display.minX, scale: scale), y: align(p.y, origin: display.minY, scale: scale))
    }

    static func clamp(_ p: CGPoint, to b: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, b.minX), b.maxX), y: min(max(p.y, b.minY), b.maxY))
    }

    /// The rect for a drag from `anchor` to `corner`, kept inside `bounds`.
    /// ⇧ (`square`) makes it square; ⌥ (`fromCenter`) grows it around the anchor.
    static func dragRect(anchor a: CGPoint, corner c: CGPoint, square: Bool, fromCenter: Bool, bounds b: CGRect) -> CGRect {
        var dx = c.x - a.x
        var dy = c.y - a.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        if fromCenter {
            var hx = min(abs(dx), a.x - b.minX, b.maxX - a.x)
            var hy = min(abs(dy), a.y - b.minY, b.maxY - a.y)
            if square { hx = min(hx, hy); hy = hx }
            hx = max(hx, 0); hy = max(hy, 0)
            return CGRect(x: a.x - hx, y: a.y - hy, width: 2 * hx, height: 2 * hy)
        }
        var ex = min(abs(dx), dx >= 0 ? b.maxX - a.x : a.x - b.minX)
        var ey = min(abs(dy), dy >= 0 ? b.maxY - a.y : a.y - b.minY)
        if square { ex = min(ex, ey); ey = ex }
        ex = max(ex, 0); ey = max(ey, 0)
        return CGRect(x: dx >= 0 ? a.x : a.x - ex, y: dy >= 0 ? a.y : a.y - ey, width: ex, height: ey)
    }

    /// Resizes `start` by moving the given handle to `p`. Dragging past the opposite edge flips.
    static func resize(_ start: CGRect, handle: Handle, to p: CGPoint, bounds: CGRect) -> CGRect {
        let p = clamp(p, to: bounds)
        var x0 = start.minX, x1 = start.maxX, y0 = start.minY, y1 = start.maxY
        switch handle {
        case .topLeft: x0 = p.x; y1 = p.y
        case .top: y1 = p.y
        case .topRight: x1 = p.x; y1 = p.y
        case .right: x1 = p.x
        case .bottomRight: x1 = p.x; y0 = p.y
        case .bottom: y0 = p.y
        case .bottomLeft: x0 = p.x; y0 = p.y
        case .left: x0 = p.x
        }
        return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
    }

    /// Pixels per arrow-key nudge. A tap is 1 px and ⇧ is always 10 px. A held arrow speeds up the longer it
    /// repeats: 2 px after 0.4 s of repeating, 4 px after 0.8 s. `repeating`: seconds since the held key's first
    /// repeat, or nil for a fresh press.
    static func nudgePixels(repeating: Double?, shift: Bool) -> CGFloat {
        if shift { return 10 }
        guard let t = repeating else { return 1 }
        return t < 0.4 ? 1 : t < 0.8 ? 2 : 4
    }

    /// Moves `r` by `d`, staying inside `bounds`.
    static func move(_ r: CGRect, by d: CGVector, within b: CGRect) -> CGRect {
        let x = min(max(r.minX + d.dx, b.minX), b.maxX - r.width)
        let y = min(max(r.minY + d.dy, b.minY), b.maxY - r.height)
        return CGRect(x: x, y: y, width: r.width, height: r.height)
    }

    /// Snaps whichever edge of a moved rect is nearest a window edge (per axis) without resizing it.
    /// Like `Geometry.snap`, a window's vertical edges count only when it's level with the rect (their
    /// y spans overlap, ± threshold), and its horizontal edges only when their x spans overlap.
    /// Returns the snapped rect and the guide lines it snapped to.
    static func snapEdges(of r: CGRect, to frames: [CGRect], threshold: CGFloat = 8) -> (rect: CGRect, guideX: CGFloat?, guideY: CGFloat?) {
        let xs = frames
            .filter { $0.minY - threshold <= r.maxY && $0.maxY + threshold >= r.minY }
            .flatMap { [$0.minX, $0.maxX] }
        let ys = frames
            .filter { $0.minX - threshold <= r.maxX && $0.maxX + threshold >= r.minX }
            .flatMap { [$0.minY, $0.maxY] }
        func best(_ a: CGFloat, _ b: CGFloat, in candidates: [CGFloat]) -> (shift: CGFloat, line: CGFloat)? {
            let sa = Geometry.snapValue(a, to: candidates, threshold: threshold).map { (shift: $0 - a, line: $0) }
            let sb = Geometry.snapValue(b, to: candidates, threshold: threshold).map { (shift: $0 - b, line: $0) }
            switch (sa, sb) {
            case let (x?, y?): return abs(x.shift) <= abs(y.shift) ? x : y
            case let (x?, nil): return x
            case let (nil, y?): return y
            default: return nil
            }
        }
        let sx = best(r.minX, r.maxX, in: xs)
        let sy = best(r.minY, r.maxY, in: ys)
        return (r.offsetBy(dx: sx?.shift ?? 0, dy: sy?.shift ?? 0), sx?.line, sy?.line)
    }

    /// The handle under `p`, if any. Corners win over edges.
    static func handle(at p: CGPoint, in r: CGRect, radius: CGFloat = 8) -> Handle? {
        let order: [Handle] = [.topLeft, .topRight, .bottomRight, .bottomLeft, .top, .right, .bottom, .left]
        for h in order {
            if !h.isCorner && (r.width < 40 || r.height < 40) { continue }
            let c = h.point(in: r)
            if abs(p.x - c.x) <= radius && abs(p.y - c.y) <= radius { return h }
        }
        return nil
    }
}
