import AppKit
import MarginKit
import SwiftUI

/// General: where shots go and what happens to them, capturing, how Margin starts, and its menu bar icon. A toggle whose
/// effect isn't obvious says it under its title.
struct GeneralSettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        PaneForm(pane: .general) {
            Section("Saving & Clipboard") {
                // The folder by name, as Finder shows it in a path bar; where it is in the tooltip.
                LabeledContent("Save to") {
                    HStack(spacing: 6) {
                        Image(nsImage: model.folderIcon)
                            .resizable()
                            .frame(width: 16, height: 16)
                            .accessibilityHidden(true)
                        Text(model.saveFolder.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(model.saveFolderDisplay)
                            .accessibilityLabel(model.saveFolderDisplay)
                        Button("Choose…") { model.chooseFolder(for: model.window()) }
                            .accessibilityLabel("Choose a folder to save to")
                    }
                }
                Toggle("Copy each capture", isOn: Binding(get: { model.copyEachCapture }, set: model.setCopyEachCapture))
                Toggle(isOn: Binding(get: { model.deletesAfterPasting }, set: model.setDeletesAfterPasting)) {
                    Text("Delete screenshots after pasting")
                    Text("Screenshots aren’t saved to your folder: one you paste or drag into an app is deleted once undo can’t bring it back.")
                }
                .help("Screenshots wait in Margin’s own folder. One you paste (⌘V) or drag into an app leaves the shelf, and its file is deleted once Restore Last Removed can’t bring it back. Close Shelf moves the ones you haven’t pasted into your folder. Screen recordings are always saved.")
            }

            Section("Capturing") {
                Toggle("Shutter sound", isOn: Binding(get: { model.shutterSound }, set: model.setShutterSound))
                Toggle(isOn: Binding(get: { model.showsCaptureHints }, set: model.setShowsCaptureHints)) {
                    Text("Show key hints while capturing")
                    Text("The bar of keys at the top of the screen.")
                }
            }

            Section("Startup") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                    if model.loginNeedsApproval {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("Approve in System Settings › General › Login Items.")
                                .foregroundStyle(.secondary)
                            Button("Open Login Items") { model.openLoginItemsSettings() }
                                .buttonStyle(.link)
                        }
                        .font(.caption)
                    } else if let error = model.loginItemError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section {
                Toggle(isOn: Binding(get: { model.menuBarIconShown }, set: model.setMenuBarIcon)) {
                    Text("Show menu bar icon")
                    Text("When it’s hidden, open Margin again from Spotlight, Launchpad or Applications to bring it back.")
                }
            } header: {
                Text("Menu Bar")
            } footer: {
                if let note = model.menuBarNote { SettingsFooter(note) }
            }
        }
    }
}

/// Shortcuts: Margin's, each with its recorder, then the macOS screenshot shortcuts that take the same keys first.
struct ShortcutsSettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        PaneForm(pane: .shortcuts) {
            Section {
                ShortcutRow(model: model, action: .captureArea)
                // Not a shortcut of its own: Space switches the area capture to windows.
                LabeledContent("Capture window") {
                    Text("Space after \(model.shortcut(for: .captureArea).displayString)")
                        .foregroundStyle(.secondary)
                }
                ShortcutRow(model: model, action: .captureScreen)
                ShortcutRow(model: model, action: .repeatArea)
                ShortcutRow(model: model, action: .recordScreen, subtitle: "Press again to stop.")
                ShortcutRow(model: model, action: .toggleShelf)
            } header: {
                Text("Margin")
            } footer: {
                SettingsFooter("Click a shortcut, then press the new keys. Each capture shortcut also works with ⌃ added (\(model.shortcut(for: .captureArea).withControl.displayString)), since every shot is already copied.")
            }

            Section {
                SystemShortcutsRow(model: model)
            } header: {
                Text("macOS Screenshot Shortcuts")
            } footer: {
                SettingsFooter(model.anySystemShortcutOn
                    ? "While these are on, macOS takes ⇧⌘3, ⇧⌘4 and ⇧⌘5 before Margin."
                    : "Margin has ⇧⌘3, ⇧⌘4 and ⇧⌘5. Restore gives them back to macOS.")
            }
        }
    }
}

/// Recording: screen recording's audio (spec §14.4), what the Mac plays and the microphone, both off until turned on
/// here.
struct RecordingSettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        PaneForm(pane: .recording) {
            Section {
                Toggle(isOn: Binding(get: { model.recordsSystemAudio }, set: model.setRecordsSystemAudio)) {
                    Text("Record system audio")
                    Text("What the Mac plays, without Margin’s own sounds.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(get: { model.recordsMicrophone }, set: model.setRecordsMicrophone)) {
                        Text("Record microphone")
                        // While macOS says no, why, in its place.
                        Text(model.microphoneNote ?? "macOS asks for permission when you turn it on.")
                    }
                    if model.microphoneNote != nil {
                        Button("Open Privacy Settings") { model.openMicrophoneSettings() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            } header: {
                Text("Audio")
            } footer: {
                SettingsFooter("\(model.shortcut(for: .recordScreen).displayString) records an area, a window or the whole screen, and stops the recording. Recordings are saved as MP4 movies to your Save to folder.")
            }
        }
    }
}

/// Updates (spec §14.3): the version, the daily check, and a check now.
struct UpdatesSettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        PaneForm(pane: .updates) {
            Section {
                LabeledContent("Version", value: model.versionText)
                Toggle(isOn: Binding(get: { model.checksForUpdates }, set: model.setChecksForUpdates)) {
                    Text("Check for updates automatically")
                    Text("At launch and once a day, from GitHub. Nothing about you is sent.")
                }
                LabeledContent {
                    Button("Check Now") { model.onCheckForUpdates() }
                } label: {
                    Text(model.lastUpdateCheckText).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// About: the icon, the version, and where Margin lives.
struct AboutSettingsView: View {
    let model: SettingsModel

    static let website = URL(string: "https://jenish-shobhit.github.io/margin/")!
    static let source = URL(string: "https://github.com/Jenish-Shobhit/margin")!
    static let issues = URL(string: "https://github.com/Jenish-Shobhit/margin/issues/new")!

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 24)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Margin").font(.system(size: 22, weight: .bold)).accessibilityAddTraits(.isHeader)
            Text("Version \(model.versionText)").font(.system(size: 12)).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Screenshots that wait in the margin of your screen.").font(.system(size: 13)).foregroundStyle(.secondary)
                .padding(.top, 2)
            HStack(spacing: 8) {
                Button("Website") { model.onOpenURL(Self.website) }
                Button("Source Code") { model.onOpenURL(Self.source) }
                Button("Report an Issue") { model.onOpenURL(Self.issues) }
            }
            .buttonStyle(.bordered).controlSize(.small)
            .padding(.top, 12)
            Spacer(minLength: 24)
            VStack(spacing: 2) {
                Text("Free and open source under the MIT License. © 2026 Jenish Shobhit.")
                Text("No analytics. The only network use is checking GitHub for updates.")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }
}

/// Turns the macOS screenshot shortcuts off (⇧⌘3, ⇧⌘4 and ⇧⌘5's toolbar), or restores them, with a short status line
/// (spec, 0.0.6 and §14.4).
private struct SystemShortcutsRow: View {
    let model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                HStack(spacing: 8) {
                    if model.systemShortcutsBusy {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Working")
                    }
                    Button(model.anySystemShortcutOn ? "Turn Off" : "Restore") { model.toggleSystemShortcuts() }
                        .disabled(model.systemShortcutsBusy)
                        .accessibilityLabel(model.anySystemShortcutOn ? "Turn off macOS screenshot shortcuts" : "Restore macOS screenshot shortcuts")
                }
            } label: {
                Text(model.systemShortcutsStatus)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.systemShortcutsError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.systemShortcutsError)
    }
}

private struct ShortcutRow: View {
    let model: SettingsModel
    let action: ShortcutAction
    var subtitle: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            LabeledContent {
                ShortcutRecorder(model: model, action: action)
            } label: {
                Text(SettingsModel.title(for: action))
                if let subtitle { Text(subtitle) }
            }
            if let message = model.message, message.action == action {
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            } else if let failure = model.failureText(for: action) ?? model.systemConflictText(for: action) {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.message?.text)
        .animation(.easeOut(duration: 0.15), value: model.failureText(for: action) ?? model.systemConflictText(for: action))
    }
}

/// Click to record; the next key with ⌘ or ⌃ becomes the shortcut. Esc cancels, Delete resets.
private struct ShortcutRecorder: View {
    let model: SettingsModel
    let action: ShortcutAction

    private var isRecording: Bool { model.recording == action }

    var body: some View {
        Button { model.toggleRecording(action) } label: {
            Text(label)
                .font(.system(size: 12.5, weight: isRecording ? .regular : .medium))
                .foregroundStyle(isRecording ? Color.accentColor : Color.primary)
                .frame(minWidth: 96)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isRecording ? Color.accentColor.opacity(0.12) : Color(nsColor: .quaternarySystemFill))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isRecording ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isRecording ? "Press the new shortcut. Esc cancels, Delete resets to \(action.defaultCombo.displayString)."
                          : "Click to record a new shortcut.")
        .accessibilityLabel("\(SettingsModel.title(for: action)) shortcut")
        .accessibilityValue(isRecording ? "Recording" : accessibilityValue)
    }

    private var accessibilityValue: String {
        let keys = model.shortcut(for: action).displayString
        return (model.failureText(for: action) ?? model.systemConflictText(for: action)).map { "\(keys), not working: \($0)" } ?? keys
    }

    private var label: String {
        guard isRecording else { return model.shortcut(for: action).displayString }
        let held = KeyCombo.modifierSymbols(model.heldModifiers)
        return held.isEmpty ? "Press keys…" : "\(held)…"
    }
}
