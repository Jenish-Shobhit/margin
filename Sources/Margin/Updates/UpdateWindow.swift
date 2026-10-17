import AppKit
import MarginKit
import SwiftUI

/// The small "Margin Update" window (spec §14.3), like Settings: SwiftUI in a titled, closable NSWindow.
@MainActor
final class UpdateWindowController: NSObject, NSWindowDelegate {
    static let shared = UpdateWindowController()

    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }
    var isKey: Bool { window?.isKeyWindow ?? false }
    /// For `screencapture -l` in tests.
    var windowNumber: Int? { window?.isVisible == true ? window?.windowNumber : nil }

    /// `activate` false (an automatic check) puts the window in front without taking the keyboard from the app in use.
    func show(activate: Bool) {
        let window = self.window ?? makeWindow()
        self.window = window
        if !window.isVisible {
            if let view = window.contentViewController?.view { window.setContentSize(view.fittingSize) }
            window.center()
        }
        if activate {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        // A menu bar app can be refused activation (cooperative activation): the window still comes to the front.
        window.orderFrontRegardless()
    }

    func close() {
        guard let window, window.isVisible else { return }
        closingFromController = true
        window.close()
        closingFromController = false
    }

    private var closingFromController = false

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: UpdateView(updates: UpdateController.shared))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "Margin Update"
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard !closingFromController else { return }
        UpdateController.shared.windowClosed()
    }
}

/// What the window shows for each `UpdateController.Phase`.
struct UpdateView: View {
    let updates: UpdateController

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var current: String { UpdateController.currentVersionString }

    @ViewBuilder private var content: some View {
        switch updates.phase {
        case .idle:
            Text("Margin \(current)").font(.headline)
            buttons { Button("OK") { updates.later() }.keyboardShortcut(.defaultAction) }
        case .checking:
            Text("Checking for updates…").font(.headline)
            ProgressView().progressViewStyle(.linear).accessibilityLabel("Checking")
            buttons { Button("Cancel") { updates.cancel() }.keyboardShortcut(.cancelAction) }
        case .upToDate:
            Text("Margin \(current) is up to date.").font(.headline)
            Text("It’s the newest version available.").foregroundStyle(.secondary)
            buttons { Button("OK") { updates.later() }.keyboardShortcut(.defaultAction) }
        case .available(let update):
            header(update)
            ReleaseNotesView(markdown: update.notes)
            HStack {
                Button("Skip This Version") { updates.skip() }
                Spacer()
                Button("Later") { updates.later() }.keyboardShortcut(.cancelAction)
                Button("Install and Relaunch") { updates.install() }
                    .keyboardShortcut(updates.askedByLink ? nil : .defaultAction)
            }
        case .downloading(let update, let fraction, let received, let total):
            header(update)
            ReleaseNotesView(markdown: update.notes)
            progress(fraction, label: downloadLabel(received, total))
            buttons { Button("Cancel") { updates.cancel() }.keyboardShortcut(.cancelAction) }
        case .verifying(let update):
            header(update)
            ReleaseNotesView(markdown: update.notes)
            progress(nil, label: "Checking the download’s signature…")
            buttons { Button("Cancel") { updates.cancel() }.keyboardShortcut(.cancelAction) }
        case .relaunching(let update):
            header(update)
            ReleaseNotesView(markdown: update.notes)
            progress(1, label: "Installing… Margin will quit and open the new version.")
            buttons { Button("Cancel") {}.disabled(true) }
        case .failed(let error, let update):
            Text(failureTitle(error, update)).font(.headline)
            Text(error.message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack {
                Button("Open Releases Page") { updates.openReleasesPage() }
                Spacer()
                if update != nil, !error.opensReleasesPage {
                    Button("Try Again") { updates.install() }
                }
                Button("Close") { updates.later() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func header(_ update: AvailableUpdate) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Margin \(update.versionString) is available — you have \(current).")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let date = update.publishedAt {
                Text("Released \(date.formatted(date: .long, time: .omitted)).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func failureTitle(_ error: UpdateError, _ update: AvailableUpdate?) -> String {
        switch error {
        case .helperFailed(let version, _): "Margin \(version) wasn’t installed."
        default:
            if let update { "Couldn’t install Margin \(update.versionString)." }
            else if error.isInstallError { "Couldn’t install the update." }
            else { "Couldn’t check for updates." }
        }
    }

    private func progress(_ fraction: Double?, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let fraction {
                ProgressView(value: fraction).progressViewStyle(.linear)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func downloadLabel(_ received: Int64, _ total: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return total > 0
            ? "Downloading… \(f.string(fromByteCount: received)) of \(f.string(fromByteCount: total))"
            : "Downloading… \(f.string(fromByteCount: received))"
    }

    private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        HStack {
            Spacer()
            content()
        }
    }
}

/// The release notes in a scrolling box: headings, bullets and paragraphs (`ReleaseNotes`), with inline Markdown
/// (bold, `code`, links) from `AttributedString`.
private struct ReleaseNotesView: View {
    let blocks: [ReleaseNotes.Block]

    init(markdown: String) {
        blocks = ReleaseNotes.blocks(markdown)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if blocks.isEmpty {
                    Text("No release notes.").foregroundStyle(.secondary)
                }
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    row(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .textSelection(.enabled)
        }
        .frame(height: 220)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        .accessibilityLabel("Release notes")
    }

    @ViewBuilder private func row(_ block: ReleaseNotes.Block) -> some View {
        switch block {
        case .heading(let level, let text) where level <= 2:
            Text(inline(text)).font(.headline).padding(.top, 4)
        case .heading(_, let text):
            Text(inline(text)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(text)).fixedSize(horizontal: false, vertical: true)
            }
        case .paragraph(let text):
            Text(inline(text)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
