import AppKit
import MarginKit

/// The shelf: a stack of thumbnails on the right edge of the display of the latest capture.
/// Spec §4 and §5. Interactions live in `ShelfController+Actions.swift`.
///
/// View tree: panel → root → stage (the full shelf, fixed size) → container (cards + pile; slides
/// off the edge when tucked) plus the tab and the toast. While tucked, the panel shrinks to just
/// the tab and the stage is offset so nothing on screen moves.
@MainActor
final class ShelfController: ShelfControlling {
    // MARK: Contract
    var onCopied: ((UUID, Int) -> Void)?
    var onRemoved: (([UUID]) -> Void)?
    private(set) var isTucked = false
    var markedItemID: UUID?
    var itemIDs: [UUID] { store.items.map(\.id) }

    // MARK: State
    let store: ShelfStore
    let panel = ShelfPanel()
    let root = ShelfRootView()
    let stage = NSView()
    let container = NSView()
    let pile = ShelfPileView()
    let toast = ShelfToastView()
    let tab = ShelfTabView()

    var cards: [UUID: ShelfCardView] = [:]
    var selection: Set<UUID> = []
    var focusedID: UUID?
    var hoveredID: UUID?
    var undoStack: [ShelfUndoStep] = []
    var dragSource: ShelfDragSource?
    /// Added but not yet on disk (contract v2): never pruned; drag, copy and Quick Look wait for `itemDidSave`.
    var pending: Set<UUID> = []
    /// A click-copy on a pending card, done when its file lands.
    var queuedCopy: UUID?
    private(set) var isPeeking = false
    private(set) var layout = ShelfLayout.layout(heights: [], availableHeight: 0)

    private var targetDisplayID: CGDirectDisplayID?
    private var stageSize = CGSize.zero
    private var containerOffset: CGFloat = 0
    private var holdFull = 0
    private var pendingTabArrivals = 0
    private var fanIDs: [UUID] = []
    private var shrinkTask: Task<Void, Never>?
    private var peekTask: Task<Void, Never>?
    private var peekPoll: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    /// After the user empties the shelf, the (invisible) panel stays a moment so ⌘Z can still reach it.
    var lingerUntil = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    init(store: ShelfStore) {
        self.store = store
        build()
        observe()
    }

    private func build() {
        root.controller = self
        root.autoresizingMask = [.width, .height]
        panel.contentView = root
        stage.wantsLayer = true
        stage.layer?.masksToBounds = false
        root.addSubview(stage)
        container.wantsLayer = true
        container.layer?.masksToBounds = false
        stage.addSubview(container)
        pile.controller = self
        pile.isHidden = true
        container.addSubview(pile.fan)
        container.addSubview(pile)
        tab.isHidden = true
        tab.onHover = { [weak self] in self?.tabHover($0) }
        tab.onClick = { [weak self] in self?.tabClicked() }
        stage.addSubview(tab)
        toast.onHidden = { [weak self] in self?.toastDidHide() }
        stage.addSubview(toast)
    }

    private func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        let wnc = NSWorkspace.shared.notificationCenter
        observers.append(wnc.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.accessibilityChanged() }
        })
    }

    // MARK: - ShelfControlling

    func restore() {
        pending = []
        queuedCopy = nil
        store.load()
        store.pruneMissing()
        for card in cards.values { card.removeFromSuperview() }
        cards = [:]
        selection = []
        for item in store.items {
            makeCard(item)
            loadThumbnail(for: item)
        }
        relayout(animated: false)
        updateVisibility()
    }

    func add(_ item: ShelfItem, thumbnail: CGImage, flyInFrom sourceRect: CGRect, displayID: CGDirectDisplayID) {
        let appearing = !panel.isVisible
        if appearing { pruneMissing() }
        let moved = targetDisplayID != displayID && screen(for: displayID) != nil
        if screen(for: displayID) != nil { targetDisplayID = displayID }

        pending.insert(item.id)
        if self.item(for: item.id) == nil { store.append(item) }
        let card = makeCard(item)
        card.setThumbnail(thumbnail)
        Task { [weak self] in
            let small = await ShelfThumbnails.downsample(ShelfImageBox(image: thumbnail))
            self?.cards[item.id]?.setThumbnail(small.image)
            self?.refreshFan(force: true)
        }

        let intoTab = isTucked && !isPeeking
        let reduce = ShelfStyle.reduceMotion
        if intoTab && !reduce { pendingTabArrivals += 1 }
        relayout(animated: !appearing && !moved)
        showPanel()

        if reduce {
            if intoTab { tab.bump() } else { card.flashNewRing() }
            return
        }
        if intoTab {
            ShelfFlyIn.run(image: thumbnail, from: sourceRect, to: screenRect(of: tab), intoTab: true) { [weak self] in
                guard let self else { return }
                self.pendingTabArrivals = max(0, self.pendingTabArrivals - 1)
                self.tab.count = self.store.items.count - self.pendingTabArrivals
                self.tab.bump()
            }
        } else {
            card.setAwaitingFlyIn(true)
            ShelfFlyIn.run(image: thumbnail, from: sourceRect, to: screenRect(of: card), intoTab: false) { [weak card] in
                card?.setAwaitingFlyIn(false)
                card?.flashNewRing()
            }
        }
    }

    func toggleTucked() { setTucked(!isTucked) }

    /// The PNG is on disk. The coordinator already wrote the final path and bookmark to the store.
    func itemDidSave(_ item: ShelfItem) {
        pending.remove(item.id)
        if let current = self.item(for: item.id) {
            cards[item.id]?.update(item: current)
        } else {
            // Dismissed while saving: point its undo record at the real file.
            for i in undoStack.indices {
                undoStack[i].removals = undoStack[i].removals.map {
                    $0.item.id == item.id ? ShelfStore.Removal(index: $0.index, item: item) : $0
                }
            }
        }
        if queuedCopy == item.id {
            queuedCopy = nil
            copy([item.id])
        }
    }

    /// Saving failed: the card goes (no undo) and the message shows as a toast.
    func itemSaveFailed(_ id: UUID, message: String) {
        pending.remove(id)
        if queuedCopy == id { queuedCopy = nil }
        for i in undoStack.indices { undoStack[i].removals.removeAll { $0.item.id == id } }
        undoStack.removeAll { $0.removals.isEmpty }
        if item(for: id) != nil {
            store.remove(ids: [id])
            detach([id], exit: .collapse)
        }
        showToast(message, isError: true)
    }

    /// Contract v2: a short message inside the shelf.
    func showToast(_ text: String) { showToast(text, isError: false) }

    func setClipboardMark(_ itemID: UUID?) {
        let id = itemID.flatMap { id in store.items.contains { $0.id == id } ? id : nil }
        markedItemID = id
        for (cid, card) in cards { card.setMarked(cid == id, animated: true) }
    }

    // MARK: - Cards

    @discardableResult
    func makeCard(_ item: ShelfItem) -> ShelfCardView {
        let card = ShelfCardView(item: item)
        card.controller = self
        container.addSubview(card, positioned: .below, relativeTo: pile.fan)
        cards[item.id] = card
        card.setMarked(item.id == markedItemID, animated: false)
        return card
    }

    func loadThumbnail(for item: ShelfItem) {
        Task { [weak self] in
            guard let box = await ShelfThumbnails.load(url: item.url, pixelSize: item.pixelSize) else { return }
            self?.cards[item.id]?.setThumbnail(box.image)
            self?.refreshFan(force: true)
        }
    }

    func item(for id: UUID) -> ShelfItem? { store.items.first { $0.id == id } }

    /// `ids` in shelf order (oldest → newest), dropping unknown ones.
    func ordered(_ ids: some Sequence<UUID>) -> [UUID] {
        let set = Set(ids)
        return store.items.map(\.id).filter { set.contains($0) }
    }

    // MARK: - Geometry

    private func screen(for id: CGDirectDisplayID?) -> NSScreen? {
        guard let id else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    /// The display of the latest capture, else the main (menu bar) display.
    private var screen: NSScreen? { screen(for: targetDisplayID) ?? NSScreen.screens.first }

    private var stageWidth: CGFloat { ShelfLayout.panelWidth + ShelfStyle.leftPad }

    private var tabRectInStage: CGRect {
        CGRect(x: stageSize.width - ShelfStyle.tabWidth, y: ShelfStyle.tabBottom, width: ShelfStyle.tabWidth, height: ShelfStyle.tabHeight)
    }

    /// Where the whole shelf sits on screen (bottom-right of the visible frame).
    private var fullFrame: CGRect {
        guard let vf = screen?.visibleFrame else { return .zero }
        return CGRect(x: vf.maxX - stageSize.width, y: vf.minY, width: stageSize.width, height: stageSize.height)
    }

    /// Recomputes the layout and panel geometry, and moves every card. Springs when `animated`.
    func relayout(animated: Bool) {
        let items = store.items
        let vf = screen?.visibleFrame ?? .zero
        let heights = items.map { ShelfLayout.cardHeight(forPixelSize: $0.pixelSize) }
        layout = ShelfLayout.layout(heights: heights, availableHeight: vf.height - ShelfStyle.headroom)
        let minH = ShelfStyle.tabBottom + ShelfStyle.tabHeight + 46
        stageSize = CGSize(width: stageWidth, height: min(max(layout.contentHeight + ShelfStyle.headroom, minH), max(vf.height, minH)))
        applyGeometry(deferShrink: animated)

        let pileFrame = layout.pileFrame?.offsetBy(dx: ShelfStyle.leftPad, dy: 0)
        for (i, item) in items.enumerated() {
            guard let card = cards[item.id] else { continue }
            let h = heights[i]
            if let f = layout.cardFrames[i] {
                if card.isInPile { card.setInPile(false, animated: animated) }
                card.setSlot(f.offsetBy(dx: ShelfStyle.leftPad, dy: 0), animated: animated)
            } else if let pf = pileFrame {
                let park = CGRect(x: pf.minX, y: pf.midY - h / 2, width: ShelfLayout.cardWidth, height: h)
                let fresh = !card.isPlaced
                card.setSlot(park, animated: animated && !card.isInPile)
                card.setInPile(true, animated: animated && !fresh)
            }
        }
        updatePile(pileFrame, animated: animated)
        tab.count = items.count - pendingTabArrivals
        positionToast(animated: animated)
        updateVisibility()
    }

    /// Sizes the panel: the full stage, or just the tab while tucked and idle.
    /// With `deferShrink`, a shrinking panel waits until the cards have settled.
    func applyGeometry(deferShrink: Bool) {
        let full = fullFrame
        guard full.width > 0 else { return }
        let compact = isTucked && !isPeeking && toast.isHidden && holdFull == 0
        let target = compact ? tabRectInStage.offsetBy(dx: full.minX, dy: full.minY) : full
        var frame = target
        let current = panel.frame
        if deferShrink, !compact, panel.isVisible, current.minX == target.minX, current.minY == target.minY,
           current.width == target.width, current.height > target.height {
            frame = current
            shrinkTask?.cancel()
            shrinkTask = ShelfMotion.after(0.7) { [weak self] in self?.applyGeometry(deferShrink: false) }
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        stage.frame = CGRect(origin: CGPoint(x: full.minX - frame.minX, y: full.minY - frame.minY), size: full.size)
        container.frame = CGRect(x: containerOffset, y: 0, width: full.width, height: full.height)
        tab.frame = tabRectInStage
    }

    private func screensChanged() {
        if screen(for: targetDisplayID) == nil { targetDisplayID = nil }
        relayout(animated: false)
        positionToast()
    }

    private func accessibilityChanged() {
        pile.rebuildMaterial()
        tab.rebuildMaterial()
        toast.rebuildMaterial()
    }

    func screenRect(of view: NSView) -> CGRect {
        guard let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    // MARK: - Pile

    private func updatePile(_ frame: CGRect?, animated: Bool) {
        if let frame, layout.pileCount > 0 {
            let wasHidden = pile.isHidden
            pile.setCount(layout.pileCount)
            pile.setSlot(frame, animated: animated && !wasHidden)
            if wasHidden {
                pile.isHidden = false
                pile.fan.isHidden = false
                if animated, let l = pile.layer { l.add(ShelfMotion.basic("opacity", from: 0, to: 1, duration: 0.3), forKey: "in") }
            }
        } else if !pile.isHidden {
            pile.fan.setFanned(false, animated: false)
            pile.isHidden = true
            pile.fan.isHidden = true
        }
        refreshFan(force: false)
    }

    /// The fan shows the newest few pile shots.
    func refreshFan(force: Bool) {
        let ids = Array(store.items.prefix(layout.pileCount).map(\.id).reversed().prefix(3))
        guard force || ids != fanIDs else { return }
        fanIDs = ids
        pile.fan.setImages(ids.compactMap { cards[$0]?.thumbnail })
    }

    func pileHover(_ inside: Bool) {
        pile.fan.setFanned(inside && dragSource == nil, animated: true)
    }

    // MARK: - Visibility

    func showPanel() {
        hideTask?.cancel()
        guard !panel.isVisible else { return }
        applyGeometry(deferShrink: false)
        panel.orderFrontRegardless()
    }

    /// Hidden when empty (after any exit animation), unless a toast is up.
    func updateVisibility() {
        if store.items.isEmpty {
            guard panel.isVisible, toast.isHidden else { return }
            hideTask?.cancel()
            let delay = max(0.45, lingerUntil.timeIntervalSinceNow)
            hideTask = ShelfMotion.after(delay) { [weak self] in
                guard let self, self.store.items.isEmpty, self.toast.isHidden else { return }
                self.panel.orderOut(nil)
            }
        } else {
            showPanel()
        }
    }

    // MARK: - Tuck, tab, peek

    func setTucked(_ on: Bool) {
        guard on != isTucked else { return }
        isTucked = on
        isPeeking = false
        peekTask?.cancel()
        peekPoll?.cancel()
        if on {
            holdPanelFull(for: 0.45)
            for card in cards.values { card.setHovered(false) }
            pile.fan.setFanned(false, animated: true)
            setContainerOffset(stageSize.width, animated: true, spring: false)
            showTab(animated: true)
            if !store.items.isEmpty { showToast(tuckedToastText, isError: false) }
        } else {
            pruneMissing()
            applyGeometry(deferShrink: false)
            setContainerOffset(0, animated: true, spring: true)
            hideTab(animated: true)
            if !store.items.isEmpty { showPanel() }
        }
    }

    private var tuckedToastText: String {
        "Shelf tucked · \(Preferences.shared.shortcut(for: .toggleShelf).displayString)"
    }

    private func holdPanelFull(for seconds: Double) {
        holdFull += 1
        applyGeometry(deferShrink: false)
        ShelfMotion.after(seconds) { [weak self] in
            guard let self else { return }
            self.holdFull -= 1
            self.applyGeometry(deferShrink: false)
        }
    }

    private func setContainerOffset(_ x: CGFloat, animated: Bool, spring: Bool) {
        let old = containerOffset
        containerOffset = x
        container.frame.origin.x = x
        guard animated, old != x, !ShelfStyle.reduceMotion, let layer = container.layer else { return }
        if spring {
            ShelfMotion.slide(layer, from: CGPoint(x: old - x, y: 0), duration: 0.45, bounce: 0.12)
        } else {
            let a = ShelfMotion.basic("position", from: NSValue(point: CGPoint(x: old - x, y: 0)), to: NSValue(point: .zero), duration: 0.32, curve: .easeIn)
            a.isAdditive = true
            layer.add(a, forKey: nil)
        }
    }

    private func showTab(animated: Bool) {
        tab.isHidden = false
        tab.alphaValue = 1
        guard animated, !ShelfStyle.reduceMotion, let l = tab.layer else { return }
        let a = ShelfMotion.spring("position", from: NSValue(point: CGPoint(x: ShelfStyle.tabWidth + 12, y: 0)), to: NSValue(point: .zero), duration: 0.4, bounce: 0.15)
        a.isAdditive = true
        a.beginTime = CACurrentMediaTime() + 0.15
        a.fillMode = .backwards
        l.add(a, forKey: "slide")
    }

    private func hideTab(animated: Bool) {
        guard !tab.isHidden else { return }
        guard animated, !ShelfStyle.reduceMotion else { tab.isHidden = true; return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            tab.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isTucked else { return }
                self.tab.isHidden = true
                self.tab.alphaValue = 1
            }
        })
    }

    private func tabHover(_ inside: Bool) {
        guard isTucked else { return }
        peekTask?.cancel()
        if inside, !isPeeking {
            peekTask = ShelfMotion.after(0.12) { [weak self] in self?.setPeeking(true) }
        }
    }

    private func tabClicked() {
        guard isTucked else { return }
        setTucked(false)
    }

    /// Hovering the tab slides the shelf in beside it; leaving the shelf slides it back.
    func setPeeking(_ on: Bool) {
        guard isTucked, on != isPeeking, !store.items.isEmpty else { return }
        isPeeking = on
        if on {
            pruneMissing()
            applyGeometry(deferShrink: false)
            setContainerOffset(-ShelfStyle.leftPad, animated: true, spring: true)
            startPeekPoll()
        } else {
            peekPoll?.cancel()
            for card in cards.values { card.setHovered(false) }
            pile.fan.setFanned(false, animated: true)
            holdPanelFull(for: 0.4)
            setContainerOffset(stageSize.width, animated: true, spring: false)
        }
    }

    /// While peeking, tuck back once the pointer has been outside the shelf for ~0.3 s.
    private func startPeekPoll() {
        peekPoll?.cancel()
        peekPoll = Task { [weak self] in
            var outside = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, self.isPeeking else { return }
                if self.dragSource != nil || self.cards.values.contains(where: { $0.isRenaming }) { outside = 0; continue }
                let inside = self.panel.frame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation)
                outside = inside ? 0 : outside + 1
                if outside >= 2 { self.setPeeking(false); return }
            }
        }
    }

    // MARK: - Toasts

    /// "Copied", "Path copied", "Restored" and errors. Inside the shelf, above the top card, 1.2 s.
    func showToast(_ text: String, isError: Bool) {
        toast.show(text, isError: isError, anchorRight: 0, bottom: 0, maxWidth: stageWidth - 12)
        positionToast()
        if !panel.isVisible { showPanel() }
        applyGeometry(deferShrink: false)
    }

    /// Keeps the toast just above the top card (or beside the tab while tucked).
    private func positionToast(animated: Bool = false) {
        guard !toast.isHidden else { return }
        let anchorRight: CGFloat, bottom: CGFloat
        if isTucked && !isPeeking {
            anchorRight = stageSize.width - ShelfStyle.tabWidth - 8
            bottom = ShelfStyle.tabBottom + ShelfStyle.tabHeight + 10
        } else {
            anchorRight = containerOffset + ShelfStyle.leftPad + ShelfLayout.edgeInset + ShelfLayout.cardWidth
            let top = store.items.isEmpty ? ShelfLayout.edgeInset : layout.contentHeight - ShelfLayout.edgeInset
            bottom = top + (layout.pileCount > 0 ? 14 : 10)
        }
        var f = toast.frame
        let old = f.origin
        f.origin = CGPoint(x: anchorRight - f.width, y: bottom)
        toast.frame = f
        if animated, let layer = toast.layer {
            ShelfMotion.slide(layer, from: CGPoint(x: old.x - f.minX, y: old.y - f.minY))
        }
    }

    private func toastDidHide() {
        applyGeometry(deferShrink: false)
        updateVisibility()
    }
}
