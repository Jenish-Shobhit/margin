import AppKit
import MarginKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private var launchGuard: LaunchGuard?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything else: a second copy of Margin gives way to the one running.
        let launchGuard = LaunchGuard()
        self.launchGuard = launchGuard
        launchGuard.run { [weak self] in self?.start() }
    }

    private func start() {
        launchGuard = nil
        MainMenu.install()
        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        coordinator.start()
    }

    /// `margin://update` (spec §14.3), from the website's Update Margin button: a check, and its result in the update
    /// window. Nothing is installed without a click there. Any other URL is ignored. At a launch it may come before
    /// `applicationDidFinishLaunching`; the check then waits for `start`.
    func application(_ application: NSApplication, open urls: [URL]) {
        // One check for any number of them; `open` logs and ignores anything else.
        if let url = urls.first(where: MarginURL.isUpdateRequest) ?? urls.first { UpdateController.shared.open(url) }
    }

    /// Opening Margin again (Finder, Spotlight, `open`) while it's running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.handleReopen()
        return false
    }

    /// Waits (briefly) for captures that are still being saved.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        coordinator?.shouldTerminate() ?? .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }
}
