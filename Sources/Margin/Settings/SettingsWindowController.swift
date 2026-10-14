import AppKit
import MarginKit
import SwiftUI

/// The small, fixed-size "Margin Settings" window.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private(set) lazy var model = SettingsModel()

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        model.reload()
        model.refreshFolderInfo(force: true) // the folder may have been created or removed since
        model.refreshLoginItem()
        model.refreshSystemShortcuts()
        if !window.isVisible {
            // The hosting controller sizes the window lazily; size it now so centering uses the real size.
            if let view = window.contentViewController?.view { window.setContentSize(view.fittingSize) }
            window.center()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // A menu bar app launched in the background can be refused activation (macOS 14+ cooperative
        // activation), which would leave the window behind the frontmost app.
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let view = SettingsView(model: model) { [weak self] in self?.window }
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "Margin Settings"
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.delegate = self
        return window
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Back from System Settings, the login item approval or the macOS shortcuts may have changed.
        model.refreshLoginItem()
        model.refreshSystemShortcuts()
    }

    func windowDidResignKey(_ notification: Notification) {
        // The open panel sheet takes key too; only stop listening when the window really loses focus.
        guard window?.attachedSheet == nil else { return }
        model.stopRecording()
    }

    func windowWillClose(_ notification: Notification) {
        model.stopRecording()
    }
}
