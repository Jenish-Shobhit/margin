import AppKit
import QuartzCore

/// Sizes, colors and motion for the shelf. Values follow `dev_artifacts/ideation_v2.1.html`.
@MainActor
enum ShelfStyle {
    static let cornerRadius: CGFloat = 10
    /// Room left of the cards for the peek shift (tab width + gap). Transparent otherwise.
    static let leftPad: CGFloat = 28
    /// Room above the top element for toasts and the pile fan.
    static let headroom: CGFloat = 64
    static let tabWidth: CGFloat = 22
    static let tabHeight: CGFloat = 86
    static let tabBottom: CGFloat = 40

    /// #a5a1ff — new-card ring and selection ring.
    static let ring = NSColor(srgbRed: 0xA5 / 255, green: 0xA1 / 255, blue: 0xFF / 255, alpha: 1)
    /// #5a54f0 — ⌘V pill and selection check.
    static let accent = NSColor(srgbRed: 0x5A / 255, green: 0x54 / 255, blue: 0xF0 / 255, alpha: 1)
    /// #ff3b30 — drag count badge.
    static let badge = NSColor(srgbRed: 1, green: 0x3B / 255, blue: 0x30 / 255, alpha: 1)
    /// rgba(28,28,32,.88) — hover chips.
    static let chip = NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 32 / 255, alpha: 0.88)

    /// Overrides for QA (DEBUG hook / demo harness); nil follows System Settings › Accessibility.
    static var reduceMotionOverride: Bool?
    static var reduceTransparencyOverride: Bool?
    static var reduceMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var reduceTransparency: Bool { reduceTransparencyOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }

    static let metaFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
}

/// Spring and curve helpers. Every animation is explicit; shelf layers have no implicit actions.
@MainActor
enum ShelfMotion {
    /// Card moves: about 0.5 s with a slight overshoot (HTML: cubic-bezier(.2,.9,.3,1.12) over .5 s).
    static func spring(_ keyPath: String, from: Any?, to: Any?, duration: CFTimeInterval = 0.5, bounce: CGFloat = 0.2) -> CASpringAnimation {
        let a = CASpringAnimation(perceptualDuration: duration, bounce: bounce)
        a.keyPath = keyPath
        a.fromValue = from
        a.toValue = to
        a.duration = a.settlingDuration
        return a
    }

    static func basic(_ keyPath: String, from: Any?, to: Any?, duration: CFTimeInterval, curve: CAMediaTimingFunctionName = .easeInEaseOut) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: curve)
        return a
    }

    /// Sets `value` on the model and animates from the current presentation value.
    static func fade(_ layer: CALayer, to opacity: Float, duration: CFTimeInterval = 0.2) {
        let from = layer.presentation()?.opacity ?? layer.opacity
        layer.opacity = opacity
        guard from != opacity, duration > 0 else { return }
        layer.add(basic("opacity", from: from, to: opacity, duration: duration), forKey: "fade")
    }

    /// Spring the layer's transform to `transform` from where it is now.
    static func transform(_ layer: CALayer, to transform: CATransform3D, duration: CFTimeInterval = 0.45, bounce: CGFloat = 0.25) {
        let from = layer.presentation()?.transform ?? layer.transform
        layer.transform = transform
        if ShelfStyle.reduceMotion { layer.removeAnimation(forKey: "transform"); return }
        layer.add(spring("transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: transform), duration: duration, bounce: bounce), forKey: "transform")
    }

    /// Additive position spring: the layer appears to travel by `-delta` back to its model position.
    static func slide(_ layer: CALayer, from delta: CGPoint, duration: CFTimeInterval = 0.5, bounce: CGFloat = 0.2) {
        guard delta != .zero, !ShelfStyle.reduceMotion else { return }
        let a = spring("position", from: NSValue(point: delta), to: NSValue(point: .zero), duration: duration, bounce: bounce)
        a.isAdditive = true
        layer.add(a, forKey: nil)
    }

    /// Runs `body` on the main actor after `seconds`.
    @discardableResult
    static func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            body()
        }
    }
}

/// Disables implicit animations on the layers we manage by hand.
final class ShelfQuietLayerDelegate: NSObject, CALayerDelegate {
    nonisolated(unsafe) static let shared = ShelfQuietLayerDelegate()
    nonisolated func action(for layer: CALayer, forKey event: String) -> (any CAAction)? { NSNull() }
}

extension CALayer {
    /// A layer with no implicit animations.
    static func shelfQuiet() -> CALayer {
        let l = CALayer()
        l.delegate = ShelfQuietLayerDelegate.shared
        return l
    }
}

extension CALayer {
    /// A scale about the layer's center, whatever its anchor point (AppKit backing layers anchor at 0,0).
    func shelfCenteredScale(_ s: CGFloat) -> CATransform3D {
        let dx = (0.5 - anchorPoint.x) * bounds.width, dy = (0.5 - anchorPoint.y) * bounds.height
        var t = CATransform3DMakeTranslation(dx, dy, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -dx, -dy, 0)
    }
}

func shelfQuiet<L: CALayer>(_ layer: L) -> L {
    layer.delegate = ShelfQuietLayerDelegate.shared
    return layer
}

/// Frame-and-size math shared by cards, the drag image and the fly-in.
enum ShelfGeometry {
    /// The rect that covers `bounds` with an image of `size`, preserving aspect (aspect-fill).
    static func aspectFill(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let s = max(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }
}

/// Sendable wrapper for handing images between tasks.
struct ShelfImageBox: @unchecked Sendable {
    let image: CGImage
}
