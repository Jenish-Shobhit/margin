import Foundation
import MarginKit
import Testing

@MainActor @Test func captureHintsShowUntilTurnedOff() {
    let suite = "margin.tests.hints.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(10, forKey: "hintCaptures.r3") // 0.0.5–0.0.7 hid the bar after 5 captures; that count no longer matters
    let prefs = Preferences(defaults: defaults)
    prefs.completedCaptures = 40
    #expect(prefs.showsCaptureHints)
    prefs.showsCaptureHints = false
    #expect(!prefs.showsCaptureHints)
    prefs.showsCaptureHints = true
    #expect(prefs.showsCaptureHints)
}

@MainActor @Test func obsoleteHintCountsAreRemoved() {
    let suite = "margin.tests.hints.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(10, forKey: "hintCaptures.r3")
    defaults.set(5, forKey: "hintCaptures.r2")
    let prefs = Preferences(defaults: defaults)
    prefs.completedCaptures = 40
    prefs.removeObsoleteKeys()
    #expect(defaults.object(forKey: "hintCaptures.r3") == nil)
    #expect(defaults.object(forKey: "hintCaptures.r2") == nil)
    #expect(prefs.completedCaptures == 40)
}
