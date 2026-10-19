import AppKit
import MarginKit
import SwiftUI

/// The Settings window's panes (spec §8), in the sidebar in two groups: what Margin does, then Margin itself.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, shortcuts, recording, updates, about

    var id: String { rawValue }

    static let featurePanes: [SettingsPane] = [.general, .shortcuts, .recording]
    static let appPanes: [SettingsPane] = [.updates, .about]

    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .recording: "Recording"
        case .updates: "Updates"
        case .about: "About"
        }
    }

    /// The one sentence under the pane's title.
    var summary: String {
        switch self {
        case .general: "Where shots go, what happens to them, and how Margin starts."
        case .shortcuts: "The keys for every capture, and macOS’s own screenshot keys."
        case .recording: "What screen recordings hear."
        case .updates: "Get new versions from GitHub."
        case .about: "Screenshots that wait in the margin."
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .shortcuts: "keyboard.fill"
        case .recording: "record.circle.fill"
        case .updates: "arrow.down.circle.fill"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general, .about: Color(nsColor: .systemGray)
        case .shortcuts: Color(nsColor: .systemBlue)
        case .recording: Color(nsColor: .systemRed)
        case .updates: Color(nsColor: .systemIndigo)
        }
    }
}

/// The root: a sidebar of icon tiles and the selected pane. Pane switches are instant.
struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SettingsSidebar(model: model)
                .navigationSplitViewColumnWidth(min: SettingsWindowController.sidebarWidth, ideal: SettingsWindowController.sidebarWidth,
                                                max: SettingsWindowController.sidebarWidth + 60)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsDetail(model: model)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .transaction { $0.animation = nil }
    }
}

private struct SettingsSidebar: View {
    @Bindable var model: SettingsModel

    private var selection: Binding<SettingsPane?> {
        Binding(get: { model.pane }, set: { if let pane = $0 { model.select(pane) } })
    }

    var body: some View {
        List(selection: selection) {
            Section { ForEach(SettingsPane.featurePanes) { item($0) } }
            Section { ForEach(SettingsPane.appPanes) { item($0) } }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarStatus(model: model) }
    }

    private func item(_ pane: SettingsPane) -> some View {
        HStack(spacing: 8) {
            IconTile(symbol: pane.symbol, tint: pane.tint)
            Text(pane.title).font(.system(size: 13))
            Spacer(minLength: 0)
            if pane == .shortcuts, model.appStatus == .shortcutProblem {
                Circle().fill(Color(nsColor: .systemOrange)).frame(width: 7, height: 7)
                    .accessibilityLabel("A shortcut isn’t working")
            }
        }
        .tag(pane)
        .accessibilityElement(children: .combine)
    }
}

/// The line pinned to the foot of the sidebar: the menu's status line, with what fixes it.
private struct SidebarStatus: View {
    let model: SettingsModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(Color(nsColor: model.appStatus.color)).frame(width: 7, height: 7).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.appStatus.title).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let fix {
                    Button(fix) { model.onFixStatus(model.appStatus) }
                        .buttonStyle(.link).font(.system(size: 12))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Margin status")
    }

    private var fix: String? {
        switch model.appStatus {
        case .needsPermission: "Allow Screen Recording…"
        case .shortcutProblem where model.pane != .shortcuts: "Change Shortcuts…"
        default: nil
        }
    }
}

private struct SettingsDetail: View {
    let model: SettingsModel

    var body: some View {
        Group {
            switch model.pane {
            case .general: GeneralSettingsView(model: model)
            case .shortcuts: ShortcutsSettingsView(model: model)
            case .recording: RecordingSettingsView(model: model)
            case .updates: UpdatesSettingsView(model: model)
            case .about: AboutSettingsView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(model.pane.title)
    }
}

/// A pane's header and its grouped form, the standard pane layout.
struct PaneForm<Content: View>: View {
    let pane: SettingsPane
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            PaneHero(pane: pane).padding(.horizontal, 30).padding(.top, 20)
            Form { content() }
                .formStyle(.grouped)
        }
    }
}

/// A white SF Symbol on a rounded colour tile, System Settings style. Decorative: hidden from VoiceOver.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// The top of every pane: its tile, title and one sentence.
struct PaneHero: View {
    let pane: SettingsPane

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: pane.symbol, tint: pane.tint, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.title).font(.system(size: 15, weight: .semibold))
                Text(pane.summary).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A section's footnote, wrapping under the section.
struct SettingsFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
