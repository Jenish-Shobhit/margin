import AppKit

/// Drag-out source for one card, the selection, or the pile. Plain file URLs, `.copy` only,
/// and only outside Margin. The file is never moved or deleted; success just means the card leaves.
@MainActor
final class ShelfDragSource: NSObject, NSDraggingSource {
    let ids: [UUID]
    weak var controller: ShelfController?

    init(ids: [UUID], controller: ShelfController) {
        self.ids = ids
        self.controller = controller
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    /// ⌘ still held from a ⌘-click must not turn the drag into a (refused) move.
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        controller?.dragEnded(self, operation: operation)
    }
}

/// Drag images, drawn once at drag start.
@MainActor
enum ShelfDragImage {
    /// Shadow room around a single lifted card.
    static let pad: CGFloat = 34

    /// The card itself, lifted: rounded, hairline ring, deeper shadow. Frame = card bounds inset by -pad.
    static func single(_ image: CGImage?, cardSize: CGSize, scale: CGFloat) -> NSImage {
        let size = CGSize(width: cardSize.width + pad * 2, height: cardSize.height + pad * 2)
        return render(size: size, scale: scale) { ctx in
            drawCard(ctx, image: image, rect: CGRect(x: pad, y: pad, width: cardSize.width, height: cardSize.height), shadow: true)
        }
    }

    /// Up to three cards stacked with slight rotations, plus a red count badge (HTML "Multi-drag").
    /// Returns the image and the front card's center inside it.
    static func stack(_ images: [CGImage], count: Int, scale: CGFloat) -> (image: NSImage, anchor: CGPoint) {
        let w: CGFloat = 150
        let front = images.first
        let aspect = front.map { CGFloat($0.height) / CGFloat(max($0.width, 1)) } ?? 0.625
        let h = min(max(w * aspect, 54), 150)
        let margin: CGFloat = 40
        let size = CGSize(width: w + margin * 2, height: h + margin * 2)
        let card = CGRect(x: margin, y: margin, width: w, height: h)
        let img = render(size: size, scale: scale) { ctx in
            var layers: [(img: CGImage?, dx: CGFloat, dy: CGFloat, rot: CGFloat, alpha: CGFloat)] = []
            if count > 2 { layers.append((images.count > 2 ? images[2] : images.last, 14, 12, -11, 0.7)) }
            if count > 1 { layers.append((images.count > 1 ? images[1] : images.last, 8, 8, -7, 0.85)) }
            layers.append((front, 0, 0, -2, 1))
            for l in layers {
                ctx.saveGState()
                ctx.setAlpha(l.alpha)
                ctx.translateBy(x: card.midX + l.dx, y: card.midY + l.dy)
                ctx.rotate(by: l.rot * .pi / 180)
                drawCard(ctx, image: l.img, rect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), shadow: true)
                ctx.restoreGState()
            }
            if count > 1 { drawBadge(ctx, count: count, topRight: CGPoint(x: card.maxX + 14, y: card.maxY + 12)) }
        }
        return (img, CGPoint(x: card.midX, y: card.midY))
    }

    private static func drawCard(_ ctx: CGContext, image: CGImage?, rect: CGRect, shadow: Bool) {
        let path = CGPath(roundedRect: rect, cornerWidth: ShelfStyle.cornerRadius, cornerHeight: ShelfStyle.cornerRadius, transform: nil)
        if shadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 26, color: NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.addPath(path)
            ctx.setFillColor(NSColor(white: 0.13, alpha: 1).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(NSColor(white: 0.13, alpha: 1).cgColor)
        ctx.fill(rect)
        if let image {
            ctx.interpolationQuality = .high
            ctx.draw(image, in: ShelfGeometry.aspectFill(CGSize(width: image.width, height: image.height), in: rect))
        }
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: ShelfStyle.cornerRadius - 0.5, cornerHeight: ShelfStyle.cornerRadius - 0.5, transform: nil))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawBadge(_ ctx: CGContext, count: Int, topRight: CGPoint) {
        let text = NSAttributedString(string: "\(count)", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.white,
        ])
        let ts = text.size()
        let h: CGFloat = 22
        let w = max(h, ceil(ts.width) + 12)
        let r = CGRect(x: topRight.x - w, y: topRight.y - h, width: w, height: h)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -2, dy: -2), cornerWidth: h / 2 + 2, cornerHeight: h / 2 + 2, transform: nil))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
        ctx.setFillColor(ShelfStyle.badge.cgColor)
        ctx.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        text.draw(at: CGPoint(x: r.midX - ts.width / 2, y: r.midY - ts.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func render(size: CGSize, scale: CGFloat, _ draw: (CGContext) -> Void) -> NSImage {
        let pw = Int(ceil(size.width * scale)), ph = Int(ceil(size.height * scale))
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return NSImage(size: size) }
        ctx.scaleBy(x: scale, y: scale)
        draw(ctx)
        guard let cg = ctx.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: cg, size: size)
    }
}
