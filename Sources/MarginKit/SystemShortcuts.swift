import Foundation

public struct SystemScreenshotShortcut: Equatable, Sendable, Identifiable {
    public let id: Int
    public let title: String
    public let keys: String
    public let enabled: Bool
}

/// Reads (never writes) the macOS screenshot shortcuts from `com.apple.symbolichotkeys`.
/// IDs 28–31. A missing entry means the shortcut is still enabled (the macOS default).
public enum SystemShortcuts {
    public static let catalog: [(id: Int, title: String, keys: String)] = [
        (28, "Save picture of screen as a file", "⌘⇧3"),
        (29, "Copy picture of screen to the clipboard", "⌃⌘⇧3"),
        (30, "Save picture of selected area as a file", "⌘⇧4"),
        (31, "Copy picture of selected area to the clipboard", "⌃⌘⇧4"),
    ]

    public static func parse(_ hotkeys: [String: Any]?) -> [SystemScreenshotShortcut] {
        catalog.map { entry in
            let e = hotkeys?[String(entry.id)] as? [String: Any]
            let enabled = (e?["enabled"] as? NSNumber)?.boolValue ?? true
            return SystemScreenshotShortcut(id: entry.id, title: entry.title, keys: entry.keys, enabled: enabled)
        }
    }

    public static func current() -> [SystemScreenshotShortcut] {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        let value = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any]
        return parse(value)
    }
}
