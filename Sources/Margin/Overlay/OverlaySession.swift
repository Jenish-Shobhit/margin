import AppKit
import MarginKit

/// One ⌘⇧4 session: the frozen overlays on every display and the selection state they share.
///
/// Area mode: drag to select and release to capture. Pressing an arrow key during the drag pins the
/// selection instead ("adjusting"): release keeps it, then handles, dragging inside, arrow nudges and
/// ↩ fine-tune and capture. Space toggles window mode, except while dragging, where holding it moves
/// the selection.
///
/// ⇧⌘5 opens the same session to choose what to record (`Purpose.record`): an area or a window as for a screenshot,
/// and a click without a drag (or ↩ with nothing selected) for the whole display.
@MainActor
final class OverlaySession {
    typealias Mode = OverlayFrame.Mode

    /// What the choice is for: a screenshot (⇧⌘4, Capture Window) or a screen recording (⇧⌘5).
    enum Purpose { case capture, record }

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
    let purpose: Purpose
    private let cache: ShareableContentCache
    private let showsHUD: Bool

    /// The chosen area: rect (AppKit global points, pixel-aligned), its display, the frozen image,
    /// the pixel rect in that image and the scale.
    var onArea: ((CGRect, DisplayInfo, CGImage, CGRect, CGFloat) -> Void)?
    /// The clicked window and whether ⌥ (keep shadow) was held.
    var onWindow: ((CapturableWindow, Bool) -> Void)?
    /// Choosing what to record: the whole display (a click without a drag, or ↩ with nothing selected).
    var onScreen: ((DisplayInfo) -> Void)?
    var onCancel: (() -> Void)?

    private(set) var mode: Mode = .area
    private(set) var phase: Phase = .idle
    private(set) var selection: CGRect?
    private(set) var selectionDisplay: DisplayInfo?
    private var images: [CGDirectDisplayID: CGImage] = [:]
    /// Displays that can't be captured (ScreenCaptureKit failed or never answered): dimmed over the live
    /// screen, and nothing can be selected there.
    private var unavailable: Set<CGDirectDisplayID> = []
    private var guideX: CGFloat?
    private var guideY: CGFloat?
    private var anchorGuideX: CGFloat?
    private var anchorGuideY: CGFloat?
    private var hovered: CapturableWindow?
    private var mouse: CGPoint
    private var anchor = CGPoint.zero
    /// Where the selection being drawn started, before snapping: snapped again should the window list land
    /// mid-drag. Nil once Space has moved the selection.
    private var unsnappedAnchor: CGPoint?
    private var lastDrag = CGPoint.zero
    private var spaceHeld = false
    /// When the held arrow key began repeating (`NSEvent.timestamp`), for nudge acceleration.
    private var nudgeRepeatStart: TimeInterval?
    /// The loupe: off until Z turns it on, for this capture only.
    private var showsMagnifier = false
    private var modifiers: NSEvent.ModifierFlags = []
    private var snapFrames: [CGRect] = []
    /// The window list is the one from before this session until the refresh it started lands (`windowsDidRefresh`).
    private var windowsFresh = false
    /// A window-mode click that came before that: it picks once the list is fresh, not from the old one (a window
    /// moved, closed or brought forward since).
    private var pendingWindowClick: (point: CGPoint, keepShadow: Bool)?
    private(set) var isFinished = false

    /// `mode`: `.area` for ⌘⇧4, `.window` for the menu's Capture Window. Space switches either way.
    init(panels: [OverlayPanel], cache: ShareableContentCache, mode: Mode = .area, purpose: Purpose = .capture,
         showsHUD: Bool) {
        self.panels = panels
        self.cache = cache
        self.mode = mode
        self.purpose = purpose
        self.showsHUD = showsHUD
        mouse = NSEvent.mouseLocation
    }

    var displays: [DisplayInfo] { panels.map(\.display) }
    var frozenCount: Int { images.count }

    /// A display's frozen frame, if it has one yet.
    func frozenImage(on id: CGDirectDisplayID) -> CGImage? { images[id] }

    // MARK: Lifecycle

    /// Puts the (still transparent) overlays up.
    func show() {
        for p in panels {
            p.overlayView.reset()
            p.overlayView.session = self
            p.orderFrontRegardless()
        }
        mouse = NSEvent.mouseLocation
        if mode == .window { hovered = window(at: mouse) }
        render()
        updateCursor()
    }

    /// This session's window list landed (fetched alongside the freeze): snapping and window mode use it from now on.
    func windowsDidRefresh() {
        guard !isFinished else { return }
        windowsFresh = true
        if mode == .window, let click = pendingWindowClick {
            pendingWindowClick = nil
            if let w = window(at: click.point) {
                isFinished = true
                onWindow?(w, click.keepShadow)
                return
            }
        }
        // A selection under way snaps to the new frames: its start now, the rest from the next move on.
        if let d = selectionDisplay {
            prepareSnapping(on: d)
            if case .dragging = phase, let start = unsnappedAnchor {
                setAnchor(start, on: d)
                if !spaceHeld { selection = dragRect(to: lastDrag, on: d) }
            }
        }
        if mode == .window { hovered = window(at: mouse) }
        render()
    }

    /// Shows a display's frozen frame. `committed` runs once the frame is handed to the render server,
    /// before the chrome (loupe, pills) catches up.
    func setFrozen(_ image: CGImage, for id: CGDirectDisplayID, committed: () -> Void = {}) {
        images[id] = image
        let view = panels.first { $0.display.id == id }?.overlayView
        // A frame that arrives after the display was given up on still counts.
        if unavailable.remove(id) != nil { view?.setUnavailable(false) }
        view?.setFrozen(image)
        committed()
        if mode == .window { hovered = window(at: mouse) }
        render()
        updateCursor()
    }

    /// A display that can't be captured: dim it over the live screen and refuse selections there.
    func setUnavailable(_ id: CGDirectDisplayID) {
        guard !isFinished, images[id] == nil, unavailable.insert(id).inserted else { return }
        panels.first { $0.display.id == id }?.overlayView.setUnavailable(true)
        render()
        updateCursor()
    }

    /// Gives up on the displays still waiting for a frame; returns how many there were.
    @discardableResult
    func abandonPendingDisplays() -> Int {
        let pending = displays.filter { images[$0.id] == nil && !unavailable.contains($0.id) }
        for d in pending { setUnavailable(d.id) }
        return pending.count
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
        unavailable.removeAll()
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
            // Nothing to pick on a display without a frozen frame; a click before the window list lands waits for it.
            guard images[d.id] != nil else { return }
            guard windowsFresh else {
                pendingWindowClick = (p, event.modifierFlags.contains(.option))
                return
            }
            if let w = window(at: p) {
                isFinished = true
                onWindow?(w, event.modifierFlags.contains(.option))
            }
            return
        }
        // Nothing to select on a display without a frozen frame (still arriving, or it can't be captured).
        guard images[d.id] != nil else { return }
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
        let start = SelectionMath.align(SelectionMath.clamp(p, to: d.frame), in: d.frame, scale: scale(d))
        unsnappedAnchor = start
        setAnchor(start, on: d)
        guideX = anchorGuideX
        guideY = anchorGuideY
        lastDrag = SelectionMath.clamp(p, to: d.frame)
        spaceHeld = false
        selection = CGRect(origin: anchor, size: .zero)
        phase = .dragging
        render()
    }

    /// Where a new selection starts: `start` snapped to window edges, kept on the display (a window hanging past
    /// its edge mustn't pull the start off it).
    private func setAnchor(_ start: CGPoint, on d: DisplayInfo) {
        let s = Geometry.snap(start, to: snapFrames, within: d.frame)
        anchor = s.point
        anchorGuideX = s.snappedX ? anchor.x : nil
        anchorGuideY = s.snappedY ? anchor.y : nil
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
            let sel = align(SelectionMath.move(snapped.rect, by: .zero, within: d.frame), on: d)
            selection = sel
            // A window edge past the display's edge can't hold the selection: no guide for it. (Within half a
            // point, since `align` may round the edge onto the pixel grid.)
            func held(_ line: CGFloat?, _ a: CGFloat, _ b: CGFloat) -> CGFloat? {
                line.flatMap { abs($0 - a) <= 0.5 || abs($0 - b) <= 0.5 ? $0 : nil }
            }
            guideX = held(snapped.guideX, sel.minX, sel.maxX)
            guideY = held(snapped.guideY, sel.minY, sel.maxY)
        case let .resizing(handle, start):
            var q = SelectionMath.align(SelectionMath.clamp(p, to: d.frame), in: d.frame, scale: scale(d))
            let s = Geometry.snap(q, to: snapFrames, within: d.frame)
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
            // Choosing what to record, a click is the whole display it's on.
            if purpose == .record, let d = selectionDisplay {
                isFinished = true
                onScreen?(d)
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
        if mode == .window { hovered = window(at: p) }
        updateCursor()
        render()
    }

    // MARK: Keys

    private enum Key {
        static let escape: UInt16 = 53, returnKey: UInt16 = 36, enter: UInt16 = 76, space: UInt16 = 49
        static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
        /// Where Z is on a US keyboard.
        static let z: UInt16 = 6

        /// Z, by the character it types, so it follows the layout (QWERTZ and AZERTY put Z elsewhere), or by
        /// position where the layout has no Latin letters. With or without ⇧ / ⌥ / ⌃, so it works mid-drag;
        /// ⌘ never gets here (the overlay swallows ⌘ shortcuts).
        static func isZ(_ e: NSEvent) -> Bool {
            let c = e.charactersIgnoringModifiers?.lowercased() ?? ""
            if c == "z" { return true }
            return e.keyCode == z && !c.unicodeScalars.contains { $0.isASCII }
        }
    }

    func keyDown(_ e: NSEvent) {
        guard !isFinished else { return }
        modifiers = e.modifierFlags
        if Key.isZ(e) {
            // The magnifier, toggled for the rest of this capture. Holding Z doesn't flicker it.
            if !e.isARepeat, mode == .area {
                showsMagnifier.toggle()
                render()
            }
            return
        }
        switch e.keyCode {
        case Key.escape:
            cancel()
        case Key.returnKey, Key.enter:
            switch phase {
            case .dragging, .pinned, .adjusting: if mode == .area { commitArea() }
            case .idle where purpose == .record && mode == .area: commitScreen()
            default: break
            }
        case Key.space:
            guard !e.isARepeat else { return }
            switch phase {
            case .dragging:
                spaceHeld = true
                lastDrag = selectionDisplay.map { SelectionMath.clamp(mouse, to: $0.frame) } ?? mouse
                render()
            case .moving, .resizing, .pinned:
                break
            case .idle, .adjusting:
                toggleMode()
            }
        case Key.left, Key.right, Key.down, Key.up:
            // Every repeat moves (the key repeat rate sets the pace), a little further the longer it's held.
            let shift = e.modifierFlags.contains(.shift)
            if e.isARepeat, !shift {
                nudgeRepeatStart = nudgeRepeatStart ?? e.timestamp
            } else {
                nudgeRepeatStart = nil
            }
            nudge(e.keyCode, pixels: SelectionMath.nudgePixels(repeating: nudgeRepeatStart.map { e.timestamp - $0 }, shift: shift))
        default:
            break
        }
    }

    func keyUp(_ e: NSEvent) {
        guard !isFinished else { return }
        if e.keyCode == Key.space, spaceHeld {
            spaceHeld = false
            lastDrag = selectionDisplay.map { SelectionMath.clamp(mouse, to: $0.frame) } ?? mouse
            // Back to drawing: ⇧ / ⌥, pressed or released while moving, apply now, not at the next mouse move.
            if case .dragging = phase, let d = selectionDisplay {
                selection = dragRect(to: lastDrag, on: d)
            }
            render()
        }
    }

    func flagsChanged(_ e: NSEvent) {
        guard !isFinished else { return }
        let before = held
        modifiers = e.modifierFlags
        // ⇧ / ⌥ apply immediately, without waiting for the next mouse move.
        if case .dragging = phase, !spaceHeld, let d = selectionDisplay {
            selection = dragRect(to: lastDrag, on: d)
            render()
        } else if held != before {
            render()  // ⌥ in window mode: "Keep shadow"
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
            unsnappedAnchor = nil
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
            let s = Geometry.snap(corner, to: snapFrames, within: d.frame)
            corner = s.point
            if s.snappedX { gx = corner.x }
            if s.snappedY { gy = corner.y }
        }
        guideX = gx ?? (fromCenter ? nil : anchorGuideX)
        guideY = gy ?? (fromCenter ? nil : anchorGuideY)
        return SelectionMath.dragRect(anchor: anchor, corner: corner, square: square, fromCenter: fromCenter, bounds: d.frame)
    }

    private func nudge(_ key: UInt16, pixels: CGFloat) {
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
        let step = pixels / scale(d)
        let v: CGVector
        switch key {
        case Key.left: v = CGVector(dx: -step, dy: 0)
        case Key.right: v = CGVector(dx: step, dy: 0)
        case Key.down: v = CGVector(dx: 0, dy: -step)
        default: v = CGVector(dx: 0, dy: step)
        }
        // Re-aligned so repeated steps never drift off the pixel grid (1/scale isn't exact at every scale).
        selection = align(SelectionMath.move(sel, by: v, within: d.frame), on: d)
        guideX = nil
        guideY = nil
        updateCursor()
        render()
    }

    private func clearSelection() {
        selection = nil
        selectionDisplay = nil
        unsnappedAnchor = nil
        guideX = nil
        guideY = nil
        anchorGuideX = nil
        anchorGuideY = nil
        spaceHeld = false
        phase = .idle
    }

    private func toggleMode() {
        mode = mode == .area ? .window : .area
        pendingWindowClick = nil
        hovered = mode == .window ? window(at: mouse) : nil
        updateCursor()
        render()
    }

    private func prepareSnapping(on d: DisplayInfo) {
        snapFrames = cache.snapFrames.filter { $0.intersects(d.frame) }
    }

    private func commitArea() {
        guard let (rect, d) = validSelection, let image = images[d.id] else { return }
        isFinished = true
        onArea?(rect, d, image, pixelRect(rect, on: d), scale(d))
    }

    /// Choosing what to record: the display under the pointer, if it's frozen (one that can't be captured can't be recorded).
    private func commitScreen() {
        guard let d = display(containing: mouse), images[d.id] != nil else { return }
        isFinished = true
        onScreen?(d)
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

    /// The window under `p`, only where the display is frozen: nothing can be picked on one that isn't.
    private func window(at p: CGPoint) -> CapturableWindow? {
        guard let d = display(containing: p), images[d.id] != nil else { return nil }
        return cache.window(at: p)
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
        f.magnifier = showsMagnifier
        if case .moving = phase {
            f.showsLoupe = false
        } else {
            f.showsLoupe = showsMagnifier && mode == .area
        }
        f.showsHUD = showsHUD
        f.recording = purpose == .record
        f.held = held
        if case .dragging = phase { f.drawing = true }
        for p in panels { p.overlayView.render(f) }
    }

    /// The keys held right now that change what happens: ⇧ / ⌥ shape a selection being drawn (Space moves it
    /// instead), and ⌥ keeps the shadow in window mode.
    private var held: HUDView.Held {
        if mode == .window { return purpose == .capture && modifiers.contains(.option) ? .keepShadow : [] }
        guard case .dragging = phase else { return [] }
        if spaceHeld { return .move }
        var h: HUDView.Held = []
        if modifiers.contains(.shift) { h.insert(.square) }
        if modifiers.contains(.option) { h.insert(.fromCenter) }
        return h
    }

    // MARK: Cursor

    func updateCursor() {
        cursor().set()
    }

    private func cursor() -> NSCursor {
        switch phase {
        case .idle, .adjusting:
            if let d = display(containing: mouse), unavailable.contains(d.id) { return .operationNotAllowed }
        case .dragging, .pinned, .moving, .resizing:
            break
        }
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
