import AppKit
import QuartzCore

/// `+N older`: two stacked Liquid Glass plates. Hover fans out a peek of the newest few pile shots
/// (drawn by `fan`, which sits just below the pile in z-order). Drag sends them all; right-click clears.
@MainActor
final class ShelfPileView: NSView {
    weak var controller: ShelfController?
    let fan = ShelfPileFanView()

    private let back = GlassBackground(cornerRadius: 9)
    private let front = GlassBackground(cornerRadius: 9)
    private let label = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private(set) var count = 0
    private(set) var isHovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        back.alphaValue = ShelfStyle.reduceTransparency ? 1 : 0.55
        addSubview(back)
        addSubview(front)
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        label.alignment = .center
        label.textColor = .labelColor
        front.content.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func rebuildMaterial() {
        back.alphaValue = ShelfStyle.reduceTransparency ? 1 : 0.55
        back.rebuild()
        front.rebuild()
        front.content.addSubview(label)
        needsLayout = true
    }

    func setCount(_ n: Int) {
        count = n
        label.stringValue = "+\(n) older"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        front.frame = bounds
        back.frame = CGRect(x: 12, y: 6, width: bounds.width - 24, height: bounds.height)
        label.sizeToFit()
        label.frame = CGRect(x: 0, y: (bounds.height - label.frame.height) / 2, width: bounds.width, height: label.frame.height)
    }

    /// Moves the pile (and its fan) to `frame`, springing from the old spot.
    func setSlot(_ frame: CGRect, animated: Bool) {
        let old = self.frame
        self.frame = frame
        fan.frame = CGRect(x: frame.minX - 40, y: frame.minY, width: frame.width + 80, height: frame.height + ShelfStyle.headroom)
        if animated, old != .zero, let layer {
            ShelfMotion.slide(layer, from: CGPoint(x: old.minX - frame.minX, y: old.minY - frame.minY))
        }
    }

    // MARK: - Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds.insetBy(dx: 0, dy: -6), options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        controller?.pileHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        controller?.pileHover(false)
    }

    private var downEvent: NSEvent?
    private var didDrag = false

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            NSMenu.popUpContextMenu(menu(for: event) ?? NSMenu(), with: event, for: self)
            downEvent = nil
            return
        }
        downEvent = event
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didDrag, let down = downEvent else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) >= 4 else { return }
        didDrag = true
        fan.setFanned(false, animated: true)
        controller?.beginPileDrag(from: self, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downEvent = nil }
        guard downEvent != nil, !didDrag else { return }
        controller?.focusShelf()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let clear = NSMenuItem(title: "Clear shelf", action: #selector(clearShelf), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        return menu
    }

    @objc private func clearShelf() { controller?.clear() }
}

/// Mini cards that rise out from behind the pile on hover ("a light peek of the top few").
@MainActor
final class ShelfPileFanView: NSView {
    private var minis: [CALayer] = []
    private(set) var isFanned = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Newest pile shot first.
    func setImages(_ images: [CGImage]) {
        minis.forEach { $0.removeFromSuperlayer() }
        minis = []
        guard let root = layer else { return }
        for image in images.prefix(3) {
            let m = CALayer.shelfQuiet()
            let aspect = CGFloat(image.height) / CGFloat(max(image.width, 1))
            let w: CGFloat = 104
            let h = min(max(w * aspect, 46), 66)
            m.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            m.contents = image
            m.contentsGravity = .resizeAspectFill
            m.cornerRadius = 7
            m.cornerCurve = .continuous
            m.masksToBounds = true
            m.borderWidth = 1
            m.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
            m.contentsScale = window?.backingScaleFactor ?? 2
            minis.append(m)
        }
        // Back to front: the newest ends on top.
        for m in minis.reversed() { root.addSublayer(m) }
        place(fanned: isFanned, animated: false)
    }

    func setFanned(_ on: Bool, animated: Bool) {
        guard on != isFanned else { return }
        isFanned = on
        place(fanned: on, animated: animated)
    }

    private func place(fanned: Bool, animated: Bool) {
        // Pile occupies y 0...30 of this view, centered horizontally.
        let cx = bounds.midX
        let pileTop: CGFloat = 30
        // Bottoms stay behind the pile; the front card peeks highest, the others lean out.
        let spreads: [(dx: CGFloat, rot: CGFloat, bottom: CGFloat)] = [(0, 0, 12), (-34, 6, 7), (34, -6, 7)]
        for (i, m) in minis.enumerated() {
            let s = spreads[i]
            let h = m.bounds.height
            let shownPos = CGPoint(x: cx + s.dx, y: s.bottom + h / 2)
            let hiddenPos = CGPoint(x: cx, y: pileTop - h / 2 + 4)
            let pos = fanned ? shownPos : hiddenPos
            var t = CATransform3DMakeRotation((fanned ? s.rot : 0) * .pi / 180, 0, 0, 1)
            if !fanned { t = CATransform3DScale(t, 0.85, 0.85, 1) }
            let opacity: Float = fanned ? (i == 0 ? 1 : 0.85) : 0
            let reduce = ShelfStyle.reduceMotion
            if animated && !reduce {
                let fromPos = m.presentation()?.position ?? m.position
                let fromT = m.presentation()?.transform ?? m.transform
                m.position = pos
                m.transform = t
                let delay = CACurrentMediaTime() + Double(i) * 0.03
                let a = ShelfMotion.spring("position", from: NSValue(point: fromPos), to: NSValue(point: pos), duration: 0.4, bounce: fanned ? 0.25 : 0)
                a.beginTime = delay
                a.fillMode = .backwards
                m.add(a, forKey: "position")
                let b = ShelfMotion.spring("transform", from: NSValue(caTransform3D: fromT), to: NSValue(caTransform3D: t), duration: 0.4, bounce: fanned ? 0.25 : 0)
                b.beginTime = delay
                b.fillMode = .backwards
                m.add(b, forKey: "transform")
                ShelfMotion.fade(m, to: opacity, duration: 0.2)
            } else {
                m.removeAllAnimations()
                m.position = pos
                m.transform = t
                m.opacity = opacity
            }
        }
    }
}
