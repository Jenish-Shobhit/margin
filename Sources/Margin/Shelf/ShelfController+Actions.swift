import AppKit
import ImageIO
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

    /// The item's file, following its bookmark if it moved in Finder (the store and card are updated).
    /// Nil when the file is gone or in the Trash.
    func resolvedURL(_ id: UUID) -> URL? {
        guard var item = item(for: id) else { return nil }
        let before = item
        let url = item.resolveFile()
        if item != before {
            store.update(item)
            cards[id]?.update(item: item)
        }
        return url
    }

    /// Click: copy that shot (same clipboard write as a capture), move the ⌘V mark, toast "Copied".
    func click(_ id: UUID) {
        focusedID = id
        clearSelection()
        if pending.contains(id) {
            queuedCopy = id   // copied as soon as the file lands
            return
        }
        copy([id])
    }

    func copyKeyTargets() {
        let ids = keyTargets
        guard !ids.isEmpty else { NSSound.beep(); return }
        copy(ids)
    }

    func copy(_ ids: [UUID]) {
        var pngs: [Data] = []
        var copied: [UUID] = []
        let ready = ordered(ids).filter { !pending.contains($0) }
        if ready.isEmpty, let last = ordered(ids).last {
            queuedCopy = last
            return
        }
        for id in ready {
            guard let url = resolvedURL(id), let data = Self.pngData(at: url) else { continue }
            pngs.append(data)
            copied.append(id)
        }
        guard let markID = copied.last else {
            pruneMissing()
            showToast("File not found", isError: true)
            return
        }
        let changeCount = ClipboardWriter.write(pngs: pngs, to: pasteboard)
        setClipboardMark(markID)
        showToast("Copied")
        onCopied?(markID, changeCount)
    }

    /// The file's PNG bytes (re-encoded if the file isn't a PNG any more).
    static func pngData(at url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return try? PNGWriter.encode(image, scale: 1)
    }

    func open(_ id: UUID) {
        guard !pending.contains(id) else { return }
        guard let url = resolvedURL(id) else {
            pruneMissing()
            showToast("File not found", isError: true)
            return
        }
        NSWorkspace.shared.open(url)
    }

    func toggleQuickLook() {
        if root.isQuickLookOpen { root.closeQuickLook(); return }
        let urls = keyTargets.filter { !pending.contains($0) }.compactMap { resolvedURL($0) }
        guard !urls.isEmpty else { NSSound.beep(); return }
        root.showQuickLook(urls)
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
        menu.addItem(ShelfMenuItem(ids.count > 1 ? "Copy Paths" : "Copy Path") { [weak self] in self?.copyPaths(ids) })
        menu.addItem(ShelfMenuItem("Reveal in Finder") { [weak self] in self?.reveal(ids) })
        let rename = ShelfMenuItem("Rename…") { [weak self] in self?.beginRename(id) }
        rename.isEnabled = ids.count == 1
        menu.addItem(rename)
        menu.addItem(.separator())
        menu.addItem(ShelfMenuItem("Move to Trash") { [weak self] in self?.trash(ids) })
        if saving { menu.items.forEach { $0.isEnabled = false } }
        return menu
    }

    func copyPaths(_ ids: [UUID]) {
        let paths = ordered(ids).compactMap { resolvedURL($0)?.path }
        guard !paths.isEmpty else { return }
        let pb = pasteboard
        pb.clearContents()
        pb.setString(paths.joined(separator: "\n"), forType: .string)
        showToast(paths.count > 1 ? "Paths copied" : "Path copied")
    }

    func reveal(_ ids: [UUID]) {
        let urls = ordered(ids).compactMap { resolvedURL($0) }
        guard !urls.isEmpty else { showToast("File not found", isError: true); return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - Rename (inline, on disk)

    func beginRename(_ id: UUID) {
        guard let card = cards[id], let item = item(for: id), !card.isInPile else { return }
        focusShelf()
        card.beginRename(initial: item.url.deletingPathExtension().lastPathComponent) { [weak self] text in
            self?.finishRename(id, text)
        }
    }

    func finishRename(_ id: UUID, _ text: String?) {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, resolvedURL(id) != nil,
              var item = item(for: id) else { return }
        var name = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let ext = item.url.pathExtension
        if !ext.isEmpty, (name as NSString).pathExtension.lowercased() != ext.lowercased() { name += "." + ext }
        let dest = item.url.deletingLastPathComponent().appendingPathComponent(name)
        guard dest.path != item.path else { return }
        let caseOnly = dest.path.lowercased() == item.path.lowercased()
        if !caseOnly, FileManager.default.fileExists(atPath: dest.path) {
            showToast("“\(name)” already exists", isError: true)
            return
        }
        do {
            try FileManager.default.moveItem(at: item.url, to: dest)
        } catch {
            showToast("Couldn't rename", isError: true)
            return
        }
        item.path = dest.path
        item.refreshBookmark()
        store.update(item)
        cards[id]?.update(item: item)
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

    /// Move to Trash, keeping where each file went so ⌘Z can put it back.
    func trash(_ ids: [UUID]) {
        var records: [UUID: ShelfUndoStep.Trashed] = [:]
        var failed = false
        for id in ordered(ids) where !pending.contains(id) {
            guard let url = resolvedURL(id) else { continue }
            var result: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                if let result { records[id] = .init(original: url, trashed: result as URL) }
            } catch {
                failed = true
            }
        }
        if !records.isEmpty { removeItems(Array(records.keys), kind: .trash, exit: .collapse, trashed: records) }
        if failed { showToast("Couldn't move to Trash", isError: true) }
    }

    /// Takes items off the shelf as one undo step, animates them out, then lets the rest settle.
    func removeItems(_ ids: [UUID], kind: ShelfUndoStep.Kind, exit: ShelfCardView.Exit, trashed: [UUID: ShelfUndoStep.Trashed] = [:]) {
        let set = Set(ids)
        var thumbs: [UUID: CGImage] = [:]
        for id in set { if let t = cards[id]?.thumbnail { thumbs[id] = t } }
        let removals = store.remove(ids: set)
        guard !removals.isEmpty else { return }
        undoStack.append(ShelfUndoStep(kind: kind, removals: removals, trashed: trashed, thumbnails: thumbs))
        if store.items.isEmpty, panel.isKeyWindow { lingerUntil = Date().addingTimeInterval(3) }
        if undoStack.count > ShelfUndoStep.limit { undoStack.removeFirst(undoStack.count - ShelfUndoStep.limit) }
        detach(removals.map(\.item.id), exit: exit)
    }

    /// Drops files that no longer resolve (shelf appearing, drag start); follows files moved in Finder.
    /// Pending items (not saved yet) are never touched. Not undoable.
    @discardableResult
    func pruneMissing() -> [UUID] {
        var dropped: [UUID] = []
        for var item in store.items where !pending.contains(item.id) {
            let before = item
            if item.resolveFile() == nil {
                dropped.append(item.id)
            } else if item != before {
                store.update(item)
                cards[item.id]?.update(item: item)
            }
        }
        guard !dropped.isEmpty else { return [] }
        store.remove(ids: Set(dropped))
        detach(dropped, exit: .fade)
        return dropped
    }

    /// Removes the views of items already gone from the store, and reports them.
    func detach(_ ids: [UUID], exit: ShelfCardView.Exit) {
        var longest = 0.0
        for id in ids {
            selection.remove(id)
            if focusedID == id { focusedID = nil }
            if hoveredID == id { hoveredID = nil }
            if markedItemID == id { markedItemID = nil }
            guard let card = cards.removeValue(forKey: id) else { continue }
            if card.isRenaming { card.endRename(commit: false) }
            if card.isInPile || card.isHidden {
                card.removeFromSuperview()
                continue
            }
            let d = card.leave(exit)
            longest = max(longest, d)
            ShelfMotion.after(d + 0.03) { card.removeFromSuperview() }
        }
        // "Collapse, then the rest settle."
        let settle = ShelfStyle.reduceMotion ? 0 : min(longest, 0.16)
        if settle > 0 {
            ShelfMotion.after(settle) { [weak self] in self?.relayout(animated: true) }
        } else {
            relayout(animated: true)
        }
        onRemoved?(ids)
    }

    // MARK: - Undo

    /// ⌘Z: bring back the last removed card(s). Trash moves the files back first.
    func undo() {
        guard let step = undoStack.popLast() else { NSSound.beep(); return }
        var removals = step.removals
        var failed = false
        if step.kind == .trash {
            var restored = Set<UUID>()
            for r in removals {
                guard let t = step.trashed[r.item.id] else { continue }
                do {
                    if FileManager.default.fileExists(atPath: t.original.path) { throw CocoaError(.fileWriteFileExists) }
                    try FileManager.default.moveItem(at: t.trashed, to: t.original)
                    restored.insert(r.item.id)
                } catch {
                    failed = true
                }
            }
            // Point the items back at their restored files before they rejoin the shelf.
            removals = removals.filter { restored.contains($0.item.id) }.map { r in
                var item = r.item
                if let t = step.trashed[item.id] {
                    item.path = t.original.path
                    item.refreshBookmark()
                }
                return ShelfStore.Removal(index: r.index, item: item)
            }
        }
        guard !removals.isEmpty else {
            showToast("Couldn't restore", isError: true)
            return
        }
        store.restore(removals)
        for r in removals where cards[r.item.id] == nil {
            let card = makeCard(r.item)
            if let thumb = step.thumbnails[r.item.id] { card.setThumbnail(thumb) } else { loadThumbnail(for: r.item) }
        }
        relayout(animated: true)
        for r in removals {
            if let card = cards[r.item.id], !card.isInPile { card.appear() }
        }
        refreshFan(force: true)
        showPanel()
        pruneMissing()
        showToast(failed ? "Some files couldn't be restored" : "Restored", isError: failed)
    }

    // MARK: - Drag out

    /// Drags the card, or the whole selection when the card is selected.
    func beginDrag(from card: ShelfCardView, event: NSEvent) {
        guard dragSource == nil, !pending.contains(card.id) else { return }
        let id = card.id
        let wanted = (selection.contains(id) ? ordered(selection) : [id]).filter { !pending.contains($0) }
        pruneMissing()
        let ids = wanted.filter { cards[$0] != nil }
        guard cards[id] != nil, !ids.isEmpty else {
            showToast("File not found", isError: true)
            return
        }
        let items = ids.compactMap { id in resolvedURL(id).flatMap { _ in item(for: id) } }
        guard !items.isEmpty else { return }
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
        pruneMissing()
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
        }
    }
}
