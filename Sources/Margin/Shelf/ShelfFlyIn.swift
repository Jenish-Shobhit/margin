import AppKit
import QuartzCore

/// The capture flies from the selection to its slot in a temporary transparent panel,
/// then hands off to the real card. About 0.45 s, spring with a slight overshoot.
@MainActor
enum ShelfFlyIn {
    private static var live: Set<NSPanel> = []

    /// `from` and `to` are AppKit global points. `intoTab` shrinks and fades into the tuck tab instead.
    static func run(image: CGImage, from: CGRect, to: CGRect, intoTab: Bool, completion: @escaping @MainActor () -> Void) {
        guard from.width >= 2, from.height >= 2, to.width >= 2 else { completion(); return }
        let margin: CGFloat = 60
        let area = from.union(to).insetBy(dx: -margin, dy: -margin)

        let panel = NSPanel(contentRect: area, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let content = NSView(frame: CGRect(origin: .zero, size: area.size))
        content.wantsLayer = true
        panel.contentView = content
        panel.setFrame(area, display: false)
        guard let root = content.layer else { completion(); return }

        func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -area.minX, dy: -area.minY) }
        let start = local(from)
        var end = local(to)
        if intoTab {
            // Land as a small chip in the middle of the tab.
            let w: CGFloat = 18, h: CGFloat = 14
            end = CGRect(x: end.midX - w / 2, y: end.midY - h / 2, width: w, height: h)
        }

        // shell: shadow + ring; img: rounded, aspect-filled.
        let shell = CALayer.shelfQuiet()
        shell.bounds = CGRect(origin: .zero, size: start.size)
        shell.position = CGPoint(x: start.midX, y: start.midY)
        shell.shadowColor = NSColor.black.cgColor
        shell.shadowOpacity = 0.5
        shell.shadowRadius = 20
        shell.shadowOffset = CGSize(width: 0, height: -16)
        shell.cornerCurve = .continuous
        let img = CALayer.shelfQuiet()
        img.frame = shell.bounds
        img.contents = image
        img.contentsGravity = .resizeAspectFill
        img.masksToBounds = true
        img.cornerCurve = .continuous
        img.contentsScale = panel.backingScaleFactor
        let ring = CALayer.shelfQuiet()
        ring.frame = shell.bounds
        ring.borderColor = ShelfStyle.ring.cgColor
        ring.borderWidth = 2
        ring.cornerCurve = .continuous
        shell.addSublayer(img)
        shell.addSublayer(ring)
        root.addSublayer(shell)

        panel.orderFrontRegardless()
        live.insert(panel)

        // Final model values.
        let radius: CGFloat = intoTab ? 4 : ShelfStyle.cornerRadius
        shell.bounds = CGRect(origin: .zero, size: end.size)
        shell.position = CGPoint(x: end.midX, y: end.midY)
        img.frame = shell.bounds
        ring.frame = shell.bounds
        img.cornerRadius = radius
        ring.cornerRadius = radius

        let duration: CFTimeInterval = 0.45
        let bounce: CGFloat = intoTab ? 0.05 : 0.22
        let pos = ShelfMotion.spring("position", from: NSValue(point: CGPoint(x: start.midX, y: start.midY)), to: NSValue(point: CGPoint(x: end.midX, y: end.midY)), duration: duration, bounce: bounce)
        let size = ShelfMotion.spring("bounds.size", from: NSValue(size: start.size), to: NSValue(size: end.size), duration: duration, bounce: bounce)
        shell.add(pos, forKey: "position")
        shell.add(size, forKey: "size")
        for l in [img, ring] {
            l.add(ShelfMotion.spring("bounds.size", from: NSValue(size: start.size), to: NSValue(size: end.size), duration: duration, bounce: bounce), forKey: "size")
            l.add(ShelfMotion.spring("position", from: NSValue(point: CGPoint(x: start.width / 2, y: start.height / 2)), to: NSValue(point: CGPoint(x: end.width / 2, y: end.height / 2)), duration: duration, bounce: bounce), forKey: "position")
            l.add(ShelfMotion.basic("cornerRadius", from: 0, to: radius, duration: 0.3, curve: .easeOut), forKey: "radius")
        }
        if intoTab {
            let fade = ShelfMotion.basic("opacity", from: 1, to: 0, duration: 0.18, curve: .easeIn)
            fade.beginTime = CACurrentMediaTime() + 0.3
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            shell.add(fade, forKey: "fade")
        }

        // Hand off once the spring has visibly settled (well under a point of travel left).
        let handoff = intoTab ? 0.48 : 0.62
        ShelfMotion.after(handoff) {
            completion()
            // One more frame so the real card is on screen before the flyer goes.
            ShelfMotion.after(0.03) {
                panel.orderOut(nil)
                live.remove(panel)
            }
        }
    }
}
