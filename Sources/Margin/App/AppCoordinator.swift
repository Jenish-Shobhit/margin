import AppKit
import MarginKit
import os

/// Owns the app's parts and wires them together: capture → save/copy → shelf, the ⌘V mark,
/// permission state, the menu bar and the global hotkeys.
@MainActor
final class AppCoordinator {
    nonisolated static let subsystem = "io.github.jenish-shobhit.margin"
    nonisolated static let log = Logger(subsystem: subsystem, category: "app")
    nonisolated static let timingLog = Logger(subsystem: subsystem, category: "timing")
    nonisolated static let signposter = OSSignposter(logger: timingLog)

    let prefs = Preferences.shared
    let store: ShelfStore
    let shelf: ShelfController
    let capture: CaptureController
    private var menuBar: StatusMenuController?
    private var hotkeys: HotkeyCenter?
    private var pasteboardTimer: Timer?
    #if DEBUG
    private var debugListener: DebugCommandListener?
    #endif

    /// Which shelf item's image is on the clipboard.
    var mark = ClipboardMark()
    /// Last known Screen Recording state (`CGPreflightScreenCaptureAccess`). Never requests access.
    private(set) var permissionGranted = false

    // Save pipeline state (see AppCoordinator+Save.swift).
    /// Every path handed to the shelf this session, so two captures in the same second never get
    /// the same name (names have one-second resolution, so this stays small).
    var reservedPaths: Set<String> = []
    /// Increments per capture; only the newest capture may overwrite the clipboard.
    var captureSequence = 0
    var lastClipboardSequence = 0
    /// Timings of the most recent capture, for the log and the DEBUG state dump.
    var lastTimings: Timings?
    var lastSavedPath: String?
    /// The last action a global hotkey fired (for the DEBUG state dump).
    private(set) var lastHotkeyAction: ShortcutAction?
    var hotkeyRegistrations: [(binding: HotkeyCenter.Binding, status: OSStatus)] {
        hotkeys?.registrationSummary ?? []
    }
    /// Shortcuts that didn't register (also in `RuntimeStatus.hotkeyFailures`), for the menu bar warning.
    var hotkeyFailures: [HotkeyCenter.Failure] { hotkeys?.failures ?? [] }

    init() {
        store = ShelfStore(fileURL: ShelfStore.defaultFileURL)
        shelf = ShelfController(store: store)
        capture = CaptureController()
    }

    // MARK: - Lifecycle

    func start() {
        shelf.restore()

        capture.onCapture = { [weak self] result in self?.handleCapture(result) }
        capture.onPermissionMissing = { [weak self] in self?.permissionMissing() }
        shelf.onCopied = { [weak self] id, changeCount in self?.shelfDidCopy(id, changeCount: changeCount) }
        shelf.onRemoved = { [weak self] ids in self?.shelfDidRemove(ids) }
        FirstRunWindowController.shared.onRelaunch = { [weak self] in self?.relaunch() }

        let menuBar = StatusMenuController(coordinator: self)
        self.menuBar = menuBar

        let hotkeys = HotkeyCenter { [weak self] action in
            self?.lastHotkeyAction = action
            self?.perform(action)
        }
        // Assigned before `start()`, so the menu can read the failures when the first registration posts them.
        self.hotkeys = hotkeys
        hotkeys.start()

        permissionGranted = CGPreflightScreenCaptureAccess()
        menuBar.setWarning(!permissionGranted)
        if !prefs.firstRunDone || !permissionGranted {
            FirstRunWindowController.shared.show()
        }
        if permissionGranted {
            Task { await capture.prewarm() }
        }
        enableLoginItemOnFirstLaunch()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        pasteboardTimer = timer

        #if DEBUG
        debugListener = DebugCommandListener(coordinator: self)
        #endif
        Self.log.notice("Margin started (permission \(self.permissionGranted ? "granted" : "missing", privacy: .public))")
    }

    func stop() {
        hotkeys?.stop()
        pasteboardTimer?.invalidate()
        pasteboardTimer = nil
    }

    /// Margin was opened again while running: show whatever needs attention, otherwise Settings.
    func handleReopen() {
        refreshPermission()
        if !permissionGranted {
            showPermissionStep()
        } else {
            showSettings()
        }
    }

    // MARK: - Actions (hotkeys, menu, DEBUG hook)

    func perform(_ action: ShortcutAction) {
        switch action {
        case .captureArea: captureArea()
        case .captureScreen: captureScreen()
        case .repeatArea: repeatArea()
        case .toggleShelf: shelf.toggleTucked()
        }
    }

    /// ⌘⇧4. Space switches to window mode from inside it.
    func captureArea() {
        guard canStartCapture() else { return }
        capture.beginInteractiveCapture()
    }

    /// Menu "Capture Window": the interactive capture, starting in window mode.
    func captureWindow() {
        guard canStartCapture() else { return }
        capture.beginWindowCapture()
    }

    func captureScreen() {
        guard canStartCapture() else { return }
        capture.captureScreenUnderPointer()
    }

    func repeatArea() {
        guard canStartCapture() else { return }
        capture.repeatLastArea()
    }

    /// DEBUG hook: a rect in AppKit global points, no overlay.
    func captureRect(_ rect: CGRect) {
        guard canStartCapture() else { return }
        capture.captureArea(rect)
    }

    func toggleShelf() { shelf.toggleTucked() }

    /// DEBUG `clear`: everything off the shelf (undoable).
    func clearShelf() { shelf.clear() }

    /// Creates the folder if it's missing, then opens it in Finder. The first touch of ~/Desktop can block
    /// on the Desktop-folder privacy prompt, so the file system is only touched off the main actor.
    func openScreenshotsFolder() {
        let folder = prefs.saveFolder
        Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                Self.log.error("Can't create the screenshots folder: \(error.localizedDescription, privacy: .public)")
            }
            await MainActor.run {
                if !NSWorkspace.shared.open(folder) { NSSound.beep() }
            }
        }
    }

    func showSettings() {
        NSApp.activate()
        SettingsWindowController.shared.show()
    }

    func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    func showPermissionStep() {
        NSApp.activate()
        FirstRunWindowController.shared.show(step: .permission)
    }

    /// Menu "macOS still uses ⇧⌘4 — Fix…": First run step 2, the live checklist of macOS's shortcuts.
    func showShortcutsStep() {
        NSApp.activate()
        FirstRunWindowController.shared.show(step: .shortcuts)
    }

    func quit() { NSApp.terminate(nil) }

    var isShelfTucked: Bool { shelf.isTucked }

    // MARK: - Permission

    /// Never prompts: without permission, show First run step 1 instead of touching ScreenCaptureKit.
    private func canStartCapture() -> Bool {
        if capture.isCapturing { return false }
        if !permissionGranted { refreshPermission() }
        guard permissionGranted else {
            permissionMissing()
            return false
        }
        return true
    }

    /// Re-reads the permission. Called once a second while it's missing, and when the menu opens.
    func refreshPermission() {
        let granted = CGPreflightScreenCaptureAccess()
        guard granted != permissionGranted else { return }
        permissionGranted = granted
        menuBar?.setWarning(!granted)
        if granted {
            Self.log.notice("Screen Recording permission granted")
            Task { await capture.prewarm() }
        }
    }

    private func permissionMissing() {
        Self.log.notice("Screen Recording permission missing")
        permissionGranted = false
        menuBar?.setWarning(true)
        showPermissionStep()
    }

    // MARK: - ⌘V mark

    private func tick() {
        if mark.observe(changeCount: NSPasteboard.general.changeCount) {
            shelf.setClipboardMark(nil)
        }
        if !permissionGranted { refreshPermission() }
    }

    private func shelfDidCopy(_ id: UUID, changeCount: Int) {
        // A deliberate copy from the shelf wins over any capture still being encoded.
        lastClipboardSequence = captureSequence
        mark.didWrite(itemID: id, changeCount: changeCount)
        shelf.setClipboardMark(id)
    }

    private func shelfDidRemove(_ ids: [UUID]) {
        for id in ids { mark.itemRemoved(id) }
    }

    // MARK: - Relaunch, login item

    /// First run's "Relaunch Margin": start a fresh copy once this one has quit, then quit.
    private func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else {
            Self.log.error("Relaunch needs an app bundle; quitting instead")
            NSApp.terminate(nil)
            return
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 0.7; /usr/bin/open -n \"$1\"", "margin-relaunch", bundlePath]
        do {
            try shell.run()
        } catch {
            Self.log.error("Relaunch failed: \(error.localizedDescription, privacy: .public)")
        }
        NSApp.terminate(nil)
    }

    private static let loginItemConfiguredKey = "loginItemConfigured"

    /// Launch at login defaults to on: register once, on the first launch from /Applications
    /// (never for a dev copy elsewhere, which would leave a stale login item behind).
    private func enableLoginItemOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.loginItemConfiguredKey) else { return }
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        defaults.set(true, forKey: Self.loginItemConfiguredKey)
        guard prefs.launchAtLogin else { return }
        LoginItem.setEnabled(true)
        if LoginItem.requiresApproval {
            Self.log.notice("Launch at login needs approval in System Settings › General › Login Items")
        } else {
            Self.log.notice("Launch at login \(LoginItem.isEnabled ? "registered" : "not registered", privacy: .public)")
        }
    }
}
