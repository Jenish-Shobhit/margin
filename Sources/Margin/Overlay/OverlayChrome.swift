import AppKit

/// Colors and metrics from the ideation doc's Capture section.
enum OverlayStyle {
    static let dim = CGColor(gray: 0, alpha: 0.34)
    static let selectionBorder = CGColor(gray: 1, alpha: 0.95)
    static let handleFill = CGColor(gray: 1, alpha: 1)
    static let handleRing = CGColor(gray: 0, alpha: 0.35)
    static let handleSize: CGFloat = 9
    static let guide = CGColor(gray: 1, alpha: 0.4)
    static let pillFill = NSColor(srgbRed: 20 / 255, green: 20 / 255, blue: 24 / 255, alpha: 0.86)
    static let pillRing = NSColor(white: 1, alpha: 0.18)
    static let accent = NSColor(srgbRed: 0x5A / 255, green: 0x54 / 255, blue: 0xF0 / 255, alpha: 1)
    static let windowFill = srgb(142 / 255, 137 / 255, 255 / 255, 0.24)
    static let windowRing = srgb(0xA5 / 255, 0xA1 / 255, 0xFF / 255, 1)
    static let windowRadius: CGFloat = 12
    static let hudFill = NSColor(srgbRed: 20 / 255, green: 20 / 255, blue: 24 / 255, alpha: 0.82)
    static let hudRing = NSColor(white: 1, alpha: 0.14)
}

private func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, a])!
}

/// A small rounded label: the size pill, "Snapped to window", the active mode, the window pill, the loupe label
/// and notes.
final class PillView: NSView {
    /// `dark`: figures in a monospaced font; `note`: the same look for a sentence; `accent`: highlighted.
    enum Style { case dark, note, accent }

    private let style: Style
    private(set) var text = ""
    private var attributed = NSAttributedString()

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var font: NSFont {
        style == .dark ? .monospacedSystemFont(ofSize: 11, weight: .semibold) : .systemFont(ofSize: 11, weight: .semibold)
    }

    /// Sets the text and resizes to fit (4 × 8 pt padding).
    func setText(_ newText: String) {
        guard newText != text || attributed.length == 0 else { return }
        text = newText
        attributed = NSAttributedString(string: newText, attributes: [.font: font, .foregroundColor: NSColor.white])
        let s = attributed.size()
        setFrameSize(CGSize(width: ceil(s.width) + 16, height: ceil(s.height) + 8))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        (style == .accent ? OverlayStyle.accent : OverlayStyle.pillFill).setFill()
        path.fill()
        if style != .accent {
            OverlayStyle.pillRing.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let s = attributed.size()
        attributed.draw(at: CGPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2))
    }
}

/// The hint bar at the top center. An item whose key is held right now (⇧, ⌥, Space) is highlighted, so it's
/// clear what the key just did.
final class HUDView: NSView {
    struct Item: Equatable {
        let key: String?
        let label: String
        var highlighted = false
        /// Also make room for this label, so swapping between the two doesn't shift the bar.
        var reserve: String?
    }

    /// Keys held during a capture that change what happens.
    struct Held: OptionSet, Equatable {
        let rawValue: Int
        /// ⇧ while drawing: a square.
        static let square = Held(rawValue: 1 << 0)
        /// ⌥ while drawing: grows around the starting point.
        static let fromCenter = Held(rawValue: 1 << 1)
        /// Space while drawing: moves the selection.
        static let move = Held(rawValue: 1 << 2)
        /// ⌥ in window mode: the shot keeps the window's shadow.
        static let keepShadow = Held(rawValue: 1 << 3)
    }

    /// While drawing a selection, Space moves it; otherwise it switches to window mode. "Z Magnifier" is
    /// highlighted while the loupe is on. Choosing what to record, ↩ records the selection.
    static func areaItems(drawing: Bool, held: Held, magnifier: Bool, recording: Bool = false) -> [Item] {
        [
            Item(key: "Space", label: drawing ? "Move" : "Window", highlighted: held.contains(.move), reserve: drawing ? "Window" : "Move"),
            Item(key: "⇧", label: "Square", highlighted: held.contains(.square)),
            Item(key: "⌥", label: "From center", highlighted: held.contains(.fromCenter)),
            Item(key: "←↑→↓", label: "Nudge"), Item(key: "Z", label: "Magnifier", highlighted: magnifier),
            Item(key: "↩", label: recording ? "Record" : "Capture"), Item(key: "Esc", label: "Cancel"),
        ]
    }

    /// ⇧⌘5 before anything is selected (spec §14.4): what each way of choosing records.
    static func recordItems() -> [Item] {
        [
            Item(key: nil, label: "Drag an area"), Item(key: "Space", label: "Window"),
            Item(key: nil, label: "Click for the whole screen"), Item(key: "Esc", label: "Cancel"),
        ]
    }

    /// A recorded window never has its shadow: no ⌥ then.
    static func windowItems(held: Held, recording: Bool = false) -> [Item] {
        recording
            ? [Item(key: nil, label: "Click to record"), Item(key: "Space", label: "Area"), Item(key: "Esc", label: "Cancel")]
            : [
                Item(key: nil, label: "Click to capture"), Item(key: "⌥", label: "Keep shadow", highlighted: held.contains(.keepShadow)),
                Item(key: "Space", label: "Area"), Item(key: "Esc", label: "Cancel"),
            ]
    }

    private static let keyFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    private static let labelFont = NSFont.systemFont(ofSize: 12)
    private static let highlightLabelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let padX: CGFloat = 14, gap: CGFloat = 14, keyGap: CGFloat = 4, keyPadX: CGFloat = 6, height: CGFloat = 38
    /// The highlight reaches this far past an item's key and label (less than half the gap, so neighbours never touch).
    private static let highlightPadX: CGFloat = 5, highlightHeight: CGFloat = 28

    private(set) var items: [Item] = []
    /// Each item's slot: x and width (at least its content; more with `reserve`).
    private var slots: [(x: CGFloat, width: CGFloat)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        layer?.shadowColor = .black
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 15
        layer?.shadowOffset = CGSize(width: 0, height: -10)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Redraws only when something changed (an item, its label or its highlight).
    func setItems(_ newItems: [Item]) {
        guard newItems != items else { return }
        let resized = newItems.map { [$0.key, $0.label, $0.reserve] } != items.map { [$0.key, $0.label, $0.reserve] }
        items = newItems
        guard resized || slots.count != items.count else {
            needsDisplay = true
            return
        }
        slots = []
        var x = Self.padX
        for (i, item) in items.enumerated() {
            if i > 0 { x += Self.gap }
            let w = max(contentWidth(item, item.label), item.reserve.map { contentWidth(item, $0) } ?? 0)
            slots.append((x, w))
            x += w
        }
        setFrameSize(CGSize(width: ceil(x + Self.padX), height: Self.height))
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        needsDisplay = true
    }

    private func contentWidth(_ item: Item, _ text: String) -> CGFloat {
        // Measured in the highlight's (heavier) font, so highlighting never overflows the slot.
        (item.key.map { keySize($0).width + Self.keyGap } ?? 0)
            + ceil(label(text, highlighted: true).size().width)
    }

    private func key(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: Self.keyFont, .foregroundColor: NSColor.white])
    }

    private func label(_ s: String, highlighted: Bool = false) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: highlighted ? Self.highlightLabelFont : Self.labelFont,
            .foregroundColor: NSColor(white: 1, alpha: highlighted ? 1 : 0.92),
        ])
    }

    private func keySize(_ s: String) -> CGSize {
        let t = key(s).size()
        return CGSize(width: ceil(t.width) + Self.keyPadX * 2, height: 21)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        OverlayStyle.hudFill.setFill()
        bg.fill()
        OverlayStyle.hudRing.setStroke()
        bg.lineWidth = 1
        bg.stroke()

        let midY = bounds.midY
        for (item, slot) in zip(items, slots) {
            let content = contentWidth(item, item.label)
            if item.highlighted {
                let h = CGRect(x: slot.x - Self.highlightPadX, y: (midY - Self.highlightHeight / 2).rounded(),
                               width: slot.width + 2 * Self.highlightPadX, height: Self.highlightHeight)
                OverlayStyle.accent.setFill()
                NSBezierPath(roundedRect: h, xRadius: 8, yRadius: 8).fill()
            }
            var x = (slot.x + (slot.width - content) / 2).rounded()
            if let k = item.key {
                let size = keySize(k)
                let r = CGRect(x: x, y: (midY - size.height / 2).rounded(), width: size.width, height: size.height)
                let cap = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
                NSColor(white: 1, alpha: item.highlighted ? 0.22 : 0.12).setFill()
                cap.fill()
                NSColor(white: 1, alpha: item.highlighted ? 0.4 : 0.2).setStroke()
                cap.lineWidth = 1
                cap.stroke()
                // The heavier bottom edge of a key cap.
                let bottom = NSBezierPath()
                bottom.move(to: CGPoint(x: r.minX + 4, y: r.minY + 1.5))
                bottom.line(to: CGPoint(x: r.maxX - 4, y: r.minY + 1.5))
                bottom.lineWidth = 1
                bottom.stroke()
                let t = key(k)
                let ts = t.size()
                t.draw(at: CGPoint(x: r.midX - ts.width / 2, y: r.midY - ts.height / 2 + 0.5))
                x = r.maxX + Self.keyGap
            }
            let l = label(item.label, highlighted: item.highlighted)
            let ls = l.size()
            l.draw(at: CGPoint(x: x, y: midY - ls.height / 2))
        }
    }
}

/// The magnifier: 11 × 11 frozen pixels around the pointer, in a ring.
final class LoupeView: NSView {
    static let cells = 11
    static let cell: CGFloat = 11
    static let ring: CGFloat = 3
    static let diameter = CGFloat(cells) * cell + 2 * ring

    private var image: CGImage?
    private var center = (x: 0, y: 0)

    override init(frame: NSRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        wantsLayer = true
        isHidden = true
        layer?.shadowColor = .black
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 15
        layer?.shadowOffset = CGSize(width: 0, height: -10)
        layer?.shadowPath = CGPath(ellipseIn: bounds, transform: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// `x`, `y`: the center pixel in the image (origin top-left).
    func show(_ image: CGImage, x: Int, y: Int) {
        guard image !== self.image || x != center.x || y != center.y else { return }
        self.image = image
        center = (x, y)
        needsDisplay = true
    }

    func clear() {
        image = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let n = Self.cells, cell = Self.cell, half = n / 2
        let inner = bounds.insetBy(dx: Self.ring, dy: Self.ring)

        ctx.saveGState()
        ctx.addEllipse(in: inner)
        ctx.clip()
        ctx.setFillColor(.black)
        ctx.fill(inner)
        if let image {
            let want = CGRect(x: center.x - half, y: center.y - half, width: n, height: n)
            let r = want.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if !r.isNull, r.width > 0, r.height > 0, let sub = image.cropping(to: r) {
                ctx.interpolationQuality = .none
                let fromTop = (r.minY - want.minY) * cell
                let dest = CGRect(x: inner.minX + (r.minX - want.minX) * cell, y: inner.maxY - fromTop - r.height * cell,
                                  width: r.width * cell, height: r.height * cell)
                ctx.draw(sub, in: dest)
            }
        }
        // Pixel grid.
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.18))
        ctx.setLineWidth(0.5)
        for i in 1..<n {
            let o = CGFloat(i) * cell
            ctx.move(to: CGPoint(x: inner.minX + o, y: inner.minY))
            ctx.addLine(to: CGPoint(x: inner.minX + o, y: inner.maxY))
            ctx.move(to: CGPoint(x: inner.minX, y: inner.minY + o))
            ctx.addLine(to: CGPoint(x: inner.maxX, y: inner.minY + o))
        }
        ctx.strokePath()
        // The center pixel: a white inset outline with a thin black edge.
        let c = CGRect(x: inner.minX + CGFloat(half) * cell, y: inner.minY + CGFloat(half) * cell, width: cell, height: cell)
        ctx.setStrokeColor(.black)
        ctx.setLineWidth(1)
        ctx.stroke(c.insetBy(dx: -0.5, dy: -0.5))
        ctx.setStrokeColor(.white)
        ctx.setLineWidth(2)
        ctx.stroke(c.insetBy(dx: 1, dy: 1))
        ctx.restoreGState()

        // Ring.
        ctx.setStrokeColor(.white)
        ctx.setLineWidth(Self.ring)
        ctx.strokeEllipse(in: bounds.insetBy(dx: Self.ring / 2, dy: Self.ring / 2))
    }

    /// The pixel's color as `#RRGGBB` in sRGB.
    static func hex(of image: CGImage, x: Int, y: Int) -> String {
        guard let sub = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return "#000000" }
        ctx.draw(sub, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let p = data.assumingMemoryBound(to: UInt8.self)
        return String(format: "#%02X%02X%02X", p[0], p[1], p[2])
    }
}
