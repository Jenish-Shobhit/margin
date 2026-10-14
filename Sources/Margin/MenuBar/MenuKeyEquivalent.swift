import AppKit
import Carbon.HIToolbox
import MarginKit

/// A `KeyCombo` (Carbon key code + modifiers) as an `NSMenuItem` key equivalent, so the menu shows
/// shortcuts like ⇧⌘4 natively. Character keys go through the current ASCII-capable keyboard
/// layout, with a US-layout fallback.
struct MenuKeyEquivalent {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    init?(_ combo: KeyCombo) {
        guard let key = Self.specialKeys[Int(combo.keyCode)].map({ String(UnicodeScalar($0)!) })
            ?? Self.layoutCharacter(for: combo.keyCode)
            ?? Self.usLayout[Int(combo.keyCode)]
        else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if combo.modifiers & KeyCombo.cmd != 0 { flags.insert(.command) }
        if combo.modifiers & KeyCombo.shift != 0 { flags.insert(.shift) }
        if combo.modifiers & KeyCombo.option != 0 { flags.insert(.option) }
        if combo.modifiers & KeyCombo.control != 0 { flags.insert(.control) }
        self.key = key.lowercased()
        self.modifiers = flags
    }

    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    }

    /// Keys that aren't characters, as the function-key code points NSMenuItem expects.
    private static let specialKeys: [Int: Int] = [
        kVK_Return: 0x0D, kVK_Tab: 0x09, kVK_Space: 0x20, kVK_Delete: 0x08, kVK_Escape: 0x1B,
        kVK_ForwardDelete: NSDeleteFunctionKey, kVK_Home: NSHomeFunctionKey, kVK_End: NSEndFunctionKey,
        kVK_PageUp: NSPageUpFunctionKey, kVK_PageDown: NSPageDownFunctionKey,
        kVK_LeftArrow: NSLeftArrowFunctionKey, kVK_RightArrow: NSRightArrowFunctionKey,
        kVK_DownArrow: NSDownArrowFunctionKey, kVK_UpArrow: NSUpArrowFunctionKey,
        kVK_F1: NSF1FunctionKey, kVK_F2: NSF2FunctionKey, kVK_F3: NSF3FunctionKey, kVK_F4: NSF4FunctionKey,
        kVK_F5: NSF5FunctionKey, kVK_F6: NSF6FunctionKey, kVK_F7: NSF7FunctionKey, kVK_F8: NSF8FunctionKey,
        kVK_F9: NSF9FunctionKey, kVK_F10: NSF10FunctionKey, kVK_F11: NSF11FunctionKey, kVK_F12: NSF12FunctionKey,
        kVK_F13: NSF13FunctionKey, kVK_F14: NSF14FunctionKey, kVK_F15: NSF15FunctionKey, kVK_F16: NSF16FunctionKey,
        kVK_F17: NSF17FunctionKey, kVK_F18: NSF18FunctionKey, kVK_F19: NSF19FunctionKey, kVK_F20: NSF20FunctionKey,
    ]

    private static let usLayout: [Int: String] = [
        kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e", kVK_ANSI_F: "f",
        kVK_ANSI_G: "g", kVK_ANSI_H: "h", kVK_ANSI_I: "i", kVK_ANSI_J: "j", kVK_ANSI_K: "k", kVK_ANSI_L: "l",
        kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o", kVK_ANSI_P: "p", kVK_ANSI_Q: "q", kVK_ANSI_R: "r",
        kVK_ANSI_S: "s", kVK_ANSI_T: "t", kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x",
        kVK_ANSI_Y: "y", kVK_ANSI_Z: "z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
    ]
}
