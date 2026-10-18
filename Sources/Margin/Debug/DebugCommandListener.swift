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
///   clear                  Close Shelf: every card off the shelf, files kept (undoable)
///   dismiss [n]            remove the n newest cards (default 1) as one undo step, as ✕ does but keeping the keys
///   restore-last           the menu's Restore Last Removed (the shelf's ⌘Z)
///   copy [n]               click the n-th newest card (default 1): the shelf's copy
///   dump-state             write the state as JSON to /tmp/margin-state.json
///   record-area x y w h    record a rect in AppKit global points, no overlay
///   record-screen          record the display under the pointer
///   record-window [id]     record a window window mode could pick (by window number; the frontmost without one)
///   stop-recording         stop and save the recording under way, as ⇧⌘5 does
///   hotkey <action>        what that shortcut does: captureArea, captureScreen, repeatArea, toggleShelf, recordScreen
///   capture-window         the menu's Capture Window (the overlay in window mode)
///   select x y w h         in the live overlay: drag from (x, y) to (x + w, y + h) and release (global points)
///   click x y [option] [window=<id>]  in the live overlay in window mode: click at (x, y), with ⌥ to keep the shadow;
///                          with `window=`, only if that's the window it would pick there (otherwise the overlay closes)
///   cancel                 close the live overlay, as Esc does
///   key space|return|escape  that key in the live overlay (Space: window mode; ↩: capture, or record the whole display)
///   show settings|first-run|shortcuts|none  open Settings, First run, or First run at its shortcuts step; or close them
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
            coordinator.closeShelf()
        case "dismiss":
            let count = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
            coordinator.shelf.dismiss(coordinator.store.items.suffix(max(count, 0)).map(\.id), exit: .collapse)
        case "restore-last":
            coordinator.restoreLastRemoved()
        case "copy":
            let n = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
            let items = coordinator.store.items
            guard n >= 1, n <= items.count else { return }
            coordinator.shelf.click(items[items.count - n].id)
        case "dump-state":
            Task { await dumpState(coordinator) }
        case "record-area":
            let numbers = parts.dropFirst().compactMap(Double.init)
            let rect = numbers.count == 4 ? CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]) : .null
            guard let display = Displays.display(bestFor: rect) else {
                Self.log.error("usage: record-area x y w h (on a display)")
                return
            }
            coordinator.startRecording(.area(rect.intersection(display.frame), display))
        case "record-screen":
            guard let display = Displays.display(containing: NSEvent.mouseLocation) else { return }
            coordinator.startRecording(.display(display))
        case "record-window":
            let id = parts.count > 1 ? CGWindowID(parts[1]) : nil
            guard coordinator.permissionGranted else { return }
            let cache = coordinator.capture.shareableContent
            Task { @MainActor in
                // The window list as it is now, not as of the last capture.
                try? await cache.refresh(onScreenOnly: true)
                guard let window = cache.pickableWindow(id: id) else {
                    Self.log.error("record-window: no window \(id.map(String.init) ?? "in front", privacy: .public)")
                    return
                }
                coordinator.startRecording(.window(window))
            }
        case "stop-recording":
            coordinator.stopRecording()
        case "hotkey":
            guard parts.count == 2, let action = ShortcutAction(rawValue: parts[1]) else {
                Self.log.error("usage: hotkey captureArea|captureScreen|repeatArea|toggleShelf|recordScreen")
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
            let expected = parts.first { $0.hasPrefix("window=") }.flatMap { CGWindowID($0.dropFirst("window=".count)) }
            click(at: CGPoint(x: numbers[0], y: numbers[1]), option: parts.contains("option"), expecting: expected, in: coordinator)
        case "cancel":
            coordinator.capture.currentSession?.cancel()
        case "key":
            let codes: [String: UInt16] = ["space": 49, "return": 36, "escape": 53]
            guard parts.count == 2, let code = codes[parts[1]], let session = coordinator.capture.currentSession else {
                Self.log.error("usage: key space|return|escape (with an overlay up)")
                return
            }
            let characters = code == 49 ? " " : code == 36 ? "\r" : "\u{1B}"
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code) else { continue }
                if type == .keyDown { session.keyDown(event) } else { session.keyUp(event) }
            }
        case "show":
            switch parts.dropFirst().first {
            case "settings": coordinator.showSettings()
            case "first-run": FirstRunWindowController.shared.show()
            case "shortcuts": coordinator.showShortcutsStep()
            case "none": for window in NSApp.windows where window.isVisible && window.level == .normal { window.close() }
            default: Self.log.error("usage: show settings|first-run|shortcuts|none")
            }
        case "mark":
            let text = parts.dropFirst().joined(separator: " ")
            CaptureLog.timing.info("mark: \(text, privacy: .public)")
        default:
            if UpdateDebugCommands.run(parts) { return }
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

    /// A click on the live overlay (window mode picks the window under it). With `expected`, only if that's the window
    /// it would pick: a test never captures or records some other app's window by mistake.
    private func click(at point: CGPoint, option: Bool, expecting expected: CGWindowID?, in c: AppCoordinator) {
        guard let session = c.capture.currentSession,
              let display = session.displays.first(where: { $0.frame.contains(point) }) else {
            Self.log.error("click: no overlay on a display at \(String(describing: point), privacy: .public)")
            return
        }
        if let expected, c.capture.shareableContent.window(at: point)?.id != expected {
            Self.log.error("click: window \(expected) isn't the one at \(String(describing: point), privacy: .public); cancelling")
            session.cancel()
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

    /// The recording under way (or the last one's numbers): its state and target, the encoded size, frame rate and bit
    /// rate, the temp file, and frames written and dropped.
    private static func recordingState(_ r: RecordingController, stats: ScreenRecorder.Stats?) -> [String: Any] {
        var out: [String: Any] = ["state": "\(r.state)", "elapsed": r.elapsed, "target": r.target?.name ?? NSNull()]
        if let source = r.source {
            let size = source.videoSize
            out["width"] = Int(size.width)
            out["height"] = Int(size.height)
            out["fps"] = source.fps
            out["bitRate"] = RecordingFormat.bitRate(width: Int(size.width), height: Int(size.height), fps: source.fps)
            out["systemAudio"] = source.systemAudio
            out["microphone"] = source.microphone
        }
        if let url = r.recorder?.url { out["tempPath"] = url.path }
        if let stats {
            out["framesWritten"] = stats.framesWritten
            out["framesDropped"] = stats.framesDropped
            out["audioSamples"] = stats.audioSamples
            out["microphoneSamples"] = stats.microphoneSamples
        }
        if let last = r.lastOutcome {
            out["last"] = ["duration": last.duration, "framesWritten": last.framesWritten,
                           "framesDropped": last.framesDropped] as [String: Any]
        }
        return out
    }

    /// "Delete screenshots after pasting" (spec §14.2): the setting, the watched clipboard write and who read it (with
    /// the keys held), the files waiting to be deleted, the clipboard's Pasteboard files, and the ⌘Z steps.
    private static func pasteboardState(_ c: AppCoordinator) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out: [String: Any] = [
            "deletesAfterPasting": c.prefs.deletesAfterPasting,
            "folder": Preferences.pasteboardFolder.path,
            "waiting": c.retention.waiting.mapValues { iso.string(from: $0) },
            "clipboardFiles": c.clipboardFiles.map { ["changeCount": $0.changeCount, "paths": $0.paths] as [String: Any] } ?? NSNull(),
            "undo": c.shelf.undoStack.map { step -> [String: Any] in
                ["kind": "\(step.kind)", "ids": step.removals.map(\.item.id.uuidString), "paths": step.removals.map(\.item.path),
                 "removedAt": iso.string(from: step.removedAt)]
            },
        ]
        if let w = c.pasteWatch {
            out["watch"] = [
                "changeCount": w.changeCount,
                "current": w.changeCount == NSPasteboard.general.changeCount,
                "finished": w.isFinished,
                "pasted": w.pasted.map(\.uuidString).sorted(),
                "switchedApps": w.switchedApps,
                "reads": w.reads.map { r -> [String: Any] in
                    ["type": r.type, "id": r.id.uuidString, "afterMs": (r.after * 1000).rounded(),
                     "command": r.keys.command, "control": r.keys.control,
                     "sinceKeyDownMs": r.keys.sinceKeyDown.isFinite ? (r.keys.sinceKeyDown * 1000).rounded() : -1, "v": r.keys.v]
                },
            ] as [String: Any]
        } else {
            out["watch"] = NSNull()
        }
        return out
    }

    private func dumpState(_ c: AppCoordinator) async {
        let prefs = c.prefs
        let stats = await c.recording.recorder?.currentStats()
        var state: [String: Any] = [
            "itemIDs": c.shelf.itemIDs.map(\.uuidString),
            "itemPaths": c.store.items.map(\.path),
            // Oldest first, as the items: which have a live card, which of those are in the pile, and which hold a
            // decoded thumbnail.
            "cards": c.store.items.map { item -> [String: Any] in
                guard let card = c.shelf.cards[item.id] else { return ["live": false] }
                return ["live": true, "inPile": card.isInPile, "thumbnail": card.thumbnail != nil]
            },
            "isTucked": c.shelf.isTucked,
            "markedItemID": c.shelf.markedItemID?.uuidString ?? NSNull(),
            "clipboardMarkItemID": c.mark.itemID?.uuidString ?? NSNull(),
            "pasteboardChangeCount": NSPasteboard.general.changeCount,
            "isCapturing": c.capture.isCapturing,
            "overlay": c.capture.currentSession.map { ["mode": "\($0.mode)", "purpose": "\($0.purpose)"] } ?? NSNull(),
            "recording": Self.recordingState(c.recording, stats: stats),
            "statusItem": c.menuBar?.debugState ?? NSNull(),
            "itemKinds": c.store.items.map(\.kind.rawValue),
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
        state["recordsSystemAudio"] = prefs.recordsSystemAudio
        state["recordsMicrophone"] = prefs.recordsMicrophone
        state["pasteboard"] = Self.pasteboardState(c)
        do {
            let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: Self.stateFileURL, options: .atomic)
        } catch {
            Self.log.error("dump-state failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
