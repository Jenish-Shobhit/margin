import AppKit
import MarginKit

/// One ⌘⇧4 session: the frozen overlays on every display and the selection state they share.
///
/// Area mode: drag to select and release to capture. Pressing an arrow key during the drag pins the
/// selection instead ("adjusting"): release keeps it, then handles, dragging inside, arrow nudges and
/// ↩ fine-tune and capture. Space toggles window mode, except while dragging, where holding it moves
/// the selection.
@MainActor
final class OverlaySession {
    typealias Mode = OverlayFrame.Mode

    enum Phase {
        case idle
        /// Drawing a new selection. Releasing captures.
        case dragging
        /// An arrow key was pressed mid-drag. Releasing keeps the selection.
        case pinned
        /// A kept selection. ↩ captures.
        case adjusting
        case moving(from: CGPoint, start: CGRect)
        case resizing(Handle, start: CGRect)
    }

    /// Selections smaller than this (pixels, either side) are ignored.
    static let minimumPixels: CGFloat = 4

    let panels: [OverlayPanel]
    private let cache: ShareableContentCache
    private let showsHUD: Bool

    /// The chosen area: rect (AppKit global points, pixel-aligned), its display, the frozen image,
    /// the pixel rect in that image and the scale.
    var onArea: ((CGRect, DisplayInfo, CGImage, CGRect, CGFloat) -> Void)?
    /// The clicked window and whether ⌥ (keep shadow) was held.
    var onWindow: ((CapturableWindow, Bool) -> Void)?
    var onCancel: (() -> Void)?

    private(set) var mode: Mode = .area
    private(set) var phase: Phase = .idle
    private(set) var selection: CGRect?
    private(set) var selectionDisplay: DisplayInfo?
    private var images: [CGDirectDisplayID: CGImage] = [:]
    private var guideX: CGFloat?
    private var guideY: CGFloat?
    private var anchorGuideX: CGFloat?
    private var anchorGuideY: CGFloat?
    private var hovered: CapturableWindow?
    private var mouse: CGPoint
    private var anchor = CGPoint.zero
    private var lastDrag = CGPoint.zero
    private var spaceHeld = false
    private var modifiers: NSEvent.ModifierFlags = []
    private var snapFrames: [CGRect] = []
    private(set) var isFinished = false

    /// `mode`: `.area` for ⌘⇧4, `.window` for the menu's Capture Window. Space switches either way.
    init(panels: [OverlayPanel], cache: ShareableContentCache, mode: Mode = .area, showsHUD: Bool) {
        self.panels = panels
        self.cache = cache
        self.mode = mode
        self.showsHUD = showsHUD
        mouse = NSEvent.mouseLocation
    }

    var displays: [DisplayInfo] { panels.map(\.display) }
    var frozenCount: Int { images.count }

    // MARK: Lifecycle

    /// Puts the (still transparent) overlays up.
    func show() {
        for p in panels {
            p.overlayView.reset()
            p.overlayView.session = self
            p.orderFrontRegardless()
        }
        mouse = NSEvent.mouseLocation
        if mode == .window { hovered = cache.window(at: mouse) }
        render()
        updateCursor()
    }

    /// Window frames were refreshed after the freeze: re-pick the window under the pointer.
    func windowsDidRefresh() {
        guard !isFinished, mode == .window else { return }
        hovered = cache.window(at: mouse)
        render()
    }

    /// Shows a display's frozen frame. `committed` runs once the frame is handed to the render server,
    /// before the chrome (loupe, pills) catches up.
    func setFrozen(_ image: CGImage, for id: CGDirectDisplayID, committed: () -> Void = {}) {
        images[id] = image
        panels.first { $0.display.id == id }?.overlayView.setFrozen(image)
        committed()
        render()
    }

    /// Makes the panel under the pointer key so it gets keyboard input.
    func makeKey() {
        guard let panel = panels.first(where: { NSMouseInRect(mouse, $0.display.frame, false) }) ?? panels.first else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.overlayView)
        updateCursor()
    }

    func close() {
        isFinished = true
        for p in panels {
            p.orderOut(nil)
            p.overlayView.session = nil
            p.overlayView.reset()
        }
        images.removeAll()
        NSCursor.arrow.set()
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        onCancel?()
    }

    // MARK: Mouse

    func mouseDown(at p: CGPoint, on d: DisplayInfo, event: NSEvent) {
        guard !isFinished else { return }
        mouse = p
        modifiers = event.modifierFlags
        if mode == .window {
            if let w = cache.window(at: p) {
                isFinished = true
                onWindow?(w, event.modifierFlags.contains(.option))
            }
            return
        }
        if case .adjusting = phase, let sel = selection, selectionDisplay?.id == d.id {
            if let h = SelectionMath.handle(at: p, in: sel) {
                phase = .resizing(h, start: sel)
                prepareSnapping(on: d)
                updateCursor()
                render()
                return
            }
            if sel.contains(p) {
                phase = .moving(from: p, start: sel)
                prepareSnapping(on: d)
                updateCursor()
                render()
                return
            }
        }
        // Start a new selection on this display.
        selectionDisplay = d
        prepareSnapping(on: d)
        var a = SelectionMath.align(SelectionMath.clamp(p, to: d.frame), in: d.frame, scale: scale(d))
        let s = Geometry.snap(a, to: snapFrames)
        a = s.point
        anchorGuideX = s.snappedX ? a.x : nil
        anchorGuideY = s.snappedY ? a.y : nil
        guideX = anchorGuideX
        guideY = anchorGuideY
        anchor = a
        lastDrag = SelectionMath.clamp(p, to: d.frame)
        spaceHeld = false
        selection = CGRect(origin: a, size: .zero)
        phase = .dragging
        render()
    }

    func mouseDragged(at p: CGPoint, event: NSEvent) {
        guard !isFinished, mode == .area, let d = selectionDisplay else { return }
        mouse = p
        modifiers = event.modifierFlags
        switch phase {
        case .dragging:
            drag(to: p, on: d)
        case let .moving(from, start):
            let moved = SelectionMath.move(start, by: CGVector(dx: p.x - from.x, dy: p.y - from.y), within: d.frame)
            let snapped = SelectionMath.snapEdges(of: moved, to: snapFrames)
            selection = align(SelectionMath.move(snapped.rect, by: .zero, within: d.frame), on: d)
            guideX = snapped.guideX
            guideY = snapped.guideY
        case let .resizing(handle, start):
            var q = SelectionMath.align(SelectionMath.clamp(p, to: d.frame), in: d.frame, scale: scale(d))
            let s = Geometry.snap(q, to: snapFrames)
            guideX = nil
            guideY = nil
            if handle.movesX, s.snappedX { q.x = s.point.x; guideX = q.x }
            if handle.movesY, s.snappedY { q.y = s.point.y; guideY = q.y }
            selection = SelectionMath.resize(start, handle: handle, to: q, bounds: d.frame)
        case .idle, .pinned, .adjusting:
            return
        }
        updateCursor()
        render()
    }

    func mouseUp(at p: CGPoint, event: NSEvent) {
        guard !isFinished, mode == .area else { return }
        mouse = p
        switch phase {
        case .dragging:
            if validSelection != nil {
                commitArea()
                return
            }
            // Too small: ignored, still selecting.
            clearSelection()
        case .pinned, .moving, .resizing:
            phase = .adjusting
            guideX = nil
            guideY = nil
        case .idle, .adjusting:
            break
        }
        updateCursor()
        render()
    }

    func mouseMoved(to p: CGPoint) {
        guard !isFinished else { return }
        mouse = p
        if mode == .window { hovered = cache.window(at: p) }
        updateCursor()
        render()
    }

    // MARK: Keys

    private enum Key {
        static let escape: UInt16 = 53, returnKey: UInt16 = 36, enter: UInt16 = 76, space: UInt16 = 49
        static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    }

    func keyDown(_ e: NSEvent) {
        guard !isFinished else { return }
        modifiers = e.modifierFlags
        switch e.keyCode {
        case Key.escape:
            cancel()
        case Key.returnKey, Key.enter:
            switch phase {
            case .dragging, .pinned, .adjusting: if mode == .area { commitArea() }
            default: break
            }
        case Key.space:
            guard !e.isARepeat else { return }
            switch phase {
            case .dragging:
                spaceHeld = true
                lastDrag = selectionDisplay.map { SelectionMath.clamp(mouse, to: $0.frame) } ?? mouse
            case .moving, .resizing, .pinned:
                break
            case .idle, .adjusting:
                toggleMode()
            }
        case Key.left, Key.right, Key.down, Key.up:
            nudge(e.keyCode, big: e.modifierFlags.contains(.shift))
        default:
            break
        }
    }

    func keyUp(_ e: NSEvent) {
        guard !isFinished else { return }
        if e.keyCode == Key.space, spaceHeld {
            spaceHeld = false
            lastDrag = selectionDisplay.map { SelectionMath.clamp(mouse, to: $0.frame) } ?? mouse
        }
    }

    func flagsChanged(_ e: NSEvent) {
        guard !isFinished else { return }
        modifiers = e.modifierFlags
        // ⇧ / ⌥ apply immediately, without waiting for the next mouse move.
        if case .dragging = phase, !spaceHeld, let d = selectionDisplay {
            selection = dragRect(to: lastDrag, on: d)
            render()
        }
    }

    // MARK: Selection

    private func drag(to p: CGPoint, on d: DisplayInfo) {
        let p = SelectionMath.clamp(p, to: d.frame)
        if spaceHeld, let sel = selection {
            let moved = align(SelectionMath.move(sel, by: CGVector(dx: p.x - lastDrag.x, dy: p.y - lastDrag.y), within: d.frame), on: d)
            anchor.x += moved.minX - sel.minX
            anchor.y += moved.minY - sel.minY
            selection = moved
            guideX = nil
            guideY = nil
            anchorGuideX = nil
            anchorGuideY = nil
        } else {
            selection = dragRect(to: p, on: d)
        }
        lastDrag = p
    }

    /// The selection from the anchor to `p`, with ⇧ / ⌥ and edge snapping applied.
    private func dragRect(to p: CGPoint, on d: DisplayInfo) -> CGRect {
        var corner = SelectionMath.align(p, in: d.frame, scale: scale(d))
        let square = modifiers.contains(.shift)
        let fromCenter = modifiers.contains(.option)
        var gx: CGFloat?
        var gy: CGFloat?
        if !square {
            let s = Geometry.snap(corner, to: snapFrames)
            corner = s.point
            if s.snappedX { gx = corner.x }
            if s.snappedY { gy = corner.y }
        }
        guideX = gx ?? (fromCenter ? nil : anchorGuideX)
        guideY = gy ?? (fromCenter ? nil : anchorGuideY)
        return SelectionMath.dragRect(anchor: anchor, corner: corner, square: square, fromCenter: fromCenter, bounds: d.frame)
    }

    private func nudge(_ key: UInt16, big: Bool) {
        guard mode == .area, let sel = selection, let d = selectionDisplay, !sel.isEmpty else { return }
        switch phase {
        case .dragging:
            phase = .pinned
            spaceHeld = false
        case .pinned, .adjusting:
            break
        case .idle, .moving, .resizing:
            return
        }
        let step = (big ? 10 : 1) / scale(d)
        let v: CGVector
        switch key {
        case Key.left: v = CGVector(dx: -step, dy: 0)
        case Key.right: v = CGVector(dx: step, dy: 0)
        case Key.down: v = CGVector(dx: 0, dy: -step)
        default: v = CGVector(dx: 0, dy: step)
        }
        selection = SelectionMath.move(sel, by: v, within: d.frame)
        guideX = nil
        guideY = nil
        updateCursor()
        render()
    }

    private func clearSelection() {
        selection = nil
        selectionDisplay = nil
        guideX = nil
        guideY = nil
        anchorGuideX = nil
        anchorGuideY = nil
        spaceHeld = false
        phase = .idle
    }

    private func toggleMode() {
        mode = mode == .area ? .window : .area
        hovered = mode == .window ? cache.window(at: mouse) : nil
        updateCursor()
        render()
    }

    private func prepareSnapping(on d: DisplayInfo) {
        snapFrames = cache.windows.map(\.frame).filter { $0.intersects(d.frame) }
    }

    private func commitArea() {
        guard let (rect, d) = validSelection, let image = images[d.id] else { return }
        isFinished = true
        onArea?(rect, d, image, pixelRect(rect, on: d), scale(d))
    }

    /// The selection if it's at least 4 × 4 pixels.
    private var validSelection: (CGRect, DisplayInfo)? {
        guard let sel = selection, let d = selectionDisplay else { return nil }
        let px = pixelRect(sel, on: d)
        return px.width >= Self.minimumPixels && px.height >= Self.minimumPixels ? (sel, d) : nil
    }

    // MARK: Geometry

    /// Pixels per point, from the frozen image when there is one.
    private func scale(_ d: DisplayInfo) -> CGFloat {
        if let image = images[d.id], d.frame.width > 0 { return CGFloat(image.width) / d.frame.width }
        return d.scale
    }

    private func pixelRect(_ r: CGRect, on d: DisplayInfo) -> CGRect {
        let s = scale(d)
        let size = images[d.id].map { CGSize(width: $0.width, height: $0.height) }
            ?? CGSize(width: (d.frame.width * s).rounded(), height: (d.frame.height * s).rounded())
        return Geometry.pixelRect(for: r, displayFrame: d.frame, scale: s, imageSize: size)
    }

    private func align(_ r: CGRect, on d: DisplayInfo) -> CGRect {
        let s = scale(d)
        let o = SelectionMath.align(r.origin, in: d.frame, scale: s)
        return CGRect(origin: o, size: r.size)
    }

    private func display(containing p: CGPoint) -> DisplayInfo? {
        displays.first { NSMouseInRect(p, $0.frame, false) }
    }

    // MARK: Rendering

    private func render() {
        var f = OverlayFrame()
        f.mode = mode
        f.selection = selection
        f.selectionDisplayID = selectionDisplay?.id
        if let sel = selection, let d = selectionDisplay {
            let px = pixelRect(sel, on: d)
            f.sizeText = "\(Int(px.width)) × \(Int(px.height))"
        }
        f.guideX = guideX
        f.guideY = guideY
        if mode == .window, let w = hovered {
            f.window = w.frame
            let s = Displays.display(bestFor: w.frame)?.scale ?? 2
            f.windowText = "\(w.appName) · \(Int((w.frame.width * s).rounded())) × \(Int((w.frame.height * s).rounded()))"
        }
        f.mouse = mouse
        f.mouseDisplayID = display(containing: mouse)?.id
        if case .moving = phase {
            f.showsLoupe = false
        } else {
            f.showsLoupe = mode == .area
        }
        f.showsHUD = showsHUD
        for p in panels { p.overlayView.render(f) }
    }

    // MARK: Cursor

    func updateCursor() {
        cursor().set()
    }

    private func cursor() -> NSCursor {
        if mode == .window { return .pointingHand }
        switch phase {
        case .moving:
            return .closedHand
        case let .resizing(h, _):
            return Self.resizeCursor(h)
        case .adjusting:
            if let sel = selection, let d = selectionDisplay, NSMouseInRect(mouse, d.frame, false) {
                if let h = SelectionMath.handle(at: mouse, in: sel) { return Self.resizeCursor(h) }
                if sel.contains(mouse) { return .openHand }
            }
            return .crosshair
        case .idle, .dragging, .pinned:
            return .crosshair
        }
    }

    private static func resizeCursor(_ h: Handle) -> NSCursor {
        let position: NSCursor.FrameResizePosition
        switch h {
        case .topLeft: position = .topLeft
        case .top: position = .top
        case .topRight: position = .topRight
        case .right: position = .right
        case .bottomRight: position = .bottomRight
        case .bottom: position = .bottom
        case .bottomLeft: position = .bottomLeft
        case .left: position = .left
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }
}
