import CoreGraphics

/// What window mode and snapping (spec §2) make of each on-screen window, front to back: the window under the pointer is
/// the first whose frame holds it, so a floating window (a utility panel, Picture in Picture, an "always on top"
/// window) is picked over the normal window behind it, and system UI in front of the windows hides them.
public enum WindowPicking {
    public enum Role: Equatable, Sendable {
        /// Window mode can pick it, and selections snap to its edges: normal windows (layer 0) and the ones floating
        /// above them below the Dock's level (floating panels 3, modal panels 8, utility windows 19).
        case pickable
        /// System UI from the Dock's level up to below the pop-up menu level (the Dock 20, notification banners 21,
        /// the menu bar 24, status items 25): it isn't picked, but the pointer over it picks nothing, never the window
        /// behind it.
        case cover
        /// Not looked at: menus and everything above them (Margin's own capture UI among them, which isn't in the
        /// frozen frame), and a window above layer 0 that's bigger than its display or covers all of it, which is an
        /// overlay (usually see-through, such as a floating companion's canvas), not a window anyone sees whole.
        case ignored
    }

    public static let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
    public static let popUpMenuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))

    /// `frame` and `displays` in the same global coordinates (either flip).
    public static func role(layer: Int, frame: CGRect, displays: [CGRect]) -> Role {
        guard layer >= 0, layer < popUpMenuLevel else { return .ignored }
        guard layer > 0 else { return .pickable }
        if isOverlay(frame, displays: displays) { return .ignored }
        return layer < dockLevel ? .pickable : .cover
    }

    /// Bigger than the display that holds most of it, in either direction, or as big as it in both; or on none.
    static func isOverlay(_ frame: CGRect, displays: [CGRect]) -> Bool {
        let area = { (r: CGRect) in r.isNull ? 0 : r.width * r.height }
        guard let display = displays.max(by: { area($0.intersection(frame)) < area($1.intersection(frame)) }),
              area(display.intersection(frame)) > 0
        else { return true }
        let tolerance: CGFloat = 1
        let exceeds = frame.width > display.width + tolerance || frame.height > display.height + tolerance
        let covers = frame.width >= display.width - tolerance && frame.height >= display.height - tolerance
        return exceeds || covers
    }
}
