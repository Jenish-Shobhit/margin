import ServiceManagement

/// Launch at login via `SMAppService.mainApp`. Only works from a bundled app (e.g. /Applications/Margin.app).
public enum LoginItem {
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// True when the user has to allow Margin in System Settings › General › Login Items.
    public static var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// What Margin's login item really is right now (one `SMAppService` query). Show this, not the
    /// `Preferences.launchAtLogin` preference, which only records what the user asked for.
    public static var state: State { State(SMAppService.mainApp.status) }

    public enum State: Sendable, Equatable {
        /// Registered and allowed: Margin opens at login.
        case on
        /// Registered, but the user has to allow it in System Settings › General › Login Items.
        case needsApproval
        /// Not registered (or not possible, e.g. outside an app bundle).
        case off

        /// How the "Launch at login" toggle shows it: on once registered, even while waiting for approval.
        public var isOn: Bool { self != .off }

        public init(_ status: SMAppService.Status) {
            switch status {
            case .enabled: self = .on
            case .requiresApproval: self = .needsApproval
            case .notRegistered, .notFound: self = .off
            @unknown default: self = .off
            }
        }
    }

    /// Opens System Settings › General › Login Items.
    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    public static func setEnabled(_ enabled: Bool) {
        let status = SMAppService.mainApp.status
        if enabled, status == .enabled || status == .requiresApproval { return }
        if !enabled, status == .notRegistered || status == .notFound { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Margin: launch at login change failed: \(error)")
        }
    }
}
