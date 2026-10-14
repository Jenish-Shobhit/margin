import AppKit
@preconcurrency import QuickLookUI

/// Borderless, non-activating panel on the right edge. It becomes key only when a click needs the shelf keys
/// next (`ShelfController.focusShelf`: ⌘-click, ✕, Rename…, Move to Trash, the pile), never on a plain click or
/// when it appears, and never activates Margin.
@MainActor
final class ShelfPanel: NSPanel {
    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        // Margin is almost never the active app; without this the card tooltips ("Options") never show.
        allowsToolTipsWhenApplicationIsInactive = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The panel's content view. First responder for the shelf keys, and the Quick Look controller.
@MainActor
final class ShelfRootView: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    weak var controller: ShelfController?
    private var qlURLs: [URL] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }

    // MARK: - Keys (only reach us while the panel is key: see `ShelfController.focusShelf`)

    override func keyDown(with event: NSEvent) {
        guard let c = controller else { return super.keyDown(with: event) }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        switch event.keyCode {
        case 49 where mods.isEmpty: c.toggleQuickLook()          // Space
        case 51, 117: c.dismissKeyTargets()                        // ⌫, ⌦
        case 53: c.escape()                                        // Esc
        // Quick Look open behind a key shelf (it was ⌘-clicked since): ← ↑ previous shot, → ↓ next.
        case 123 where isQuickLookOpen, 126 where isQuickLookOpen: stepQuickLook(-1)
        case 124 where isQuickLookOpen, 125 where isQuickLookOpen: stepQuickLook(1)
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // While the rename field is editing, ⌘A/⌘C/⌘Z belong to the text.
        guard let c = controller, window?.isKeyWindow == true, event.type == .keyDown,
              !(window?.firstResponder is NSText) else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if mods == .command {
            switch key {
            case "c": c.copyKeyTargets(); return true
            case "z": c.undo(); return true
            case "a": c.selectAll(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // Responder-chain versions, in case a main menu routes ⌘C / ⌘Z here.
    @objc func copy(_ sender: Any?) { controller?.copyKeyTargets() }
    @objc func undo(_ sender: Any?) { controller?.undo() }
    @objc override func selectAll(_ sender: Any?) { controller?.selectAll() }

    // MARK: - Quick Look

    /// Shows Quick Look with the keyboard, which it takes from the shelf. Margin isn't the active app: the shelf
    /// holds the keyboard because it's a non-activating panel, and Quick Look's panel must be one too. Left as
    /// it ships, it became key in Margin while the keyboard went back to the user's app, so Space and Esc
    /// landed there and it stayed open. Non-activating, it handles its own keys: Space and Esc close it, the
    /// arrows step through the shots.
    func showQuickLook(_ urls: [URL]) {
        qlURLs = urls
        quickLookClosing = false
        guard let ql = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), ql.isVisible, ql.currentController != nil {
            ql.reloadData()
        } else {
            ql.styleMask.insert(.nonactivatingPanel)
            ql.makeKeyAndOrderFront(nil)
        }
    }

    /// Set while Quick Look animates away after `closeQuickLook`: another `orderOut` then cancels the close and
    /// leaves it open (macOS 27), so it counts as closed already.
    private var quickLookClosing = false

    func closeQuickLook() {
        guard isQuickLookOpen, let ql = QLPreviewPanel.shared() else { return }
        quickLookClosing = true
        ql.orderOut(nil)
    }

    var isQuickLookOpen: Bool {
        !quickLookClosing && QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    /// Quick Look has the keyboard (it's open and was opened or clicked last).
    var isQuickLookKey: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isKeyWindow ?? false)
    }

    /// ← → while Quick Look is open but the shelf has the keys (a ⌘-click since): the previous or next shot.
    private func stepQuickLook(_ delta: Int) {
        guard let ql = QLPreviewPanel.shared(), ql.currentController != nil else { return }
        let index = ql.currentPreviewItemIndex + delta
        guard qlURLs.indices.contains(index) else { return }
        ql.currentPreviewItemIndex = index
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
            panel.currentPreviewItemIndex = 0
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
            quickLookClosing = false
            // Closed, by its own keys (Space, Esc), its close button or `releaseKeys`: the shelf is key again,
            // and the keyboard goes back to the user's app, as Esc on the shelf does.
            Task { @MainActor [weak self] in
                guard let self, !self.isQuickLookOpen else { return }
                self.controller?.releaseKeys()
            }
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { qlURLs.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { qlURLs.indices.contains(index) ? qlURLs[index] as NSURL : nil }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let url = item?.previewItemURL else { return .zero }
        return MainActor.assumeIsolated { controller?.screenFrame(forFileURL: url) ?? .zero }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        false
    }
}

/// A menu item that runs a closure.
@MainActor
final class ShelfMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    convenience init(_ title: String, _ handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.handler = handler
        target = self
    }

    @objc private func fire() { handler?() }
}
