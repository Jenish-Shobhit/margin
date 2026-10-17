import AppKit
import MarginKit
import SwiftUI

/// The settings (spec §8) in a grouped form.
struct SettingsView: View {
    @Bindable var model: SettingsModel
    /// The hosting window, for the folder sheet.
    var window: () -> NSWindow?

    var body: some View {
        Form {
            Section {
                LabeledContent("Save to") {
                    HStack(spacing: 8) {
                        Image(nsImage: model.folderIcon)
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(model.saveFolderDisplay)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(model.saveFolder.path)
                        Button("Choose…") { model.chooseFolder(for: window()) }
                    }
                }
                Toggle("Copy each capture", isOn: Binding(get: { model.copyEachCapture }, set: model.setCopyEachCapture))
                Toggle("Shutter sound", isOn: Binding(get: { model.shutterSound }, set: model.setShutterSound))
                Toggle("Show key hints while capturing", isOn: Binding(get: { model.showsCaptureHints }, set: model.setShowsCaptureHints))
                Toggle("Check for updates automatically", isOn: Binding(get: { model.checksForUpdates }, set: model.setChecksForUpdates))
                    .help("At launch and once a day, Margin asks GitHub for its latest release. Nothing about you is sent.")
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
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    ShortcutRow(model: model, action: action)
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Window capture: press Space after \(model.shortcut(for: .captureArea).displayString). Adding ⌃ to any capture shortcut does the same thing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                SystemShortcutsRow(model: model)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Turns the four macOS screenshot shortcuts off, or restores them, with a short status line (spec, 0.0.6).
private struct SystemShortcutsRow: View {
    let model: SettingsModel

    var body: some View {
        // Always two lines: the button title is too long to share a line with the status in a 460 pt window.
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("macOS screenshot shortcuts")
                Text(model.systemShortcutsStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if model.systemShortcutsBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Working")
                }
                Button(model.anySystemShortcutOn ? "Turn off macOS screenshot shortcuts" : "Restore macOS screenshot shortcuts") {
                    model.toggleSystemShortcuts()
                }
                .disabled(model.systemShortcutsBusy)
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

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            LabeledContent(SettingsModel.title(for: action)) {
                ShortcutRecorder(model: model, action: action)
            }
            if let message = model.message, message.action == action {
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            } else if let failure = model.failureText(for: action) {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.message?.text)
        .animation(.easeOut(duration: 0.15), value: model.failureText(for: action))
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
        return model.failureText(for: action).map { "\(keys), not working: \($0)" } ?? keys
    }

    private var label: String {
        guard isRecording else { return model.shortcut(for: action).displayString }
        let held = KeyCombo.modifierSymbols(model.heldModifiers)
        return held.isEmpty ? "Press keys…" : "\(held)…"
    }
}
