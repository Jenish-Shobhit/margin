import AppKit
import MarginKit

/// The menu bar icon and its menu (spec §6). Rebuilt each time it opens, so shortcuts, the shelf's
/// tuck state and the permission warning are always current.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private weak var coordinator: AppCoordinator?
    private let warningDot = WarningDotView(frame: NSRect(x: 0, y: 0, width: 7, height: 7))
    private(set) var showsWarning = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "rectangle.righthalf.inset.filled", accessibilityDescription: "Margin")
                ?? NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Margin")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "Margin"
            warningDot.isHidden = true
            button.addSubview(warningDot)
        }
        statusItem.behavior = []
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuild()
    }

    /// Screen Recording missing: a dot on the icon, and the first item becomes "Allow Screen Recording…".
    func setWarning(_ on: Bool) {
        showsWarning = on
        warningDot.isHidden = !on
        layoutWarningDot()
        statusItem.button?.toolTip = on ? "Margin — Screen Recording permission needed" : "Margin"
        statusItem.button?.setAccessibilityLabel(statusItem.button?.toolTip)
        rebuild()
    }

    private func layoutWarningDot() {
        guard let button = statusItem.button else { return }
        let size = warningDot.frame.size
        let b = button.bounds
        // Top-right of the glyph, nudged in so it never clips at the button's edge.
        let x = b.midX + 4
        let y = button.isFlipped ? b.midY - 9 : b.midY + 9 - size.height
        warningDot.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        coordinator?.refreshPermission()
        rebuild()
    }

    // MARK: - Building

    private func rebuild() {
        menu.removeAllItems()
        let prefs = Preferences.shared

        if showsWarning {
            menu.addItem(item("Allow Screen Recording…", symbol: "exclamationmark.triangle", action: #selector(allowScreenRecording)))
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
        menu.addItem(item("Open Screenshots Folder", symbol: "folder", action: #selector(openFolder)))
        menu.addItem(.separator())
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
    @objc private func captureArea() { afterMenuCloses { [weak self] in self?.coordinator?.captureArea() } }
    @objc private func captureWindow() { afterMenuCloses { [weak self] in self?.coordinator?.captureArea() } }
    @objc private func captureScreen() { afterMenuCloses { [weak self] in self?.coordinator?.captureScreen() } }
    @objc private func repeatArea() { afterMenuCloses { [weak self] in self?.coordinator?.repeatArea() } }
    @objc private func toggleShelf() { coordinator?.toggleShelf() }
    @objc private func openFolder() { coordinator?.openScreenshotsFolder() }
    @objc private func openSettings() { coordinator?.showSettings() }
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
