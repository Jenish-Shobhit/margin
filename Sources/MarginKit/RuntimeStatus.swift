import Foundation

/// Live app state shared between the coordinator, hotkeys, Settings and First run.
/// Posts `RuntimeStatus.didChange` whenever a value changes.
@MainActor
public final class RuntimeStatus {
    public static let shared = RuntimeStatus()
    public static let didChange = Notification.Name("MarginRuntimeStatusDidChange")

    public init() {}

    /// Shortcuts whose registration failed, with the Carbon OSStatus (e.g. `eventHotKeyExistsErr` when another
    /// app owns the combo). Written by HotkeyCenter after every (re)registration; empty when all succeeded.
    public var hotkeyFailures: [ShortcutAction: Int32] = [:] {
        didSet { if hotkeyFailures != oldValue { post() } }
    }

    /// A capture failed for lack of Screen Recording permission since launch. `CGPreflightScreenCaptureAccess`
    /// is cached per process and can't be trusted to flip back, so treat permission as missing until a capture
    /// succeeds or the app relaunches.
    public var screenRecordingRevoked = false {
        didSet { if screenRecordingRevoked != oldValue { post() } }
    }

    private func post() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
