import Foundation

/// Whether the menu bar icon shows, and how hiding it and bringing it back work (Hide from Menu Bar, spec §6).
///
/// Hiding asks once (a confirmation saying how to come back, with "Don't show this again"). Opening Margin again while
/// it runs (Spotlight, Finder, Launchpad) brings the icon back. A hidden icon never strands the user: while something
/// needs attention (Screen Recording missing, a shortcut that didn't register) it can't be hidden, and one hidden earlier
/// comes back with its warning dot. A recording shows it for as long as it runs (its timer and Stop are there), without
/// changing the choice. Pure value state; `Preferences` keeps `hidden` and `skipsConfirmation`.
public struct MenuBarIconPolicy: Equatable, Sendable {
    /// What a hide request does.
    public enum HideStep: Equatable, Sendable {
        /// Ask first (the confirmation with "Don't show this again").
        case confirm
        /// Hide at once (the user chose not to be asked again).
        case hide
        /// Keep the icon: it's already hidden, or something needs attention.
        case refuse
    }

    public private(set) var hidden: Bool
    public private(set) var skipsConfirmation: Bool

    public init(hidden: Bool = false, skipsConfirmation: Bool = false) {
        self.hidden = hidden
        self.skipsConfirmation = skipsConfirmation
    }

    /// Whether the status item shows right now: the user's choice, except during a recording.
    public func isShown(recording: Bool) -> Bool { !hidden || recording }

    /// The user chose Hide from Menu Bar (the menu item or the Settings switch).
    public func hideStep(needsAttention: Bool) -> HideStep {
        guard !hidden, !needsAttention else { return .refuse }
        return skipsConfirmation ? .hide : .confirm
    }

    /// The user confirmed (or wasn't asked). `dontAskAgain`: the confirmation's checkbox.
    public mutating func hide(dontAskAgain: Bool) {
        hidden = true
        if dontAskAgain { skipsConfirmation = true }
    }

    /// The Settings switch turned the icon back on, or Margin was opened again while running. Returns true when it
    /// changed.
    @discardableResult
    public mutating func show() -> Bool {
        guard hidden else { return false }
        hidden = false
        return true
    }

    /// Something needs attention now (or no longer does). Returns true when this brought a hidden icon back.
    public mutating func attentionChanged(_ needsAttention: Bool) -> Bool {
        needsAttention ? show() : false
    }
}
