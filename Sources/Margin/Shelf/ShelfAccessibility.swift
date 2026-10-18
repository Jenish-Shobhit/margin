import AppKit
import MarginKit

/// VoiceOver and other assistive apps. The shelf's views are layer-drawn, so each says what it is here.
///
/// The panel's children are the Close Shelf button, the visible pile, cards and tab, top to bottom
/// (`ShelfController.accessibilityElements`).
/// Each card is a button: pressing it copies (as a click does), its actions menu has the rest, and its ✕ and •••
/// are buttons inside it. Toasts are spoken as announcements. Nothing here makes the panel key: an action takes
/// the keys only where its mouse twin does (✕, Rename, Move to Trash, Quick Look), so the focus rules hold.
extension ShelfController {
    /// What an assistive app sees in the panel, in reading order. While tucked (not peeking) only the tab is on
    /// screen.
    var accessibilityElements: [Any] {
        if isTucked && !isPeeking { return tab.isHidden ? [] : [tab] }
        var elements: [Any] = []
        // There whether or not the pointer is over the shelf, which is when it shows.
        if !store.items.isEmpty { elements.append(closeButton) }
        if !pile.isHidden { elements.append(pile) }
        // The oldest visible card is at the top.
        for item in store.items {
            if let card = cards[item.id], card.isAccessibilityElement() { elements.append(card) }
        }
        if !tab.isHidden { elements.append(tab) }
        return elements
    }

    /// "Screenshot, 14:32, 3024 × 1964" ("Screen recording, 14:32, 0:12, 2940 × 1912"), then its state: selected, copied
    /// (the ⌘V mark), saving.
    func accessibilityLabel(for card: ShelfCardView) -> String {
        let item = card.item
        var parts = [item.kind == .recording ? "Screen recording" : "Screenshot",
                     ShelfStyle.metaFormatter.string(from: item.createdAt)]
        if item.kind == .recording { parts.append(RecordingFormat.cardDurationText(item.duration ?? 0)) }
        parts.append("\(item.pixelWidth) × \(item.pixelHeight)")
        if card.isSelected { parts.append("selected") }
        if card.isMarked { parts.append("copied, ready to paste") }
        if pending.contains(card.id) { parts.append("saving") }
        return parts.joined(separator: ", ")
    }

    /// The card's actions menu: the click, the double-click, Space, and the ••• menu and ✕. A shot still being
    /// saved offers only what works without its file.
    func accessibilityActions(for card: ShelfCardView) -> [NSAccessibilityCustomAction] {
        let id = card.id
        func action(_ name: String, _ body: @escaping (ShelfController) -> Void) -> NSAccessibilityCustomAction {
            NSAccessibilityCustomAction(name: name) { [weak self] in
                guard let self, self.cards[id] != nil else { return false }
                body(self)
                return true
            }
        }
        let copy = action("Copy") { $0.click(id) }
        let remove = action("Remove from shelf") { $0.removeFromShelf(id) }
        if pending.contains(id) { return [copy, remove] }
        return [
            copy,
            action("Open") { $0.open(id) },
            action("Quick Look") { c in
                c.focusShelf()   // its Space and Esc are shelf keys
                c.quickLook([id])
            },
            action("Show in Finder") { $0.reveal([id]) },
            action("Copy Path") { c in
                c.copyPaths([id])
                c.releaseKeys()
            },
            action("Rename") { $0.beginRename(id) },
            remove,
            action("Move to Trash") { c in
                c.focusShelf()   // so ⌘Z brings it back
                c.trash([id])
            },
        ]
    }

    /// ✕: the card leaves, and the shelf takes the keys so ⌘Z brings it back.
    func removeFromShelf(_ id: UUID) {
        focusShelf()
        dismiss([id], exit: .collapse)
    }

    /// A toast, spoken. Toasts never take focus, so VoiceOver would otherwise miss them.
    func announce(_ text: String) {
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}

extension ShelfCardView {
    override func isAccessibilityElement() -> Bool { !isInPile && !isHidden && !isLeaving }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { controller?.accessibilityLabel(for: self) }
    /// The file's name: the label has the time and size, as the card shows.
    override func accessibilityHelp() -> String? { item.url.lastPathComponent }
    override func isAccessibilitySelected() -> Bool { isSelected }

    /// A click: copy, keyboard left where it is.
    override func accessibilityPerformPress() -> Bool {
        controller?.click(id)
        return true
    }

    /// The ••• menu. Popped up after the action returns: a menu tracks modally, and the assistive app is
    /// waiting for an answer.
    override func accessibilityPerformShowMenu() -> Bool {
        Task { @MainActor [weak self] in self?.showOptionsMenu() }
        return true
    }

    func showOptionsMenu() {
        guard let menu = controller?.menu(for: self) else { return }
        menu.popUp(positioning: nil, at: moreMenuAnchor, in: self)
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        controller?.accessibilityActions(for: self)
    }

    /// ✕ and •••, plus the rename field while it's open.
    override func accessibilityChildren() -> [Any]? {
        guard isAccessibilityElement() else { return [] }
        return (super.accessibilityChildren() ?? []) + accessibilityParts
    }

    /// Over ✕ or •••, that button. (Assistive apps call in on the main thread.)
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        nonisolated(unsafe) var part: ShelfCardPart?
        MainActor.assumeIsolated {
            guard let window, isAccessibilityElement() else { return }
            let p = convert(window.convertPoint(fromScreen: point), from: nil)
            part = accessibilityParts.first { hitRect(of: $0.kind).contains(p) }
        }
        return part ?? super.accessibilityHitTest(point)
    }

    /// Where ✕ or ••• is pressed, in the card's coordinates.
    func hitRect(of part: ShelfCardPart.Kind) -> CGRect {
        part == .close ? closeHitRect : moreHitRect
    }

    /// ✕ removes the card (and the shelf takes the keys, as a click on it does); ••• opens the menu.
    func press(_ part: ShelfCardPart.Kind) -> Bool {
        guard let controller else { return false }
        switch part {
        case .close: controller.removeFromShelf(id)
        case .options: Task { @MainActor [weak self] in self?.showOptionsMenu() }
        }
        return true
    }
}

/// ✕ or ••• on a card: drawn in the card's layers, so not views of their own. Assistive apps see them as
/// buttons whether or not the pointer is over the card (which is when they show). They call in on the main
/// thread, through `NSAccessibilityElement`'s nonisolated methods.
final class ShelfCardPart: NSAccessibilityElement {
    enum Kind: CaseIterable, Sendable { case close, options }
    let kind: Kind
    private weak var card: ShelfCardView?

    init(card: ShelfCardView, kind: Kind) {
        self.card = card
        self.kind = kind
        super.init()
    }

    override func accessibilityParent() -> Any? { card }
    override func accessibilityRole() -> NSAccessibility.Role? { kind == .close ? .button : .menuButton }
    override func accessibilityLabel() -> String? { kind == .close ? "Remove from shelf" : "Options" }
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityFrame() -> NSRect {
        guard let card else { return .zero }
        let kind = kind
        return MainActor.assumeIsolated {
            guard let window = card.window else { return .zero }
            return window.convertToScreen(card.convert(card.hitRect(of: kind), to: nil))
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let card else { return false }
        let kind = kind
        return MainActor.assumeIsolated { card.press(kind) }
    }
}

extension ShelfPileView {
    override func isAccessibilityElement() -> Bool { !isHidden }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "\(count) older screenshot\(count == 1 ? "" : "s")" }
    override func accessibilityHelp() -> String? { "Drag to send them all" }
    override func accessibilityChildren() -> [Any]? { [] }

    /// A click on the pile: the shelf takes the keys (⌘Z, ⌘A, Esc).
    override func accessibilityPerformPress() -> Bool {
        controller?.focusShelf()
        return true
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: "Close shelf") { [weak self] in
            guard let self, let controller = self.controller else { return false }
            controller.close()
            return true
        }]
    }
}

extension ShelfCloseButton {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Close shelf" }
    override func accessibilityHelp() -> String? { "Takes every card off the shelf. The files stay in their folder." }
    override func accessibilityChildren() -> [Any]? { [] }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

extension ShelfTabView {
    override func isAccessibilityElement() -> Bool { !isHidden }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? {
        "Show shelf, \(count) screenshot\(count == 1 ? "" : "s")"
    }
    override func accessibilityChildren() -> [Any]? { [] }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
