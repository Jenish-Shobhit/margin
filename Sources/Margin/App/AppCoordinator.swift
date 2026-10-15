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
    /// The permission warning (dot, "Allow Screen Recording…") shows while preflight says no, and after a
    /// capture failed for lack of permission (`RuntimeStatus.screenRecordingRevoked`) until a capture
    /// succeeds or Margin relaunches: preflight is cached per process and often still says yes.
    var needsPermission: Bool { !permissionGranted || RuntimeStatus.shared.screenRecordingRevoked }

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
    /// Captures whose PNG (and clipboard copy) hasn't finished yet. Quitting waits for them.
    var savesInFlight = 0
    /// Quit was asked for while saves were in flight; `applicationShouldTerminate` answered `.terminateLater`.
    private(set) var isTerminating = false
    private var terminationReplied = false
    /// The longest a quit waits for in-flight saves.
    static let terminationTimeout: TimeInterval = 3
    /// The last action a global hotkey fired (for the DEBUG state dump).
    private(set) var lastHotkeyAction: ShortcutAction?
    var hotkeyRegistrations: [(binding: HotkeyCenter.Binding, status: OSStatus)] {
        hotkeys?.registrationSummary ?? []
    }
    /// Shortcuts that didn't register (also in `RuntimeStatus.hotkeyFailures`), for the menu bar warning.
    var hotkeyFailures: [HotkeyCenter.Failure] { hotkeys?.failures ?? [] }
    /// Whether the Unsaved folder holds shots, for the menu's Show Unsaved Shots. The menu is built synchronously,
    /// so it reads this cached flag (see `refreshUnsavedShots`).
    private(set) var hasUnsavedShots = false
    /// Bumped by every check and fallback save: only the latest one sets `hasUnsavedShots`.
    private var unsavedShotsGeneration = 0

    init() {
        store = ShelfStore(fileURL: ShelfStore.defaultFileURL)
        shelf = ShelfController(store: store)
        capture = CaptureController()
    }

    // MARK: - Lifecycle

    func start() {
        // Before anything names a shortcut: the keys are named as the user's keyboard layout labels them.
        KeyboardLayout.current.startObserving()
        Preferences.shared.removeObsoleteKeys()
        shelf.restore()

        capture.onCapture = { [weak self] result in self?.handleCapture(result) }
        capture.onPermissionMissing = { [weak self] in self?.captureLostPermission() }
        // Not in the CaptureControlling contract: a failed capture says so in the shelf instead of doing nothing.
        capture.onFailure = { [weak self] message in self?.shelf.showToast(message, isError: true) }
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
        menuBar.setWarning(needsPermission)
        // The welcome window only when there's something to do: first run unfinished or no permission.
        // (macOS shortcuts still enabled after that are offered from the menu: "macOS still uses ⇧⌘4 — Fix…".)
        if !prefs.firstRunDone || !permissionGranted {
            FirstRunWindowController.shared.show()
        }
        if permissionGranted {
            Task { await capture.prewarm() }
        }
        enableLoginItemOnFirstLaunch()
        refreshUnsavedShots()

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

    /// `applicationShouldTerminate`: a capture whose PNG is still being written would be lost (or left as a
    /// hidden temp file), so wait for in-flight saves, at most `terminationTimeout`, then let the quit go on.
    func shouldTerminate() -> NSApplication.TerminateReply {
        guard savesInFlight > 0 else { return .terminateNow }
        guard !isTerminating else { return .terminateLater } // asked again while already waiting
        isTerminating = true
        Self.log.notice("Quit: waiting for \(self.savesInFlight) capture(s) to finish saving")
        // Until the reply, AppKit runs the main run loop in NSModalPanelRunLoopMode. Save completions hop to
        // the main actor through the main queue, which that mode services: unless `terminate` was called
        // from inside a main-queue block, which then can't be re-entered. So the timeout is a run-loop timer
        // in the common modes, not `asyncAfter`: it fires either way, and a quit never hangs.
        let timeout = Timer(timeInterval: Self.terminationTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.terminationReplied else { return }
                Self.log.error("Quit: \(self.savesInFlight) capture(s) still saving after the timeout; quitting anyway")
                self.replyToTermination()
            }
        }
        RunLoop.main.add(timeout, forMode: .common)
        return .terminateLater
    }

    /// Called by the save pipeline when a capture's save finished (or failed).
    func saveFinished() {
        savesInFlight = max(0, savesInFlight - 1)
        if isTerminating, savesInFlight == 0 { replyToTermination() }
    }

    private func replyToTermination() {
        guard isTerminating, !terminationReplied else { return }
        terminationReplied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// Margin was opened again while running: show whatever needs attention, otherwise Settings.
    func handleReopen() {
        refreshPermission()
        if needsPermission {
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

    /// Menu "Restore Last Removed": the shelf's ⌘Z, for when the shelf isn't key.
    func restoreLastRemoved() { shelf.undo(fromMenu: true) }
    var canRestoreLastRemoved: Bool { shelf.canUndo }

    /// DEBUG `clear`: everything off the shelf (undoable).
    func clearShelf() { shelf.clear() }

    /// Creates the folder if it's missing, then opens it in Finder. The first touch of ~/Desktop can block
    /// on the Desktop-folder privacy prompt, so the file system is only touched off the main actor.
    /// A folder that can't be opened (access denied, an unplugged disk) says so in the shelf, and the Unsaved
    /// folder opens instead when shots are waiting there.
    func openScreenshotsFolder() {
        let folder = prefs.saveFolder
        let unsaved = Preferences.fallbackSaveFolder
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                Self.log.error("Can't create the screenshots folder: \(error.localizedDescription, privacy: .public)")
            }
            let hasUnsaved = UnsavedShots.exist(in: unsaved)
            await self?.open(folder, orUnsaved: unsaved, hasUnsaved: hasUnsaved)
        }
    }

    private func open(_ folder: URL, orUnsaved unsaved: URL, hasUnsaved: Bool) {
        if NSWorkspace.shared.open(folder) { return }
        let name = "“\(folder.lastPathComponent)”"
        if hasUnsaved, NSWorkspace.shared.open(unsaved) {
            shelf.showToast("Can't open \(name). Showing Unsaved shots", isError: true)
        } else {
            shelf.showToast("Can't open \(name)", isError: true)
        }
    }

    /// Menu "Show Unsaved Shots": the folder captures go to when the save folder can't be written.
    func showUnsavedShots() {
        if !NSWorkspace.shared.open(Preferences.fallbackSaveFolder) { NSSound.beep() }
        refreshUnsavedShots()
    }

    /// Checks the Unsaved folder off the main actor (it's in Application Support, which never prompts, but the
    /// main actor stays off the file system). Runs at launch and each time the menu opens, for the next time.
    func refreshUnsavedShots() {
        unsavedShotsGeneration += 1
        let generation = unsavedShotsGeneration
        let folder = Preferences.fallbackSaveFolder
        Task.detached(priority: .utility) { [weak self] in
            let found = UnsavedShots.exist(in: folder)
            await self?.unsavedShotsChecked(found, generation: generation)
        }
    }

    private func unsavedShotsChecked(_ found: Bool, generation: Int) {
        guard generation == unsavedShotsGeneration else { return }
        hasUnsavedShots = found
    }

    /// A capture just went to Unsaved: the menu shows Show Unsaved Shots from now on.
    func didSaveToUnsaved() {
        unsavedShotsGeneration += 1   // a check still running may have looked before this file existed
        hasUnsavedShots = true
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
    /// After a capture failed for lack of permission, captures are still attempted while preflight says
    /// yes: the user may have granted it again, and only a capture that works can clear the warning.
    private func canStartCapture() -> Bool {
        if capture.isCapturing || isTerminating { return false }
        if !permissionGranted { refreshPermission() }
        guard permissionGranted else {
            permissionMissing()
            return false
        }
        return true
    }

    /// Re-reads the permission. Called once a second while the warning shows, and when the menu opens.
    /// A yes from preflight doesn't clear a revoked permission (see `needsPermission`).
    func refreshPermission() {
        let granted = CGPreflightScreenCaptureAccess()
        if granted != permissionGranted {
            permissionGranted = granted
            if granted {
                Self.log.notice("Screen Recording permission granted")
                Task { await capture.prewarm() }
            }
        }
        // Only on a change: this runs every second, and rebuilding an open menu would reset it.
        if let menuBar, menuBar.showsWarning != needsPermission { menuBar.setWarning(needsPermission) }
    }

    /// Preflight says no: show First run step 1.
    private func permissionMissing() {
        Self.log.notice("Screen Recording permission missing")
        menuBar?.setWarning(true)
        showPermissionStep()
    }

    /// A capture failed because Screen Recording permission is missing (revoked while running, usually).
    /// `permissionGranted` keeps following preflight; the revoked flag holds the warning until a capture
    /// succeeds or Margin relaunches.
    private func captureLostPermission() {
        RuntimeStatus.shared.screenRecordingRevoked = true
        permissionMissing()
    }

    /// Called for every successful capture: Screen Recording evidently works.
    func screenRecordingWorked() {
        guard needsPermission else { return }
        Self.log.notice("Capture succeeded: Screen Recording permission works")
        permissionGranted = true
        RuntimeStatus.shared.screenRecordingRevoked = false
        menuBar?.setWarning(false)
    }

    // MARK: - ⌘V mark

    private func tick() {
        if mark.observe(changeCount: NSPasteboard.general.changeCount) {
            shelf.setClipboardMark(nil)
        }
        if needsPermission { refreshPermission() }
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

    /// "Relaunch Margin" (First run, and the menu while permission is revoked): start a fresh copy once
    /// this one has quit, then quit.
    func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else {
            Self.log.error("Relaunch needs an app bundle; quitting instead")
            NSApp.terminate(nil)
            return
        }
        // Wait for this process to exit (quitting can wait up to `terminationTimeout` for saves), at most
        // 10 s, then open the app. Not `open -n`: that would start a second copy if this one were stuck.
        let script = """
            i=0; while /bin/kill -0 "$2" 2>/dev/null && [ "$i" -lt 100 ]; do /bin/sleep 0.1; i=$((i+1)); done
            /usr/bin/open "$1"
            """
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", script, "margin-relaunch", bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
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
