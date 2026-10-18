import AppKit
import MarginKit
import SwiftUI

/// The Settings window: a pane per toolbar tab (`SettingsPane`), titled after it, as tall as that pane.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var tabs: SettingsTabViewController?
    private(set) lazy var model = SettingsModel()

    /// Shows the window, on `pane` when given (the menu's shortcut warning opens Shortcuts), else where it was left.
    func show(_ pane: SettingsPane? = nil) {
        let window = self.window ?? makeWindow()
        self.window = window
        model.reload()
        model.refreshFolderInfo(force: true) // the folder may have been created or removed since
        model.refreshLoginItem()
        model.refreshSystemShortcuts()
        model.refreshMicrophoneAccess()
        if let pane { tabs?.select(pane) }
        if !window.isVisible {
            // The hosting controllers size lazily; size it now so centering uses the real size.
            tabs?.fitWindow(animated: false)
            window.center()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // A menu bar app launched in the background can be refused activation (macOS 14+ cooperative
        // activation), which would leave the window behind the frontmost app.
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let tabs = SettingsTabViewController(model: model) { [weak self] in self?.window }
        self.tabs = tabs
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.delegate = self
        return window
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Back from System Settings, the login item approval, the macOS shortcuts or the microphone may have changed.
        model.refreshLoginItem()
        model.refreshSystemShortcuts()
        model.refreshMicrophoneAccess()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Whatever has the keys now (another app, a sheet or an alert), they're no longer the recorder's: the local
        // monitor sees every key Margin gets, and would record ⇧⌘G typed in the folder sheet.
        model.stopRecording()
    }

    func windowWillClose(_ notification: Notification) {
        model.stopRecording()
    }
}

/// The toolbar tabs. The window takes the selected pane's height (keeping its top edge where it is), when a tab is
/// chosen and when the pane grows or shrinks (a warning under a shortcut, the login item's approval line).
@MainActor
final class SettingsTabViewController: NSTabViewController {
    private let panes: [SettingsPane]

    init(model: SettingsModel, window: @escaping () -> NSWindow?) {
        panes = SettingsPane.allCases
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = []
        canPropagateSelectedChildViewControllerTitle = true
        for pane in panes {
            let content: AnyView = switch pane {
            case .general: AnyView(GeneralSettingsView(model: model, window: window))
            case .shortcuts: AnyView(ShortcutsSettingsView(model: model))
            case .recording: AnyView(RecordingSettingsView(model: model))
            }
            let hosting = NSHostingController(rootView: content)
            hosting.sizingOptions = [.preferredContentSize]
            hosting.title = pane.title
            let item = NSTabViewItem(viewController: hosting)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            item.identifier = pane.rawValue
            addTabViewItem(item)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func select(_ pane: SettingsPane) {
        guard let index = panes.firstIndex(of: pane), selectedTabViewItemIndex != index else { return }
        selectedTabViewItemIndex = index
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fitWindow(animated: view.window?.isVisible ?? false)
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard viewController === tabViewItems[safe: selectedTabViewItemIndex]?.viewController else { return }
        fitWindow(animated: view.window?.isVisible ?? false)
    }

    /// Sizes the window to the selected pane, its top-left corner staying put.
    func fitWindow(animated: Bool) {
        guard let window = view.window, let pane = tabViewItems[safe: selectedTabViewItemIndex]?.viewController else { return }
        let size = pane.view.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
        frame.origin = CGPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
