import AppKit
import Carbon.HIToolbox
import MarginKit
import os

/// The overlay's keys as Carbon hotkeys, so they reach it from the moment ⌘⇧4 is pressed, before it can be key.
///
/// The overlay becomes key only once the first frozen frame is on screen. Sooner, it would take key status from the
/// frontmost window while ScreenCaptureKit is still grabbing the frame, and the shot would show that window
/// unfocused: a grey selection, no caret (made key at once, 11 of 12 test frames caught the window unfocused).
/// Until then a key would reach the frontmost app instead: Space typed into a document, Esc taking a full-screen app
/// out of full screen. So Esc, Space, ↩, ⌤, Z and the arrows, alone or with any of ⇧ ⌥ ⌃, are registered when the
/// capture starts: Carbon hotkeys need no permission and keep the key from the frontmost app. Each press (and
/// release) is handed on as a key event. Registering the 72 combos takes 2–4 ms.
///
/// Unregistering a hotkey drops a press of it that's still waiting in the event queue, so only the arrows go when
/// the overlay becomes key (they need key repeat, which hotkeys don't have; there's no selection to nudge yet then).
/// The others stay until the capture ends.
@MainActor
final class OverlayHotkeys {
    private static let log = Logger(subsystem: AppCoordinator.subsystem, category: "hotkeys")
    /// 'MRGK'
    private static let signature: OSType = 0x4D52_474B
    /// The instance the Carbon callback dispatches to.
    private static weak var active: OverlayHotkeys?
    private static var handlerRef: EventHandlerRef?

    private struct Combo {
        let keyCode: UInt16
        let modifiers: UInt32
        let characters: String
        let ref: EventHotKeyRef
    }

    private let onKey: (NSEvent) -> Void
    /// Registered combos by hotkey ID.
    private var combos: [UInt32: Combo] = [:]

    init(onKey: @escaping (NSEvent) -> Void) {
        self.onKey = onKey
    }

    /// The keys, with the characters they type (Z where the keyboard layout has it).
    private static func keys() -> [(UInt16, String)] {
        let z = UInt16(KeyCombo.keyCode(forCharacter: "Z", layout: .current) ?? UInt32(kVK_ANSI_Z))
        return [
            (UInt16(kVK_Escape), "\u{1B}"), (UInt16(kVK_Space), " "), (UInt16(kVK_Return), "\r"),
            (UInt16(kVK_ANSI_KeypadEnter), "\u{3}"), (z, "z"),
        ] + arrows.map { ($0, String(Character(UnicodeScalar(UInt16(arrowCharacters[$0]!))!))) }
    }

    private static let arrows = [UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow), UInt16(kVK_DownArrow), UInt16(kVK_UpArrow)]
    private static let arrowCharacters: [UInt16: Int] = [
        UInt16(kVK_LeftArrow): NSLeftArrowFunctionKey, UInt16(kVK_RightArrow): NSRightArrowFunctionKey,
        UInt16(kVK_DownArrow): NSDownArrowFunctionKey, UInt16(kVK_UpArrow): NSUpArrowFunctionKey,
    ]

    /// Every combination of ⇧ ⌥ ⌃ (⌘ shortcuts do nothing in the overlay).
    private static let modifierSets: [UInt32] = (0..<8).map { i in
        (i & 1 != 0 ? KeyCombo.shift : 0) | (i & 2 != 0 ? KeyCombo.option : 0) | (i & 4 != 0 ? KeyCombo.control : 0)
    }

    /// When the capture starts.
    func register() {
        guard combos.isEmpty else { return }
        Self.installHandler()
        Self.active = self
        var id: UInt32 = 0
        for (keyCode, characters) in Self.keys() {
            for modifiers in Self.modifierSets {
                id += 1
                var ref: EventHotKeyRef?
                // A combo another app or one of Margin's own shortcuts already has just isn't caught here.
                let status = RegisterEventHotKey(UInt32(keyCode), modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                                 GetApplicationEventTarget(), 0, &ref)
                guard status == noErr, let ref else { continue }
                combos[id] = Combo(keyCode: keyCode, modifiers: modifiers, characters: characters, ref: ref)
            }
        }
    }

    /// When the overlay becomes key: the arrows go to it as ordinary keys from now on, with key repeat.
    func overlayIsKey() {
        for (id, combo) in combos where Self.arrows.contains(combo.keyCode) {
            UnregisterEventHotKey(combo.ref)
            combos[id] = nil
        }
    }

    /// When the capture ends.
    func unregister() {
        for combo in combos.values { UnregisterEventHotKey(combo.ref) }
        combos = [:]
    }

    private static func installHandler() {
        guard handlerRef == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(GetApplicationEventTarget(), overlayHotkeyEventHandler, eventTypes.count, &eventTypes,
                                         nil, &handlerRef)
        if status != noErr { log.error("InstallEventHandler for the overlay's keys failed: OSStatus \(status)") }
    }

    fileprivate static func dispatch(_ hotKeyID: EventHotKeyID, pressed: Bool) -> Bool {
        guard hotKeyID.signature == signature else { return false }
        guard let hotkeys = active, let combo = hotkeys.combos[hotKeyID.id],
              let event = NSEvent.keyEvent(
                with: pressed ? .keyDown : .keyUp, location: NSEvent.mouseLocation,
                modifierFlags: KeyCombo.cocoaModifiers(from: combo.modifiers), timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0, context: nil, characters: combo.characters, charactersIgnoringModifiers: combo.characters,
                isARepeat: false, keyCode: combo.keyCode) else { return true }
        hotkeys.onKey(event)
        return true
    }
}

/// Carbon calls this on the main thread for the application event target, before `HotkeyCenter`'s handler (the
/// last one installed goes first); anything that isn't one of these hotkeys is passed on.
private func overlayHotkeyEventHandler(
    _ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return OSStatus(eventNotHandledErr) }
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    let handled = MainActor.assumeIsolated { OverlayHotkeys.dispatch(hotKeyID, pressed: pressed) }
    return handled ? noErr : OSStatus(eventNotHandledErr)
}
