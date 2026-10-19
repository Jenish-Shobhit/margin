import AppKit
import MarginKit
import SwiftUI

/// The Settings window (spec §8): a sidebar of panes and a grouped form per pane, in an AppKit window hosting SwiftUI.
/// The app talks to this façade only. What the menu bar knows (the status, the icon's visibility) is kept here from
/// launch, while the model and the window are made on first use.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    static let size = NSSize(width: 700, height: 720)
    static let minSize = NSSize(width: 640, height: 440)
    static let sidebarWidth: CGFloat = 190

    private var window: NSWindow?
    private var madeModel: SettingsModel?
    private var appStatus = MarginStatus.ready
    private var menuBarIconShown = true
    /// A note set before the model was made: it shows the next time the window opens.
    private var menuBarNote: String?

    /// Show menu bar icon turned on (showing never asks).
    var onShowMenuBarIcon: (() -> Void)?
    /// Show menu bar icon turned off: the app runs Hide from Menu Bar (the confirmation, the attention rule).
    var onRequestHideMenuBarIcon: (() -> Void)?
    /// The sidebar's status line has a button: Allow… or Change….
    var onFixStatus: ((MarginStatus) -> Void)?

    var model: SettingsModel {
        if let madeModel { return madeModel }
        let model = SettingsModel()
        model.appStatus = appStatus
        model.menuBarIconShown = menuBarIconShown
        model.menuBarNote = menuBarNote
        model.onSetMenuBarIcon = { [weak self] on in
            if on { self?.onShowMenuBarIcon?() } else { self?.onRequestHideMenuBarIcon?() }
        }
        model.onCheckForUpdates = { UpdateController.shared.checkForUpdates() }
        model.onFixStatus = { [weak self] in self?.onFixStatus?($0) }
        model.window = { [weak self] in self?.window }
        madeModel = model
        return model
    }

    // MARK: State from the app

    func setStatus(_ status: MarginStatus) {
        appStatus = status
        if let madeModel, madeModel.appStatus != status { madeModel.appStatus = status }
    }

    func setMenuBarIconShown(_ shown: Bool) {
        menuBarIconShown = shown
        if let madeModel, madeModel.menuBarIconShown != shown { madeModel.menuBarIconShown = shown }
    }

    /// A one-line note under Settings › General › Menu Bar; nil clears it. It stays until the window closes, so one set
    /// while it's closed shows the next time it opens. Never makes the model (that waits for the window).
    func showMenuBarNote(_ note: String?) {
        menuBarNote = note
        madeModel?.menuBarNote = note
    }

    // MARK: Window

    /// Shows the window, on `pane` when given (the menu's shortcut warning opens Shortcuts, About opens About), else
    /// where it was left.
    func show(_ pane: SettingsPane? = nil) {
        let model = self.model
        let window = self.window ?? makeWindow()
        self.window = window
        model.reload()
        model.refreshFolderInfo(force: true) // the folder may have been created or removed since
        model.refreshLoginItem()
        model.refreshSystemShortcuts()
        model.refreshMicrophoneAccess()
        if let pane { model.select(pane) }
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // A menu bar app launched in the background can be refused activation (macOS 14+ cooperative
        // activation), which would leave the window behind the frontmost app.
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Margin Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(Self.size)
        window.contentMinSize = Self.minSize
        window.contentMaxSize = NSSize(width: 980, height: 1400)
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
        showMenuBarNote(nil)
    }

    // MARK: Hide from Menu Bar

    static let hideMessage = "Hide Margin from the menu bar?"
    static let hideDetail = "Margin keeps running: your shortcuts and the shelf keep working. To bring the icon back, open Margin again from Spotlight, Launchpad or Applications."

    /// Asks before hiding the menu bar icon, and answers (confirmed, don't ask again): a sheet on Settings when it's
    /// open, otherwise an alert.
    func confirmHideIcon(_ answer: @escaping @MainActor (Bool, Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = Self.hideMessage
        alert.informativeText = Self.hideDetail
        alert.addButton(withTitle: "Hide")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        let reply: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            answer(response == .alertFirstButtonReturn, alert.suppressionButton?.state == .on)
        }
        guard let window, window.isVisible else {
            NSApp.activate()
            reply(alert.runModal())
            return
        }
        // Settings may be behind another app, or on another Space: it comes forward with the question. One at a time.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        guard window.attachedSheet == nil else { return }
        alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { reply(response) } }
    }
}
