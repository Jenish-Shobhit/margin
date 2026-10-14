import AppKit
import MarginKit

/// A `KeyCombo` as an `NSMenuItem` key equivalent, so the menu draws shortcuts natively (⇧⌘4,
/// right-aligned). Built from MarginKit's key names, so it matches `KeyCombo.displayString` in Settings.
struct MenuKeyEquivalent {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    init?(_ combo: KeyCombo) {
        guard let name = KeyCombo.keyName(for: combo.keyCode) else { return nil }
        if let special = Self.specialKeys[name] {
            key = String(UnicodeScalar(UInt16(special)).map(Character.init) ?? " ")
        } else if name.count == 1 {
            key = name.lowercased()
        } else if name.hasPrefix("F"), let n = Int(name.dropFirst()), (1...35).contains(n) {
            key = String(Character(UnicodeScalar(UInt16(NSF1FunctionKey + n - 1))!))
        } else {
            return nil
        }
        modifiers = KeyCombo.cocoaModifiers(from: combo.modifiers)
    }

    /// MarginKit key names that aren't the character NSMenuItem expects.
    private static let specialKeys: [String: Int] = [
        "Space": 0x20, "↩": 0x0D, "⌤": 0x03, "⇥": 0x09, "⌫": 0x08, "⎋": 0x1B,
        "⌦": NSDeleteFunctionKey, "↖": NSHomeFunctionKey, "↘": NSEndFunctionKey,
        "⇞": NSPageUpFunctionKey, "⇟": NSPageDownFunctionKey,
        "←": NSLeftArrowFunctionKey, "→": NSRightArrowFunctionKey,
        "↓": NSDownArrowFunctionKey, "↑": NSUpArrowFunctionKey,
    ]
}
