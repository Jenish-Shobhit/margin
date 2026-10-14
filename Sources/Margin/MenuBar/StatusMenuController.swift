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
        // Hotkey failures can change while the menu is closed (Settings re-registers them).
        observers.append(NotificationCenter.default.addObserver(
            forName: RuntimeStatus.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        refresh()
    }

    /// Screen Recording missing: a dot on the icon, and the first item becomes "Allow Screen Recording…".
    func setWarning(_ on: Bool) {
        showsWarning = on
        refresh()
    }

    /// Redraws the icon (a dot when something needs attention) and rebuilds the menu.
    private func refresh() {
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
        rebuild()
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

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        coordinator?.refreshPermission()
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

    private func rebuild() {
        menu.removeAllItems()
        let prefs = Preferences.shared

        if let warning = Self.hotkeyWarning(coordinator?.hotkeyFailures ?? []) {
            menu.addItem(item("\(warning) — Change in Settings…", symbol: "exclamationmark.triangle",
                              action: #selector(openSettings)))
            menu.addItem(.separator())
        }
        if showsWarning {
            menu.addItem(item("Allow Screen Recording…", symbol: "exclamationmark.triangle", action: #selector(allowScreenRecording)))
            // Revoked while running: macOS usually only hands the permission back to a fresh process.
            if RuntimeStatus.shared.screenRecordingRevoked {
                menu.addItem(item("Relaunch Margin", symbol: "arrow.triangle.2.circlepath", action: #selector(relaunch)))
            }
        } else {
            menu.addItem(item("Capture Area", symbol: "rectangle.dashed", action: #selector(captureArea),
                              combo: prefs.shortcut(for: .captureArea)))
        }
        menu.addItem(item("Capture Window", symbol: "macwindow", action: #selector(captureWindow)))
        menu.addItem(item("Capture Screen", symbol: "display", action: #selector(captureScreen),
                          combo: prefs.shortcut(for: .captureScreen)))
        menu.addItem(item("Repeat Last Area", symbol: "arrow.clockwise", action: #selector(repeatArea),
                          combo: prefs.shortcut(for: .repeatArea)))
        menu.addItem(.separator())
        let tucked = coordinator?.isShelfTucked ?? false
        menu.addItem(item(tucked ? "Show Shelf" : "Tuck Shelf", symbol: "sidebar.right", action: #selector(toggleShelf),
                          combo: prefs.shortcut(for: .toggleShelf)))
        let restore = item("Restore Last Removed", symbol: "arrow.uturn.backward", action: #selector(restoreLastRemoved))
        restore.isEnabled = coordinator?.canRestoreLastRemoved ?? false
        menu.addItem(restore)
        menu.addItem(item("Open Screenshots Folder", symbol: "folder", action: #selector(openFolder)))
        menu.addItem(.separator())
        // Quiet: no warning symbol or dot. The welcome window closes after the first shot, so this is how
        // someone who skipped step 2 finds it again.
        if let title = Self.systemConflictTitle(systemConflicts) {
            menu.addItem(item(title, symbol: "keyboard", action: #selector(fixShortcuts)))
        }
        let settings = item("Settings…", symbol: "gearshape", action: #selector(openSettings))
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = .command
        menu.addItem(settings)
        menu.addItem(item("About Margin \(Self.version)", symbol: "info.circle", action: #selector(about)))
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
    @objc private func toggleShelf() { coordinator?.toggleShelf() }
    @objc private func restoreLastRemoved() { coordinator?.restoreLastRemoved() }
    @objc private func openFolder() { coordinator?.openScreenshotsFolder() }
    @objc private func openSettings() { coordinator?.showSettings() }
    @objc private func fixShortcuts() { coordinator?.showShortcutsStep() }
    @objc private func about() { coordinator?.showAbout() }
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
