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
    /// Not in the ShelfControlling contract: Copy Path wrote the clipboard. A copy from the shelf like `onCopied`,
    /// but of paths, not an image, so no card gets the ⌘V mark.
    var onCopiedPaths: (() -> Void)?
    /// Not in the ShelfControlling contract: the launch put leftover saves back (`recoverLeftoverSavesThenRefresh`),
    /// perhaps in the Unsaved folder.
    var onLeftoversRecovered: (() -> Void)?
    /// Not in the ShelfControlling contract: ⌘Z steps pushed out by newer ones (`ShelfUndoStep.limit`). Their cards can't
    /// come back, so a Pasteboard file of theirs may go (spec §14.2).
    var onUndoExpired: (([ShelfUndoStep]) -> Void)?
    /// Not in the ShelfControlling contract: a copy or Copy Path put these files (or their paths) on the clipboard.
    var onClipboardFiles: ((_ files: [URL], _ changeCount: Int) -> Void)?
    /// Not in the ShelfControlling contract: writes a copy to the clipboard watched for a paste (spec §14.2), returning
    /// the change count, or nil to leave the write to the shelf as always.
    var writeWatchedCopy: ((_ copied: [(id: UUID, entry: ClipboardWriter.Entry)]) -> Int?)?
    /// Not in the ShelfControlling contract: Pasteboard files the clipboard still offers, which the launch's cleanup keeps
    /// although no card holds them (spec §14.2). Set before `restore()`.
    var pasteboardFilesOnClipboard: Set<String> = []
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

    /// The live cards: the ones in view, or soon could be (`ShelfController+Cards.swift`). Items deep in the pile have none.
    var cards: [UUID: ShelfCardView] = [:]
    var selection: Set<UUID> = []
    var focusedID: UUID?
    var hoveredID: UUID?
    var undoStack: [ShelfUndoStep] = []
    /// ⌘Z one step at a time: a Trash step restores off the main thread, and the next mustn't overtake it.
    var undoSequencer = UndoSequencer()
    var dragSource: ShelfDragSource?
    /// Where click/⌘C copies and Copy Path write. `.general` except in tests.
    var pasteboard: NSPasteboard = .general
    /// On the shelf but not yet on disk (contract v2): never pruned; drag, copy and Quick Look wait for
    /// `itemDidSave`. Only cards on the shelf are in here; `detach` takes ids out.
    var pending: Set<UUID> = []
    /// Added this session with no `itemDidSave`/`itemSaveFailed` yet, on the shelf or not. When ⌘Z brings
    /// one of these back, it's pending again until its file shows up on disk.
    var awaitingSave: Set<UUID> = []
    /// A click-copy on a pending card, done when its file lands (unless another copy comes first).
    var queuedCopy: UUID?
    /// Background file checks (`refreshFiles`): one at a time, rerun once if asked meanwhile.
    var fileRefreshRunning = false
    var fileRefreshQueued = false
    /// Bumped by every copy and Copy Path; a slower read that finishes after a newer copy started doesn't write.
    var copyGeneration = 0
    /// Thumbnails decoding from their files, a few at a time.
    var thumbnailLoads = ThumbnailLoads<UUID>(limit: ShelfController.thumbnailLoadLimit)
    /// Since `restore`, until the thumbnails it asked for are in (for the timing log).
    var restoreThumbnailsClock: Stopwatch?
    /// Where the shelf's keys went, for `releaseKeys`. `keysWentElsewhere`: another app's window took them while the
    /// shelf had them (Spotlight, a launcher, a click there). `keysCameBack`: that app then handed them back to the
    /// shelf. `releasingKeys`: the shelf's next resign is `releaseKeys` giving them away.
    var keysWentElsewhere = false
    var keysCameBack = false
    var releasingKeys = false
    private(set) var isPeeking = false
    private(set) var layout = ShelfLayout.layout(heights: [], availableHeight: 0)

    private var targetDisplayID: CGDirectDisplayID?
    private var stageSize = CGSize.zero
    private var containerOffset: CGFloat = 0
    private var holdFull = 0
    private var pendingTabArrivals = 0
    /// The pile shots the fan shows, newest first.
    private(set) var fanIDs: [UUID] = []
    private var shrinkTask: Task<Void, Never>?
    private var peekTask: Task<Void, Never>?
    private var peekPoll: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    /// Shots in the air, by item.
    private var flights: [UUID: ShelfFlight] = [:]
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
        // Quick Look and the keyboard (`keyWindowChanged`). Checked once the change has settled: while one window
        // resigns key, the next isn't key yet.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.keyWindowChanged() }
            })
        }
        // Where the shelf's keys go (`releaseKeys`), also once the change has settled.
        observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.shelfResignedKey() }
        })
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.shelfBecameKey() }
        })
        let wnc = NSWorkspace.shared.notificationCenter
        observers.append(wnc.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.accessibilityChanged() }
        })
    }

    // MARK: - ShelfControlling

    func restore() {
        let clock = Stopwatch()
        pending = []
        awaitingSave = []
        queuedCopy = nil
        // shelf.json lives in Application Support (no privacy prompt); the shots themselves are checked
        // in the background, so the cards show right away from the persisted list.
        store.load()
        for card in cards.values { card.removeFromSuperview() }
        cards = [:]
        selection = []
        restoreThumbnailsClock = store.items.isEmpty ? nil : clock
        // The layout makes the cards in view (or nearly), and starts decoding their thumbnails.
        relayout(animated: false)
        updateVisibility()
        recoverLeftoverSavesThenRefresh(quietWithin: 0.5, keeping: pasteboardFilesOnClipboard)
        CaptureTimings.shared.record("shelfRestore", clock.ms)
    }

    func add(_ item: ShelfItem, thumbnail: CGImage, flyInFrom sourceRect: CGRect, displayID: CGDirectDisplayID) {
        let appearing = !panel.isVisible
        if appearing { refreshFiles() }
        let moved = targetDisplayID != displayID && screen(for: displayID) != nil
        if screen(for: displayID) != nil { targetDisplayID = displayID }

        pending.insert(item.id)
        awaitingSave.insert(item.id)
        if self.item(for: item.id) == nil { store.append(item) }
        let card = makeCard(item)
        setFreshThumbnail(thumbnail, of: item.id)

        let intoTab = isTucked && !isPeeking
        let reduce = ShelfStyle.reduceMotion
        if intoTab && !reduce { pendingTabArrivals += 1 }
        if !reduce { card.setAwaitingFlyIn(true) }
        relayout(animated: !appearing && !moved)
        showPanel()

        if reduce {
            if intoTab { tab.bump() } else { card.flashNewRing() }
            return
        }
        let id = item.id
        let target = flightTarget(for: id) ?? (screenRect(of: card), .card)
        let flight = ShelfFlight.start(image: thumbnail, from: sourceRect, to: target.rect, landing: target.landing,
                                       shelf: fullFrame) { [weak self] landing in
            self?.flightLanded(id, landing)
        }
        if let flight { flights[id] = flight }
    }

    /// A new shot's thumbnail onto its card at once, then the card's own size of it (downsampled off the main thread),
    /// unless another has replaced it meanwhile (`replaceThumbnail`).
    private func setFreshThumbnail(_ thumbnail: CGImage, of id: UUID) {
        cards[id]?.setThumbnail(thumbnail)
        Task { [weak self] in
            let small = await ShelfThumbnails.downsample(ShelfImageBox(image: thumbnail))
            guard let self, let card = cards[id], card.thumbnail === thumbnail else { return }
            card.setThumbnail(small.image)
            refreshFan(force: true)
        }
    }

    /// Not in the ShelfControlling contract: window mode's stand-in (made at the click) gives way to the window's own shot,
    /// wherever its thumbnail is: in the air (without flying in again), on the card or in the pile's fan, or in an undo
    /// step if the card was removed meanwhile. `pixelSize` is the shot's, which differs from the stand-in's when the
    /// shadow (⌥) grew with the window's focused look.
    func replaceThumbnail(of id: UUID, with thumbnail: CGImage, pixelSize: CGSize) {
        flights[id]?.replaceImage(thumbnail)
        if var current = item(for: id), current.pixelSize != pixelSize {
            current.pixelWidth = Int(pixelSize.width)
            current.pixelHeight = Int(pixelSize.height)
            store.update(current)
            cards[id]?.update(item: current)
            relayout(animated: true)
        }
        if cards[id] != nil {
            setFreshThumbnail(thumbnail, of: id)
            return
        }
        for i in undoStack.indices where undoStack[i].removals.contains(where: { $0.item.id == id }) {
            if undoStack[i].thumbnails[id] != nil { undoStack[i].thumbnails[id] = thumbnail }
            undoStack[i].removals = undoStack[i].removals.map { r in
                guard r.item.id == id else { return r }
                var item = r.item
                item.pixelWidth = Int(pixelSize.width)
                item.pixelHeight = Int(pixelSize.height)
                return ShelfStore.Removal(index: r.index, item: item)
            }
        }
    }

    // MARK: - Fly-in

    /// Where a shot in the air should land right now: the tab while tucked, the pile if its card was
    /// pushed into it, else its card's slot.
    private func flightTarget(for id: UUID) -> (rect: CGRect, landing: ShelfFlight.Landing)? {
        guard let card = cards[id] else { return nil }
        if isTucked && !isPeeking { return (screenRect(of: tab), .tab) }
        if card.isInPile, !pile.isHidden { return (screenRect(of: pile), .pile) }
        return (screenRect(of: card), .card)
    }

    /// Re-aims every shot in the air at its card's live slot (after a relayout, tuck or peek).
    private func retargetFlights() {
        guard !flights.isEmpty else { return }
        for (id, flight) in flights {
            guard let t = flightTarget(for: id) else { continue }
            if flight.landing == .tab, t.landing != .tab { pendingTabArrivals = max(0, pendingTabArrivals - 1) }
            if flight.landing != .tab, t.landing == .tab { pendingTabArrivals += 1 }
            flight.retarget(to: t.rect, landing: t.landing)
        }
        tab.count = store.items.count - pendingTabArrivals
    }

    private func flightLanded(_ id: UUID, _ landing: ShelfFlight.Landing) {
        flights[id] = nil
        let card = cards[id]
        card?.setAwaitingFlyIn(false)
        switch landing {
        case .card:
            card?.flashNewRing()
        case .tab:
            pendingTabArrivals = max(0, pendingTabArrivals - 1)
            tab.count = store.items.count - pendingTabArrivals
            tab.bump()
        case .pile:
            break
        }
    }

    /// The shots left the shelf: anything still flying fades away.
    func cancelFlights(_ ids: [UUID]) {
        for id in ids {
            guard let flight = flights.removeValue(forKey: id) else { continue }
            if flight.landing == .tab { pendingTabArrivals = max(0, pendingTabArrivals - 1) }
            flight.cancel()
        }
    }

    func toggleTucked() { setTucked(!isTucked) }

    /// The PNG is on disk. Called whether or not the item is still on the shelf.
    func itemDidSave(_ item: ShelfItem) {
        awaitingSave.remove(item.id)
        if var current = self.item(for: item.id) {
            // The coordinator normally wrote the final path and bookmark already; make sure either way.
            if current.path != item.path || (item.bookmark != nil && current.bookmark != item.bookmark) {
                current.path = item.path
                if item.bookmark != nil { current.bookmark = item.bookmark }
                store.update(current)
            }
            cards[item.id]?.update(item: current)
        } else {
            // Removed while saving: point its undo record at the real file, so ⌘Z brings back a working card.
            for i in undoStack.indices {
                undoStack[i].removals = undoStack[i].removals.map { r in
                    guard r.item.id == item.id else { return r }
                    var saved = r.item
                    saved.path = item.path
                    if item.bookmark != nil { saved.bookmark = item.bookmark }
                    return ShelfStore.Removal(index: r.index, item: saved)
                }
            }
        }
        markReady(item.id)
    }

    /// The item's file is on disk: drag, copy and the menu work, and a click-copy or a drag that was waiting
    /// for it runs.
    func markReady(_ id: UUID) {
        pending.remove(id)
        if queuedCopy == id {
            queuedCopy = nil
            if item(for: id) != nil { copy([id]) }
        }
        cards[id]?.fileDidLand()
        // A card brought back by ⌘Z before its file existed, without its thumbnail: it can decode now.
        if let card = cards[id], card.thumbnail == nil {
            thumbnailLoads.retry(id)
            loadThumbnails()
        }
    }

    /// Saving failed: the card goes (no undo) and the message shows as a toast.
    func itemSaveFailed(_ id: UUID, message: String) {
        pending.remove(id)
        awaitingSave.remove(id)
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

    /// A card for an item, below the cards of newer items (so a newer card's shadow falls on an older one).
    @discardableResult
    func makeCard(_ item: ShelfItem) -> ShelfCardView {
        let card = ShelfCardView(item: item)
        card.controller = self
        let newer = store.items.drop { $0.id != item.id }.dropFirst().lazy.compactMap { self.cards[$0.id] }.first
        container.addSubview(card, positioned: .below, relativeTo: newer ?? pile.fan)
        cards[item.id] = card
        card.setMarked(item.id == markedItemID, animated: false)
        return card
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

    /// Recomputes the layout and panel geometry, makes the cards that came forward (with `thumbnails`, an undo
    /// step's, where it has them) and moves every card. Springs when `animated`.
    func relayout(animated: Bool, thumbnails: [UUID: CGImage] = [:]) {
        let items = store.items
        let vf = screen?.visibleFrame ?? .zero
        let heights = items.map { ShelfLayout.cardHeight(forPixelSize: $0.pixelSize) }
        layout = ShelfLayout.layout(heights: heights, availableHeight: vf.height - ShelfStyle.headroom)
        makeLiveCards(thumbnails: thumbnails)
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
        retargetFlights()
        dropHiddenCards()
        NSAccessibility.post(element: panel, notification: .layoutChanged)
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

    /// Whether ⌘⇧1 would do anything: there's nothing to tuck on an empty shelf (for the menu bar item).
    var canToggleTucked: Bool { isTucked || !store.items.isEmpty }

    /// ⌘⇧1. Tucking an empty shelf does nothing (later shots would otherwise fly into a bare tab).
    /// Without `animated`, the shelf snaps back into place (the tab still fades).
    func setTucked(_ on: Bool, animated: Bool = true) {
        guard on != isTucked, !(on && store.items.isEmpty) else { return }
        isTucked = on
        isPeeking = false
        peekTask?.cancel()
        peekPoll?.cancel()
        if on {
            // Out of sight, out of the way: a rename keeps what was typed, and the keys go back to the user's app.
            for card in cards.values where card.isRenaming { card.endRename(commit: true) }
            releaseKeys()
            holdPanelFull(for: 0.45)
            for card in cards.values { card.setHovered(false) }
            pile.fan.setFanned(false, animated: true)
            setContainerOffset(stageSize.width, animated: true, spring: false)
            showTab(animated: true)
            if !store.items.isEmpty { showToast(tuckedToastText, isError: false) }
        } else {
            refreshFiles()
            applyGeometry(deferShrink: false)
            setContainerOffset(0, animated: animated, spring: true)
            hideTab(animated: true)
            if !store.items.isEmpty { showPanel() }
        }
        retargetFlights()
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
            refreshFiles()
            applyGeometry(deferShrink: false)
            setContainerOffset(-ShelfStyle.leftPad, animated: true, spring: true)
            startPeekPoll()
        } else {
            peekPoll?.cancel()
            releaseKeys()   // the peek poll waits while a rename is open
            for card in cards.values { card.setHovered(false) }
            pile.fan.setFanned(false, animated: true)
            holdPanelFull(for: 0.4)
            setContainerOffset(stageSize.width, animated: true, spring: false)
        }
        retargetFlights()
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

    /// "Copied", "Path copied", "Restored" and errors. Inside the shelf, above the top card, 1.2 s unless the
    /// message needs longer (up to three lines).
    func showToast(_ text: String, isError: Bool, duration: TimeInterval = ShelfToastView.defaultDuration) {
        toast.show(text, isError: isError, anchorRight: 0, bottom: 0, maxWidth: stageWidth - 12, duration: duration)
        announce(text)
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
        // A long (wrapped) toast stays inside the stage, rather than lose its top lines off the panel, or its left
        // edge: beside the tab, or while peeking, there's less room left of the anchor than a toast's full width.
        // Shifted right, it's still above the tab and the cards.
        f.origin = CGPoint(x: max(4, anchorRight - f.width), y: max(0, min(bottom, stageSize.height - f.height - 4)))
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
