import ServiceManagement

/// Launch at login via `SMAppService.mainApp`.
public enum LoginItem {
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    public static func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Margin: launch at login change failed: \(error)")
        }
    }
}
