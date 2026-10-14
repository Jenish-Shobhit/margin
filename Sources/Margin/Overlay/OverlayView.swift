import AppKit
import QuartzCore

/// Hosts the plain CALayers (frozen image, dim, border, handles, guides, window highlight).
private final class CanvasView: NSView {
    let root = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = root
        wantsLayer = true
        root.masksToBounds = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// What a display's overlay draws. Everything global is in AppKit global points.
struct OverlayFrame {
    enum Mode { case area, window }

    var mode: Mode = .area
    var selection: CGRect?
    var selectionDisplayID: CGDirectDisplayID?
    var sizeText: String?
    var guideX: CGFloat?
    var guideY: CGFloat?
    var window: CGRect?
    var windowText: String?
    var mouse: CGPoint = .zero
    var mouseDisplayID: CGDirectDisplayID?
    var showsLoupe = false
    var showsHUD = false
}

/// The overlay for one display: the frozen screen plus the selection UI. Forwards input to the session.
final class OverlayView: NSView {
    var display: DisplayInfo {
        didSet { layoutCanvas() }
    }
    weak var session: OverlaySession?
    private(set) var image: CGImage?
    /// This display can't be captured: the live screen shows through, dimmed, with a note.
    private(set) var isUnavailable = false

    private let canvas: CanvasView
    private let imageLayer = CALayer()
    private let unavailableLayer = CALayer()
    private let unavailablePill = PillView(style: .note)
    private let dimLayers = (0..<4).map { _ in CALayer() }
    private let borderLayer = CALayer()
    private let handleLayers = Handle.allCases.map { _ in CALayer() }
    private let guideXLayer = CALayer()
    private let guideYLayer = CALayer()
    private let windowLayer = CALayer()
    private let sizePill = PillView(style: .dark)
    private let snapPill = PillView(style: .accent)
    private let windowPill = PillView(style: .dark)
    private let loupe = LoupeView(frame: .zero)
    private let loupeLabel = PillView(style: .dark)
    private let hud = HUDView(frame: .zero)

    init(display: DisplayInfo) {
        self.display = display
        let bounds = CGRect(origin: .zero, size: display.frame.size)
        canvas = CanvasView(frame: bounds)
        super.init(frame: bounds)
        wantsLayer = true
        layer?.backgroundColor = .clear

        canvas.autoresizingMask = [.width, .height]
        addSubview(canvas)
        let root = canvas.root
        imageLayer.contentsGravity = .resize
        root.addSublayer(imageLayer)
        unavailableLayer.backgroundColor = OverlayStyle.dim
        root.addSublayer(unavailableLayer)
        for d in dimLayers {
            d.backgroundColor = OverlayStyle.dim
            root.addSublayer(d)
        }
        windowLayer.backgroundColor = OverlayStyle.windowFill
        windowLayer.borderColor = OverlayStyle.windowRing
        windowLayer.borderWidth = 2
        windowLayer.cornerRadius = OverlayStyle.windowRadius
        root.addSublayer(windowLayer)
        for g in [guideXLayer, guideYLayer] {
            g.backgroundColor = OverlayStyle.guide
            root.addSublayer(g)
        }
        borderLayer.borderColor = OverlayStyle.selectionBorder
        borderLayer.borderWidth = 1
        root.addSublayer(borderLayer)
        for h in handleLayers {
            h.backgroundColor = OverlayStyle.handleFill
            h.borderColor = OverlayStyle.handleRing
            h.borderWidth = 1
            h.cornerRadius = OverlayStyle.handleSize / 2
            h.bounds = CGRect(x: 0, y: 0, width: OverlayStyle.handleSize, height: OverlayStyle.handleSize)
            root.addSublayer(h)
        }
        for v in [unavailablePill, windowPill, snapPill, sizePill, loupe, loupeLabel, hud] as [NSView] { addSubview(v) }
        layoutCanvas()
        reset()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func layoutCanvas() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = display.scale
        for l in [imageLayer, unavailableLayer, borderLayer, guideXLayer, guideYLayer, windowLayer] + dimLayers + handleLayers { l.contentsScale = scale }
        imageLayer.frame = CGRect(origin: .zero, size: display.frame.size)
        unavailableLayer.frame = imageLayer.frame
        CATransaction.commit()
    }

    /// Back to an empty, transparent overlay.
    func reset() {
        image = nil
        isUnavailable = false
        loupe.clear()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        for l in dimLayers + handleLayers + [unavailableLayer, borderLayer, guideXLayer, guideYLayer, windowLayer] { l.isHidden = true }
        CATransaction.commit()
        for v in [unavailablePill, windowPill, snapPill, sizePill, loupe, loupeLabel, hud] as [NSView] { v.isHidden = true }
    }

    /// Marks this display as one that can't be captured (or clears that when its frame turns up late).
    func setUnavailable(_ on: Bool) {
        isUnavailable = on
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        unavailableLayer.isHidden = !on
        CATransaction.commit()
        if on {
            unavailablePill.setText(Self.unavailableText)
            let s = unavailablePill.frame.size
            unavailablePill.setFrameOrigin(CGPoint(x: ((bounds.width - s.width) / 2).rounded(), y: ((bounds.height - s.height) / 2).rounded()))
        }
        unavailablePill.isHidden = !on
    }

    private static let unavailableText = "Can't capture this display"

    /// Draws every piece of chrome once (fonts, text layout, layer setup) so the first ⌘⇧4 doesn't pay for it.
    func warmUp() {
        let f = display.frame
        var frame = OverlayFrame()
        frame.selection = CGRect(x: f.midX - 100, y: f.midY - 100, width: 200, height: 200)
        frame.selectionDisplayID = display.id
        frame.sizeText = "400 × 400"
        frame.guideX = f.midX - 100
        frame.mouse = CGPoint(x: f.midX, y: f.midY)
        frame.mouseDisplayID = display.id
        frame.showsHUD = true
        render(frame)
        frame.mode = .window
        frame.window = frame.selection
        frame.windowText = "Margin · 400 × 400"
        render(frame)
        loupeLabel.setText("0, 0 · #000000")
        unavailablePill.setText(Self.unavailableText)
        for v in [unavailablePill, windowPill, snapPill, sizePill, loupeLabel, hud] as [NSView] { v.isHidden = false }
        displayIfNeeded()
        reset()
    }

    /// Shows the frozen frame and commits it right away.
    func setFrozen(_ image: CGImage) {
        self.image = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
        CATransaction.flush()
    }

    // MARK: Rendering

    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY) }
    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - display.frame.minX, y: p.y - display.frame.minY) }

    func render(_ f: OverlayFrame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let b = bounds
        let here = display.id

        // Selection, dim, handles.
        var selectionHere: CGRect?
        if f.mode == .area, let sel = f.selection, !sel.isEmpty {
            if f.selectionDisplayID == here {
                let r = local(sel)
                selectionHere = r
                dimLayers[0].frame = CGRect(x: 0, y: r.maxY, width: b.width, height: max(0, b.maxY - r.maxY))
                dimLayers[1].frame = CGRect(x: 0, y: 0, width: b.width, height: max(0, r.minY))
                dimLayers[2].frame = CGRect(x: 0, y: r.minY, width: max(0, r.minX), height: r.height)
                dimLayers[3].frame = CGRect(x: r.maxX, y: r.minY, width: max(0, b.maxX - r.maxX), height: r.height)
                for d in dimLayers { d.isHidden = false }
                borderLayer.frame = r.insetBy(dx: -1, dy: -1)
                borderLayer.isHidden = false
                let showEdges = r.width >= 40 && r.height >= 40
                for (layer, handle) in zip(handleLayers, Handle.allCases) {
                    layer.position = handle.point(in: r)
                    layer.isHidden = !(handle.isCorner || showEdges)
                }
            } else {
                // The selection is on another display: dim this one entirely (unless it already is).
                dimLayers[0].frame = b
                dimLayers[0].isHidden = isUnavailable
                for d in dimLayers.dropFirst() { d.isHidden = true }
                borderLayer.isHidden = true
                for h in handleLayers { h.isHidden = true }
            }
        } else {
            for l in dimLayers + handleLayers + [borderLayer] { l.isHidden = true }
        }

        // Guides.
        if let x = f.guideX, selectionHere != nil, x >= display.frame.minX, x <= display.frame.maxX {
            guideXLayer.frame = CGRect(x: (x - display.frame.minX).rounded() - 0.5, y: 0, width: 1, height: b.height)
            guideXLayer.isHidden = false
        } else {
            guideXLayer.isHidden = true
        }
        if let y = f.guideY, selectionHere != nil, y >= display.frame.minY, y <= display.frame.maxY {
            guideYLayer.frame = CGRect(x: 0, y: (y - display.frame.minY).rounded() - 0.5, width: b.width, height: 1)
            guideYLayer.isHidden = false
        } else {
            guideYLayer.isHidden = true
        }

        // Size pill and "Snapped to window", right-aligned 7 pt below the selection.
        if let r = selectionHere, let text = f.sizeText {
            sizePill.setText(text)
            let snapped = f.guideX != nil || f.guideY != nil
            if snapped { snapPill.setText("Snapped to window") }
            let h = sizePill.frame.height
            let total = sizePill.frame.width + (snapped ? snapPill.frame.width + 6 : 0)
            var y = r.minY - 7 - h
            if y < 4 { y = r.maxY + 7 }
            if y + h > b.maxY - 4 { y = r.minY + 7 }
            let right = min(max(r.maxX, total + 4), b.maxX - 4)
            sizePill.setFrameOrigin(CGPoint(x: right - sizePill.frame.width, y: y))
            sizePill.isHidden = false
            snapPill.setFrameOrigin(CGPoint(x: right - total, y: y))
            snapPill.isHidden = !snapped
        } else {
            sizePill.isHidden = true
            snapPill.isHidden = true
        }

        // Window highlight.
        if f.mode == .window, let w = f.window, w.intersects(display.frame) {
            let r = local(w)
            windowLayer.frame = r
            windowLayer.isHidden = false
            if f.mouseDisplayID == here, let text = f.windowText {
                windowPill.setText(text)
                let visible = r.intersection(b)
                let s = windowPill.frame.size
                let x = min(max(r.minX + 10, visible.minX + 6), visible.maxX - s.width - 6)
                let y = max(min(r.maxY - 40 - s.height, visible.maxY - s.height - 6), visible.minY + 6)
                windowPill.setFrameOrigin(CGPoint(x: x, y: y))
                windowPill.isHidden = false
            } else {
                windowPill.isHidden = true
            }
        } else {
            windowLayer.isHidden = true
            windowPill.isHidden = true
        }

        // Loupe: up and to the right of the pointer (away from the selection), flipped at the edges.
        if f.showsLoupe, f.mouseDisplayID == here, let image {
            let m = local(f.mouse)
            let px = min(max(Int((m.x * display.scale).rounded(.down)), 0), image.width - 1)
            let py = min(max(Int(((b.height - m.y) * display.scale).rounded(.down)), 0), image.height - 1)
            loupe.show(image, x: px, y: py)
            loupeLabel.setText("\(px), \(py) · \(LoupeView.hex(of: image, x: px, y: py))")
            let d = LoupeView.diameter
            let labelSize = loupeLabel.frame.size
            var right = true
            if let r = selectionHere, m.x < r.midX { right = false }
            if right, m.x + 18 + d > b.maxX - 4 { right = false }
            if !right, m.x - 18 - d < 4 { right = true }
            let loupeX = right ? m.x + 18 : m.x - 18 - d
            var labelY = m.y + 6
            var loupeY = labelY + labelSize.height + 8
            if loupeY + d > b.maxY - 4 {
                labelY = m.y - 6 - labelSize.height
                loupeY = labelY - 8 - d
            }
            loupe.setFrameOrigin(CGPoint(x: loupeX, y: loupeY))
            loupeLabel.setFrameOrigin(CGPoint(x: (loupeX + d / 2 - labelSize.width / 2).rounded(), y: labelY))
            loupe.isHidden = false
            loupeLabel.isHidden = false
        } else {
            loupe.isHidden = true
            loupeLabel.isHidden = true
        }

        // Hint bar at the top center, below the menu bar and the notch.
        if f.showsHUD, f.mouseDisplayID == here {
            hud.setItems(f.mode == .area ? HUDView.areaItems : HUDView.windowItems)
            var top: CGFloat = 24
            if let screen = Displays.screen(for: here) {
                top = max(top, screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
            }
            let s = hud.frame.size
            let origin = CGPoint(x: ((b.width - s.width) / 2).rounded(), y: (b.height - top - 14 - s.height).rounded())
            hud.setFrameOrigin(origin)
            // Step aside if the selection reaches under it.
            let covered = selectionHere.map { $0.intersects(CGRect(origin: origin, size: s).insetBy(dx: -8, dy: -8)) } ?? false
            hud.isHidden = covered
        } else {
            hud.isHidden = true
        }
    }

    // MARK: Input

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) != nil ? self : nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func global(_ event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    override func mouseDown(with event: NSEvent) { session?.mouseDown(at: global(event), on: display, event: event) }
    override func mouseDragged(with event: NSEvent) { session?.mouseDragged(at: global(event), event: event) }
    override func mouseUp(with event: NSEvent) { session?.mouseUp(at: global(event), event: event) }
    override func mouseMoved(with event: NSEvent) { session?.mouseMoved(to: global(event)) }
    override func mouseEntered(with event: NSEvent) { session?.mouseMoved(to: global(event)) }
    /// A second way out besides Esc, so the overlay can never be stuck if keys don't reach it.
    override func rightMouseDown(with event: NSEvent) { session?.cancel() }
    override func scrollWheel(with event: NSEvent) {}
    override func cursorUpdate(with event: NSEvent) { session?.updateCursor() }
    override func keyDown(with event: NSEvent) { session?.keyDown(event) }
    override func keyUp(with event: NSEvent) { session?.keyUp(event) }
    override func flagsChanged(with event: NSEvent) { session?.flagsChanged(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Swallow ⌘-shortcuts while the overlay is up; everything else goes to keyDown.
        event.modifierFlags.contains(.command) || super.performKeyEquivalent(with: event)
    }
}
