import AppKit

/// Briefly outlines a captured area (⌘⇧2), in a click-through panel. Shown only after the capture,
/// and Margin is excluded from every capture anyway.
@MainActor
enum AreaFlash {
    static let duration: Duration = .milliseconds(150)
    private static let pad: CGFloat = 3

    /// `rect`: AppKit global points.
    static func show(_ rect: CGRect) {
        let frame = rect.insetBy(dx: -pad, dy: -pad)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = OutlineView(frame: CGRect(origin: .zero, size: frame.size))
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        Task { @MainActor in
            try? await Task.sleep(for: duration)
            panel.orderOut(nil)
            panel.close()
        }
    }

    private final class OutlineView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            // A dark hairline outside a white 2 pt line, so it reads on light and dark content.
            let outer = NSBezierPath(rect: bounds.insetBy(dx: AreaFlash.pad - 2.5, dy: AreaFlash.pad - 2.5))
            NSColor(white: 0, alpha: 0.35).setStroke()
            outer.lineWidth = 1
            outer.stroke()
            let inner = NSBezierPath(rect: bounds.insetBy(dx: AreaFlash.pad - 1, dy: AreaFlash.pad - 1))
            NSColor.white.setStroke()
            inner.lineWidth = 2
            inner.stroke()
        }
    }
}
