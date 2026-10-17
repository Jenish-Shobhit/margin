import AppKit
import MarginKit

/// One copy of Margin at a time (`RunningCopies`). Asked first thing at launch: a copy that gives way never registers a
/// shortcut, restores the shelf or touches ScreenCaptureKit. It asks the older copy to show itself, as opening Margin
/// again does (Settings, or First run without permission), and quits.
///
/// An older copy may only be quitting: a relaunch quits one copy and opens the next, and a quit can wait for saves
/// (`AppCoordinator.terminationTimeout`) or for a recording to be saved (`recordingTerminationTimeout`). So this one
/// waits for it to go before giving up, and starts if it does.
@MainActor
final class LaunchGuard {
    /// Handing over waits this long: a copy that's quitting has usually gone by then, and isn't asked to show itself on
    /// its way out.
    static let grace: TimeInterval = 0.5
    /// How long an older copy has to quit before this one decides it's staying.
    static let patience: TimeInterval =
        max(AppCoordinator.terminationTimeout, AppCoordinator.recordingTerminationTimeout) + 2

    private var timer: Timer?
    private var start: (@MainActor () -> Void)?
    private var handedOver = false
    private let launched = Date()

    /// Calls `start` now, or once the older copy has quit; or quits this copy if it doesn't.
    func run(start: @escaping @MainActor () -> Void) {
        guard let older = Self.olderCopy() else {
            start()
            return
        }
        AppCoordinator.log.notice("Margin is already running (pid \(older.processIdentifier)); waiting for it to quit")
        self.start = start
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let older = Self.olderCopy() else {
            AppCoordinator.log.notice("The other copy of Margin has quit; starting")
            finish()
            start?()
            return
        }
        let waited = Date().timeIntervalSince(launched)
        if !handedOver, waited >= Self.grace {
            handedOver = true
            Self.reopen(older)
        }
        if waited >= Self.patience {
            AppCoordinator.log.notice("Margin keeps running as pid \(older.processIdentifier); quitting this copy")
            finish()
            NSApp.terminate(nil)
        }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
    }

    /// The running copy this one gives way to, if any.
    private static func olderCopy() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil } // a bare `swift run` build
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated && $0.processIdentifier != me.processIdentifier }
        let copy = { (app: NSRunningApplication) in RunningCopies.Copy(processID: app.processIdentifier, launchDate: app.launchDate) }
        guard let older = RunningCopies.olderCopy(than: copy(me), among: others.map(copy)) else { return nil }
        return others.first { $0.processIdentifier == older.processID }
    }

    /// Opens the running copy as Finder would, which reaches its `applicationShouldHandleReopen`.
    private static func reopen(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else {
            app.activate()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                AppCoordinator.log.error("Couldn't reopen the running copy: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
