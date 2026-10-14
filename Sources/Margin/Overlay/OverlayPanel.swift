import AppKit

/// One borderless full-screen panel per display, above the shelf, on every Space.
final class OverlayPanel: NSPanel {
    private(set) var display: DisplayInfo
    let overlayView: OverlayView

    init(display: DisplayInfo) {
        self.display = display
        overlayView = OverlayView(display: display)
        super.init(contentRect: display.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Explicit, so the transparent panel still takes every click before the frozen image arrives.
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
        // The session sets the cursor itself (crosshair, resize, hand); keep AppKit's cursor rects out of it.
        disableCursorRects()
        contentView = overlayView
        setFrame(display.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Borderless panels may cover the menu bar and the notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func update(display: DisplayInfo) {
        self.display = display
        overlayView.display = display
        setFrame(display.frame, display: false)
    }
}

/// Overlay panels are made once (at prewarm) and reused, so the hotkey path only orders them in.
/// Owning these windows also keeps Margin listed in SCShareableContent, which the exclusion filter needs.
@MainActor
final class OverlayPanelPool {
    private(set) var panels: [CGDirectDisplayID: OverlayPanel] = [:]

    /// Matches the panels to the current displays.
    func sync() {
        let displays = Displays.all
        for (id, panel) in panels where !displays.contains(where: { $0.id == id }) {
            panel.orderOut(nil)
            panel.close()
            panels[id] = nil
        }
        for d in displays {
            if let panel = panels[d.id] {
                if panel.display != d { panel.update(display: d) }
            } else {
                panels[d.id] = OverlayPanel(display: d)
            }
        }
    }

    /// Orders every panel in once, invisible and click-through, so the window server has their
    /// surfaces before the first ⌘⇧4 (that first order-in otherwise costs ~25 ms).
    func warmUp() {
        for panel in panels.values where !panel.isVisible {
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
            panel.overlayView.warmUp()
            panel.displayIfNeeded()
            panel.orderOut(nil)
            panel.ignoresMouseEvents = false
            panel.alphaValue = 1
        }
    }

    /// Panels for the given displays, in the same order.
    func panels(for displays: [DisplayInfo]) -> [OverlayPanel] {
        displays.compactMap { panels[$0.id] }
    }
}
