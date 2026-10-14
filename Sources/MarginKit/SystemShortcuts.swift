import Foundation

public struct SystemScreenshotShortcut: Equatable, Sendable, Identifiable {
    public let id: Int
    public let title: String
    /// The binding as shown in System Settings, e.g. "⇧⌘4" (`combo.displayString`).
    public let keys: String
    public let enabled: Bool
    /// The binding macOS uses: read from the entry's `parameters`, or the macOS default when absent.
    public let combo: KeyCombo
}

/// Reads (never writes) the macOS screenshot shortcuts from `com.apple.symbolichotkeys`.
/// IDs 28–31. A missing entry means the shortcut is still enabled (the macOS default).
public enum SystemShortcuts {
    /// Keys are in the macOS menu order (⌃⌥⇧⌘), matching System Settings › Keyboard Shortcuts › Screenshots.
    public static let catalog: [(id: Int, title: String, keys: String)] = [
        (28, "Save picture of screen as a file", "⇧⌘3"),
        (29, "Copy picture of screen to the clipboard", "⌃⇧⌘3"),
        (30, "Save picture of selected area as a file", "⇧⌘4"),
        (31, "Copy picture of selected area to the clipboard", "⌃⇧⌘4"),
    ]

    /// The macOS default binding for IDs 28–31.
    public static func defaultCombo(forID id: Int) -> KeyCombo? {
        let cs = KeyCombo.cmd | KeyCombo.shift
        switch id {
        case 28: return KeyCombo(keyCode: 0x14, modifiers: cs)
        case 29: return KeyCombo(keyCode: 0x14, modifiers: cs | KeyCombo.control)
        case 30: return KeyCombo(keyCode: 0x15, modifiers: cs)
        case 31: return KeyCombo(keyCode: 0x15, modifiers: cs | KeyCombo.control)
        default: return nil
        }
    }

    /// `hotkeys` is the `AppleSymbolicHotKeys` dictionary. Each entry looks like
    /// `{ enabled = 1; value = { parameters = (52, 21, 1179648); type = standard; }; }`, where the
    /// parameters are (character, Carbon key code, AppKit modifier flags).
    public static func parse(_ hotkeys: [String: Any]?) -> [SystemScreenshotShortcut] {
        catalog.map { entry in
            let e = hotkeys?[String(entry.id)] as? [String: Any]
            let enabled = e.flatMap { boolValue($0["enabled"]) } ?? true
            let combo = e.flatMap(parseCombo) ?? defaultCombo(forID: entry.id)!
            return SystemScreenshotShortcut(id: entry.id, title: entry.title, keys: combo.displayString,
                                            enabled: enabled, combo: combo)
        }
    }

    public static func current() -> [SystemScreenshotShortcut] {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        let value = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any]
        return parse(value)
    }

    /// The enabled system shortcuts whose binding is one of `combos` (e.g. `Preferences.registeredCombos()`).
    /// macOS takes these keys before Margin sees them, so these are the boxes the user still has to untick.
    public static func conflicts(_ shortcuts: [SystemScreenshotShortcut], with combos: [KeyCombo]) -> [SystemScreenshotShortcut] {
        let taken = Set(combos)
        return shortcuts.filter { $0.enabled && taken.contains($0.combo) }
    }

    static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let n as NSNumber: return n.boolValue
        case let b as Bool: return b
        case let i as Int: return i != 0
        case let s as String: return (s as NSString).boolValue
        default: return nil
        }
    }

    static func parseCombo(_ entry: [String: Any]) -> KeyCombo? {
        guard let value = entry["value"] as? [String: Any],
              let params = value["parameters"] as? [Any], params.count >= 3,
              let keyCode = (params[1] as? NSNumber)?.intValue,
              let flags = (params[2] as? NSNumber)?.intValue,
              keyCode >= 0, keyCode < 0xFFFF else { return nil }
        // AppKit flags: shift 1<<17, control 1<<18, option 1<<19, command 1<<20.
        var m: UInt32 = 0
        if flags & (1 << 17) != 0 { m |= KeyCombo.shift }
        if flags & (1 << 18) != 0 { m |= KeyCombo.control }
        if flags & (1 << 19) != 0 { m |= KeyCombo.option }
        if flags & (1 << 20) != 0 { m |= KeyCombo.cmd }
        return KeyCombo(keyCode: UInt32(keyCode), modifiers: m)
    }
}
