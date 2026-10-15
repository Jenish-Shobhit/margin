import AppKit

/// Display strings and key-code mapping for `KeyCombo`.
/// Carbon virtual key codes are named after the ANSI (US) layout. Character keys (letters, digits, punctuation)
/// are shown the way the user's keyboard layout labels them (`KeyboardLayout`); special keys keep their symbols.
extension KeyCombo {
    /// "⇧⌘4", "⌃⇧⌘4", "⌥⌘Space": modifiers in the macOS menu order ⌃⌥⇧⌘, then the key, on the current layout.
    public var displayString: String { displayString(layout: .current) }

    /// `displayString`, with character keys named by `layout`.
    public func displayString(layout: KeyboardLayout) -> String {
        Self.modifierSymbols(modifiers) + (keyName(layout: layout) ?? "#\(keyCode)")
    }

    /// This combo's key, as `keyName(for:command:layout:)` names it with the combo's ⌘.
    public func keyName(layout: KeyboardLayout = .current) -> String? {
        Self.keyName(for: keyCode, command: modifiers & Self.cmd != 0, layout: layout)
    }

    /// The modifier symbols in the macOS menu order ⌃⌥⇧⌘ (e.g. "⌃⇧⌘").
    public static func modifierSymbols(_ modifiers: UInt32) -> String {
        var s = ""
        if modifiers & control != 0 { s += "⌃" }
        if modifiers & option != 0 { s += "⌥" }
        if modifiers & shift != 0 { s += "⇧" }
        if modifiers & cmd != 0 { s += "⌘" }
        return s
    }

    /// True when the combo has ⌘ or ⌃, which a global shortcut needs.
    /// ⇧ and ⌥ alone aren't enough: ⌥/⌥⇧ + key types characters (å, Ø), macOS 15.0–15.1 refused such hotkeys,
    /// and macOS still drops them while Secure Input is on (password fields, Terminal's Secure Keyboard Entry).
    public var hasRequiredModifier: Bool { modifiers & (Self.cmd | Self.control) != 0 }

    /// The same combo with ⌃ added (the "twin" that capture actions also register).
    public var withControl: KeyCombo { KeyCombo(keyCode: keyCode, modifiers: modifiers | Self.control) }

    /// Builds a combo from an AppKit key event's key code and modifier flags.
    public init(keyCode: UInt16, cocoaModifiers: NSEvent.ModifierFlags) {
        self.init(keyCode: UInt32(keyCode), modifiers: Self.carbonModifiers(from: cocoaModifiers))
    }

    /// AppKit modifier flags → Carbon modifier bits (only ⌘ ⇧ ⌥ ⌃ are kept).
    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= cmd }
        if flags.contains(.shift) { m |= shift }
        if flags.contains(.option) { m |= option }
        if flags.contains(.control) { m |= control }
        return m
    }

    /// Carbon modifier bits → AppKit modifier flags.
    public static func cocoaModifiers(from carbon: UInt32) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if carbon & cmd != 0 { f.insert(.command) }
        if carbon & shift != 0 { f.insert(.shift) }
        if carbon & option != 0 { f.insert(.option) }
        if carbon & control != 0 { f.insert(.control) }
        return f
    }

    /// What the key is called on a menu, on the current keyboard layout: "A", "4", "F5", "Space", "↩", "←", …
    /// Nil for keys without a name here.
    public static func keyName(for keyCode: UInt32) -> String? {
        keyName(for: keyCode, layout: .current)
    }

    /// `keyName(for:)` on `layout`, as the key types with ⌘ held when `command` (in a combo with ⌘: on "Dvorak –
    /// QWERTY ⌘", key code 0x06 is ; alone but Z with ⌘). Only the keys named here can be shortcuts: the layout
    /// changes what a character key is called (key code 0x10 is Z on a German layout), never which keys have a name.
    public static func keyName(for keyCode: UInt32, command: Bool = false, layout: KeyboardLayout) -> String? {
        guard let us = keyNames[keyCode] else { return nil }
        guard characterKeyNames[keyCode] != nil else { return us }
        return layout.characterName(for: keyCode, command: command) ?? us
    }

    /// The character key named `name` on `layout` without ⌘ ("Z" is key code 0x10 on a German layout), or its US
    /// key code.
    public static func keyCode(forCharacter name: String, layout: KeyboardLayout) -> UInt32? {
        let name = name.uppercased()
        return characterKeyNames.keys.sorted().first { layout.characterName(for: $0, command: false) == name } ?? keyCode(for: name)
    }

    /// The Carbon key code for a key's US name (what `keyName(for:)` says before the app reads the keyboard layout).
    /// Letters are case-insensitive.
    public static func keyCode(for name: String) -> UInt32? {
        let key = name.count == 1 ? name.uppercased() : name
        return keyCodes[key]
    }

    /// The character keys, by what they type on an ANSI (US) keyboard. Key codes from `<HIToolbox/Events.h>`
    /// (`kVK_ANSI_*`).
    static let characterKeyNames: [UInt32: String] = [
        // ANSI letters
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G", 0x04: "H",
        0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P",
        0x0C: "Q", 0x0F: "R", 0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z",
        // ANSI digits
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7",
        0x1C: "8", 0x19: "9",
        // ANSI punctuation
        0x1B: "-", 0x18: "=", 0x21: "[", 0x1E: "]", 0x2A: "\\", 0x29: ";", 0x27: "'", 0x32: "`",
        0x2B: ",", 0x2F: ".", 0x2C: "/",
    ]

    /// Every key with a name, by its US name. Key codes from `<HIToolbox/Events.h>` (`kVK_*`).
    static let keyNames: [UInt32: String] = {
        var names = characterKeyNames.merging([
            // Named keys
            0x31: "Space", 0x24: "↩", 0x4C: "⌤", 0x30: "⇥", 0x33: "⌫", 0x75: "⌦", 0x35: "⎋",
            0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
            0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟",
        ]) { current, _ in current }
        let functionKeys: [UInt32] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
                                      0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A]
        for (i, code) in functionKeys.enumerated() { names[code] = "F\(i + 1)" }
        return names
    }()

    static let keyCodes: [String: UInt32] = {
        var codes = Dictionary(uniqueKeysWithValues: keyNames.map { ($0.value, $0.key) })
        // Word aliases for the symbol-named keys.
        let aliases: [String: UInt32] = [
            "Return": 0x24, "Enter": 0x4C, "Tab": 0x30, "Delete": 0x33, "ForwardDelete": 0x75,
            "Escape": 0x35, "Esc": 0x35, "Left": 0x7B, "Right": 0x7C, "Down": 0x7D, "Up": 0x7E,
            "Home": 0x73, "End": 0x77, "PageUp": 0x74, "PageDown": 0x79, " ": 0x31,
        ]
        codes.merge(aliases) { current, _ in current }
        return codes
    }()
}
