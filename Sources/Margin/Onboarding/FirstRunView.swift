import AppKit
import MarginKit
import SwiftUI

/// "Welcome to Margin": three steps, each done / now / pending (see dev_artifacts/ideation_v2.1.html, First run).
struct FirstRunView: View {
    @Bindable var model: FirstRunModel
    var relaunch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepRow(model: model, step: .permission, number: 1, title: "Allow Screen Recording") { permission }
            Divider()
            StepRow(model: model, step: .shortcuts, number: 2, title: "Hand over the shortcuts") { shortcuts }
            Divider()
            StepRow(model: model, step: .firstShot, number: 3, title: "Take your first shot") { firstShot }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .frame(width: 460, alignment: .leading)
        .overlay { if model.finished { AllSet(note: model.stillOnNote).transition(.opacity) } }
        .animation(.easeOut(duration: 0.2), value: model.finished)
    }

    // MARK: Step 1

    @ViewBuilder private var permission: some View {
        switch model.state(of: .permission) {
        case .done:
            Detail("Margin can see the screen.")
        case .pending:
            Detail("Needed to see the screen. macOS asks once.")
        case .now:
            if model.permissionRevoked {
                // macOS keeps answering "allowed" until Margin relaunches, so asking again can't help.
                Detail("Margin lost access to the screen. Turn Margin back on in Privacy & Security › Screen & System Audio Recording, then relaunch it.")
                HStack(spacing: 8) {
                    Button("Open Privacy Settings") { model.openScreenRecordingSettings() }
                    Button("Relaunch Margin", action: relaunch)
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 8)
            } else if !model.requestedPermission {
                Detail("Needed to see the screen. macOS asks once.")
                Button("Allow…") { model.requestPermission() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
            } else {
                Detail("Turn on Margin in Privacy & Security › Screen & System Audio Recording. If it’s already on, relaunch Margin so it takes effect.")
                HStack(spacing: 8) {
                    Button("Open Privacy Settings") { model.openScreenRecordingSettings() }
                        .buttonStyle(.borderedProminent)
                    Button("Relaunch Margin", action: relaunch)
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: Step 2

    @ViewBuilder private var shortcuts: some View {
        switch model.state(of: .shortcuts) {
        case .done:
            Detail("macOS no longer takes Margin’s keys.")
        case .pending:
            Detail("Turn off the macOS screenshot shortcuts.")
        case .now:
            // The deep link opens Keyboard settings; the Screenshots list is behind "Keyboard Shortcuts…".
            Detail("In Keyboard Shortcuts… › Screenshots, untick:")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.shortcuts) { shortcut in
                    Tick(title: shortcut.title, keys: shortcut.keys, ok: !model.conflictIDs.contains(shortcut.id))
                }
            }
            .padding(.top, 6)
            Button("Open Keyboard Shortcuts") { model.openKeyboardSettings() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            HStack(spacing: 4) {
                Kbd("⇧⌘5")
                Text("stays with macOS for screen recording.")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.top, 10)
        }
    }

    // MARK: Step 3

    @ViewBuilder private var firstShot: some View {
        if model.state(of: .firstShot) == .done {
            Detail("You’re set.")
        } else {
            // Says "on" only when the login item really is registered and allowed.
            HStack(spacing: 0) {
                Text("Press ")
                Kbd(model.areaShortcut)
                switch model.loginItem {
                case .on: Text(". Launch at login is on.")
                case .needsApproval: Text(".")
                case .off: Text(". Launch at login is off.")
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            if model.loginItem == .needsApproval {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Launch at login is waiting for your approval.")
                        .foregroundStyle(.secondary)
                    Button("Open Login Items") { model.openLoginItemsSettings() }
                        .buttonStyle(.link)
                }
                .font(.system(size: 12))
                .padding(.top, 4)
            }
        }
    }
}

/// One step: a numbered badge, the title, and its details.
private struct StepRow<Content: View>: View {
    let model: FirstRunModel
    let step: FirstRunModel.Step
    let number: Int
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        let state = model.state(of: step)
        HStack(alignment: .top, spacing: 12) {
            Badge(state: state, number: number)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(state == .pending ? .secondary : .primary)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        // A pending step can be opened by clicking it.
        .onTapGesture { if state == .pending { model.focus = step } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number), \(title), \(state == .done ? "done" : state == .now ? "current" : "to do")")
    }
}

private struct Badge: View {
    let state: FirstRunModel.StepState
    let number: Int

    var body: some View {
        ZStack {
            Circle().fill(fill)
            if state == .done {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
            } else {
                Text("\(number)").font(.system(size: 12, weight: .bold))
            }
        }
        .foregroundStyle(state == .pending ? Color.secondary : Color.white)
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }

    private var fill: Color {
        switch state {
        case .done: Color(nsColor: .systemGreen)
        case .now: Color.accentColor
        case .pending: Color(nsColor: .quaternarySystemFill)
        }
    }
}

private struct Detail: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A checklist line: a box that ticks itself once the macOS shortcut is off.
private struct Tick: View {
    let title: String
    let keys: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(ok ? Color(nsColor: .systemGreen) : Color.clear)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(ok ? Color(nsColor: .systemGreen) : Color(nsColor: .tertiaryLabelColor), lineWidth: 1.5)
                if ok {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                }
            }
            .frame(width: 15, height: 15)
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Kbd(keys)
        }
        .padding(.vertical, 4)
        .animation(.easeOut(duration: 0.2), value: ok)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(keys), \(ok ? "off" : "still on")")
    }
}

/// A key cap, like `<kbd>`.
private struct Kbd: View {
    let keys: String
    init(_ keys: String) { self.keys = keys }

    var body: some View {
        Text(keys)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(nsColor: .quaternarySystemFill)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

/// The brief "You're set" state before the window closes.
private struct AllSet: View {
    /// Shown when macOS still owns some of Margin's shortcuts.
    let note: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.white, Color(nsColor: .systemGreen))
            Text("You’re set")
                .font(.system(size: 20, weight: .semibold))
            Text("Margin lives in the menu bar. Every shot waits on the shelf.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if let note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .combine)
    }
}
