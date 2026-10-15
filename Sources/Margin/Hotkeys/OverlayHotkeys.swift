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
/// out of full screen. So ⌤, Z and the arrows, alone or with any of ⇧ ⌥ ⌃, and Esc, Space and ↩, alone or with ⇧,
/// are registered when the capture starts: Carbon hotkeys need no permission and keep the key from the frontmost app.
/// Each press (and release) is handed on as a key event. Not Esc, Space or ↩ with ⌥ or ⌃: those are other apps'
/// global shortcuts (⌥Space opens launchers, ⌃Space switches input source), and a combo two apps register fires in
/// both, so the launcher would open and the overlay would switch to window mode.
///
/// Plain Esc and Space go first, before anything else on the hotkey path (`registerFirst`): about 0.1 ms. The other
/// 52 combos (2–3 ms) follow once the overlay is up (`register`). Registered after the captures had started, as they
/// were, the first one could wait 5–7 ms on the window server, which is busy starting them, and a key pressed 10–15
/// ms after ⇧⌘4 still reached the frontmost app. Keys pressed before Margin even gets ⇧⌘4 (the window server hands
/// it over 15–30 ms after the press) can't be caught at all.
///
/// Unregistering a hotkey drops a press of it that's still waiting in the event queue, so only the arrows go when
/// the overlay becomes key (they need key repeat, which hotkeys don't have; there's no selection to nudge yet then).
/// The others stay until the capture ends, and a key held down then (the Esc or ↩ that ended it, a Space held to
/// move the selection) until it's released: unregistered at once, its release would reach the app in front alone,
/// and apps that read key releases (a terminal with the kitty keyboard protocol, games) would get a stray one.
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
    /// The combos pressed and not yet released.
    private var held: Set<UInt32> = []
    /// Set when the capture has ended with keys still held: their combos are all that's left, each waiting for its
    /// release, and this drops them all if one never comes (`releaseTimeout`).
    private var lingering: Task<Void, Never>?
    /// The longest a key that was held when the capture ended keeps its combo taken.
    private static let releaseTimeout = Duration.milliseconds(500)

    init(onKey: @escaping (NSEvent) -> Void) {
        self.onKey = onKey
    }

    /// The keys, with the characters they type (Z where the keyboard layout has it). Esc and Space come first
    /// (`registerFirst`).
    private static func keys() -> [(UInt16, String)] {
        let z = UInt16(KeyCombo.keyCode(forCharacter: "Z", layout: .current) ?? UInt32(kVK_ANSI_Z))
        return firstKeys + [
            (UInt16(kVK_Return), "\r"), (UInt16(kVK_ANSI_KeypadEnter), "\u{3}"), (z, "z"),
        ] + arrows.map { ($0, String(Character(UnicodeScalar(UInt16(arrowCharacters[$0]!))!))) }
    }

    private static let firstKeys = [(UInt16(kVK_Escape), "\u{1B}"), (UInt16(kVK_Space), " ")]

    private static let arrows = [UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow), UInt16(kVK_DownArrow), UInt16(kVK_UpArrow)]
    private static let arrowCharacters: [UInt16: Int] = [
        UInt16(kVK_LeftArrow): NSLeftArrowFunctionKey, UInt16(kVK_RightArrow): NSRightArrowFunctionKey,
        UInt16(kVK_DownArrow): NSDownArrowFunctionKey, UInt16(kVK_UpArrow): NSUpArrowFunctionKey,
    ]

    /// Every combination of ⇧ ⌥ ⌃ (⌘ shortcuts do nothing in the overlay).
    private static let modifierSets: [UInt32] = (0..<8).map { i in
        (i & 1 != 0 ? KeyCombo.shift : 0) | (i & 2 != 0 ? KeyCombo.option : 0) | (i & 4 != 0 ? KeyCombo.control : 0)
    }

    /// Caught alone or with ⇧ only: with ⌥ or ⌃ they're other apps' shortcuts.
    private static let shiftOnlyKeys: Set<UInt16> = [UInt16(kVK_Escape), UInt16(kVK_Space), UInt16(kVK_Return)]

    /// At launch (`CaptureController.prewarm`): the Carbon handler, so the first capture doesn't install it.
    func prepare() {
        Self.installHandler()
    }

    /// First thing when the capture starts: plain Esc and Space, the keys most likely pressed straight after ⇧⌘4.
    func registerFirst() {
        // A key still held from the last capture lets go now: this capture registers its own.
        if lingering != nil { dropAll() }
        Self.installHandler()
        Self.active = self
        for (index, (keyCode, characters)) in Self.firstKeys.enumerated() {
            add(keyCode, modifiers: 0, characters: characters, id: Self.id(key: index, modifiers: 0))
        }
    }

    /// Once the overlay is up: the rest.
    func register() {
        Self.installHandler()
        Self.active = self
        for (index, (keyCode, characters)) in Self.keys().enumerated() {
            for (set, modifiers) in Self.modifierSets.enumerated()
            where !Self.shiftOnlyKeys.contains(keyCode) || modifiers & ~KeyCombo.shift == 0 {
                add(keyCode, modifiers: modifiers, characters: characters, id: Self.id(key: index, modifiers: set))
            }
        }
    }

    /// The same combo always has the same ID, so `register` skips what `registerFirst` did.
    private static func id(key: Int, modifiers set: Int) -> UInt32 {
        UInt32(key * modifierSets.count + set + 1)
    }

    private func add(_ keyCode: UInt16, modifiers: UInt32, characters: String, id: UInt32) {
        guard combos[id] == nil else { return }
        var ref: EventHotKeyRef?
        // A combo another app or one of Margin's own shortcuts already has just isn't caught here.
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return }
        combos[id] = Combo(keyCode: keyCode, modifiers: modifiers, characters: characters, ref: ref)
    }

    /// When the overlay becomes key: the arrows go to it as ordinary keys from now on, with key repeat.
    func overlayIsKey() {
        for (id, combo) in combos where Self.arrows.contains(combo.keyCode) {
            UnregisterEventHotKey(combo.ref)
            combos[id] = nil
            held.remove(id)   // its release is an ordinary key event now
        }
    }

    /// When the capture ends. A combo whose key is still down stays until the key is released (its release is
    /// swallowed then), or at most `releaseTimeout`, so no combo can stay taken.
    func unregister() {
        for (id, combo) in combos where !held.contains(id) {
            UnregisterEventHotKey(combo.ref)
            combos[id] = nil
        }
        if combos.isEmpty { held = [] }
        guard !combos.isEmpty, lingering == nil else { return }
        lingering = Task { [weak self] in
            try? await Task.sleep(for: Self.releaseTimeout)
            guard !Task.isCancelled else { return }
            self?.dropAll()
        }
    }

    /// After the capture: one lingering combo's key went up (or down again).
    private func drop(_ id: UInt32) {
        if let combo = combos.removeValue(forKey: id) { UnregisterEventHotKey(combo.ref) }
        held.remove(id)
        if combos.isEmpty { dropAll() }
    }

    private func dropAll() {
        for combo in combos.values { UnregisterEventHotKey(combo.ref) }
        combos = [:]
        held = []
        lingering?.cancel()
        lingering = nil
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
        guard let hotkeys = active, let combo = hotkeys.combos[hotKeyID.id] else { return true }
        // The capture is over: the release of a key held when it ended.
        if hotkeys.lingering != nil {
            hotkeys.drop(hotKeyID.id)
            return true
        }
        if pressed { hotkeys.held.insert(hotKeyID.id) } else { hotkeys.held.remove(hotKeyID.id) }
        guard let event = NSEvent.keyEvent(
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
