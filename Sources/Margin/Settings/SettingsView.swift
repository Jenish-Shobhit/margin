import AppKit
import MarginKit
import SwiftUI

/// The five settings (spec §8) in a grouped form.
struct SettingsView: View {
    @Bindable var model: SettingsModel
    /// The hosting window, for the folder sheet.
    var window: () -> NSWindow?

    var body: some View {
        Form {
            Section {
                LabeledContent("Save to") {
                    HStack(spacing: 8) {
                        Image(nsImage: folderIcon)
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
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                    if model.launchAtLogin && model.loginNeedsApproval {
                        Text("Allow Margin in System Settings › General › Login Items.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var folderIcon: NSImage {
        FileManager.default.fileExists(atPath: model.saveFolder.path)
            ? NSWorkspace.shared.icon(forFile: model.saveFolder.path)
            : NSWorkspace.shared.icon(for: .folder)
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
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.message?.text)
    }
}

/// Click to record; the next key with ⌘, ⌃ or ⌥ becomes the shortcut. Esc cancels, Delete resets.
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
        .accessibilityValue(isRecording ? "Recording" : model.shortcut(for: action).displayString)
    }

    private var label: String {
        guard isRecording else { return model.shortcut(for: action).displayString }
        let held = KeyCombo.modifierSymbols(model.heldModifiers)
        return held.isEmpty ? "Press keys…" : "\(held)…"
    }
}
