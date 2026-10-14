import AppKit

/// STUB — replaced by the Kit agent. Keep `shared`, `show(step:)`, `captureSucceeded()`, `onRelaunch`.
@MainActor
final class FirstRunWindowController {
    enum Step { case permission, shortcuts, firstShot }

    static let shared = FirstRunWindowController()

    /// Called when the user taps "Relaunch Margin" after granting permission.
    var onRelaunch: (() -> Void)?

    /// Shows the window at the first incomplete step (or `step` if given).
    func show(step: Step? = nil) {}
    /// The coordinator calls this after every successful capture; the window closes after the first.
    func captureSucceeded() {}
}
