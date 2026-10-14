#if DEBUG
import AppKit
import MarginKit
import os

/// DEBUG-only control hook (spec §10), driven by `scripts/debug.sh`.
///
/// Listens for the distributed notification `io.github.jenish-shobhit.margin.debug` whose `object`
/// is the command string:
///   capture-area x y w h   capture a rect in AppKit global points, no overlay
///   capture-screen         the display under the pointer
///   toggle-shelf           tuck / show the shelf
///   clear                  remove every item from the shelf (undoable)
///   dump-state             write the state as JSON to /tmp/margin-state.json
@MainActor
final class DebugCommandListener: NSObject {
    static let notificationName = Notification.Name("io.github.jenish-shobhit.margin.debug")
    static let stateFileURL = URL(fileURLWithPath: "/tmp/margin-state.json")
    private static let log = Logger(subsystem: AppCoordinator.subsystem, category: "debug")

    private weak var coordinator: AppCoordinator?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init()
        // Accessory apps are rarely "active"; deliver immediately instead of coalescing.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(received(_:)), name: Self.notificationName, object: nil,
            suspensionBehavior: .deliverImmediately)
        Self.log.notice("DEBUG control hook listening on \(Self.notificationName.rawValue, privacy: .public)")
    }

    @objc private func received(_ notification: Notification) {
        guard let command = notification.object as? String else { return }
        Self.log.notice("debug command: \(command, privacy: .public)")
        run(command)
    }

    private func run(_ command: String) {
        guard let coordinator else { return }
        let parts = command.split(separator: " ").map(String.init)
        switch parts.first {
        case "capture-area":
            let numbers = parts.dropFirst().compactMap(Double.init)
            guard numbers.count == 4 else {
                Self.log.error("usage: capture-area x y w h")
                return
            }
            coordinator.captureRect(CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]))
        case "capture-screen":
            coordinator.captureScreen()
        case "toggle-shelf":
            coordinator.toggleShelf()
        case "clear":
            coordinator.clearShelf()
        case "dump-state":
            dumpState(coordinator)
        default:
            Self.log.error("unknown debug command: \(command, privacy: .public)")
        }
    }

    private func dumpState(_ c: AppCoordinator) {
        let prefs = c.prefs
        var state: [String: Any] = [
            "itemIDs": c.shelf.itemIDs.map(\.uuidString),
            "itemPaths": c.store.items.map(\.path),
            "isTucked": c.shelf.isTucked,
            "markedItemID": c.shelf.markedItemID?.uuidString ?? NSNull(),
            "clipboardMarkItemID": c.mark.itemID?.uuidString ?? NSNull(),
            "pasteboardChangeCount": NSPasteboard.general.changeCount,
            "isCapturing": c.capture.isCapturing,
            "saveFolder": prefs.saveFolder.path,
            "lastSavedPath": c.lastSavedPath ?? NSNull(),
            "completedCaptures": prefs.completedCaptures,
            "firstRunDone": prefs.firstRunDone,
            "copyEachCapture": prefs.copyEachCapture,
            "shutterSound": prefs.shutterSound,
            "permission": [
                "preflight": CGPreflightScreenCaptureAccess(),
                "granted": c.permissionGranted,
                "revoked": RuntimeStatus.shared.screenRecordingRevoked,
                "warning": c.needsPermission,
            ],
            "hotkeyFailures": Dictionary(uniqueKeysWithValues: RuntimeStatus.shared.hotkeyFailures.map {
                ($0.key.rawValue, Int($0.value))
            }),
            "hotkeys": c.hotkeyRegistrations.map { entry in
                [
                    "action": entry.binding.action.rawValue,
                    "keyCode": Int(entry.binding.combo.keyCode),
                    "modifiers": Int(entry.binding.combo.modifiers),
                    "controlTwin": entry.binding.isControlTwin,
                    "display": entry.binding.combo.displayString,
                    "status": Int(entry.status),
                ] as [String: Any]
            },
            "lastHotkey": c.lastHotkeyAction?.rawValue ?? NSNull(),
            "bundlePath": Bundle.main.bundlePath,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "dumpedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let t = c.lastTimings {
            var timings: [String: Any] = [
                "kind": t.kind,
                "pixelWidth": t.pixelWidth,
                "pixelHeight": t.pixelHeight,
                "releaseToThumbnailMs": t.releaseToThumbnailMs,
                "thumbnailMs": t.thumbnailMs,
                "usedFallback": t.usedFallback,
            ]
            if let v = t.encodeMs { timings["encodeMs"] = v }
            if let v = t.writeMs { timings["writeMs"] = v }
            if let v = t.releaseToFileMs { timings["releaseToFileMs"] = v }
            if let v = t.savedPath { timings["savedPath"] = v }
            if let v = t.error { timings["error"] = v }
            state["lastTimings"] = timings
        } else {
            state["lastTimings"] = NSNull()
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: Self.stateFileURL, options: .atomic)
        } catch {
            Self.log.error("dump-state failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
