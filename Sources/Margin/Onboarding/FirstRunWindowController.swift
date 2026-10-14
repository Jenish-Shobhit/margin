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
    private var statusObserver: NSObjectProtocol?

    override init() {
        super.init()
        // A revoked permission (or its recovery) shows at once, without waiting for the next poll.
        statusObserver = NotificationCenter.default.addObserver(
            forName: RuntimeStatus.didChange, object: RuntimeStatus.shared, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else { return }
                self.model.refresh()
            }
        }
    }

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
        // A menu bar app launched in the background can be refused activation (macOS 14+ cooperative
        // activation), which would leave the window behind the frontmost app.
        window.orderFrontRegardless()
        startPolling()
    }

    /// The coordinator calls this after every successful capture. The first one finishes first run (spec §7):
    /// a capture proves permission, so first run is done even if some macOS shortcuts are still on (the
    /// "You're set" moment mentions them). If the window is open, it shows "You're set" and closes.
    func captureSucceeded() {
        let prefs = model.prefs
        let isOpen = window?.isVisible == true
        guard !prefs.firstRunDone || isOpen else { return }
        model.capturedOnce = true
        model.refresh()
        if !prefs.firstRunDone { prefs.firstRunDone = true }
        guard isOpen, !model.finished else { return }
        model.finished = true
        closeTask?.cancel()
        // Leave time to read the extra line about macOS shortcuts that are still on.
        let delay: Duration = model.stillOnNote == nil ? .seconds(1.6) : .seconds(4)
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
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
