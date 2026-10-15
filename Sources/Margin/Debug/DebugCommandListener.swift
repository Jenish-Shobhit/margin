#if DEBUG || MARGIN_BENCH
import AppKit
import MarginKit
import os

/// The control hook (spec §10) of DEBUG builds, driven by `scripts/debug.sh`, and of bench builds (release
/// optimisation plus `-DMARGIN_BENCH`, `scripts/build.sh --bench`), driven by `scripts/bench.sh`. Never in a
/// shipped release.
///
/// Listens for the distributed notification `io.github.jenish-shobhit.margin.debug` whose `object`
/// is the command string:
///   capture-area x y w h   capture a rect in AppKit global points, no overlay
///   capture-screen         the display under the pointer
///   toggle-shelf           tuck / show the shelf
///   clear                  remove every item from the shelf (undoable)
///   dump-state             write the state as JSON to /tmp/margin-state.json
///   hotkey <action>        what that shortcut does: captureArea, captureScreen, repeatArea, toggleShelf
///   capture-window         the menu's Capture Window (the overlay in window mode)
///   select x y w h         in the live overlay: drag from (x, y) to (x + w, y + h) and release (global points)
///   click x y [option]     in the live overlay in window mode: click at (x, y), with ⌥ to keep the shadow
///   cancel                 close the live overlay, as Esc does
///   mark <text>            log `mark: <text>` in the timing category (`scripts/bench.sh` tells captures apart by it)
/// The overlay commands call the session's mouse handlers in-process: no event reaches any other app.
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
        case "hotkey":
            guard parts.count == 2, let action = ShortcutAction(rawValue: parts[1]) else {
                Self.log.error("usage: hotkey captureArea|captureScreen|repeatArea|toggleShelf")
                return
            }
            coordinator.perform(action)
        case "capture-window":
            coordinator.captureWindow()
        case "select":
            let numbers = parts.dropFirst().compactMap(Double.init)
            guard numbers.count == 4 else {
                Self.log.error("usage: select x y w h")
                return
            }
            select(from: CGPoint(x: numbers[0], y: numbers[1]),
                   to: CGPoint(x: numbers[0] + numbers[2], y: numbers[1] + numbers[3]), in: coordinator)
        case "click":
            let numbers = parts.dropFirst().compactMap(Double.init)
            guard numbers.count == 2 else {
                Self.log.error("usage: click x y [option]")
                return
            }
            click(at: CGPoint(x: numbers[0], y: numbers[1]), option: parts.contains("option"), in: coordinator)
        case "cancel":
            coordinator.capture.currentSession?.cancel()
        case "mark":
            let text = parts.dropFirst().joined(separator: " ")
            CaptureLog.timing.info("mark: \(text, privacy: .public)")
        default:
            Self.log.error("unknown debug command: \(command, privacy: .public)")
        }
    }

    /// A drag across the live overlay, like a user's: down, a few moves a frame apart, a short pause, release.
    private func select(from start: CGPoint, to end: CGPoint, in c: AppCoordinator) {
        guard let session = c.capture.currentSession,
              let display = session.displays.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(start) }) else {
            Self.log.error("select: no overlay on a display at \(String(describing: start), privacy: .public)")
            return
        }
        session.mouseDown(at: start, on: display, event: Self.mouseEvent(.leftMouseDown))
        Task { @MainActor in
            let steps = 6
            for i in 1...steps {
                try? await Task.sleep(for: .milliseconds(16))
                let f = CGFloat(i) / CGFloat(steps)
                let p = CGPoint(x: start.x + (end.x - start.x) * f, y: start.y + (end.y - start.y) * f)
                session.mouseDragged(at: p, event: Self.mouseEvent(.leftMouseDragged))
            }
            try? await Task.sleep(for: .milliseconds(50))
            session.mouseUp(at: end, event: Self.mouseEvent(.leftMouseUp))
        }
    }

    /// A click on the live overlay (window mode picks the window under it).
    private func click(at point: CGPoint, option: Bool, in c: AppCoordinator) {
        guard let session = c.capture.currentSession,
              let display = session.displays.first(where: { $0.frame.contains(point) }) else {
            Self.log.error("click: no overlay on a display at \(String(describing: point), privacy: .public)")
            return
        }
        session.mouseDown(at: point, on: display, event: Self.mouseEvent(.leftMouseDown, option: option))
    }

    /// The session reads only the event's modifier flags.
    private static func mouseEvent(_ type: NSEvent.EventType, option: Bool = false) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: .zero, modifierFlags: option ? .option : [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 0,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
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
            "overlay": c.capture.currentSession.map { ["mode": "\($0.mode)"] } ?? NSNull(),
            "focus": [
                "keyWindow": NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none",
                "isActive": NSApp.isActive,
                "frontmost": NSWorkspace.shared.frontmostApplication?.localizedName ?? "none",
            ] as [String: Any],
            "saveFolder": prefs.saveFolder.path,
            "lastSavedPath": c.lastSavedPath ?? NSNull(),
            "completedCaptures": prefs.completedCaptures,
            "firstRunDone": prefs.firstRunDone,
            "copyEachCapture": prefs.copyEachCapture,
            "shutterSound": prefs.shutterSound,
            // What macOS actually has (the preference is only the user's intent).
            "launchAtLogin": [
                "on": LoginItem.isEnabled || LoginItem.requiresApproval,
                "requiresApproval": LoginItem.requiresApproval,
                "preference": prefs.launchAtLogin,
            ],
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
