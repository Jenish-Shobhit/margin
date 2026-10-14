import AppKit
import CoreGraphics
import MarginKit
import Observation

/// Live state of the three first-run steps, refreshed once a second while the window is open.
@MainActor @Observable
final class FirstRunModel {
    typealias Step = FirstRunWindowController.Step
    enum StepState { case done, now, pending }

    static let screenRecordingSettings = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")!
    static let keyboardSettings = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

    /// Screen Recording works: preflight says yes and no capture has failed for lack of permission since launch.
    private(set) var hasPermission = false
    /// A capture failed for lack of permission since launch (`RuntimeStatus.screenRecordingRevoked`).
    /// `CGPreflightScreenCaptureAccess` is cached per process and can still say yes, so only a relaunch
    /// (or a capture that works again) clears this.
    private(set) var permissionRevoked = false
    /// The user clicked "Allow…" in this session.
    private(set) var requestedPermission = false
    private(set) var shortcuts: [SystemScreenshotShortcut] = []
    /// IDs of enabled macOS shortcuts that take one of Margin's keys.
    private(set) var conflictIDs: Set<Int> = []
    private(set) var areaShortcut = ShortcutAction.captureArea.defaultCombo.displayString
    private(set) var launchAtLogin = true
    var capturedOnce = false
    /// Brief "You're set" state before the window closes.
    var finished = false
    /// The step the window was opened at (`show(step:)`), while it's still incomplete.
    var focus: Step?

    // Sources, swappable for visual checks.
    @ObservationIgnored var preflight: () -> Bool = { CGPreflightScreenCaptureAccess() }
    @ObservationIgnored var revoked: () -> Bool = { RuntimeStatus.shared.screenRecordingRevoked }
    @ObservationIgnored var request: () -> Void = { _ = CGRequestScreenCaptureAccess() }
    @ObservationIgnored var readShortcuts: () -> [SystemScreenshotShortcut] = { SystemShortcuts.current() }
    @ObservationIgnored var prefs: Preferences = .shared

    var permissionDone: Bool { !permissionRevoked && (hasPermission || capturedOnce) }
    var shortcutsDone: Bool { !shortcuts.isEmpty && conflictIDs.isEmpty }
    var allDone: Bool { permissionDone && shortcutsDone && capturedOnce }

    /// The enabled macOS shortcuts that still take one of Margin's keys, as shown in System Settings ("⇧⌘4").
    var systemKeysStillOn: [String] {
        shortcuts.filter { conflictIDs.contains($0.id) }.map(\.keys)
    }

    /// The gentle line on "You're set" while macOS still owns some of Margin's keys.
    var stillOnNote: String? {
        let keys = systemKeysStillOn
        guard !keys.isEmpty else { return nil }
        let list = ListFormatter.localizedString(byJoining: keys)
        return "macOS still uses \(list) — you can turn \(keys.count == 1 ? "it" : "them") off any time from the menu bar."
    }

    func isDone(_ step: Step) -> Bool {
        switch step {
        case .permission: permissionDone
        case .shortcuts: shortcutsDone
        case .firstShot: capturedOnce
        }
    }

    /// The step being worked on: the requested one while it's incomplete, else the first incomplete one.
    var current: Step? {
        if let focus, !isDone(focus) { return focus }
        return Step.allCases.first { !isDone($0) }
    }

    func state(of step: Step) -> StepState {
        if finished || isDone(step) { return .done }
        return step == current ? .now : .pending
    }

    func refresh() {
        permissionRevoked = revoked()
        hasPermission = preflight() && !permissionRevoked
        shortcuts = readShortcuts()
        conflictIDs = Set(SystemShortcuts.conflicts(shortcuts, with: prefs.registeredCombos().map(\.combo)).map(\.id))
        areaShortcut = prefs.shortcut(for: .captureArea).displayString
        launchAtLogin = prefs.launchAtLogin
    }

    // MARK: Actions

    func requestPermission() {
        request()
        requestedPermission = true
        refresh()
    }

    func openScreenRecordingSettings() { NSWorkspace.shared.open(Self.screenRecordingSettings) }
    func openKeyboardSettings() { NSWorkspace.shared.open(Self.keyboardSettings) }
}

extension FirstRunWindowController.Step: CaseIterable {
    static var allCases: [Self] { [.permission, .shortcuts, .firstShot] }
}
