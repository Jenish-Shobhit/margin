import AppKit
import MarginKit

/// One ⌘Z step: what left the shelf, and how to bring it back.
struct ShelfUndoStep {
    enum Kind { case dragOut, dismiss, clear, trash }
    struct Trashed {
        let original: URL
        let trashed: URL
    }

    let kind: Kind
    var removals: [ShelfStore.Removal]
    var trashed: [UUID: Trashed] = [:]
    var thumbnails: [UUID: CGImage] = [:]

    static let limit = 20
    /// Only the newest few steps keep their thumbnails in memory; older ones reload from disk.
    static let thumbnailSteps = 5
}

/// Spec §5: every shelf interaction.
extension ShelfController {
    // MARK: - Focus and selection

    /// Makes the panel key without activating Margin, so the shelf keys work until the user clicks elsewhere.
    func focusShelf() {
        if !panel.isKeyWindow { panel.makeKey() }
        if !(panel.firstResponder is NSTextView) { panel.makeFirstResponder(root) }
    }

    func cardHover(_ card: ShelfCardView, inside: Bool) {
        if inside {
            guard dragSource == nil else { return }
            hoveredID = card.id
            card.setHovered(true)
        } else {
            if hoveredID == card.id { hoveredID = nil }
            card.setHovered(false)
        }
    }

    func toggleSelection(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        cards[id]?.setSelected(selection.contains(id))
        focusedID = id
    }

    func clearSelection() {
        for id in selection { cards[id]?.setSelected(false) }
        selection = []
    }

    /// ⌘A: every card that isn't folded into the pile.
    func selectAll() {
        for (id, card) in cards where !card.isInPile {
            selection.insert(id)
            card.setSelected(true)
        }
    }

    func escape() {
        if root.isQuickLookOpen { root.closeQuickLook(); return }
        if cards.values.contains(where: { $0.isRenaming }) { return }
        clearSelection()
    }

    /// What the keys act on: the selection, else the hovered card, else the last clicked card.
    var keyTargets: [UUID] {
        if !selection.isEmpty { return ordered(selection) }
        if let hoveredID, cards[hoveredID] != nil { return [hoveredID] }
        if let focusedID, cards[focusedID] != nil { return [focusedID] }
        return []
    }

    // MARK: - Click, copy, open

    /// Click: copy that shot (same clipboard write as a capture), move the ⌘V mark, toast "Copied".
    /// Focus and selection change at once; the copy waits out the double-click interval, so a double-click
    /// (open) never touches the clipboard.
    func click(_ id: UUID) {
        focusedID = id
        clearSelection()
        clickCopyTask?.cancel()
        clickCopyTask = ShelfMotion.after(NSEvent.doubleClickInterval) { [weak self] in
            guard let self else { return }
            self.clickCopyTask = nil
            guard self.item(for: id) != nil else { return }
            if self.pending.contains(id) {
                self.queuedCopy = id   // copied as soon as the file lands
            } else {
                self.copy([id])
            }
        }
    }

    /// A second click arrived: it's a double-click, so the first click's copy is off.
    func cancelClickCopy() {
        clickCopyTask?.cancel()
        clickCopyTask = nil
    }

    func copyKeyTargets() {
        let ids = keyTargets
        guard !ids.isEmpty else { NSSound.beep(); return }
        copy(ids)
    }

    /// Reads the files off the main thread, then puts the same bytes on the clipboard.
    func copy(_ ids: [UUID]) {
        let ids = ordered(ids)
        let ready = ids.filter { !pending.contains($0) }
        if ready.isEmpty, let last = ids.last {
            queuedCopy = last
            return
        }
        let items = ready.compactMap { item(for: $0) }
        guard !items.isEmpty else { return }
        copyGeneration += 1
        let generation = copyGeneration
        Task { [weak self] in
            let results = await ShelfFiles.check(items) { ShelfFiles.pngData(at: $0) }
            guard let self, generation == self.copyGeneration else { return }
            let live = self.apply(results)
            let copied = live.compactMap { r in r.value.map { (id: r.item.id, png: $0) } }
            guard let markID = copied.last?.id else {
                if results.contains(where: { $0.status.isGone }) {
                    self.showToast("File not found", isError: true)
                } else if !live.isEmpty {
                    self.showToast("Couldn't read the file", isError: true)
                }
                return
            }
            let changeCount = ClipboardWriter.write(pngs: copied.map(\.png), to: self.pasteboard)
            self.setClipboardMark(markID)
            self.showToast("Copied")
            self.onCopied?(markID, changeCount)
        }
    }

    func open(_ id: UUID) {
        cancelClickCopy()
        guard !pending.contains(id), let item = item(for: id) else { return }
        Task { [weak self] in
            let results = await ShelfFiles.check([item]) { $0 }
            guard let self else { return }
            if let url = self.apply(results).first?.value {
                NSWorkspace.shared.open(url)
            } else if results.first?.status.isGone == true {
                self.showToast("File not found", isError: true)
            }
        }
    }

    func toggleQuickLook() {
        if root.isQuickLookOpen { root.closeQuickLook(); return }
        let items = keyTargets.filter { !pending.contains($0) }.compactMap { item(for: $0) }
        guard !items.isEmpty else { NSSound.beep(); return }
        Task { [weak self] in
            let results = await ShelfFiles.check(items) { $0 }
            guard let self else { return }
            let urls = self.apply(results).compactMap(\.value)
            guard !urls.isEmpty else {
                self.showToast("File not found", isError: true)
                return
            }
            self.root.showQuickLook(urls)
        }
    }

    /// For Quick Look's zoom: the card showing this file, in screen points.
    func screenFrame(forFileURL url: URL) -> CGRect {
        guard let item = store.items.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }),
              let card = cards[item.id], !card.isInPile, !card.isHidden, !isTucked || isPeeking else { return .zero }
        return screenRect(of: card)
    }

    // MARK: - Menu (••• and right-click)

    func menu(for card: ShelfCardView) -> NSMenu {
        let id = card.id
        let ids = selection.contains(id) && selection.count > 1 ? ordered(selection) : [id]
        let menu = NSMenu()
        menu.autoenablesItems = false
        // Until the file is on disk there's nothing to act on.
        let saving = ids.contains { pending.contains($0) }
        // Choosing an item counts as a click on the shelf (spec §5), so ⌘Z works right after Move to Trash.
        menu.addItem(ShelfMenuItem(ids.count > 1 ? "Copy Paths" : "Copy Path") { [weak self] in self?.focusShelf(); self?.copyPaths(ids) })
        menu.addItem(ShelfMenuItem("Reveal in Finder") { [weak self] in self?.reveal(ids) })
        let rename = ShelfMenuItem("Rename…") { [weak self] in self?.beginRename(id) }
        rename.isEnabled = ids.count == 1
        menu.addItem(rename)
        menu.addItem(.separator())
        menu.addItem(ShelfMenuItem("Move to Trash") { [weak self] in self?.focusShelf(); self?.trash(ids) })
        if saving { menu.items.forEach { $0.isEnabled = false } }
        return menu
    }

    func copyPaths(_ ids: [UUID]) {
        let items = ordered(ids).compactMap { item(for: $0) }
        guard !items.isEmpty else { return }
        Task { [weak self] in
            let results = await ShelfFiles.check(items) { $0.path }
            guard let self else { return }
            let paths = self.apply(results).compactMap(\.value)
            guard !paths.isEmpty else {
                self.showToast("File not found", isError: true)
                return
            }
            let pb = self.pasteboard
            pb.clearContents()
            pb.setString(paths.joined(separator: "\n"), forType: .string)
            self.showToast(paths.count > 1 ? "Paths copied" : "Path copied")
        }
    }

    func reveal(_ ids: [UUID]) {
        let items = ordered(ids).compactMap { item(for: $0) }
        guard !items.isEmpty else { return }
        Task { [weak self] in
            let results = await ShelfFiles.check(items) { $0 }
            guard let self else { return }
            let urls = self.apply(results).compactMap(\.value)
            guard !urls.isEmpty else {
                self.showToast("File not found", isError: true)
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    // MARK: - Rename (inline, on disk)

    func beginRename(_ id: UUID) {
        guard let card = cards[id], let item = item(for: id), !card.isInPile else { return }
        focusShelf()
        card.beginRename(initial: item.url.deletingPathExtension().lastPathComponent) { [weak self] text in
            self?.finishRename(id, text)
        }
    }

    /// Renames the file on disk (off the main thread), then points the card at the new name.
    func finishRename(_ id: UUID, _ text: String?) {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let item = item(for: id), !pending.contains(id) else { return }
        let name = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { ShelfFiles.rename(item, to: name) }.value
            guard let self else { return }
            switch outcome {
            case .renamed(let renamed):
                guard var current = self.item(for: id) else { return }
                current.path = renamed.path
                current.bookmark = renamed.bookmark
                self.store.update(current)
                self.cards[id]?.update(item: current)
            case .unchanged:
                break
            case .exists(let taken):
                self.showToast("“\(taken)” already exists", isError: true)
            case .gone:
                self.apply([ShelfFiles.Result<Bool>(item: item, status: .gone, value: nil)])
                self.showToast("File not found", isError: true)
            case .failed:
                self.showToast("Couldn't rename", isError: true)
            }
        }
    }

    // MARK: - Removal

    func dismissKeyTargets() {
        let ids = keyTargets
        guard !ids.isEmpty else { NSSound.beep(); return }
        dismiss(ids, exit: .collapse)
    }

    /// ✕, ⌫, swipe: the card leaves; the file stays on disk.
    func dismiss(_ ids: [UUID], exit: ShelfCardView.Exit) {
        removeItems(ids, kind: .dismiss, exit: exit)
    }

    /// "Clear shelf" (pile menu and the DEBUG `clear` command). Undoable with ⌘Z.
    func clear() {
        removeItems(store.items.map(\.id), kind: .clear, exit: .collapse)
    }

    /// Move to Trash (off the main thread), keeping where each file went so ⌘Z can put it back.
    func trash(_ ids: [UUID]) {
        let items = ordered(ids).filter { !pending.contains($0) }.compactMap { item(for: $0) }
        guard !items.isEmpty else { return }
        Task { [weak self] in
            let results = await ShelfFiles.check(items) { ShelfFiles.trash($0) }
            guard let self else { return }
            let live = self.apply(results)
            var records: [UUID: ShelfUndoStep.Trashed] = [:]
            for r in live { if let t = r.value { records[r.item.id] = t } }
            if !records.isEmpty { self.removeItems(Array(records.keys), kind: .trash, exit: .collapse, trashed: records) }
            if live.contains(where: { $0.value == nil }) { self.showToast("Couldn't move to Trash", isError: true) }
        }
    }

    /// Takes items off the shelf as one undo step, animates them out, then lets the rest settle.
    func removeItems(_ ids: [UUID], kind: ShelfUndoStep.Kind, exit: ShelfCardView.Exit, trashed: [UUID: ShelfUndoStep.Trashed] = [:]) {
        let set = Set(ids)
        var thumbs: [UUID: CGImage] = [:]
        for id in set { if let t = cards[id]?.thumbnail { thumbs[id] = t } }
        let removals = store.remove(ids: set)
        guard !removals.isEmpty else { return }
        undoStack.append(ShelfUndoStep(kind: kind, removals: removals, trashed: trashed, thumbnails: thumbs))
        // The shelf just emptied: keep the (now invisible) panel 3 s, so ⌘Z can still reach it.
        if store.items.isEmpty { lingerUntil = Date().addingTimeInterval(3) }
        if undoStack.count > ShelfUndoStep.limit { undoStack.removeFirst(undoStack.count - ShelfUndoStep.limit) }
        if undoStack.count > ShelfUndoStep.thumbnailSteps {
            undoStack[undoStack.count - ShelfUndoStep.thumbnailSteps - 1].thumbnails = [:]
        }
        detach(removals.map(\.item.id), exit: exit)
    }

    /// Removes the views of items already gone from the store, and reports them.
    /// Without `animated`, the cards vanish and the rest snap into place.
    func detach(_ ids: [UUID], exit: ShelfCardView.Exit, animated: Bool = true) {
        // The shelf emptied while tucked: untuck it, so the next shot lands on the shelf, not in a bare tab.
        // Cards tucked off-screen (not peeking) just go, and the shelf snaps back unseen.
        let emptiedWhileTucked = isTucked && store.items.isEmpty
        let offscreen = emptiedWhileTucked && !isPeeking
        cancelFlights(ids)
        var longest = 0.0
        for id in ids {
            // Off the shelf it isn't pending any more (⌘Z re-checks), and a queued click-copy is moot.
            pending.remove(id)
            if queuedCopy == id { queuedCopy = nil }
            selection.remove(id)
            if focusedID == id { focusedID = nil }
            if hoveredID == id { hoveredID = nil }
            if markedItemID == id { markedItemID = nil }
            guard let card = cards.removeValue(forKey: id) else { continue }
            if card.isRenaming { card.endRename(commit: false) }
            if !animated || offscreen || card.isInPile || card.isHidden {
                card.removeFromSuperview()
                continue
            }
            let d = card.leave(exit)
            longest = max(longest, d)
            ShelfMotion.after(d + 0.03) { card.removeFromSuperview() }
        }
        if emptiedWhileTucked { setTucked(false, animated: !offscreen) }
        // "Collapse, then the rest settle."
        let settle = ShelfStyle.reduceMotion ? 0 : min(longest, 0.16)
        if settle > 0 {
            ShelfMotion.after(settle) { [weak self] in self?.relayout(animated: true) }
        } else {
            relayout(animated: animated)
        }
        onRemoved?(ids)
    }

    // MARK: - Undo

    /// Whether ⌘Z / "Restore Last Removed" has anything to bring back (for menu validation).
    var canUndo: Bool { !undoStack.isEmpty }

    /// ⌘Z on the shelf: bring back the last removed card(s); beeps when there's nothing to restore.
    func undo() { undo(fromMenu: false) }

    /// "Restore Last Removed" in the menu bar (`fromMenu: true`): never beeps. Works any time, even with the
    /// panel hidden: the cards come back and the panel shows. Trash moves the files back first (off main).
    func undo(fromMenu: Bool) {
        guard let step = undoStack.popLast() else {
            if !fromMenu { NSSound.beep() }
            return
        }
        guard step.kind == .trash else {
            bringBack(step.removals, thumbnails: step.thumbnails, failed: false)
            return
        }
        let removals = step.removals
        let trashed = step.trashed
        let thumbnails = step.thumbnails
        Task { [weak self] in
            let restored = await Task.detached(priority: .userInitiated) { () -> [ShelfStore.Removal] in
                removals.compactMap { r in
                    guard let t = trashed[r.item.id], ShelfFiles.untrash(t) else { return nil }
                    // Point the item back at its restored file before it rejoins the shelf.
                    var item = r.item
                    item.path = t.original.path
                    item.refreshBookmark()
                    return ShelfStore.Removal(index: r.index, item: item)
                }
            }.value
            self?.bringBack(restored, thumbnails: thumbnails, failed: restored.count < removals.count)
        }
    }

    /// Puts removed items back in their old places and shows them, with the panel.
    private func bringBack(_ removals: [ShelfStore.Removal], thumbnails: [UUID: CGImage], failed: Bool) {
        guard !removals.isEmpty else {
            showToast("Couldn't restore", isError: true)
            return
        }
        store.restore(removals)
        repend(removals.map(\.item))
        for r in removals where cards[r.item.id] == nil {
            let card = makeCard(r.item)
            if let thumb = thumbnails[r.item.id] { card.setThumbnail(thumb) } else { loadThumbnail(for: r.item) }
        }
        relayout(animated: true)
        for r in removals {
            if let card = cards[r.item.id], !card.isInPile { card.appear() }
        }
        refreshFan(force: true)
        showPanel()
        // Tucked: the cards are back in the tucked shelf, like a new shot; the tab says so.
        if isTucked && !isPeeking { tab.bump() }
        refreshFiles()
        showToast(failed ? "Some files couldn't be restored" : "Restored", isError: failed)
    }

    /// Restored items whose save hasn't been reported are pending until their file is on disk: either
    /// `itemDidSave` arrives, or the file is already there (checked off the main thread).
    private func repend(_ items: [ShelfItem]) {
        let unsure = items.filter { awaitingSave.contains($0.id) }
        guard !unsure.isEmpty else { return }
        for item in unsure { pending.insert(item.id) }
        let paths = unsure.map { ($0.id, $0.path) }
        Task { [weak self] in
            let present = await Task.detached(priority: .userInitiated) {
                paths.filter { ShelfFiles.exists($0.1) }.map(\.0)
            }.value
            guard let self else { return }
            for id in present where self.pending.contains(id) && self.item(for: id) != nil {
                self.markReady(id)
            }
        }
    }

    // MARK: - Drag out

    /// Drags the card, or the whole selection when the card is selected. Paths come from the store as of
    /// the last background check (the press that starts a drag runs one), so a drag never waits on the disk.
    func beginDrag(from card: ShelfCardView, event: NSEvent) {
        guard dragSource == nil, !pending.contains(card.id), item(for: card.id) != nil else { return }
        let id = card.id
        let wanted = selection.contains(id) ? ordered(selection) : [id]
        let items = wanted.filter { !pending.contains($0) && cards[$0] != nil }.compactMap { item(for: $0) }
        let ids = items.map(\.id)
        guard ids.contains(id) else { return }
        let scale = panel.backingScaleFactor
        var dragItems: [NSDraggingItem] = []
        if items.count == 1, let only = items.first {
            let di = NSDraggingItem(pasteboardWriter: only.url as NSURL)
            let image = ShelfDragImage.single(card.thumbnail, cardSize: card.bounds.size, scale: scale)
            di.setDraggingFrame(card.bounds.insetBy(dx: -ShelfDragImage.pad, dy: -ShelfDragImage.pad), contents: image)
            dragItems = [di]
        } else {
            // Front of the stack is the card under the pointer, then the newest others.
            let others = ids.reversed().filter { $0 != id }
            let thumbs = ([id] + others).compactMap { cards[$0]?.thumbnail }
            let stack = ShelfDragImage.stack(thumbs, count: items.count, scale: scale)
            dragItems = stackedItems(items, image: stack.image, anchor: stack.anchor, at: card.convert(event.locationInWindow, from: nil))
        }
        startSession(dragItems, ids: ids, from: card, event: event)
    }

    /// Dragging the pile sends every shot folded into it.
    func beginPileDrag(from pileView: ShelfPileView, event: NSEvent) {
        guard dragSource == nil else { return }
        let items = store.items.prefix(layout.pileCount).filter { !pending.contains($0.id) }
        guard !items.isEmpty else { return }
        let thumbs = items.reversed().prefix(3).compactMap { cards[$0.id]?.thumbnail }
        let stack = ShelfDragImage.stack(Array(thumbs), count: items.count, scale: panel.backingScaleFactor)
        let dragItems = stackedItems(items, image: stack.image, anchor: stack.anchor, at: pileView.convert(event.locationInWindow, from: nil))
        startSession(dragItems, ids: items.map(\.id), from: pileView, event: event)
        pileView.alphaValue = 0.4
    }

    /// One dragging item per file; the first carries the stacked image, the rest ride along invisibly.
    private func stackedItems(_ items: [ShelfItem], image: NSImage, anchor: CGPoint, at point: CGPoint) -> [NSDraggingItem] {
        let frame = CGRect(origin: CGPoint(x: point.x - anchor.x, y: point.y - anchor.y), size: image.size)
        return items.enumerated().map { i, item in
            let di = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            di.setDraggingFrame(frame, contents: i == 0 ? image : nil)
            return di
        }
    }

    private func startSession(_ dragItems: [NSDraggingItem], ids: [UUID], from view: NSView, event: NSEvent) {
        let source = ShelfDragSource(ids: ids, controller: self)
        dragSource = source
        let session = view.beginDraggingSession(with: dragItems, event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        for id in ids { cards[id]?.setDragging(true) }
        pile.fan.setFanned(false, animated: true)
    }

    /// A non-empty operation without ⌥ means the drop landed: the card(s) leave. Otherwise they stay.
    func dragEnded(_ source: ShelfDragSource, operation: NSDragOperation) {
        guard dragSource === source else { return }
        dragSource = nil
        pile.alphaValue = 1
        let keep = NSEvent.modifierFlags.contains(.option)
        if !operation.isEmpty && !keep {
            removeItems(source.ids, kind: .dragOut, exit: .collapse)
        } else {
            for id in source.ids { cards[id]?.setDragging(false) }
            // A file found missing mid-drag was kept for the drag; check again now.
            refreshFiles()
        }
    }
}
