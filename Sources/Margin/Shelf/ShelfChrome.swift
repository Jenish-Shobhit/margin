import AppKit
import QuartzCore

/// Liquid Glass (`NSGlassEffectView`), or a solid material when Reduce Transparency is on.
/// Put labels in `content`; it moves between the two backgrounds when the setting changes.
@MainActor
final class GlassBackground: NSView {
    let content = NSView()
    var cornerRadius: CGFloat { didSet { applyRadius() } }
    private var glass: NSGlassEffectView?
    private var solid: SolidBackground?

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Call when Reduce Transparency changes.
    func rebuild() {
        content.removeFromSuperview()
        glass?.removeFromSuperview(); glass = nil
        solid?.removeFromSuperview(); solid = nil
        if ShelfStyle.reduceTransparency {
            let s = SolidBackground()
            s.frame = bounds
            s.autoresizingMask = [.width, .height]
            content.frame = s.bounds
            content.autoresizingMask = [.width, .height]
            s.addSubview(content)
            addSubview(s)
            solid = s
        } else {
            let g = NSGlassEffectView()
            g.frame = bounds
            g.autoresizingMask = [.width, .height]
            content.frame = g.bounds
            content.autoresizingMask = [.width, .height]
            g.contentView = content
            addSubview(g)
            glass = g
        }
        applyRadius()
    }

    private func applyRadius() {
        glass?.cornerRadius = cornerRadius
        solid?.radius = cornerRadius
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The Reduce Transparency fallback: an opaque rounded plate in the window background color.
@MainActor
final class SolidBackground: NSView {
    var radius: CGFloat = 10 { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        layer.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer.borderColor = NSColor.separatorColor.cgColor
        layer.borderWidth = 1
    }
}

/// "Copied", "Path copied", "Restored", errors. Lives inside the shelf, above the top card.
@MainActor
final class ShelfToastView: NSView {
    private let background = GlassBackground(cornerRadius: 9)
    private let label = NSTextField(labelWithString: "")
    private var hideTask: Task<Void, Never>?
    /// Called once the toast has faded out.
    var onHidden: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(background)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        background.content.addSubview(label)
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Size for `text` (padding 6 × 10, like the HTML).
    func show(_ text: String, isError: Bool, anchorRight: CGFloat, bottom: CGFloat, maxWidth: CGFloat) {
        label.stringValue = text
        label.textColor = isError ? .systemRed : .labelColor
        label.sizeToFit()
        let w = min(ceil(label.frame.width) + 20, maxWidth)
        let h: CGFloat = 25
        frame = CGRect(x: anchorRight - w, y: bottom, width: w, height: h)
        background.frame = bounds
        label.frame = CGRect(x: 10, y: (h - label.frame.height) / 2, width: w - 20, height: label.frame.height)

        hideTask?.cancel()
        isHidden = false
        let layer = self.layer!
        if alphaValue < 1 {
            alphaValue = 1
            if !ShelfStyle.reduceMotion {
                layer.add(ShelfMotion.basic("opacity", from: 0, to: 1, duration: 0.18), forKey: "in")
                let rise = ShelfMotion.spring("position", from: NSValue(point: CGPoint(x: 0, y: -6)), to: NSValue(point: .zero), duration: 0.35, bounce: 0.2)
                rise.isAdditive = true
                layer.add(rise, forKey: "rise")
            }
        }
        hideTask = ShelfMotion.after(1.2) { [weak self] in self?.hide() }
    }

    func hide() {
        hideTask?.cancel()
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue == 0 else { return }
                self.isHidden = true
                self.onHidden?()
            }
        })
    }

    func rebuildMaterial() { background.rebuild(); background.content.addSubview(label) }
}

/// The 22 pt tab left at the screen edge when the shelf is tucked: a count and a ‹ glyph.
@MainActor
final class ShelfTabView: NSView {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    private let background = GlassBackground(cornerRadius: 11)
    private let countLabel = NSTextField(labelWithString: "0")
    private let chevron = NSTextField(labelWithString: "‹")
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(background)
        countLabel.font = .systemFont(ofSize: 11, weight: .bold)
        countLabel.alignment = .center
        chevron.font = .systemFont(ofSize: 13, weight: .semibold)
        chevron.alignment = .center
        chevron.alphaValue = 0.7
        addLabels()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func addLabels() {
        background.content.addSubview(countLabel)
        background.content.addSubview(chevron)
    }

    func rebuildMaterial() { background.rebuild(); addLabels(); needsLayout = true }

    var count: Int = 0 {
        didSet { countLabel.stringValue = "\(count)"; needsLayout = true }
    }

    /// A little pop when a shot lands in the tab.
    func bump() {
        guard let layer, !ShelfStyle.reduceMotion else { return }
        let a = CAKeyframeAnimation(keyPath: "transform")
        a.values = [1, 1.18, 0.96, 1].map { NSValue(caTransform3D: layer.shelfCenteredScale($0)) }
        a.keyTimes = [0, 0.35, 0.7, 1]
        a.duration = 0.4
        layer.add(a, forKey: "bump")
    }

    override func layout() {
        super.layout()
        // The glass extends past the right edge (clipped by the screen edge) so only the left corners round.
        background.frame = CGRect(x: 0, y: 0, width: bounds.width + 12, height: bounds.height)
        let w = ShelfStyle.tabWidth
        countLabel.sizeToFit()
        chevron.sizeToFit()
        let total = countLabel.frame.height + 2 + chevron.frame.height
        let y0 = (bounds.height - total) / 2
        chevron.frame = CGRect(x: 0, y: y0, width: w, height: chevron.frame.height)
        countLabel.frame = CGRect(x: 0, y: y0 + chevron.frame.height + 2, width: w, height: countLabel.frame.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}
