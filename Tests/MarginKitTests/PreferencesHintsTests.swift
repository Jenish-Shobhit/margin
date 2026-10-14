import Foundation
import MarginKit
import Testing

@MainActor @Test func captureHintsShowForFiveCapturesPerRevision() {
    let suite = "margin.tests.hints.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let prefs = Preferences(defaults: defaults)
    prefs.completedCaptures = 40 // an existing user past the old 5-capture limit
    #expect(prefs.showsCaptureHints)
    for _ in 0..<4 { prefs.capturesSinceHintsChanged += 1 }
    #expect(prefs.showsCaptureHints)
    prefs.capturesSinceHintsChanged += 1
    #expect(!prefs.showsCaptureHints)
}
