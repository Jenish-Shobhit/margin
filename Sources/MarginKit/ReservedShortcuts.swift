import Foundation

/// Combos a Margin shortcut mustn't take. A registered hotkey wins over every app, so ⌘Q would stop quitting
/// apps everywhere and ⌃C would stop interrupting in terminals; and a combo macOS already uses for a system
/// shortcut never reaches Margin at all.
public enum ReservedShortcuts {
    /// Why `combo` can't be a Margin shortcut, or nil when it can. `systemCombos`: the bindings of the enabled
    /// system shortcuts (`SystemShortcuts.otherEnabledCombos`).
    public static func reason(for combo: KeyCombo, systemCombos: some Collection<KeyCombo> = [],
                              layout: KeyboardLayout = .current) -> String? {
        let keys = combo.displayString(layout: layout)
        if !functionKeys.contains(combo.keyCode) {
            switch combo.modifiers {
            case KeyCombo.cmd: return "Apps use ⌘ with one key (⌘C, ⌘Q…). Add ⇧, ⌥ or ⌃."
            case KeyCombo.control: return "⌃ with one key types control characters (⌃C in a terminal). Add ⇧, ⌥ or ⌘."
            default: break
            }
        }
        if let name = commonName(for: combo, layout: layout) { return "\(keys) is \(name). Choose another." }
        if systemCombos.contains(combo) { return "macOS uses \(keys) for a system shortcut. Choose another." }
        return nil
    }

    /// F1–F20, which nothing types: fine with a single modifier.
    static let functionKeys: Set<UInt32> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
        0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
    ]

    /// A key in `common`. Menu shortcuts are typed characters, so they follow the keyboard layout (Redo is ⇧⌘ on
    /// the key labelled Z, wherever a German or French layout puts it; on "Dvorak – QWERTY ⌘", on the key that types
    /// Z with ⌘ held); system shortcuts are bound to key codes.
    enum Key: Equatable {
        case character(String)
        case code(UInt32)
    }

    /// What `combo` is in `common`, on `layout`.
    static func commonName(for combo: KeyCombo, layout: KeyboardLayout) -> String? {
        let name = combo.keyName(layout: layout)
        return common.first { key, modifiers, _ in
            guard modifiers == combo.modifiers else { return false }
            switch key {
            case let .character(character): return character == name
            case let .code(code): return code == combo.keyCode
            }
        }?.2
    }

    /// Combos with two or more modifiers that macOS or most apps use. (⇧⌘5, macOS's screenshot toolbar, is Margin's
    /// Record Screen since 0.1.0: while that macOS shortcut is on, it's an enabled system shortcut like any other.)
    static let common: [(Key, UInt32, String)] = {
        let cmd = KeyCombo.cmd, shift = KeyCombo.shift, option = KeyCombo.option, control = KeyCombo.control
        return [
            (.character("Z"), cmd | shift, "Redo"),
            (.character("Q"), cmd | shift, "Log Out"),
            (.character("T"), cmd | shift, "Reopen Closed Tab"),
            (.code(0x2C), cmd | shift, "the Help menu"),
            (.code(0x35), cmd | option, "Force Quit"),
            (.code(0x02), cmd | option, "Hide or Show the Dock"),
            (.character("H"), cmd | option, "Hide Others"),
            (.character("W"), cmd | option, "Close All"),
            (.character("M"), cmd | option, "Minimize All"),
            (.code(0x31), cmd | option, "Finder search"),
            (.character("Q"), cmd | control, "Lock Screen"),
            (.character("F"), cmd | control, "Enter Full Screen"),
            (.code(0x31), cmd | control, "Emoji & Symbols"),
        ]
    }()
}
