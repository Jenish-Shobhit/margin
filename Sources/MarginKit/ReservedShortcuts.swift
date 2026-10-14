import Foundation

/// Combos a Margin shortcut mustn't take. A registered hotkey wins over every app, so ⌘Q would stop quitting
/// apps everywhere and ⌃C would stop interrupting in terminals; and a combo macOS already uses for a system
/// shortcut never reaches Margin at all.
public enum ReservedShortcuts {
    /// Why `combo` can't be a Margin shortcut, or nil when it can. `systemCombos`: the bindings of the enabled
    /// system shortcuts (`SystemShortcuts.otherEnabledCombos`).
    public static func reason(for combo: KeyCombo, systemCombos: some Collection<KeyCombo> = []) -> String? {
        let keys = combo.displayString
        if !functionKeys.contains(combo.keyCode) {
            switch combo.modifiers {
            case KeyCombo.cmd: return "Apps use ⌘ with one key (⌘C, ⌘Q…). Add ⇧, ⌥ or ⌃."
            case KeyCombo.control: return "⌃ with one key types control characters (⌃C in a terminal). Add ⇧, ⌥ or ⌘."
            default: break
            }
        }
        if let name = common[combo] { return "\(keys) is \(name). Choose another." }
        if systemCombos.contains(combo) { return "macOS uses \(keys) for a system shortcut. Choose another." }
        return nil
    }

    /// F1–F20, which nothing types: fine with a single modifier.
    static let functionKeys: Set<UInt32> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
        0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
    ]

    /// Combos with two or more modifiers that macOS or most apps use.
    static let common: [KeyCombo: String] = {
        let cmd = KeyCombo.cmd, shift = KeyCombo.shift, option = KeyCombo.option, control = KeyCombo.control
        let entries: [(UInt32, UInt32, String)] = [
            (0x06, cmd | shift, "Redo"),
            (0x0C, cmd | shift, "Log Out"),
            (0x17, cmd | shift, "the macOS screenshot toolbar"),
            (0x11, cmd | shift, "Reopen Closed Tab"),
            (0x2C, cmd | shift, "the Help menu"),
            (0x35, cmd | option, "Force Quit"),
            (0x02, cmd | option, "Hide or Show the Dock"),
            (0x04, cmd | option, "Hide Others"),
            (0x0D, cmd | option, "Close All"),
            (0x2E, cmd | option, "Minimize All"),
            (0x31, cmd | option, "Finder search"),
            (0x0C, cmd | control, "Lock Screen"),
            (0x03, cmd | control, "Enter Full Screen"),
            (0x31, cmd | control, "Emoji & Symbols"),
        ]
        return Dictionary(uniqueKeysWithValues: entries.map { (KeyCombo(keyCode: $0.0, modifiers: $0.1), $0.2) })
    }()
}
