import Foundation

/// Why turning the macOS screenshot shortcuts off (or back on) didn't fully work.
public enum SystemShortcutsError: Error, Equatable, LocalizedError {
    /// `AppleSymbolicHotKeys` exists but isn't a dictionary. Nothing was written, so nothing else is lost.
    case unreadable
    /// The preferences couldn't be saved.
    case writeFailed
    /// `activateSettings` couldn't be started.
    case activationUnavailable(String)
    /// `activateSettings` ran but failed (exit status, or the signal that stopped it).
    case activationFailed(Int32)
    /// `activateSettings` didn't finish in time, so it was stopped.
    case activationTimedOut
    /// Something kept putting the old setting back (System Settings open on Keyboard can do this).
    case didNotStick

    /// True when the new setting is saved but macOS may not use it until the next login.
    public var isSaved: Bool {
        switch self {
        case .unreadable, .writeFailed, .didNotStick: false
        case .activationUnavailable, .activationFailed, .activationTimedOut: true
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unreadable: "The macOS keyboard shortcut settings couldn’t be read."
        case .writeFailed: "The macOS keyboard shortcut settings couldn’t be saved."
        case .activationUnavailable(let reason): "macOS couldn’t apply the change (\(reason))."
        case .activationFailed(let status): "macOS couldn’t apply the change (activateSettings failed with \(status))."
        case .activationTimedOut: "macOS took too long to apply the change."
        case .didNotStick: "Something changed the shortcuts back. If System Settings is open, quit it and try again."
        }
    }
}

extension SystemShortcuts {
    /// The screenshot shortcuts: 28–31.
    public static var allIDs: [Int] { catalog.map(\.id) }

    /// Applies symbolic hot key changes from the preferences at once, without logging out.
    public static let activateSettingsPath =
        "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"

    /// The macOS default `value.parameters` for IDs 28–31: (character, Carbon key code, AppKit modifier flags).
    /// 51/52 are "3"/"4", 20/21 their key codes, 1179648 = ⇧⌘ and 1441792 = ⌃⇧⌘.
    public static func defaultParameters(forID id: Int) -> [Int]? {
        switch id {
        case 28: [51, 20, 1_179_648]
        case 29: [51, 20, 1_441_792]
        case 30: [52, 21, 1_179_648]
        case 31: [52, 21, 1_441_792]
        default: nil
        }
    }

    /// `hotkeys` (the `AppleSymbolicHotKeys` dictionary, nil when absent) with `enabled` set for each of `ids`.
    /// Everything else is kept as it was: other IDs, each entry's `value` (so a binding the user changed stays),
    /// and any other keys in an entry. A missing entry, or one without a `value`, gets the macOS default
    /// `{ parameters = (…); type = standard; }` so the shortcut keeps its usual keys when it's turned back on.
    public static func applying(enabled: Bool, ids: [Int] = allIDs, to hotkeys: [String: Any]?) -> [String: Any] {
        var result = hotkeys ?? [:]
        for id in ids {
            let key = String(id)
            var entry = result[key] as? [String: Any] ?? [:]
            entry["enabled"] = enabled
            if !(entry["value"] is [String: Any]), let parameters = defaultParameters(forID: id) {
                entry["value"] = ["parameters": parameters, "type": "standard"] as [String: Any]
            }
            result[key] = entry
        }
        return result
    }

    /// Turns the macOS screenshot shortcuts off (so Margin gets ⇧⌘3/⇧⌘4) or back on. Only on an explicit click.
    ///
    /// Rewrites `AppleSymbolicHotKeys` in `com.apple.symbolichotkeys` (current user, any host) with
    /// `applying(enabled:ids:to:)`, then runs `activateSettings -u` so macOS uses it at once.
    ///
    /// While macOS applies the change one shortcut at a time, a process that mirrors these settings (seen with
    /// System Settings' Keyboard pane loaded) can save a half-applied snapshot back, which leaves some shortcuts
    /// as they were. So this waits until the preferences and the live state agree for a moment, and writes and
    /// activates again if they don't (three tries).
    ///
    /// Blocks for about half a second, and at most `timeout` seconds per `activateSettings` run: call it off the
    /// main thread (`setEnabledInBackground` does).
    public static func setEnabled(_ enabled: Bool, ids: [Int] = allIDs, timeout: TimeInterval = 5) throws(SystemShortcutsError) {
        assert(!Thread.isMainThread, "SystemShortcuts.setEnabled waits for activateSettings; call it off the main thread")
        for _ in 1...3 {
            try write(enabled, ids: ids)
            try activate(timeout: timeout)
            if waitUntilApplied(enabled, ids: ids) { return }
        }
        throw .didNotStick
    }

    /// `setEnabled` on a background thread, so the caller (usually the main actor) never waits on it.
    public static func setEnabledInBackground(_ enabled: Bool, ids: [Int] = allIDs) async throws(SystemShortcutsError) {
        let result = await Task.detached(priority: .userInitiated) { () -> Result<Void, SystemShortcutsError> in
            Result { () throws(SystemShortcutsError) in try setEnabled(enabled, ids: ids) }
        }.value
        try result.get()
    }

    /// Writes `enabled` for `ids` into the preferences, keeping everything else.
    static func write(_ enabled: Bool, ids: [Int]) throws(SystemShortcutsError) {
        CFPreferencesAppSynchronize(domain)
        let raw = CFPreferencesCopyAppValue(hotKeysKey, domain)
        // Something unexpected is stored: writing our four entries over it would lose the user's other shortcuts.
        guard raw == nil || raw is [String: Any] else { throw .unreadable }
        let updated = applying(enabled: enabled, ids: ids, to: raw as? [String: Any])
        CFPreferencesSetAppValue(hotKeysKey, updated as CFDictionary, domain)
        guard CFPreferencesAppSynchronize(domain) else { throw .writeFailed }
    }

    /// Whether every one of `ids` is `enabled`, both in the saved preferences and (when it can be read) in the
    /// shortcuts macOS is using right now.
    public static func isApplied(_ enabled: Bool, ids: [Int] = allIDs) -> Bool {
        CFPreferencesAppSynchronize(domain)
        let saved = CFPreferencesCopyAppValue(hotKeysKey, domain) as? [String: Any]
        return ids.allSatisfy { id in
            let entry = saved?[String(id)] as? [String: Any]
            let isOn = entry.flatMap { boolValue($0["enabled"]) } ?? true
            return isOn == enabled && (LiveSymbolicHotKeys.isEnabled(id) ?? enabled) == enabled
        }
    }

    /// Polls `isApplied` for up to `limit` seconds and returns true once it has held for `steady` seconds.
    static func waitUntilApplied(_ enabled: Bool, ids: [Int], limit: TimeInterval = 1.2,
                                 steady: TimeInterval = 0.3) -> Bool {
        let interval: TimeInterval = 0.05
        let start = Date()
        var heldSince: Date?
        while Date().timeIntervalSince(start) < limit {
            if isApplied(enabled, ids: ids) {
                let since = heldSince ?? Date()
                heldSince = since
                if Date().timeIntervalSince(since) >= steady { return true }
            } else {
                heldSince = nil
            }
            Thread.sleep(forTimeInterval: interval)
        }
        return false
    }

    /// Runs `activateSettings -u` (or `executable` with `arguments`, for tests) and waits up to `timeout` seconds.
    /// Throws unless it exits with status 0 in time; a run that's too slow is stopped.
    public static func activate(_ executable: String = activateSettingsPath, arguments: [String] = ["-u"],
                                timeout: TimeInterval = 5) throws(SystemShortcutsError) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            throw .activationUnavailable((error as NSError).localizedDescription)
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            throw .activationTimedOut
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw .activationFailed(process.terminationStatus)
        }
    }
}

/// What the WindowServer is using right now, read through SkyLight's private `CGSIsSymbolicHotKeyEnabled`.
/// Read-only, and only to check that a change took; nil when the symbol isn't there.
enum LiveSymbolicHotKeys {
    private typealias IsEnabled = @convention(c) (Int32) -> Bool

    private static let isEnabledFunction: IsEnabled? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let symbol = dlsym(handle, "CGSIsSymbolicHotKeyEnabled") else { return nil }
        return unsafeBitCast(symbol, to: IsEnabled.self)
    }()

    static func isEnabled(_ id: Int) -> Bool? { isEnabledFunction?(Int32(id)) }
}
