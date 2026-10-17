import CoreGraphics
import Foundation
import MarginKit
import Testing

/// Counts notifications posted synchronously on the main thread.
final class NotificationCounter: @unchecked Sendable {
    private(set) var count = 0
    private var token: NSObjectProtocol?

    init(_ name: Notification.Name, object: AnyObject) {
        token = NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [unowned self] _ in
            self.count += 1
        }
    }

    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

/// Each test gets a fresh `UserDefaults(suiteName:)`; its domain is removed afterwards.
@MainActor @Suite final class PreferencesTests {
    let suite = "io.github.jenish-shobhit.margin.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let prefs: Preferences

    init() {
        defaults = UserDefaults(suiteName: suite)!
        prefs = Preferences(defaults: defaults)
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        // Removing the domain leaves an empty plist behind.
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suite).plist")
        try? FileManager.default.removeItem(at: plist)
    }

    @Test func defaultsMatchTheSpec() {
        #expect(prefs.saveFolder == Preferences.defaultSaveFolder)
        #expect(Preferences.defaultSaveFolder.path.hasSuffix("/Desktop/Screenshots"))
        #expect(prefs.copyEachCapture == true)
        #expect(prefs.shutterSound == true)
        #expect(prefs.launchAtLogin == true)
        #expect(prefs.completedCaptures == 0)
        #expect(prefs.firstRunDone == false)
        #expect(prefs.lastArea == nil)
        #expect(prefs.isRecordingShortcut == false)
        #expect(prefs.recordsSystemAudio == false)
        #expect(prefs.recordsMicrophone == false)
        for action in ShortcutAction.allCases {
            #expect(prefs.shortcut(for: action) == action.defaultCombo)
        }
        #expect(Preferences.fallbackSaveFolder.path.hasSuffix("/Library/Application Support/Margin/Unsaved"))
    }

    /// Everything in the Pasteboard folder goes once its card can't come back: it's never where normal shots are saved.
    @Test func thePasteboardFolderIsNeverTheSaveFolder() {
        prefs.saveFolder = Preferences.pasteboardFolder
        #expect(prefs.saveFolder == Preferences.defaultSaveFolder)
        prefs.saveFolder = Preferences.pasteboardFolder.appendingPathComponent("Shots", isDirectory: true)
        #expect(prefs.saveFolder.lastPathComponent == "Shots")
    }

    /// The startup disk ignores case: `…/margin/pasteboard`, written by hand, is the Pasteboard folder too.
    @Test func thePasteboardFolderIsNeverTheSaveFolderInAnyCase() {
        let path = Preferences.pasteboardFolder.path
        for spelling in [path.lowercased(), path.uppercased(), path + "/", path.replacingOccurrences(of: "/Pasteboard", with: "/./pAsteboard")] {
            prefs.saveFolder = URL(fileURLWithPath: spelling, isDirectory: true)
            #expect(prefs.saveFolder == Preferences.defaultSaveFolder, "\(spelling)")
        }
        prefs.saveFolder = URL(fileURLWithPath: path + " 2", isDirectory: true)
        #expect(prefs.saveFolder.lastPathComponent == "Pasteboard 2")
    }

    @Test func roundTrips() {
        let folder = URL(fileURLWithPath: "/tmp/My Shots", isDirectory: true)
        prefs.saveFolder = folder
        prefs.copyEachCapture = false
        prefs.shutterSound = false
        prefs.launchAtLogin = false
        prefs.completedCaptures = 7
        prefs.firstRunDone = true
        prefs.recordsSystemAudio = true
        prefs.recordsMicrophone = true
        let area = LastArea(rect: CGRect(x: -400.5, y: 20, width: 300, height: 200.25), displayID: 42,
                            displayFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        prefs.lastArea = area
        let combo = KeyCombo(keyCode: 0x00, modifiers: KeyCombo.cmd | KeyCombo.option)
        prefs.setShortcut(combo, for: .toggleShelf)

        // A second instance on the same defaults sees everything.
        let again = Preferences(defaults: defaults)
        #expect(again.saveFolder.path == folder.path)
        #expect(again.copyEachCapture == false)
        #expect(again.shutterSound == false)
        #expect(again.launchAtLogin == false)
        #expect(again.completedCaptures == 7)
        #expect(again.firstRunDone == true)
        #expect(again.recordsSystemAudio == true)
        #expect(again.recordsMicrophone == true)
        #expect(again.lastArea == area)
        #expect(again.shortcut(for: .toggleShelf) == combo)
        #expect(again.shortcut(for: .captureArea) == ShortcutAction.captureArea.defaultCombo)

        prefs.lastArea = nil
        #expect(again.lastArea == nil)
    }

    @Test func togglesBackToTrue() {
        prefs.copyEachCapture = false
        prefs.copyEachCapture = true
        #expect(prefs.copyEachCapture == true)
    }

    @Test func didChangeIsPostedForEveryWrite() {
        let counter = NotificationCounter(Preferences.didChange, object: prefs)
        prefs.saveFolder = URL(fileURLWithPath: "/tmp")
        prefs.copyEachCapture = false
        prefs.shutterSound = false
        prefs.launchAtLogin = false
        prefs.completedCaptures += 1
        prefs.firstRunDone = true
        prefs.lastArea = LastArea(rect: .zero, displayID: 1, displayFrame: .zero)
        prefs.setShortcut(ShortcutAction.toggleShelf.defaultCombo, for: .toggleShelf)
        prefs.resetShortcut(for: .toggleShelf)
        prefs.recordsSystemAudio = true
        prefs.recordsMicrophone = true
        #expect(counter.count == 11)
    }

    @Test func didChangeIsScopedToTheInstance() {
        let other = Preferences(defaults: defaults)
        let counter = NotificationCounter(Preferences.didChange, object: prefs)
        other.shutterSound = false
        #expect(counter.count == 0)
    }

    @Test func resetShortcut() {
        prefs.setShortcut(KeyCombo(keyCode: 0x00, modifiers: KeyCombo.cmd | KeyCombo.control), for: .captureArea)
        #expect(prefs.shortcut(for: .captureArea) != ShortcutAction.captureArea.defaultCombo)
        prefs.resetShortcut(for: .captureArea)
        #expect(prefs.shortcut(for: .captureArea) == ShortcutAction.captureArea.defaultCombo)
        #expect(defaults.object(forKey: "shortcut.captureArea") == nil)
    }

    @Test func recordingFlagPostsItsOwnNotification() {
        let changes = NotificationCounter(Preferences.didChange, object: prefs)
        let recording = NotificationCounter(Preferences.recordingShortcutDidChange, object: prefs)
        prefs.isRecordingShortcut = true
        prefs.isRecordingShortcut = true // no change → no post
        prefs.isRecordingShortcut = false
        #expect(recording.count == 2)
        #expect(changes.count == 0)
        #expect(Preferences(defaults: defaults).isRecordingShortcut == false) // not persisted
    }

    @Test func registeredCombosIncludeControlTwins() {
        let combos = prefs.registeredCombos()
        #expect(combos.count == 9)
        let area = combos.filter { $0.action == .captureArea }.map(\.combo)
        #expect(area == [ShortcutAction.captureArea.defaultCombo, ShortcutAction.captureArea.defaultCombo.withControl])
        #expect(combos.filter { $0.action == .toggleShelf }.map(\.combo) == [ShortcutAction.toggleShelf.defaultCombo])
    }

    @Test func garbageShortcutDataFallsBackToDefault() {
        defaults.set(Data("nope".utf8), forKey: "shortcut.repeatArea")
        #expect(prefs.shortcut(for: .repeatArea) == ShortcutAction.repeatArea.defaultCombo)
    }

    @Test func legacyOrGarbageLastAreaReadsAsNil() throws {
        // 0.0.8 and earlier: a rect in global points, which can't be placed on today's arrangement.
        let legacy = LegacyLastArea(rect: CGRect(x: 1600, y: 200, width: 400, height: 300), displayID: 2)
        defaults.set(try JSONEncoder().encode(legacy), forKey: "lastArea")
        #expect(defaults.data(forKey: "lastArea") != nil)
        #expect(prefs.lastArea == nil)
        defaults.set(Data("nope".utf8), forKey: "lastArea")
        #expect(prefs.lastArea == nil)
    }

    @Test func legacyLastAreaMigratesOnlyWithOneMatchingDisplay() throws {
        let main = (id: UInt32(1), frame: CGRect(x: 0, y: 0, width: 1470, height: 956))
        let legacy = LegacyLastArea(rect: CGRect(x: 326, y: 413, width: 326, height: 326), displayID: 1)
        let stored = try JSONEncoder().encode(legacy)

        // Two displays: the old global rect could belong anywhere now.
        defaults.set(stored, forKey: "lastArea")
        #expect(prefs.migrateLegacyLastArea(displays: [main, (2, CGRect(x: 1470, y: 0, width: 1920, height: 1080))]) == nil)
        // Another display, or a rect that no longer fits.
        #expect(prefs.migrateLegacyLastArea(displays: [(2, main.frame)]) == nil)
        #expect(prefs.migrateLegacyLastArea(displays: [(1, CGRect(x: 0, y: 0, width: 600, height: 500))]) == nil)
        #expect(prefs.lastArea == nil)

        // One display, the same one, the area inside it: converted and stored in the new format.
        let area = try #require(prefs.migrateLegacyLastArea(displays: [main]))
        #expect(area.rect(onDisplayFrame: main.frame) == legacy.rect)
        #expect(prefs.lastArea == area)
        // A value already in the new format is left alone.
        #expect(prefs.migrateLegacyLastArea(displays: [main]) == nil)
    }
}

@Suite struct ShortcutActionTests {
    let cs = KeyCombo.cmd | KeyCombo.shift

    @Test func defaults() {
        #expect(ShortcutAction.captureArea.defaultCombo.displayString == "⇧⌘4")
        #expect(ShortcutAction.captureScreen.defaultCombo.displayString == "⇧⌘3")
        #expect(ShortcutAction.repeatArea.defaultCombo.displayString == "⇧⌘2")
        #expect(ShortcutAction.toggleShelf.defaultCombo.displayString == "⇧⌘1")
        #expect(ShortcutAction.recordScreen.defaultCombo.displayString == "⇧⌘5")
        // Record Screen has its ⌃ twin like the capture actions; only the shelf's toggle doesn't.
        #expect(ShortcutAction.allCases.filter(\.hasControlTwin) == [.captureArea, .captureScreen, .repeatArea, .recordScreen])
        #expect(ShortcutAction.recordScreen.registeredCombos(for: ShortcutAction.recordScreen.defaultCombo)
            == [ShortcutAction.recordScreen.defaultCombo, ShortcutAction.recordScreen.defaultCombo.withControl])
    }

    @Test func registeredCombos() {
        let c = KeyCombo(keyCode: 0x15, modifiers: cs)
        #expect(ShortcutAction.captureArea.registeredCombos(for: c) == [c, c.withControl])
        #expect(ShortcutAction.toggleShelf.registeredCombos(for: c) == [c])
        // Already has ⌃: the twin would be the same combo, so it's listed once.
        #expect(ShortcutAction.captureArea.registeredCombos(for: c.withControl) == [c.withControl])
    }

    @Test func conflicts() {
        let current: (ShortcutAction) -> KeyCombo = { $0.defaultCombo }
        let area = ShortcutAction.captureArea.defaultCombo
        // Same combo as another action.
        #expect(ShortcutAction.toggleShelf.conflict(assigning: area, current: current) == .captureArea)
        // Another action's ⌃ twin.
        #expect(ShortcutAction.toggleShelf.conflict(assigning: area.withControl, current: current) == .captureArea)
        // A capture action taking the shelf's combo.
        #expect(ShortcutAction.captureArea.conflict(assigning: KeyCombo(keyCode: 0x12, modifiers: cs), current: current) == .toggleShelf)
        // A capture action whose ⌃ twin would land on another action's combo: shelf = ⌃⌥A, area = ⌥A.
        let shelfWithControl: (ShortcutAction) -> KeyCombo = {
            $0 == .toggleShelf ? KeyCombo(keyCode: 0x00, modifiers: KeyCombo.control | KeyCombo.option) : $0.defaultCombo
        }
        #expect(ShortcutAction.captureArea.conflict(assigning: KeyCombo(keyCode: 0x00, modifiers: KeyCombo.option),
                                                    current: shelfWithControl) == .toggleShelf)
        // Its own current combo is fine.
        #expect(ShortcutAction.captureArea.conflict(assigning: area, current: current) == nil)
        // Something unused.
        #expect(ShortcutAction.captureArea.conflict(assigning: KeyCombo(keyCode: 0x00, modifiers: KeyCombo.cmd | KeyCombo.option), current: current) == nil)
    }

    @Test func toggleShelfWithControlCollidesWithCaptureTwin() {
        // toggleShelf has no twin, but ⌃⇧⌘3 is captureScreen's twin.
        let current: (ShortcutAction) -> KeyCombo = { $0.defaultCombo }
        let screenTwin = ShortcutAction.captureScreen.defaultCombo.withControl
        #expect(ShortcutAction.toggleShelf.conflict(assigning: screenTwin, current: current) == .captureScreen)
    }
}
