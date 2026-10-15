import AppKit
import QuartzCore

/// The capture flies from the selection to its slot in a temporary transparent panel, then hands off to
/// the real card. About 0.45 s, spring with a slight overshoot. The shelf keeps one per shot in the air
/// and calls `retarget` whenever the destination moves (another capture pushes the card up, ⌘⇧1 tucks
/// the shelf, a peek slides it in), so the shot always lands where its card really is.
@MainActor
final class ShelfFlight {
    enum Landing {
        /// Lands as the card, in its slot.
        case card
        /// Shrinks into the tuck tab and fades.
        case tab
        /// Shrinks into the `+N older` pile and fades.
        case pile

        var absorbs: Bool { self != .card }
    }

    private(set) var landing: Landing
    private let panel: NSPanel
    /// The panel's frame (global points): the start, the first target and the whole shelf, so later targets fit.
    private let area: CGRect
    private let shell = CALayer.shelfQuiet()
    private let img = CALayer.shelfQuiet()
    private let ring = CALayer.shelfQuiet()
    private var target: CGRect
    private var handoff: Task<Void, Never>?
    private var onLand: ((Landing) -> Void)?
    private var finished = false

    /// Starts a flight from `from` to `to` (AppKit global points). `shelf` is the shelf's whole frame on
    /// screen, so a later target inside it needs no new panel. When there's nothing to animate, calls
    /// `onLand` right away and returns nil.
    static func start(image: CGImage, from: CGRect, to: CGRect, landing: Landing, shelf: CGRect,
                      onLand: @escaping @MainActor (Landing) -> Void) -> ShelfFlight? {
        guard from.width >= 2, from.height >= 2, to.width >= 2 else { onLand(landing); return nil }
        return ShelfFlight(image: image, from: from, to: to, landing: landing, shelf: shelf, onLand: onLand)
    }

    private init(image: CGImage, from: CGRect, to: CGRect, landing: Landing, shelf: CGRect,
                 onLand: @escaping @MainActor (Landing) -> Void) {
        self.landing = landing
        self.target = to
        self.onLand = onLand
        var area = from.union(to)
        if shelf.width > 0 { area = area.union(shelf) }
        area = area.insetBy(dx: -60, dy: -60)
        self.area = area

        panel = FlightPanels.take(area)

        // shell: shadow + ring; img: rounded, aspect-filled.
        let start = local(from)
        shell.bounds = CGRect(origin: .zero, size: start.size)
        shell.position = CGPoint(x: start.midX, y: start.midY)
        shell.shadowColor = NSColor.black.cgColor
        shell.shadowOpacity = 0.5
        shell.shadowRadius = 20
        shell.shadowOffset = CGSize(width: 0, height: -16)
        shell.cornerCurve = .continuous
        img.frame = shell.bounds
        img.contents = image
        img.contentsGravity = .resizeAspectFill
        img.masksToBounds = true
        img.cornerCurve = .continuous
        img.contentsScale = panel.backingScaleFactor
        ring.frame = shell.bounds
        ring.borderColor = ShelfStyle.ring.cgColor
        ring.borderWidth = 2
        ring.cornerCurve = .continuous
        shell.addSublayer(img)
        shell.addSublayer(ring)
        panel.contentView?.layer?.addSublayer(shell)

        panel.orderFrontRegardless()
        fly(from: start, to: to, duration: 0.45, bounce: landing.absorbs ? 0.05 : 0.22, fadeDelay: 0.3)
    }

    /// Re-aims a flight in the air from wherever it is now. A target off this panel lands at once.
    func retarget(to rect: CGRect, landing: Landing) {
        guard !finished else { return }
        guard rect != target || landing != self.landing else { return }
        guard rect.width >= 2, area.contains(rect) else {
            self.landing = landing
            land()
            return
        }
        let p = shell.presentation() ?? shell
        let now = CGRect(x: p.position.x - p.bounds.width / 2, y: p.position.y - p.bounds.height / 2,
                         width: p.bounds.width, height: p.bounds.height)
        self.landing = landing
        fly(from: now, to: rect, duration: 0.35, bounce: landing.absorbs ? 0.05 : 0.15, fadeDelay: 0.12)
    }

    /// Another image of the same shot, in place of this one from now on (window mode's stand-in giving way to the shot).
    func replaceImage(_ image: CGImage) {
        guard !finished else { return }
        img.contents = image
    }

    /// The shot left the shelf mid-flight: the flyer fades away and nothing lands.
    func cancel() {
        guard !finished else { return }
        finished = true
        handoff?.cancel()
        onLand = nil
        ShelfMotion.fade(shell, to: 0, duration: 0.15)
        ShelfMotion.after(0.17) { [panel, shell] in FlightPanels.giveBack(panel, emptying: shell) }
    }

    // MARK: - Private

    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -area.minX, dy: -area.minY) }

    /// Springs from `start` (panel-local) to `to` (global), then hands off once it has visibly settled.
    private func fly(from start: CGRect, to: CGRect, duration: CFTimeInterval, bounce: CGFloat, fadeDelay: CFTimeInterval) {
        target = to
        var end = local(to)
        if landing.absorbs {
            // Land as a small chip in the middle of the tab or pile.
            let w: CGFloat = 18, h: CGFloat = 14
            end = CGRect(x: end.midX - w / 2, y: end.midY - h / 2, width: w, height: h)
        }
        let fromRadius = (img.presentation() ?? img).cornerRadius
        let radius: CGFloat = landing.absorbs ? 4 : ShelfStyle.cornerRadius

        // Final model values.
        shell.bounds = CGRect(origin: .zero, size: end.size)
        shell.position = CGPoint(x: end.midX, y: end.midY)
        img.frame = shell.bounds
        ring.frame = shell.bounds
        img.cornerRadius = radius
        ring.cornerRadius = radius

        func spring(_ key: String, _ a: NSValue, _ b: NSValue) -> CASpringAnimation {
            ShelfMotion.spring(key, from: a, to: b, duration: duration, bounce: bounce)
        }
        shell.add(spring("position", NSValue(point: CGPoint(x: start.midX, y: start.midY)), NSValue(point: CGPoint(x: end.midX, y: end.midY))), forKey: "position")
        shell.add(spring("bounds.size", NSValue(size: start.size), NSValue(size: end.size)), forKey: "size")
        for l in [img, ring] {
            l.add(spring("bounds.size", NSValue(size: start.size), NSValue(size: end.size)), forKey: "size")
            l.add(spring("position", NSValue(point: CGPoint(x: start.width / 2, y: start.height / 2)), NSValue(point: CGPoint(x: end.width / 2, y: end.height / 2))), forKey: "position")
            l.add(ShelfMotion.basic("cornerRadius", from: fromRadius, to: radius, duration: 0.3, curve: .easeOut), forKey: "radius")
        }
        shell.removeAnimation(forKey: "fade")
        shell.opacity = 1
        if landing.absorbs {
            let fade = ShelfMotion.basic("opacity", from: 1, to: 0, duration: 0.18, curve: .easeIn)
            fade.beginTime = CACurrentMediaTime() + fadeDelay
            fade.fillMode = .both
            fade.isRemovedOnCompletion = false
            shell.add(fade, forKey: "fade")
        }

        // Hand off once the spring has visibly settled (well under a point of travel left).
        handoff?.cancel()
        handoff = ShelfMotion.after(landing.absorbs ? duration + 0.03 : duration + 0.17) { [weak self] in self?.land() }
    }

    private func land() {
        guard !finished else { return }
        finished = true
        handoff?.cancel()
        let done = onLand
        onLand = nil
        done?(landing)
        // One more frame so the real card is on screen before the flyer goes.
        ShelfMotion.after(0.03) { [panel, shell] in FlightPanels.giveBack(panel, emptying: shell) }
    }
}

/// The fly-in's panels, reused: making a new one for every shot cost the main thread 2–3 ms on the way to the
/// thumbnail's commit. A panel goes back empty and ordered out once its flyer has gone; shots in the air at once
/// each take their own.
@MainActor
private enum FlightPanels {
    private static var spare: [NSPanel] = []
    /// More than this many shots rarely fly at once; any extra panels are let go.
    private static let maxSpare = 2

    /// A panel over `frame` (global points), not yet on screen.
    static func take(_ frame: CGRect) -> NSPanel {
        guard let panel = spare.popLast() else { return make(frame) }
        panel.setFrame(frame, display: false)
        return panel
    }

    /// Ordered out, without the flyer's `layer`.
    static func giveBack(_ panel: NSPanel, emptying layer: CALayer) {
        panel.orderOut(nil)
        layer.removeFromSuperlayer()
        if spare.count < maxSpare { spare.append(panel) }
    }

    private static func make(_ frame: CGRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let content = NSView(frame: CGRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        panel.contentView = content
        panel.setFrame(frame, display: false)
        return panel
    }
}
