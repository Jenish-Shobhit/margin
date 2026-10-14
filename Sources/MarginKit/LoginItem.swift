import ServiceManagement

/// Launch at login via `SMAppService.mainApp`. Only works from a bundled app (e.g. /Applications/Margin.app).
public enum LoginItem {
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// True when the user has to allow Margin in System Settings › General › Login Items.
    public static var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

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
