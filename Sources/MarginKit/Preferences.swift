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

    private func set(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
