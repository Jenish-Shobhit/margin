import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        coordinator.start()
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
