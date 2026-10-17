import AppKit
import AVFoundation
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
    private(set) var deletesAfterPasting: Bool
    private(set) var shutterSound: Bool
    private(set) var showsCaptureHints: Bool
    private(set) var recordsSystemAudio: Bool
    private(set) var recordsMicrophone: Bool
    /// Microphone permission, as last read (`refreshMicrophoneAccess`): reading it never asks.
    private(set) var microphoneAccess: AVAuthorizationStatus = .notDetermined
    /// The login item's real state (`LoginItem.state`), not the preference: on once registered.
    private(set) var launchAtLogin = false
    /// Registered, but the user still has to allow it in System Settings › General › Login Items.
    private(set) var loginNeedsApproval = false
    /// Shown under the toggle when turning launch at login on didn't work.
    private(set) var loginItemError: String?
    /// Check GitHub for a newer release at launch and every 24 hours (spec §14.3).
    private(set) var checksForUpdates = true
    private(set) var shortcuts: [ShortcutAction: KeyCombo] = [:]

    /// The recorder that's listening for keys, if any.
    private(set) var recording: ShortcutAction?
    /// Modifiers held while recording, for the live "⌃⇧…" preview.
    private(set) var heldModifiers: UInt32 = 0
    /// An inline message under one recorder (rejected combo).
    private(set) var message: (action: ShortcutAction, text: String)?
    /// Shortcuts the hotkey center couldn't register, with the Carbon status (`RuntimeStatus.hotkeyFailures`).
    private(set) var hotkeyFailures: [ShortcutAction: Int32] = [:]

    /// The macOS screenshot shortcuts (IDs 28–31 and 184), as last read (`refreshSystemShortcuts`).
    private(set) var systemShortcuts: [SystemScreenshotShortcut] = []
    /// Turning them off or restoring them is running (about half a second).
    private(set) var systemShortcutsBusy = false
    /// Why the last turn off / restore didn't work.
    private(set) var systemShortcutsError: String?

    @ObservationIgnored let status: RuntimeStatus
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var checkedFolder: URL?
    @ObservationIgnored private var folderCheck: Task<Void, Never>?
    // Login item sources, swappable for visual checks.
    @ObservationIgnored var readLoginItem: () -> LoginItem.State = { LoginItem.state }
    @ObservationIgnored var setLoginItem: (Bool) -> Void = { LoginItem.setEnabled($0) }
    // macOS screenshot shortcut sources, swappable for visual checks.
    @ObservationIgnored var readSystemShortcuts: () -> [SystemScreenshotShortcut] = { SystemShortcuts.current() }
    @ObservationIgnored var setSystemShortcuts: (Bool) async throws -> Void = { try await SystemShortcuts.setEnabledInBackground($0) }
    /// The other system shortcuts' bindings, checked when recording (read once per recording).
    @ObservationIgnored var readSystemCombos: () -> Set<KeyCombo> = { SystemShortcuts.currentOtherEnabledCombos() }
    @ObservationIgnored private var systemCombos: Set<KeyCombo>?
    // Microphone permission sources, swappable for visual checks.
    @ObservationIgnored var readMicrophoneAccess: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) }
    @ObservationIgnored var requestMicrophoneAccess: () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }

    static let genericFolderIcon = NSWorkspace.shared.icon(for: .folder)

    init(prefs: Preferences = .shared, status: RuntimeStatus = .shared) {
        self.prefs = prefs
        self.status = status
        saveFolder = prefs.saveFolder
        copyEachCapture = prefs.copyEachCapture
        deletesAfterPasting = prefs.deletesAfterPasting
        shutterSound = prefs.shutterSound
        showsCaptureHints = prefs.showsCaptureHints
        recordsSystemAudio = prefs.recordsSystemAudio
        recordsMicrophone = prefs.recordsMicrophone
        reload()
        refreshLoginItem()
        refreshSystemShortcuts()
        hotkeyFailures = status.hotkeyFailures
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: Preferences.didChange, object: prefs, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        // Another keyboard layout names the keys differently (Y and Z swap on a German one).
        observers.append(center.addObserver(forName: KeyboardLayout.didChange, object: nil, queue: .main) { [weak self] _ in
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
        deletesAfterPasting = prefs.deletesAfterPasting
        shutterSound = prefs.shutterSound
        showsCaptureHints = prefs.showsCaptureHints
        recordsSystemAudio = prefs.recordsSystemAudio
        recordsMicrophone = prefs.recordsMicrophone
        shortcuts = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, prefs.shortcut(for: $0)) })
        refreshFolderInfo()
        checksForUpdates = prefs.checksForUpdates
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
    /// Spec §14.2. Turning it either way moves and deletes nothing: it decides where the next screenshots go.
    func setDeletesAfterPasting(_ on: Bool) { prefs.deletesAfterPasting = on }
    func setShutterSound(_ on: Bool) { prefs.shutterSound = on }
    func setShowsCaptureHints(_ on: Bool) { prefs.showsCaptureHints = on }

    // MARK: Screen recording

    func setRecordsSystemAudio(_ on: Bool) { prefs.recordsSystemAudio = on }

    /// Turning the microphone on asks for permission now, if macOS hasn't asked yet, rather than at the next recording.
    func setRecordsMicrophone(_ on: Bool) {
        prefs.recordsMicrophone = on
        refreshMicrophoneAccess()
        guard on, microphoneAccess == .notDetermined else { return }
        Task {
            _ = await requestMicrophoneAccess()
            refreshMicrophoneAccess()
        }
    }

    /// When the window opens or becomes key again (back from Privacy & Security), and after asking.
    func refreshMicrophoneAccess() {
        microphoneAccess = readMicrophoneAccess()
    }

    /// Under the toggle while recordings can't have the microphone: it's on, but macOS says no.
    var microphoneNote: String? {
        guard recordsMicrophone, microphoneAccess == .denied || microphoneAccess == .restricted else { return nil }
        return "Margin isn’t allowed to use the microphone. Allow it in Privacy & Security › Microphone."
    }

    static let microphoneSettings = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone")!

    func openMicrophoneSettings() { NSWorkspace.shared.open(Self.microphoneSettings) }

    // MARK: Launch at login

    /// Re-reads the login item (an `SMAppService` query, so not on every preference change): when the window
    /// opens or becomes key again (e.g. back from System Settings), and after toggling.
    func refreshLoginItem() {
        let state = readLoginItem()
        launchAtLogin = state.isOn
        loginNeedsApproval = state == .needsApproval
        if state.isOn { loginItemError = nil }
    }

    func setLaunchAtLogin(_ on: Bool) {
        setLoginItem(on)
        prefs.launchAtLogin = on
        refreshLoginItem()
        loginItemError = on && !launchAtLogin
            ? "Couldn’t turn on launch at login. Make sure Margin is in the Applications folder." : nil
    }

    func openLoginItemsSettings() { LoginItem.openSystemSettings() }

    func setChecksForUpdates(_ on: Bool) { prefs.checksForUpdates = on }

    // MARK: macOS screenshot shortcuts

    /// Re-reads `com.apple.symbolichotkeys` (cheap): when the window opens or becomes key again (the user may
    /// have changed them in System Settings), and after turning them off or restoring them.
    func refreshSystemShortcuts() {
        systemShortcuts = readSystemShortcuts()
    }

    /// Any of them is on, so the row offers to turn them off; otherwise it offers to restore them.
    var anySystemShortcutOn: Bool { systemShortcuts.contains { $0.enabled } }

    /// The row's short status line, e.g. "All five are on, so macOS takes them before Margin."
    var systemShortcutsStatus: String {
        let on = systemShortcuts.filter(\.enabled)
        let keys = { (list: [SystemScreenshotShortcut]) in ListFormatter.localizedString(byJoining: list.map(\.keys)) }
        let all = Self.spelledOut(systemShortcuts.count)
        let state = switch on.count {
        case 0: "All \(all) are off"
        case systemShortcuts.count: "All \(all) are on"
        default: "\(keys(on)) \(on.count == 1 ? "is" : "are") on"
        }
        // From the observed `shortcuts`, so the line updates as soon as one of Margin's shortcuts is re-recorded.
        let margin = ShortcutAction.allCases.flatMap { $0.registeredCombos(for: shortcut(for: $0)) }
        let conflicts = SystemShortcuts.conflicts(systemShortcuts, with: margin)
        guard !conflicts.isEmpty else { return state + "." }
        let which = conflicts.count == on.count ? (on.count == 1 ? "it" : "them") : keys(conflicts)
        return "\(state), so macOS takes \(which) before Margin."
    }

    /// "five", for "All five are on".
    private static func spelledOut(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// The macOS shortcut that takes `action`'s keys before Margin does, as "macOS uses ⇧⌘5…": the usual warning under a
    /// shortcut until its macOS twin is turned off (below, or in First run). Hidden while that recorder is listening or
    /// has a message of its own.
    func systemConflictText(for action: ShortcutAction) -> String? {
        guard recording != action, message?.action != action else { return nil }
        let conflicts = SystemShortcuts.conflicts(systemShortcuts, with: action.registeredCombos(for: shortcut(for: action)))
        guard !conflicts.isEmpty else { return nil }
        let keys = ListFormatter.localizedString(byJoining: conflicts.map(\.keys))
        return "macOS uses \(keys) first. Turn off its screenshot shortcuts below."
    }

    /// "Turn off macOS screenshot shortcuts" when any are on, "Restore macOS screenshot shortcuts" when all are off.
    /// Only ever on this click (spec, 0.0.6).
    func toggleSystemShortcuts() {
        guard !systemShortcutsBusy else { return }
        let enable = !anySystemShortcutOn
        systemShortcutsBusy = true
        systemShortcutsError = nil
        Task {
            do {
                try await setSystemShortcuts(enable)
            } catch let error as SystemShortcutsError where error.isSaved {
                systemShortcutsError = "Saved, but macOS hasn’t applied it yet. It will after you log out and back in."
            } catch {
                systemShortcutsError = "\(enable ? "Couldn’t restore them." : "Couldn’t turn them off.") \(error.localizedDescription)"
            }
            refreshSystemShortcuts()
            systemShortcutsBusy = false
        }
    }

    var saveFolderDisplay: String { (saveFolder.path as NSString).abbreviatingWithTildeInPath }

    func chooseFolder(for window: NSWindow?) {
        // The panel's keys are its own (⇧⌘G goes to a folder): a recorder that was listening stops.
        stopRecording()
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
        systemCombos = nil // read again: the user may have changed a system shortcut since
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
        let combo = KeyCombo(keyCode: keyCode, cocoaModifiers: flags)
        switch keyCode {
        case 0x35 where !combo.hasRequiredModifier: // Esc cancels
            stopRecording()
        case 0x33 where !combo.hasRequiredModifier, 0x75 where !combo.hasRequiredModifier: // Delete: back to the default
            assign(action.defaultCombo, to: action)
        default:
            if !combo.hasRequiredModifier {
                message = (action, "Use ⌘ or ⌃ with the key. ⇧ and ⌥ alone aren’t enough.")
            } else if KeyCombo.keyName(for: combo.keyCode) == nil {
                message = (action, "That key can’t be used for a shortcut.")
            } else if let reason = reservedReason(for: combo, action: action) {
                message = (action, reason)
            } else {
                assign(combo, to: action)
            }
        }
        return true
    }

    /// Why `combo` (or its ⌃ twin) can't be `action`'s shortcut. The defaults are always allowed.
    private func reservedReason(for combo: KeyCombo, action: ShortcutAction) -> String? {
        guard combo != action.defaultCombo else { return nil }
        if systemCombos == nil { systemCombos = readSystemCombos() }
        let system = systemCombos ?? []
        return action.registeredCombos(for: combo).lazy.compactMap { ReservedShortcuts.reason(for: $0, systemCombos: system) }.first
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
        case .recordScreen: "Record screen"
        }
    }
}
