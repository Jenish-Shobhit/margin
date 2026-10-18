import AppKit
import MarginKit

/// The menu bar icon and its menu (spec §6). Rebuilt each time it opens, so shortcuts, the shelf's
/// tuck state and the warnings are always current.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private weak var coordinator: AppCoordinator?
    private let warningDot = WarningDotView(frame: NSRect(x: 0, y: 0, width: dotDiameter, height: dotDiameter))
    private let glyph: NSImage
    private let badgedGlyph: NSImage
    private var observers: [NSObjectProtocol] = []
    private(set) var showsWarning = false
    /// How long the recording under way has run; nil when there's none (spec §14.4).
    private(set) var recordingElapsed: TimeInterval?
    #if DEBUG || MARGIN_BENCH
    /// What the button shows, for the DEBUG state dump.
    var debugState: [String: Any] {
        [
            "title": statusItem.button?.title ?? "",
            "recordingGlyph": statusItem.button?.image === recordingGlyph,
            "variableLength": statusItem.length == NSStatusItem.variableLength,
            "menu": menu.items.map { $0.isSeparatorItem ? "—" : $0.title + ($0.keyEquivalent.isEmpty ? "" : " [\($0.keyEquivalent)]") },
        ]
    }
    #endif

    /// The red stop glyph that stands in for the icon while recording: not a template, so it stays red.
    private lazy var recordingGlyph: NSImage = {
        let config = NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed])
            .applying(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        let image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Recording")?
            .withSymbolConfiguration(config) ?? glyph
        image.isTemplate = false
        return image
    }()

    private static let dotDiameter: CGFloat = 6
    /// The dot's centre, inset from the glyph's top-right corner (glyph coordinates, y up).
    private static let dotInset: CGFloat = 1

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let symbol = NSImage(systemSymbolName: "rectangle.righthalf.inset.filled", accessibilityDescription: "Margin")
            ?? NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Margin")
            ?? NSImage(size: NSSize(width: 18, height: 14))
        symbol.isTemplate = true
        glyph = symbol
        badgedGlyph = Self.cutOutBadge(from: symbol)
        super.init()

        if let button = statusItem.button {
            button.image = glyph
            button.imagePosition = .imageOnly
            button.toolTip = "Margin"
            warningDot.isHidden = true
            button.addSubview(warningDot)
        }
        statusItem.behavior = []
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        // Hotkey failures can change while the menu is closed (Settings re-registers them), and so can a revoked
        // permission: a freeze or prewarm that works clears it, even when no capture completes (Esc).
        observers.append(NotificationCenter.default.addObserver(
            forName: RuntimeStatus.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.runtimeStatusChanged() }
        })
        refresh()
    }

    /// Screen Recording missing: a dot on the icon, and the first item becomes "Allow Screen Recording…".
    func setWarning(_ on: Bool) {
        showsWarning = on
        refresh()
    }

    private func runtimeStatusChanged() {
        if let coordinator { showsWarning = coordinator.needsPermission }
        refresh()
    }

    /// While recording: the red stop glyph and the elapsed time (m:ss) instead of the icon, and Stop Recording first in
    /// the menu. Called every second meanwhile, which only redraws the button: the menu is rebuilt (an open one would
    /// reset) only when a recording starts or ends.
    func setRecording(_ elapsed: TimeInterval?) {
        let changed = (elapsed == nil) != (recordingElapsed == nil)
        recordingElapsed = elapsed
        if changed { refresh() } else { updateRecordingButton() }
    }

    /// The button while recording; false (and nothing done) when there's no recording.
    @discardableResult
    private func updateRecordingButton() -> Bool {
        guard let elapsed = recordingElapsed, let button = statusItem.button else { return false }
        let time = RecordingFormat.durationText(elapsed)
        statusItem.length = NSStatusItem.variableLength
        button.image = recordingGlyph
        button.imagePosition = .imageLeading
        button.attributedTitle = NSAttributedString(string: " " + time, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        ])
        warningDot.isHidden = true
        let tip = "Margin — recording, \(time). Stop with \(Preferences.shared.shortcut(for: .recordScreen).displayString)"
        button.toolTip = tip
        button.setAccessibilityLabel("Margin — recording, \(time)")
        return true
    }

    /// Redraws the icon (a dot when something needs attention) and rebuilds the menu.
    private func refresh() {
        defer { rebuild() }
        if updateRecordingButton() { return }
        statusItem.length = NSStatusItem.squareLength
        statusItem.button?.title = ""
        statusItem.button?.imagePosition = .imageOnly
        let hotkeyWarning = Self.hotkeyWarning(coordinator?.hotkeyFailures ?? [])
        let attention = showsWarning || hotkeyWarning != nil
        statusItem.button?.image = attention ? badgedGlyph : glyph
        warningDot.isHidden = !attention
        layoutWarningDot()
        let tip: String
        if showsWarning {
            tip = "Margin — Screen Recording permission needed"
        } else if let hotkeyWarning {
            tip = "Margin — \(hotkeyWarning)"
        } else {
            tip = "Margin"
        }
        statusItem.button?.toolTip = tip
        statusItem.button?.setAccessibilityLabel(tip)
    }

    /// "⇧⌘4 is used by another app", or nil when every shortcut registered.
    static func hotkeyWarning(_ failures: [HotkeyCenter.Failure]) -> String? {
        guard !failures.isEmpty else { return nil }
        let keys = ListFormatter.localizedString(byJoining: failures.map(\.binding.combo.displayString))
        let one = failures.count == 1
        if failures.allSatisfy({ $0.reason == .taken }) {
            return one ? "\(keys) is used by another app" : "\(keys) are used by other apps"
        }
        if failures.allSatisfy({ $0.reason == .duplicate }) {
            return one ? "\(keys) is set for two actions" : "\(keys) are set for two actions"
        }
        return one ? "\(keys) isn't available" : "\(keys) aren't available"
    }

    /// The glyph with a transparent ring where the dot sits, so the badge reads as separate.
    private static func cutOutBadge(from glyph: NSImage) -> NSImage {
        let size = glyph.size
        let image = NSImage(size: size, flipped: false) { rect in
            glyph.draw(in: rect)
            let r = dotDiameter / 2 + 1.5
            let centre = NSPoint(x: size.width - dotInset, y: size.height - dotInset)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = glyph.accessibilityDescription
        return image
    }

    private func layoutWarningDot() {
        guard let button = statusItem.button else { return }
        button.layoutSubtreeIfNeeded()
        let b = button.bounds, g = glyph.size, d = Self.dotDiameter
        // The image is centred in the button.
        let originX = (b.width - g.width) / 2
        let originY = (b.height - g.height) / 2
        let cx = originX + g.width - Self.dotInset
        let cyUp = originY + g.height - Self.dotInset
        let cy = button.isFlipped ? b.height - cyUp : cyUp
        warningDot.frame = NSRect(x: (cx - d / 2).rounded(), y: (cy - d / 2).rounded(), width: d, height: d)
    }

    #if DEBUG || MARGIN_BENCH
    /// DEBUG `show menu`: opens the menu as a click on the icon does, and closes it after `seconds` (the menu tracks
    /// modally, so the timer runs in the run loop's common modes).
    func debugShowMenu(seconds: Double) {
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.menu.cancelTracking() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusItem.button?.performClick(nil)
    }
    #endif

    // MARK: - NSMenuDelegate

    /// What gives the shelf's keys back once the menu has closed (`ShelfController.menuOpening`).
    private var giveKeysBack: (() -> Void)?

    func menuWillOpen(_ menu: NSMenu) {
        giveKeysBack = coordinator?.shelf.menuOpening()
    }

    /// Once the shelf has had the keys, AppKit makes it key again as this menu closes, with or without a choice, and
    /// none of the items needs it to keep them: they go back to the user's app, unless the shelf had them when the menu
    /// opened. After the chosen item's action, which runs once the menu has closed: an item that opens one of Margin's
    /// windows (Settings…, About) has made it key by then, and the shelf has nothing to give back.
    func menuDidClose(_ menu: NSMenu) {
        let giveKeysBack = self.giveKeysBack
        self.giveKeysBack = nil
        Task { @MainActor in giveKeysBack?() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        coordinator?.refreshPermission()
        // Off the main thread: this menu shows the previous check, the next one shows this one.
        coordinator?.refreshUnsavedShots()
        // Re-read the macOS screenshot shortcuts only here, when someone is about to look (no timer).
        systemConflicts = SystemShortcuts.conflicts(
            SystemShortcuts.current(), with: Preferences.shared.registeredCombos().map(\.combo))
        rebuild()
    }

    /// The enabled macOS screenshot shortcuts that take one of Margin's combos first, as of the last menu open.
    private var systemConflicts: [SystemScreenshotShortcut] = []

    /// "macOS still uses ⇧⌘4 — Fix…", or nil when macOS has handed over every combo Margin uses.
    static func systemConflictTitle(_ conflicts: [SystemScreenshotShortcut]) -> String? {
        switch conflicts.count {
        case 0: return nil
        case 1, 2: return "macOS still uses \(ListFormatter.localizedString(byJoining: conflicts.map(\.keys))) — Fix…"
        default: return "macOS still uses \(conflicts.count) of Margin's shortcuts — Fix…"
        }
    }

    // MARK: - Building

    /// In groups (spec §6): what needs attention first (Stop Recording, then the warnings), the captures, the shelf, the
    /// files, and Margin itself, with Quit on its own.
    private func rebuild() {
        menu.removeAllItems()
        let prefs = Preferences.shared

        // From the overlay closing until the recording is being saved.
        let recording = recordingElapsed != nil
        if recording {
            menu.addItem(item("Stop Recording", symbol: "stop.circle", action: #selector(stopRecording),
                              combo: prefs.shortcut(for: .recordScreen)))
            menu.addItem(.separator())
        }
        var warnings: [NSMenuItem] = []
        if let warning = Self.hotkeyWarning(coordinator?.hotkeyFailures ?? []) {
            warnings.append(item("\(warning) — Change in Settings…", symbol: "exclamationmark.triangle",
                                 action: #selector(openShortcutSettings)))
        }
        if showsWarning {
            warnings.append(item("Allow Screen Recording…", symbol: "exclamationmark.triangle", action: #selector(allowScreenRecording)))
            // Revoked while running: macOS usually only hands the permission back to a fresh process.
            if RuntimeStatus.shared.screenRecordingRevoked {
                warnings.append(item("Relaunch Margin", symbol: "arrow.triangle.2.circlepath", action: #selector(relaunch)))
            }
        }
        if !warnings.isEmpty {
            warnings.forEach(menu.addItem)
            menu.addItem(.separator())
        }

        // The captures. Without permission, each opens First run's permission step instead.
        menu.addItem(item("Capture Area", symbol: "rectangle.dashed", action: #selector(captureArea),
                          combo: prefs.shortcut(for: .captureArea)))
        menu.addItem(item("Capture Window", symbol: "macwindow", action: #selector(captureWindow)))
        menu.addItem(item("Capture Screen", symbol: "display", action: #selector(captureScreen),
                          combo: prefs.shortcut(for: .captureScreen)))
        menu.addItem(item("Repeat Last Area", symbol: "arrow.clockwise", action: #selector(repeatArea),
                          combo: prefs.shortcut(for: .repeatArea)))
        if !recording {
            menu.addItem(item("Record Screen", symbol: "record.circle", action: #selector(recordScreen),
                              combo: prefs.shortcut(for: .recordScreen)))
        }
        menu.addItem(.separator())

        // The shelf. An empty one has nothing to tuck (⇧⌘1 does nothing then either) or close.
        let tucked = coordinator?.isShelfTucked ?? false
        let toggle = item(tucked ? "Show Shelf" : "Tuck Shelf", symbol: "sidebar.right", action: #selector(toggleShelf),
                          combo: prefs.shortcut(for: .toggleShelf))
        toggle.isEnabled = coordinator?.shelf.canToggleTucked ?? false
        menu.addItem(toggle)
        let close = item("Close Shelf", symbol: "xmark.circle", action: #selector(closeShelf))
        close.isEnabled = coordinator?.canCloseShelf ?? false
        menu.addItem(close)
        let restore = item("Restore Last Removed", symbol: "arrow.uturn.backward", action: #selector(restoreLastRemoved))
        restore.isEnabled = coordinator?.canRestoreLastRemoved ?? false
        menu.addItem(restore)
        menu.addItem(.separator())

        // The files.
        menu.addItem(item("Open Screenshots Folder", symbol: "folder", action: #selector(openFolder)))
        // Only while shots are waiting there, because the save folder couldn't be written.
        if coordinator?.hasUnsavedShots == true {
            menu.addItem(item(UnsavedShots.menuItemTitle, symbol: "tray.full", action: #selector(showUnsaved)))
        }
        menu.addItem(.separator())

        // Margin itself. The shortcut item is quiet: no warning symbol or dot. The welcome window closes after the first
        // shot, so this is how someone who skipped step 2 finds it again.
        if let title = Self.systemConflictTitle(systemConflicts) {
            menu.addItem(item(title, symbol: "keyboard", action: #selector(fixShortcuts)))
        }
        let settings = item("Settings…", symbol: "gearshape", action: #selector(openSettings))
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = .command
        menu.addItem(settings)
        menu.addItem(item("Check for Updates…", symbol: "arrow.down.circle", action: #selector(checkForUpdates)))
        menu.addItem(item("About Margin \(Self.version)", symbol: "info.circle", action: #selector(about)))
        menu.addItem(.separator())
        let quit = item("Quit Margin", symbol: "power", action: #selector(quit))
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)
    }

    private func item(_ title: String, symbol: String, action: Selector, combo: KeyCombo? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if let combo, let equivalent = MenuKeyEquivalent(combo) {
            item.keyEquivalent = equivalent.key
            item.keyEquivalentModifierMask = equivalent.modifiers
        }
        return item
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
    }

    // MARK: - Actions

    /// Let the menu finish closing before the screen is frozen, so it never ends up in the shot.
    private func afterMenuCloses(_ body: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            body()
        }
    }

    @objc private func allowScreenRecording() { coordinator?.showPermissionStep() }
    @objc private func relaunch() { coordinator?.relaunch() }
    @objc private func captureArea() { afterMenuCloses { [weak self] in self?.coordinator?.captureArea() } }
    @objc private func captureWindow() { afterMenuCloses { [weak self] in self?.coordinator?.captureWindow() } }
    @objc private func captureScreen() { afterMenuCloses { [weak self] in self?.coordinator?.captureScreen() } }
    @objc private func repeatArea() { afterMenuCloses { [weak self] in self?.coordinator?.repeatArea() } }
    @objc private func recordScreen() { afterMenuCloses { [weak self] in self?.coordinator?.toggleRecording() } }
    @objc private func stopRecording() { coordinator?.stopRecording() }
    @objc private func toggleShelf() { coordinator?.toggleShelf() }
    @objc private func closeShelf() { coordinator?.closeShelf() }
    @objc private func restoreLastRemoved() { coordinator?.restoreLastRemoved() }
    @objc private func openFolder() { coordinator?.openScreenshotsFolder() }
    @objc private func showUnsaved() { coordinator?.showUnsavedShots() }
    @objc private func openSettings() { coordinator?.showSettings() }
    @objc private func openShortcutSettings() { coordinator?.showSettings(.shortcuts) }
    @objc private func fixShortcuts() { coordinator?.showShortcutsStep() }
    @objc private func about() { coordinator?.showAbout() }
    @objc private func checkForUpdates() { UpdateController.shared.checkForUpdates() }
    @objc private func quit() { coordinator?.quit() }
}

/// The small warning dot on the status item.
private final class WarningDotView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateLayer() {
        layer?.cornerRadius = bounds.width / 2
        layer?.backgroundColor = NSColor.systemOrange.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
