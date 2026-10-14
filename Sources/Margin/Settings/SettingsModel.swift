import AppKit
import Carbon.HIToolbox
import MarginKit
import Observation

/// What the Settings window shows, mirrored from `Preferences` (which posts `didChange` on every write).
@MainActor @Observable
final class SettingsModel {
    @ObservationIgnored let prefs: Preferences

    private(set) var saveFolder: URL
    /// The save folder's Finder icon; the generic folder icon until it's been read, or if the folder is missing.
    private(set) var folderIcon: NSImage = SettingsModel.genericFolderIcon
    /// Whether the save folder exists; nil until the first check finishes (`refreshFolderInfo`).
    private(set) var saveFolderExists: Bool?
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
    /// Shortcuts the hotkey center couldn't register, with the Carbon status (`RuntimeStatus.hotkeyFailures`).
    private(set) var hotkeyFailures: [ShortcutAction: Int32] = [:]

    @ObservationIgnored let status: RuntimeStatus
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var checkedFolder: URL?
    @ObservationIgnored private var folderCheck: Task<Void, Never>?

    static let genericFolderIcon = NSWorkspace.shared.icon(for: .folder)

    init(prefs: Preferences = .shared, status: RuntimeStatus = .shared) {
        self.prefs = prefs
        self.status = status
        saveFolder = prefs.saveFolder
        copyEachCapture = prefs.copyEachCapture
        shutterSound = prefs.shutterSound
        launchAtLogin = prefs.launchAtLogin
        reload()
        hotkeyFailures = status.hotkeyFailures
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: Preferences.didChange, object: prefs, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        observers.append(center.addObserver(forName: RuntimeStatus.didChange, object: status, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hotkeyFailures = self.status.hotkeyFailures
            }
        })
    }

    /// Why `action`'s shortcut isn't working right now, if it isn't. Hidden while that recorder is listening
    /// (hotkeys are paused then) or showing its own message.
    func failureText(for action: ShortcutAction) -> String? {
        guard recording != action, message?.action != action, let code = hotkeyFailures[action] else { return nil }
        switch OSStatus(code) {
        case OSStatus(eventHotKeyExistsErr): return "Another app uses this shortcut. Choose another."
        default: return "macOS didn’t accept this shortcut. Choose another."
        }
    }

    func reload() {
        saveFolder = prefs.saveFolder
        copyEachCapture = prefs.copyEachCapture
        shutterSound = prefs.shutterSound
        launchAtLogin = prefs.launchAtLogin
        loginNeedsApproval = LoginItem.requiresApproval
        shortcuts = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, prefs.shortcut(for: $0)) })
        refreshFolderInfo()
    }

    // MARK: Save folder

    /// Reads whether the save folder exists, and its icon, off the main thread. The first access to ~/Desktop
    /// can wait on a privacy prompt, which must never freeze the app (and never happen in a view's `body`).
    /// Only re-reads when the folder changed, unless `force` (e.g. each time the window opens).
    func refreshFolderInfo(force: Bool = false) {
        let folder = saveFolder
        guard force || folder != checkedFolder else { return }
        checkedFolder = folder
        folderCheck?.cancel()
        folderCheck = Task { [weak self] in
            let info = await Task.detached(priority: .utility) { Self.readFolderInfo(folder) }.value
            guard !Task.isCancelled, let self, self.saveFolder == folder else { return }
            self.saveFolderExists = info.exists
            self.folderIcon = info.icon ?? Self.genericFolderIcon
        }
    }

    /// Touches the disk: call off the main thread only.
    nonisolated private static func readFolderInfo(_ folder: URL) -> (exists: Bool, icon: NSImage?) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return (false, nil)
        }
        let icon = (try? folder.resourceValues(forKeys: [.effectiveIconKey]))?.effectiveIcon as? NSImage
        return (true, icon)
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
        // Uses the last off-main check; never touches the disk here.
        panel.directoryURL = saveFolderExists == true ? saveFolder : saveFolder.deletingLastPathComponent()
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
                message = (action, "Use ⌘ or ⌃ with the key. ⇧ and ⌥ alone aren’t enough.")
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
