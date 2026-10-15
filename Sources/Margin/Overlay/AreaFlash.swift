import AppKit

/// Briefly outlines a captured area (⌘⇧2), in a click-through panel. Shown only after the capture,
/// and Margin is excluded from every capture anyway.
///
/// One panel, made on first use and moved to each area, with the outline as two layer borders. A new panel each time
/// cost the main thread ≈ 4 ms, and a view stroking the outline drew it on the CPU into a backing store the size of
/// the area (≈ 4.4 ms for 1200 × 800 pt), both before the shot's thumbnail could be committed.
@MainActor
enum AreaFlash {
    static let duration: Duration = .milliseconds(150)
    private static let pad: CGFloat = 3
    private static var panel: NSPanel?
    /// A dark hairline outside a white 2 pt line, so it reads on light and dark content.
    private static let outer = outline(width: 1, color: NSColor(white: 0, alpha: 0.35))
    private static let inner = outline(width: 2, color: .white)
    /// Counts flashes, so only the last one's timer takes the outline down.
    private static var flashes = 0

    /// `rect`: AppKit global points.
    static func show(_ rect: CGRect) {
        let frame = rect.insetBy(dx: -pad, dy: -pad)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(frame, display: false)
        let bounds = CGRect(origin: .zero, size: frame.size)
        outer.frame = bounds                            // the outermost point
        inner.frame = bounds.insetBy(dx: 1, dy: 1)      // the 2 pt inside it
        CATransaction.commit()
        // Committed before the panel comes up, so it never shows the last area's outline.
        CATransaction.flush()
        panel.orderFrontRegardless()
        flashes += 1
        let flash = flashes
        Task { @MainActor in
            try? await Task.sleep(for: duration)
            guard flash == flashes else { return }
            panel.orderOut(nil)
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let content = NSView()
        content.wantsLayer = true
        content.layer?.addSublayer(outer)
        content.layer?.addSublayer(inner)
        panel.contentView = content
        return panel
    }

    private static func outline(width: CGFloat, color: NSColor) -> CALayer {
        let layer = CALayer()
        layer.borderWidth = width
        layer.borderColor = color.cgColor
        return layer
    }
}
