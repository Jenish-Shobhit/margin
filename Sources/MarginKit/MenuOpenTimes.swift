import Foundation

/// When Margin last had a menu open, in event time (seconds since startup, as Carbon's `GetEventTime` counts it).
///
/// While a menu is open (the menu bar icon's, a card's), AppKit holds Carbon hotkey events back and delivers them once
/// it closes, so a shortcut pressed with the menu open would fire late: ⇧⌘3 pressed there captured the screen as the
/// menu closed, with Settings opening, say. `HotkeyCenter` drops a press made while a menu was open instead, so it does
/// nothing (spec §6).
public struct MenuOpenTimes: Sendable {
    /// Menus open now: one inside another counts once.
    private var depth = 0
    private var openedAt: TimeInterval?
    private var closedAt: TimeInterval?

    public init() {}

    public mutating func menuOpened(at time: TimeInterval) {
        if depth == 0 {
            openedAt = time
            closedAt = nil
        }
        depth += 1
    }

    public mutating func menuClosed(at time: TimeInterval) {
        guard depth > 0 else { return }
        depth -= 1
        if depth == 0 { closedAt = time }
    }

    /// Whether a key pressed at `time` was pressed while the last menu was open. Only once that menu has closed: a
    /// hotkey that arrives while one is still open wasn't held back by it, so it goes through, and a close that never
    /// came can't swallow every shortcut.
    public func held(_ time: TimeInterval) -> Bool {
        guard let openedAt, let closedAt else { return false }
        return openedAt <= time && time <= closedAt
    }
}
