import Foundation
import MarginKit
import Testing

@Suite struct MenuBarIconPolicyTests {
    @Test func shownUntilHidden() {
        var policy = MenuBarIconPolicy()
        #expect(policy.isShown(recording: false))
        #expect(policy.hideStep(needsAttention: false) == .confirm)
        policy.hide(dontAskAgain: false)
        #expect(!policy.isShown(recording: false))
        #expect(!policy.skipsConfirmation)
        // Already hidden: nothing more to hide.
        #expect(policy.hideStep(needsAttention: false) == .refuse)
    }

    @Test func dontAskAgainSkipsTheConfirmationNextTime() {
        var policy = MenuBarIconPolicy()
        policy.hide(dontAskAgain: true)
        let shown = policy.show()
        #expect(shown)
        #expect(policy.hideStep(needsAttention: false) == .hide)
    }

    @Test func neverHiddenWhileSomethingNeedsAttention() {
        let policy = MenuBarIconPolicy(skipsConfirmation: true)
        #expect(policy.hideStep(needsAttention: true) == .refuse)
    }

    @Test func attentionBringsAHiddenIconBack() {
        var policy = MenuBarIconPolicy(hidden: true)
        let cleared = policy.attentionChanged(false)
        #expect(!cleared)
        #expect(policy.hidden)
        let needed = policy.attentionChanged(true)
        #expect(needed)
        #expect(!policy.hidden)
        // Already shown: nothing changes.
        let again = policy.attentionChanged(true)
        #expect(!again)
    }

    @Test func aRecordingShowsItWithoutChangingTheChoice() {
        let policy = MenuBarIconPolicy(hidden: true)
        #expect(policy.isShown(recording: true))
        #expect(policy.hidden)
        #expect(!policy.isShown(recording: false))
    }

    @Test func showOnlyChangesAHiddenIcon() {
        var policy = MenuBarIconPolicy()
        let unchanged = policy.show()
        #expect(!unchanged)
        policy.hide(dontAskAgain: false)
        let changed = policy.show()
        #expect(changed)
        #expect(policy.isShown(recording: false))
    }
}

@MainActor @Suite final class MenuBarIconPreferencesTests {
    let suite = "io.github.jenish-shobhit.margin.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let prefs: Preferences

    init() {
        defaults = UserDefaults(suiteName: suite)!
        prefs = Preferences(defaults: defaults)
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suite).plist")
        try? FileManager.default.removeItem(at: plist)
    }

    @Test func shownByDefault() {
        #expect(prefs.menuBarIcon == MenuBarIconPolicy())
    }

    @Test func roundTrips() {
        var policy = prefs.menuBarIcon
        policy.hide(dontAskAgain: true)
        let counter = NotificationCounter(Preferences.didChange, object: prefs)
        prefs.menuBarIcon = policy
        #expect(counter.count == 1)
        #expect(Preferences(defaults: defaults).menuBarIcon == MenuBarIconPolicy(hidden: true, skipsConfirmation: true))
        policy.show()
        prefs.menuBarIcon = policy
        #expect(prefs.menuBarIcon == MenuBarIconPolicy(skipsConfirmation: true))
        // Shown again, nothing is left behind for "hidden".
        #expect(defaults.object(forKey: "menuBarIconHidden") == nil)
    }
}
