import AppKit
import MarginKit
import Observation

/// What the Settings window shows, mirrored from `Preferences` (which posts `didChange` on every write).
@MainActor @Observable
final class SettingsModel {
    @ObservationIgnored let prefs: Preferences

    private(set) var saveFolder: URL
    private(set) var copyEachCapture: Bool
    private(set) var shutterSound: Bool
    private(set) var launchAtLogin: Bool
    private(set) var loginNeedsApproval = false
    private(set) var shortcuts: [ShortcutAction: KeyCombo] = [:]

    /// The recorder that's listening for keys, if any.
    private(set) var recording: ShortcutAction?
    /// Modifiers held while recording, for the live "⌃⇧…" preview.
    private(set) var heldModifiers: UInt32 = 0
    /// An inline message under one recorder (rejected combo).
    private(set) var message: (action: ShortcutAction, text: String)?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var monitor: Any?

    init(prefs: Preferences = .shared) {
        self.prefs = prefs
        saveFolder = prefs.saveFolder
        copyEachCapture = prefs.copyEachCapture
        shutterSound = prefs.shutterSound
        launchAtLogin = prefs.launchAtLogin
        reload()
        observers.append(NotificationCenter.default.addObserver(forName: Preferences.didChange, object: prefs, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
    }

    func reload() {
        saveFolder = prefs.saveFolder
        copyEachCapture = prefs.copyEachCapture
        shutterSound = prefs.shutterSound
        launchAtLogin = prefs.launchAtLogin
        loginNeedsApproval = LoginItem.requiresApproval
        shortcuts = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, prefs.shortcut(for: $0)) })
    }

    // MARK: Simple settings

    func setSaveFolder(_ url: URL) { prefs.saveFolder = url }
    func setCopyEachCapture(_ on: Bool) { prefs.copyEachCapture = on }
    func setShutterSound(_ on: Bool) { prefs.shutterSound = on }

    func setLaunchAtLogin(_ on: Bool) {
        LoginItem.setEnabled(on)
        prefs.launchAtLogin = on
    }

    var saveFolderDisplay: String { (saveFolder.path as NSString).abbreviatingWithTildeInPath }

    func chooseFolder(for window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where Margin saves screenshots."
        panel.directoryURL = FileManager.default.fileExists(atPath: saveFolder.path)
            ? saveFolder : saveFolder.deletingLastPathComponent()
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.setSaveFolder(url)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    // MARK: Shortcut recording

    func shortcut(for action: ShortcutAction) -> KeyCombo { shortcuts[action] ?? action.defaultCombo }

    func toggleRecording(_ action: ShortcutAction) {
        if recording == action { stopRecording() } else { startRecording(action) }
    }

    func startRecording(_ action: ShortcutAction) {
        recording = action
        heldModifiers = 0
        message = nil
        prefs.isRecordingShortcut = true
        guard monitor == nil else { return }
        // Local monitors run on the main thread. Returning nil swallows the key while recording.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let keyCode = event.keyCode, flags = event.modifierFlags, isFlags = event.type == .flagsChanged
            let swallowed = MainActor.assumeIsolated {
                self?.handle(keyCode: keyCode, flags: flags, isFlagsChanged: isFlags) ?? false
            }
            return swallowed ? nil : event
        }
    }

    func stopRecording(keepMessage: Bool = false) {
        recording = nil
        heldModifiers = 0
        if !keepMessage { message = nil }
        prefs.isRecordingShortcut = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Handles a key event while recording. Returns true when the event was used (and should be swallowed).
    func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags, isFlagsChanged: Bool) -> Bool {
        guard let action = recording else { return false }
        if isFlagsChanged {
            heldModifiers = KeyCombo.carbonModifiers(from: flags)
            return true
        }
        switch keyCode {
        case 0x35: // Esc cancels
            stopRecording()
        case 0x33, 0x75: // Delete / forward delete: back to the default
            assign(action.defaultCombo, to: action)
        default:
            let combo = KeyCombo(keyCode: keyCode, cocoaModifiers: flags)
            if !combo.hasRequiredModifier {
                message = (action, "Use ⌘, ⌃ or ⌥ with the key. ⇧ alone isn’t enough.")
            } else if KeyCombo.keyName(for: combo.keyCode) == nil {
                message = (action, "That key can’t be used for a shortcut.")
            } else {
                assign(combo, to: action)
            }
        }
        return true
    }

    private func assign(_ combo: KeyCombo, to action: ShortcutAction) {
        if let other = action.conflict(assigning: combo, current: shortcut(for:)) {
            message = (action, "\(combo.displayString) is already used by \(Self.title(for: other)).")
            return
        }
        if combo == action.defaultCombo { prefs.resetShortcut(for: action) } else { prefs.setShortcut(combo, for: action) }
        stopRecording()
    }

    static func title(for action: ShortcutAction) -> String {
        switch action {
        case .captureArea: "Capture area"
        case .captureScreen: "Capture screen"
        case .repeatArea: "Repeat last area"
        case .toggleShelf: "Show or tuck shelf"
        }
    }
}
