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

    /// True when the new setting is saved but macOS may not use it until the next login.
    public var isSaved: Bool {
        switch self {
        case .unreadable, .writeFailed: false
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
    /// Blocks for up to `timeout` seconds while that runs: call it off the main thread
    /// (`setEnabledInBackground` does).
    public static func setEnabled(_ enabled: Bool, ids: [Int] = allIDs, timeout: TimeInterval = 5) throws(SystemShortcutsError) {
        assert(!Thread.isMainThread, "SystemShortcuts.setEnabled waits for activateSettings; call it off the main thread")
        CFPreferencesAppSynchronize(domain)
        let raw = CFPreferencesCopyAppValue(hotKeysKey, domain)
        // Something unexpected is stored: writing our four entries over it would lose the user's other shortcuts.
        guard raw == nil || raw is [String: Any] else { throw .unreadable }
        let updated = applying(enabled: enabled, ids: ids, to: raw as? [String: Any])
        CFPreferencesSetAppValue(hotKeysKey, updated as CFDictionary, domain)
        guard CFPreferencesAppSynchronize(domain) else { throw .writeFailed }
        let saved = parse(CFPreferencesCopyAppValue(hotKeysKey, domain) as? [String: Any])
        guard saved.filter({ ids.contains($0.id) }).allSatisfy({ $0.enabled == enabled }) else { throw .writeFailed }
        try activate(timeout: timeout)
    }

    /// `setEnabled` on a background thread, so the caller (usually the main actor) never waits on it.
    public static func setEnabledInBackground(_ enabled: Bool, ids: [Int] = allIDs) async throws(SystemShortcutsError) {
        let result = await Task.detached(priority: .userInitiated) { () -> Result<Void, SystemShortcutsError> in
            Result { () throws(SystemShortcutsError) in try setEnabled(enabled, ids: ids) }
        }.value
        try result.get()
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
