import Foundation
import MarginKit
import Testing

@Suite struct ReservedShortcutsTests {
    let cmd = KeyCombo.cmd, shift = KeyCombo.shift, option = KeyCombo.option, control = KeyCombo.control

    @Test func oneModifierWithATypingKeyIsRefused() {
        #expect(ReservedShortcuts.reason(for: KeyCombo(keyCode: 0x0C, modifiers: cmd)) != nil)     // ⌘Q
        #expect(ReservedShortcuts.reason(for: KeyCombo(keyCode: 0x09, modifiers: cmd)) != nil)     // ⌘V
        #expect(ReservedShortcuts.reason(for: KeyCombo(keyCode: 0x31, modifiers: cmd)) != nil)     // ⌘Space
        #expect(ReservedShortcuts.reason(for: KeyCombo(keyCode: 0x08, modifiers: control)) != nil) // ⌃C
        #expect(ReservedShortcuts.reason(for: KeyCombo(keyCode: 0x7B, modifiers: control)) != nil) // ⌃←
        // F-keys type nothing, so one modifier is fine.
        #expect(ReservedShortcuts.reason(for: KeyCombo(keyCode: 0x7A, modifiers: cmd)) == nil)     // ⌘F1
    }

    @Test func commonTwoModifierCombosAreRefused() {
        #expect(ReservedShortcuts.reason(for: KeyCombo(keyCode: 0x06, modifiers: cmd | shift)) == "⇧⌘Z is Redo. Choose another.")
        #expect(ReservedShortcuts.reason(for: KeyCombo(keyCode: 0x17, modifiers: cmd | shift)) != nil)   // ⇧⌘5
        #expect(ReservedShortcuts.reason(for: KeyCombo(keyCode: 0x35, modifiers: cmd | option)) != nil)  // ⌥⌘⎋
        #expect(ReservedShortcuts.reason(for: KeyCombo(keyCode: 0x0C, modifiers: cmd | control)) != nil) // ⌃⌘Q
    }

    @Test func marginDefaultsAndOrdinaryCombosAreAllowed() {
        for action in ShortcutAction.allCases {
            for combo in action.registeredCombos(for: action.defaultCombo) {
                #expect(ReservedShortcuts.reason(for: combo) == nil, "\(combo.displayString)")
            }
        }
        #expect(ReservedShortcuts.reason(for: KeyCombo(keyCode: 0x00, modifiers: cmd | option | shift)) == nil) // ⌥⇧⌘A
    }

    @Test func enabledSystemShortcutsAreRefused() {
        // Spotlight (64) on ⌘Space, Mission Control (32) on ⌃↑ turned off, the screenshot toolbar (184) on ⌥⇧⌘S,
        // and ⇧⌘4 (30): the four screenshot IDs are Margin's to handle, so they don't count.
        let hotkeys: [String: Any] = [
            "64": ["enabled": true, "value": ["parameters": [32, 49, 1_048_576], "type": "standard"]],
            "32": ["enabled": false, "value": ["parameters": [65535, 126, 8_650_752], "type": "standard"]],
            "184": ["enabled": 1, "value": ["parameters": [115, 1, 1_703_936], "type": "standard"]],
            "30": ["enabled": true, "value": ["parameters": [52, 21, 1_179_648], "type": "standard"]],
        ]
        let system = SystemShortcuts.otherEnabledCombos(hotkeys)
        let toolbar = KeyCombo(keyCode: 0x01, modifiers: cmd | shift | option)
        #expect(system == [KeyCombo(keyCode: 0x31, modifiers: cmd), toolbar])
        #expect(ReservedShortcuts.reason(for: toolbar, systemCombos: system) == "macOS uses ⌥⇧⌘S for a system shortcut. Choose another.")
        #expect(ReservedShortcuts.reason(for: ShortcutAction.captureArea.defaultCombo, systemCombos: system) == nil)
        #expect(SystemShortcuts.otherEnabledCombos(nil).isEmpty)
    }
}
