import Carbon.HIToolbox
import Foundation
import MarginKit
import os

/// Global hotkeys via Carbon `RegisterEventHotKey` (needs no permission).
///
/// Registers `Preferences.shared.registeredCombos()` (each action's shortcut plus the ⌃ twins of the
/// capture actions) and re-registers when the shortcuts change. Everything is unregistered while a
/// Settings shortcut recorder is listening (`Preferences.isRecordingShortcut`), otherwise Carbon would
/// swallow the keys before the recorder sees them. While macOS's own ⌘⇧3/⌘⇧4 are still enabled, the
/// system gets those keys first; registration still succeeds. After every (re)registration the failures
/// (e.g. a combo another app already registered) go to `RuntimeStatus.hotkeyFailures`.
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
        /// Skipped because an earlier binding (another of Margin's actions) already has this combo.
        var isDuplicate = false
    }

    private static let log = Logger(subsystem: AppCoordinator.subsystem, category: "hotkeys")
    /// 'MRGN'
    private static let signature: OSType = 0x4D52_474E
    /// The instance the Carbon callback dispatches to.
    private static weak var active: HotkeyCenter?

    private let prefs: Preferences
    private let onAction: (ShortcutAction) -> Void
    private var handlerRef: EventHandlerRef?
    private var registrations: [UInt32: Registration] = [:]
    private var bindings: [Binding] = []
    private var observers: [NSObjectProtocol] = []
    /// True while hotkeys are paused because a shortcut recorder is listening.
    private(set) var isSuspended = false

    /// For the DEBUG state dump: each binding and the OSStatus of its registration.
    var registrationSummary: [(binding: Binding, status: OSStatus)] {
        registrations.keys.sorted().compactMap { registrations[$0] }.map { ($0.binding, $0.status) }
    }

    /// A combo that didn't register, for the menu bar warning.
    struct Failure {
        enum Reason { case duplicate, taken, other }
        let binding: Binding
        let status: OSStatus
        /// `duplicate`: two of Margin's actions share the combo. `taken`: Carbon's `eventHotKeyExistsErr`
        /// (already registered elsewhere). Note that on macOS 27 another process registering the same combo,
        /// even with `kEventHotKeyExclusive`, does not make this registration fail.
        let reason: Reason
    }

    /// Every combo (⌃ twins included) whose last registration failed, in registration order.
    var failures: [Failure] {
        registrations.keys.sorted().compactMap { registrations[$0] }.filter { $0.status != noErr }.map {
            let reason: Failure.Reason = $0.isDuplicate ? .duplicate
                : $0.status == OSStatus(eventHotKeyExistsErr) ? .taken : .other
            return Failure(binding: $0.binding, status: $0.status, reason: reason)
        }
    }

    init(prefs: Preferences = .shared, onAction: @escaping (ShortcutAction) -> Void) {
        self.prefs = prefs
        self.onAction = onAction
    }

    func start() {
        Self.active = self
        installHandler()
        isSuspended = prefs.isRecordingShortcut
        reregisterIfNeeded(force: true)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: Preferences.didChange, object: prefs, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reregisterIfNeeded() }
            },
            center.addObserver(forName: Preferences.recordingShortcutDidChange, object: prefs, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.setSuspended(self.prefs.isRecordingShortcut)
                }
            },
        ]
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        unregisterAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        if Self.active === self { Self.active = nil }
    }

    /// Pauses every hotkey (unregistered, so the keys reach the app) and resumes them.
    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        Self.log.info("Hotkeys \(suspended ? "suspended" : "resumed", privacy: .public)")
        if suspended { unregisterAll() } else { reregisterIfNeeded(force: true) }
    }

    // MARK: - Registration

    /// The bindings the current preferences ask for.
    private func desiredBindings() -> [Binding] {
        prefs.registeredCombos().map { entry in
            Binding(action: entry.action, combo: entry.combo, isControlTwin: entry.combo != prefs.shortcut(for: entry.action))
        }
    }

    /// `Preferences.didChange` fires for every setting (and every capture's counter), so only
    /// touch Carbon when the shortcuts actually changed.
    private func reregisterIfNeeded(force: Bool = false) {
        guard !isSuspended else { return }
        let desired = desiredBindings()
        guard force || desired != bindings else { return }
        unregisterAll()
        bindings = desired
        var seen = Set<KeyCombo>()
        for (index, binding) in desired.enumerated() {
            let id = UInt32(index + 1)
            let keys = binding.combo.displayString
            if !seen.insert(binding.combo).inserted {
                Self.log.error(
                    "Shortcut \(keys, privacy: .public) for \(binding.action.rawValue, privacy: .public) is already used by another action")
                registrations[id] = Registration(
                    binding: binding, ref: nil, status: OSStatus(eventHotKeyExistsErr), isDuplicate: true)
                continue
            }
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
            let status = RegisterEventHotKey(
                binding.combo.keyCode, binding.combo.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            registrations[id] = Registration(binding: binding, ref: ref, status: status)
            if status == noErr {
                Self.log.info("Registered \(keys, privacy: .public) → \(binding.action.rawValue, privacy: .public)")
            } else {
                Self.log.error(
                    "RegisterEventHotKey \(keys, privacy: .public) → \(binding.action.rawValue, privacy: .public) failed: OSStatus \(status)")
            }
        }
        publishFailures()
    }

    /// Shares the outcome with the menu bar and Settings: each action's first failure (its own combo
    /// before its ⌃ twin), or an empty dictionary when everything registered.
    private func publishFailures() {
        var byAction: [ShortcutAction: Int32] = [:]
        for failure in failures where byAction[failure.binding.action] == nil {
            byAction[failure.binding.action] = failure.status
        }
        RuntimeStatus.shared.hotkeyFailures = byAction
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
