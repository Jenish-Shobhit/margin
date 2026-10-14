import AppKit
import MarginKit
import Testing

@Suite struct KeyComboDisplayTests {
    let cmd = KeyCombo.cmd, shift = KeyCombo.shift, option = KeyCombo.option, control = KeyCombo.control

    @Test func modifierOrderIsControlOptionShiftCommand() {
        #expect(KeyCombo(keyCode: 0x15, modifiers: cmd | shift).displayString == "⇧⌘4")
        #expect(KeyCombo(keyCode: 0x15, modifiers: cmd | shift | control).displayString == "⌃⇧⌘4")
        #expect(KeyCombo(keyCode: 0x00, modifiers: cmd | shift | control | option).displayString == "⌃⌥⇧⌘A")
        #expect(KeyCombo(keyCode: 0x00, modifiers: option | cmd).displayString == "⌥⌘A")
        #expect(KeyCombo(keyCode: 0x00, modifiers: control | option).displayString == "⌃⌥A")
        #expect(KeyCombo(keyCode: 0x00, modifiers: 0).displayString == "A")
        #expect(KeyCombo.modifierSymbols(cmd | shift | control | option) == "⌃⌥⇧⌘")
    }

    @Test(arguments: [
        (UInt32(0x00), "A"), (0x0B, "B"), (0x08, "C"), (0x06, "Z"), (0x0C, "Q"), (0x10, "Y"),
        (0x1D, "0"), (0x12, "1"), (0x13, "2"), (0x14, "3"), (0x15, "4"), (0x17, "5"), (0x16, "6"),
        (0x1A, "7"), (0x1C, "8"), (0x19, "9"),
        (0x7A, "F1"), (0x78, "F2"), (0x63, "F3"), (0x76, "F4"), (0x60, "F5"), (0x61, "F6"),
        (0x62, "F7"), (0x64, "F8"), (0x65, "F9"), (0x6D, "F10"), (0x67, "F11"), (0x6F, "F12"),
        (0x31, "Space"), (0x24, "↩"), (0x30, "⇥"), (0x33, "⌫"), (0x75, "⌦"), (0x35, "⎋"),
        (0x7B, "←"), (0x7C, "→"), (0x7D, "↓"), (0x7E, "↑"),
        (0x1B, "-"), (0x18, "="), (0x2C, "/"), (0x2A, "\\"),
    ])
    func keyNames(code: UInt32, name: String) {
        #expect(KeyCombo.keyName(for: code) == name)
        #expect(KeyCombo.keyCode(for: name) == code)
    }

    @Test func everyLetterAndDigitRoundTrips() {
        for ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" {
            let code = KeyCombo.keyCode(for: String(ch))
            #expect(code != nil, "no key code for \(ch)")
            #expect(code.flatMap(KeyCombo.keyName(for:)) == String(ch))
        }
    }

    @Test func allKeyCodesAreDistinct() {
        let names = (0..<128).compactMap { KeyCombo.keyName(for: UInt32($0)) }
        #expect(Set(names).count == names.count)
        #expect(names.count >= 26 + 10 + 20 + 10)
    }

    @Test func lettersAreCaseInsensitive() {
        #expect(KeyCombo.keyCode(for: "a") == 0x00)
        #expect(KeyCombo.keyCode(for: "z") == 0x06)
    }

    @Test func wordAliases() {
        #expect(KeyCombo.keyCode(for: "Return") == 0x24)
        #expect(KeyCombo.keyCode(for: "Escape") == 0x35)
        #expect(KeyCombo.keyCode(for: "Delete") == 0x33)
        #expect(KeyCombo.keyCode(for: "Tab") == 0x30)
        #expect(KeyCombo.keyCode(for: "Left") == 0x7B)
        #expect(KeyCombo.keyCode(for: " ") == 0x31)
        #expect(KeyCombo.keyCode(for: "nope") == nil)
    }

    @Test func specialKeysInCombos() {
        #expect(KeyCombo(keyCode: 0x31, modifiers: option | cmd).displayString == "⌥⌘Space")
        #expect(KeyCombo(keyCode: 0x7E, modifiers: control | cmd).displayString == "⌃⌘↑")
        #expect(KeyCombo(keyCode: 0x6F, modifiers: shift | cmd).displayString == "⇧⌘F12")
        #expect(KeyCombo(keyCode: 0x24, modifiers: cmd).displayString == "⌘↩")
    }

    @Test func unknownKeyCodeStillDisplays() {
        #expect(KeyCombo.keyName(for: 0x3F) == nil) // fn
        #expect(KeyCombo(keyCode: 0x3F, modifiers: cmd).displayString == "⌘#63")
    }

    @Test func requiredModifier() {
        #expect(!KeyCombo(keyCode: 0x15, modifiers: 0).hasRequiredModifier)
        #expect(!KeyCombo(keyCode: 0x15, modifiers: shift).hasRequiredModifier)
        #expect(KeyCombo(keyCode: 0x15, modifiers: cmd).hasRequiredModifier)
        #expect(KeyCombo(keyCode: 0x15, modifiers: control).hasRequiredModifier)
        #expect(KeyCombo(keyCode: 0x15, modifiers: option | shift).hasRequiredModifier)
    }

    @Test func controlTwin() {
        let c = KeyCombo(keyCode: 0x15, modifiers: cmd | shift)
        #expect(c.withControl == KeyCombo(keyCode: 0x15, modifiers: cmd | shift | control))
        #expect(c.withControl.withControl == c.withControl)
    }

    @Test func cocoaCarbonModifierConversion() {
        let flags: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        #expect(KeyCombo.carbonModifiers(from: flags) == cmd | shift | option | control)
        #expect(KeyCombo.carbonModifiers(from: [.command, .capsLock, .function, .numericPad]) == cmd)
        #expect(KeyCombo.carbonModifiers(from: []) == 0)
        for m in [cmd, shift, option, control, cmd | shift, control | option | cmd] {
            #expect(KeyCombo.carbonModifiers(from: KeyCombo.cocoaModifiers(from: m)) == m)
        }
        let combo = KeyCombo(keyCode: UInt16(0x15), cocoaModifiers: [.command, .shift])
        #expect(combo == ShortcutAction.captureArea.defaultCombo)
    }

    @Test func codableRoundTrip() throws {
        let c = KeyCombo(keyCode: 0x7A, modifiers: control | option)
        #expect(try JSONDecoder().decode(KeyCombo.self, from: JSONEncoder().encode(c)) == c)
    }
}
