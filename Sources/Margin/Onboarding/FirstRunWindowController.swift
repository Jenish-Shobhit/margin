import AppKit
import MarginKit
import SwiftUI

/// The "Welcome to Margin" window (spec §7). Shows on first launch or whenever permission is missing,
/// polls permission and the macOS shortcuts once a second, and closes after the first successful capture.
@MainActor
final class FirstRunWindowController: NSObject, NSWindowDelegate {
    enum Step { case permission, shortcuts, firstShot }

    static let shared = FirstRunWindowController()

    /// Called when the user taps "Relaunch Margin" after granting permission.
    /// If nil, Margin relaunches itself (bundled builds only).
    var onRelaunch: (() -> Void)?

    let model = FirstRunModel()
    private var window: NSWindow?
    private var poll: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?

    /// Shows the window at the first incomplete step (or `step` if given).
    func show(step: Step? = nil) {
        closeTask?.cancel()
        model.finished = false
        model.focus = step
        model.refresh()
        let window = self.window ?? makeWindow()
        self.window = window
        if !window.isVisible {
            // The hosting controller sizes the window lazily; size it now so centering uses the real size.
            if let view = window.contentViewController?.view { window.setContentSize(view.fittingSize) }
            window.center()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        startPolling()
    }

    /// The coordinator calls this after every successful capture; the window closes after the first.
    /// First run is done once permission and the shortcuts are sorted out too.
    func captureSucceeded() {
        let prefs = Preferences.shared
        guard !prefs.firstRunDone else { return }
        model.capturedOnce = true
        model.refresh()
        guard model.permissionDone, model.shortcutsDone else { return } // window stays open at step 2
        prefs.firstRunDone = true
        guard let window, window.isVisible else { return }
        model.finished = true
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.window?.close()
        }
    }

    private func makeWindow() -> NSWindow {
        let view = FirstRunView(model: model) { [weak self] in self?.relaunch() }
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "Welcome to Margin"
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.delegate = self
        return window
    }

    private func startPolling() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.model.refresh()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        poll?.cancel()
        poll = nil
        closeTask?.cancel()
        closeTask = nil
        model.finished = false
    }

    private func relaunch() {
        if let onRelaunch { onRelaunch(); return }
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
