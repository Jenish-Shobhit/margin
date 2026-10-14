import Carbon.HIToolbox
import Foundation
import MarginKit
import os

/// Global hotkeys via Carbon `RegisterEventHotKey` (needs no permission).
///
/// Registers every `ShortcutAction` from `Preferences.shared.shortcut(for:)`, plus a ⌃ twin for the
/// capture actions, and re-registers when the shortcuts change. While macOS's own ⌘⇧3/⌘⇧4 are still
/// enabled, the system gets those keys first; registration still succeeds.
@MainActor
final class HotkeyCenter {
    struct Binding: Equatable {
        let action: ShortcutAction
        let combo: KeyCombo
        let isControlTwin: Bool
    }

    struct Registration {
        let binding: Binding
        let ref: EventHotKeyRef?
        let status: OSStatus
    }

    private static let log = Logger(subsystem: AppCoordinator.subsystem, category: "hotkeys")
    /// 'MRGN'
    private static let signature: OSType = 0x4D52_474E
    /// The instance the Carbon callback dispatches to.
    private static weak var active: HotkeyCenter?

    private let onAction: (ShortcutAction) -> Void
    private var handlerRef: EventHandlerRef?
    private var registrations: [UInt32: Registration] = [:]
    private var bindings: [Binding] = []
    private var preferencesObserver: NSObjectProtocol?
    /// True while hotkeys are paused (e.g. a shortcut recorder is listening).
    private(set) var isSuspended = false

    /// For the DEBUG state dump: each binding and the OSStatus of its registration.
    var registrationSummary: [(binding: Binding, status: OSStatus)] {
        registrations.keys.sorted().compactMap { registrations[$0] }.map { ($0.binding, $0.status) }
    }

    init(onAction: @escaping (ShortcutAction) -> Void) {
        self.onAction = onAction
    }

    func start() {
        Self.active = self
        installHandler()
        reregisterIfNeeded(force: true)
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: Preferences.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reregisterIfNeeded() }
        }
    }

    func stop() {
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
        preferencesObserver = nil
        unregisterAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        if Self.active === self { Self.active = nil }
    }

    /// Pauses every hotkey (so a shortcut recorder can receive the keys) and resumes them.
    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        if suspended { unregisterAll() } else { reregisterIfNeeded(force: true) }
    }

    // MARK: - Registration

    /// The bindings the current preferences ask for.
    static func desiredBindings(_ prefs: Preferences = .shared) -> [Binding] {
        var result: [Binding] = []
        for action in ShortcutAction.allCases {
            let combo = prefs.shortcut(for: action)
            result.append(Binding(action: action, combo: combo, isControlTwin: false))
            if action.hasControlTwin, combo.modifiers & KeyCombo.control == 0 {
                let twin = KeyCombo(keyCode: combo.keyCode, modifiers: combo.modifiers | KeyCombo.control)
                result.append(Binding(action: action, combo: twin, isControlTwin: true))
            }
        }
        return result
    }

    /// `Preferences.didChange` fires for every setting (and every capture's counter), so only
    /// touch Carbon when the shortcuts actually changed.
    private func reregisterIfNeeded(force: Bool = false) {
        guard !isSuspended else { return }
        let desired = Self.desiredBindings()
        guard force || desired != bindings else { return }
        unregisterAll()
        bindings = desired
        var seen = Set<KeyCombo>()
        for (index, binding) in desired.enumerated() {
            let id = UInt32(index + 1)
            if !seen.insert(binding.combo).inserted {
                Self.log.error(
                    "Shortcut \(Self.describe(binding.combo), privacy: .public) for \(binding.action.rawValue, privacy: .public) is already used by another action")
                registrations[id] = Registration(binding: binding, ref: nil, status: OSStatus(eventHotKeyExistsErr))
                continue
            }
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
            let status = RegisterEventHotKey(
                binding.combo.keyCode, binding.combo.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            registrations[id] = Registration(binding: binding, ref: ref, status: status)
            if status == noErr {
                Self.log.info(
                    "Registered \(Self.describe(binding.combo), privacy: .public) → \(binding.action.rawValue, privacy: .public)")
            } else {
                Self.log.error(
                    "RegisterEventHotKey \(Self.describe(binding.combo), privacy: .public) → \(binding.action.rawValue, privacy: .public) failed: OSStatus \(status)")
            }
        }
    }

    private func unregisterAll() {
        for registration in registrations.values {
            if let ref = registration.ref { UnregisterEventHotKey(ref) }
        }
        registrations = [:]
        bindings = []
    }

    // MARK: - Events

    private func installHandler() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &eventType, nil, &handlerRef)
        if status != noErr {
            Self.log.error("InstallEventHandler failed: OSStatus \(status)")
        }
    }

    fileprivate static func dispatch(_ hotKeyID: EventHotKeyID) -> Bool {
        guard hotKeyID.signature == signature, let center = active,
              let registration = center.registrations[hotKeyID.id], !center.isSuspended
        else { return false }
        center.onAction(registration.binding.action)
        return true
    }

    /// `⌃⌥⇧⌘` + key, for logs.
    static func describe(_ combo: KeyCombo) -> String {
        var s = ""
        if combo.modifiers & KeyCombo.control != 0 { s += "⌃" }
        if combo.modifiers & KeyCombo.option != 0 { s += "⌥" }
        if combo.modifiers & KeyCombo.shift != 0 { s += "⇧" }
        if combo.modifiers & KeyCombo.cmd != 0 { s += "⌘" }
        return s + String(format: "key 0x%02X", combo.keyCode)
    }
}

/// Carbon calls this on the main thread for the application event target.
private func hotKeyEventHandler(
    _ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let handled = MainActor.assumeIsolated { HotkeyCenter.dispatch(hotKeyID) }
    return handled ? noErr : OSStatus(eventNotHandledErr)
}
