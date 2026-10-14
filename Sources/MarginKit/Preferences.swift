import CoreGraphics
import Foundation

/// A hotkey in Carbon terms (what `RegisterEventHotKey` takes).
public struct KeyCombo: Codable, Hashable, Sendable {
    /// Carbon virtual key code (`kVK_*`).
    public var keyCode: UInt32
    /// Carbon modifier flags: cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000.
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let cmd: UInt32 = 0x100, shift: UInt32 = 0x200, option: UInt32 = 0x800, control: UInt32 = 0x1000
}

public enum ShortcutAction: String, Codable, CaseIterable, Sendable {
    case captureArea, captureScreen, repeatArea, toggleShelf

    public var defaultCombo: KeyCombo {
        let cs = KeyCombo.cmd | KeyCombo.shift
        switch self {
        case .captureArea: return KeyCombo(keyCode: 0x15, modifiers: cs)   // ⌘⇧4
        case .captureScreen: return KeyCombo(keyCode: 0x14, modifiers: cs) // ⌘⇧3
        case .repeatArea: return KeyCombo(keyCode: 0x13, modifiers: cs)    // ⌘⇧2
        case .toggleShelf: return KeyCombo(keyCode: 0x12, modifiers: cs)   // ⌘⇧1
        }
    }

    /// Capture actions also register a ⌃ twin that does the same thing.
    public var hasControlTwin: Bool { self != .toggleShelf }

    /// Every combo registered for this action when it's bound to `combo`: the combo itself plus,
    /// for capture actions, its ⌃ twin (unless `combo` already has ⌃).
    public func registeredCombos(for combo: KeyCombo) -> [KeyCombo] {
        hasControlTwin && combo != combo.withControl ? [combo, combo.withControl] : [combo]
    }

    /// The other action that already uses `combo` (directly or through a ⌃ twin), if any.
    /// `current` returns each action's binding, e.g. `Preferences.shared.shortcut(for:)`.
    public func conflict(assigning combo: KeyCombo, current: (ShortcutAction) -> KeyCombo) -> ShortcutAction? {
        let mine = Set(registeredCombos(for: combo))
        return Self.allCases.first { other in
            other != self && !mine.isDisjoint(with: other.registeredCombos(for: current(other)))
        }
    }
}

public struct LastArea: Codable, Equatable, Sendable {
    /// AppKit global points.
    public var rect: CGRect
    public var displayID: UInt32

    public init(rect: CGRect, displayID: UInt32) {
        self.rect = rect
        self.displayID = displayID
    }
}

/// The five user settings plus a little internal state. Posts `Preferences.didChange` on every write.
@MainActor
public final class Preferences {
    public static let shared = Preferences()
    public static let didChange = Notification.Name("MarginPreferencesDidChange")

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static var defaultSaveFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Screenshots", isDirectory: true)
    }

    /// Where captures go when `saveFolder` isn't writable (spec §3): `~/Library/Application Support/Margin/Unsaved`.
    public static var fallbackSaveFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Margin/Unsaved", isDirectory: true)
    }

    /// Posted (object: the `Preferences`) when `isRecordingShortcut` changes. It isn't a settings change,
    /// so `didChange` isn't posted for it.
    public static let recordingShortcutDidChange = Notification.Name("MarginPreferencesRecordingShortcutDidChange")

    public var saveFolder: URL {
        get { defaults.string(forKey: "saveFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultSaveFolder }
        set { set(newValue.path, "saveFolder") }
    }

    public var copyEachCapture: Bool {
        get { defaults.object(forKey: "copyEachCapture") as? Bool ?? true }
        set { set(newValue, "copyEachCapture") }
    }

    public var shutterSound: Bool {
        get { defaults.object(forKey: "shutterSound") as? Bool ?? true }
        set { set(newValue, "shutterSound") }
    }

    public var launchAtLogin: Bool {
        get { defaults.object(forKey: "launchAtLogin") as? Bool ?? true }
        set { set(newValue, "launchAtLogin") }
    }

    /// Successful captures so far (HUD hides after 5; first run closes after 1).
    public var completedCaptures: Int {
        get { defaults.integer(forKey: "completedCaptures") }
        set { set(newValue, "completedCaptures") }
    }

    public var firstRunDone: Bool {
        get { defaults.bool(forKey: "firstRunDone") }
        set { set(newValue, "firstRunDone") }
    }

    public var lastArea: LastArea? {
        get { defaults.data(forKey: "lastArea").flatMap { try? JSONDecoder().decode(LastArea.self, from: $0) } }
        set { set(newValue.flatMap { try? JSONEncoder().encode($0) }, "lastArea") }
    }

    public func shortcut(for action: ShortcutAction) -> KeyCombo {
        defaults.data(forKey: "shortcut.\(action.rawValue)").flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
            ?? action.defaultCombo
    }

    public func setShortcut(_ combo: KeyCombo, for action: ShortcutAction) {
        set(try? JSONEncoder().encode(combo), "shortcut.\(action.rawValue)")
    }

    /// Back to `action.defaultCombo`.
    public func resetShortcut(for action: ShortcutAction) {
        set(nil, "shortcut.\(action.rawValue)")
    }

    /// Every combo Margin should register right now: each action's shortcut plus the ⌃ twins.
    public func registeredCombos() -> [(action: ShortcutAction, combo: KeyCombo)] {
        ShortcutAction.allCases.flatMap { action in
            action.registeredCombos(for: shortcut(for: action)).map { (action: action, combo: $0) }
        }
    }

    /// True while a Settings shortcut recorder is listening for keys. The hotkey manager should unregister
    /// Margin's hotkeys while this is true, so pressing a current shortcut records it instead of firing it.
    /// Not persisted. Posts `recordingShortcutDidChange` (not `didChange`).
    public var isRecordingShortcut = false {
        didSet {
            guard isRecordingShortcut != oldValue else { return }
            NotificationCenter.default.post(name: Self.recordingShortcutDidChange, object: self)
        }
    }

    private func set(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
