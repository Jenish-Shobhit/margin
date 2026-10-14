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

    func showQuickLook(_ urls: [URL]) {
        qlURLs = urls
        guard let ql = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), ql.isVisible, ql.currentController != nil {
            ql.reloadData()
        } else {
            ql.makeKeyAndOrderFront(nil)
        }
    }

    func closeQuickLook() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let ql = QLPreviewPanel.shared(), ql.isVisible else { return }
        ql.orderOut(nil)
    }

    var isQuickLookOpen: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
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
