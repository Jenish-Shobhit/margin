import MarginKit
import Testing

@Suite struct KeyboardLayoutTests {
    let cmd = KeyCombo.cmd, shift = KeyCombo.shift, option = KeyCombo.option, control = KeyCombo.control

    /// A few keys of a German (QWERTZ) layout: Y and Z swapped, ß and ´ where US has - and =.
    static let qwertz = KeyboardLayout(id: "qwertz") { code, shift in
        let keys: [UInt32: (String, String)] = [
            0x10: ("z", "Z"), 0x06: ("y", "Y"), 0x00: ("a", "A"), 0x15: ("4", "$"), 0x1B: ("ß", "?"), 0x18: ("´", "`"),
            0x29: ("ö", "Ö"),
        ]
        return keys[code].map { shift ? $0.1 : $0.0 }
    }

    /// A few keys of a French (AZERTY) layout: A/Q and Z/W swapped, symbols on the digit row (digits need ⇧).
    static let azerty = KeyboardLayout(id: "azerty") { code, shift in
        let keys: [UInt32: (String, String)] = [
            0x0C: ("a", "A"), 0x00: ("q", "Q"), 0x0D: ("z", "Z"), 0x06: ("w", "W"),
            0x15: ("'", "4"), 0x12: ("&", "1"), 0x1D: ("à", "0"),
        ]
        return keys[code].map { shift ? $0.1 : $0.0 }
    }

    @Test func charactersFollowTheLayout() {
        #expect(KeyCombo(keyCode: 0x10, modifiers: control | option | cmd).displayString(layout: Self.qwertz) == "⌃⌥⌘Z")
        #expect(KeyCombo(keyCode: 0x06, modifiers: cmd).displayString(layout: Self.qwertz) == "⌘Y")
        #expect(KeyCombo(keyCode: 0x29, modifiers: cmd).displayString(layout: Self.qwertz) == "⌘Ö")
        #expect(KeyCombo(keyCode: 0x0C, modifiers: shift | cmd).displayString(layout: Self.azerty) == "⇧⌘A")
        #expect(KeyCombo(keyCode: 0x00, modifiers: shift | cmd).displayString(layout: Self.azerty) == "⇧⌘Q")
        #expect(KeyCombo(keyCode: 0x0D, modifiers: cmd).displayString(layout: Self.azerty) == "⌘Z")
    }

    @Test func theSameKeysHaveUSNamesWithoutALayout() {
        #expect(KeyCombo(keyCode: 0x10, modifiers: control | option | cmd).displayString(layout: .us) == "⌃⌥⌘Y")
        #expect(KeyCombo(keyCode: 0x0C, modifiers: shift | cmd).displayString(layout: .us) == "⇧⌘Q")
        #expect(KeyboardLayout.us.characterName(for: 0x10) == nil)
        #expect(KeyboardLayout.us.inputSourceID == nil)
    }

    /// The French digit row types symbols; macOS still calls those keys 1–0 (⇧⌘4 is the area shortcut there too).
    @Test func digitRowKeepsItsDigitsWhereTheyNeedShift() {
        #expect(ShortcutAction.captureArea.defaultCombo.displayString(layout: Self.azerty) == "⇧⌘4")
        #expect(KeyCombo.keyName(for: 0x12, layout: Self.azerty) == "1")
        #expect(KeyCombo.keyName(for: 0x1D, layout: Self.azerty) == "0")
        // A digit typed without ⇧ stays the digit, never its shifted symbol.
        #expect(KeyCombo.keyName(for: 0x15, layout: Self.qwertz) == "4")
    }

    @Test func specialKeysKeepTheirSymbols() {
        let everythingIsX = KeyboardLayout { _, _ in "x" }
        #expect(KeyCombo(keyCode: 0x31, modifiers: option | cmd).displayString(layout: everythingIsX) == "⌥⌘Space")
        #expect(KeyCombo(keyCode: 0x7E, modifiers: control | cmd).displayString(layout: everythingIsX) == "⌃⌘↑")
        #expect(KeyCombo(keyCode: 0x6F, modifiers: shift | cmd).displayString(layout: everythingIsX) == "⇧⌘F12")
        #expect(KeyCombo(keyCode: 0x24, modifiers: cmd).displayString(layout: everythingIsX) == "⌘↩")
        #expect(KeyCombo(keyCode: 0x35, modifiers: cmd).displayString(layout: everythingIsX) == "⌘⎋")
        // The layout renames keys; it never makes an unnamed key (fn, keypad) nameable.
        #expect(KeyCombo.keyName(for: 0x3F, layout: everythingIsX) == nil)
        #expect(KeyCombo.keyName(for: 0x53, layout: everythingIsX) == nil)
    }

    @Test func unprintableOrMissingCharactersFallBackToUSNames() {
        let odd = KeyboardLayout { code, _ in
            switch code {
            case 0x00: return nil
            case 0x0B: return "\u{10}"
            case 0x08: return " "
            case 0x02: return ""
            default: return "ab"
            }
        }
        #expect(KeyCombo.keyName(for: 0x00, layout: odd) == "A")
        #expect(KeyCombo.keyName(for: 0x0B, layout: odd) == "B")
        #expect(KeyCombo.keyName(for: 0x08, layout: odd) == "C")
        #expect(KeyCombo.keyName(for: 0x02, layout: odd) == "D")
        #expect(KeyCombo.keyName(for: 0x0E, layout: odd) == "E")
    }

    /// ß upper-cases to SS: a name stays one character.
    @Test func lettersAreUpperCasedWhenThatStaysOneCharacter() {
        #expect(KeyCombo.keyName(for: 0x1B, layout: Self.qwertz) == "ß")
        #expect(KeyCombo.keyName(for: 0x18, layout: Self.qwertz) == "´")
        #expect(KeyCombo.keyName(for: 0x00, layout: Self.qwertz) == "A")
    }

    /// The overlay catches Z by where the layout has it.
    @Test func keyCodeForACharacterFollowsTheLayout() {
        #expect(KeyCombo.keyCode(forCharacter: "Z", layout: Self.qwertz) == 0x10)
        #expect(KeyCombo.keyCode(forCharacter: "z", layout: Self.azerty) == 0x0D)
        #expect(KeyCombo.keyCode(forCharacter: "A", layout: Self.azerty) == 0x0C)
        #expect(KeyCombo.keyCode(forCharacter: "Z", layout: .us) == 0x06)
        // Not on this (partial) layout: the US key.
        #expect(KeyCombo.keyCode(forCharacter: "B", layout: Self.qwertz) == 0x0B)
    }

    // MARK: Installed layouts (UCKeyTranslate)

    @MainActor @Test func germanLayout() throws {
        let german = try #require(KeyboardLayout(inputSourceID: "com.apple.keylayout.German"))
        #expect(german.inputSourceID == "com.apple.keylayout.German")
        #expect(KeyCombo(keyCode: 0x10, modifiers: control | option | cmd).displayString(layout: german) == "⌃⌥⌘Z")
        #expect(KeyCombo.keyName(for: 0x06, layout: german) == "Y")
        #expect(KeyCombo.keyName(for: 0x29, layout: german) == "Ö")
        #expect(KeyCombo.keyName(for: 0x1B, layout: german) == "ß")
        #expect(ShortcutAction.captureArea.defaultCombo.displayString(layout: german) == "⇧⌘4")
    }

    @MainActor @Test func frenchLayout() throws {
        let french = try #require(KeyboardLayout(inputSourceID: "com.apple.keylayout.French"))
        #expect(KeyCombo(keyCode: 0x0C, modifiers: shift | cmd).displayString(layout: french) == "⇧⌘A")
        #expect(KeyCombo.keyName(for: 0x00, layout: french) == "Q")
        #expect(KeyCombo.keyName(for: 0x0D, layout: french) == "Z")
        #expect(KeyCombo.keyName(for: 0x06, layout: french) == "W")
        for action in ShortcutAction.allCases {
            #expect(action.defaultCombo.displayString(layout: french) == action.defaultCombo.displayString(layout: .us))
        }
    }

    @MainActor @Test func usLayoutMatchesTheBuiltInNames() throws {
        let us = try #require(KeyboardLayout(inputSourceID: "com.apple.keylayout.US"))
        for code in UInt32(0)..<128 {
            #expect(KeyCombo.keyName(for: code, layout: us) == KeyCombo.keyName(for: code, layout: .us), "key code \(code)")
        }
    }
}
