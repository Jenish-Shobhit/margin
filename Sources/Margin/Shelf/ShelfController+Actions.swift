import AppKit
import MarginKit

/// One ⌘Z step: what left the shelf, and how to bring it back.
struct ShelfUndoStep {
    /// `paste`: pasted into another app while "Delete screenshots after pasting" is on (spec §14.2).
    enum Kind { case dragOut, dismiss, clear, trash, paste }
    struct Trashed {
        let original: URL
        let trashed: URL
    }

    let kind: Kind
    var removals: [ShelfStore.Removal]
    var trashed: [UUID: Trashed] = [:]
    var thumbnails: [UUID: CGImage] = [:]
    /// When the cards left: a pasted or dropped shot's file stays a little while after (`PasteboardShots.Departure`).
    var removedAt = Date()

    static let limit = 20
    /// Only the newest few steps keep their thumbnails in memory; older ones reload from disk.
    static let thumbnailSteps = 5
}

/// Spec §5: every shelf interaction.
extension ShelfController {
    // MARK: - Focus and selection

    /// Makes the panel key without activating Margin, so the shelf keys work until the user clicks elsewhere.
    /// Only for what needs those keys next (⌘-click, ✕, Rename…, Move to Trash, Clear shelf, the pile): a plain
    /// click copies, and its ⌘V belongs to the app the user is in.
    func focusShelf() {
        keysWentElsewhere = false
        keysCameBack = false
        releasingKeys = false
        if !panel.isKeyWindow { panel.makeKey() }
        if !(panel.firstResponder is NSTextView) { panel.makeFirstResponder(root) }
    }

    /// Gives the keyboard back to the app the user is in. The shelf took it without activating Margin, so
    /// deactivating hands it straight back: that app's window is key again (checked on macOS 27). Not while
    /// Margin itself is in front (Settings, Welcome), which would send the user to another app.
    func releaseKeys() {
        guard panel.isKeyWindow || root.isQuickLookKey, !NSRunningApplication.current.isActive else { return }
        // Quick Look holds the keyboard the same way, and closes first. Deactivating while it animates away
        // would leave the shelf key once it's gone (and its close can't be repeated), so the keyboard goes back
        // when it has closed (`ShelfRootView.endPreviewPanelControl`).
        if root.isQuickLookOpen {
            root.closeQuickLook()
            return
        }
        if keysCameBack {
            handKeysBack()
        } else {
            releasingKeys = true
            NSApp.deactivate()
        }
    }

    /// `releaseKeys` once another app has handed the keys back to the shelf (Spotlight opened and closed with ⌘Space):
    /// macOS then no longer leads the keyboard home, and deactivating leaves it with no window at all, typing lost
    /// until a click. So Margin activates and hands activation to the user's app, as at the end of a capture, which
    /// gives that app's window the keyboard again. Handed over before Margin's own activation has landed, the app
    /// would end up active without its key window (see `CaptureController.giveFocusBack`), so it waits for that.
    private func handKeysBack() {
        keysCameBack = false
        guard let app = NSWorkspace.shared.frontmostApplication, app != .current else { return }
        NSApp.activate()
        Task { @MainActor [weak self] in
            let requested = ContinuousClock.now
            while !NSRunningApplication.current.isActive, ContinuousClock.now - requested < .milliseconds(300) {
                try? await Task.sleep(for: .milliseconds(5))
            }
            let landed = NSRunningApplication.current.isActive
            try? await Task.sleep(for: .milliseconds(60))
            // The user went to another app meanwhile: it keeps the keys.
            guard let self, !app.isTerminated, !landed || NSRunningApplication.current.isActive else { return }
            self.releasingKeys = true
            NSApp.yieldActivation(to: app)
            app.activate(from: .current, options: [])
        }
    }

    /// The shelf lost the keys: to another app's window, unless `releaseKeys` gave them away or one of Margin's own
    /// windows (Quick Look, the overlay, Settings) took them. Keys that had come back are gone again (a click in the
    /// user's app after Spotlight): only if they come back once more does `releaseKeys` need `handKeysBack`.
    func shelfResignedKey() {
        if releasingKeys {
            releasingKeys = false
        } else if NSApp.keyWindow == nil, !NSRunningApplication.current.isActive {
            keysWentElsewhere = true
            keysCameBack = false
        }
    }

    /// The shelf has the keys again without asking for them (`focusShelf`): the app that took them handed them back.
    func shelfBecameKey() {
        guard keysWentElsewhere else { return }
        keysWentElsewhere = false
        keysCameBack = true
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

    /// Esc closes Quick Look; otherwise it clears the selection. Either way the keyboard goes back.
    func escape() {
        if root.isQuickLookOpen { closeQuickLook(); return }
        if cards.values.contains(where: { $0.isRenaming }) { return }
        clearSelection()
        releaseKeys()
    }

    /// What the keys act on: the selection, else the hovered card, else the last clicked card.
    var keyTargets: [UUID] {
        if !selection.isEmpty { return ordered(selection) }
        if let hoveredID, cards[hoveredID] != nil { return [hoveredID] }
        if let focusedID, cards[focusedID] != nil { return [focusedID] }
        return []
    }

    // MARK: - Click, copy, open

    /// Click: copy that shot (same clipboard write as a capture), move the ⌘V mark, toast "Copied". The copy
    /// starts at once, so ⌘V straight after the click pastes it; a pending card's copy runs when its file lands.
    /// The first click of a double-click copies too, and the second opens the file.
    /// The click never takes the keyboard, and gives it back if the shelf had it (see `copyKeyTargets`).
    func click(_ id: UUID) {
        focusedID = id
        clearSelection()
        copy([id])
        releaseKeys()
    }

    /// ⌘C. A copy is for pasting elsewhere, so the keyboard goes back to the user's app, where ⌘V pastes.
    func copyKeyTargets() {
        let ids = keyTargets
        guard !ids.isEmpty else { NSSound.beep(); return }
        copy(ids)
        releaseKeys()
    }

    /// Reads the files off the main thread, then puts the same bytes on the clipboard, each with its file's
    /// URL (as a capture does, so ⌘V in a terminal pastes the paths). A recording goes as its file alone, never read.
    func copy(_ ids: [UUID]) {
        let ids = ordered(ids)
        let ready = ids.filter { !pending.contains($0) }
        if ready.isEmpty, let last = ids.last {
            queuedCopy = last
            return
        }
        let items = ready.compactMap { item(for: $0) }
        guard !items.isEmpty else { return }
        queuedCopy = nil
        copyGeneration += 1
        let generation = copyGeneration
        Task { [weak self] in
            let results = await ShelfFiles.check(items) { item, url -> ClipboardWriter.Entry? in
                switch item.kind {
                case .screenshot: ShelfFiles.pngData(at: url).map { ClipboardWriter.Entry(png: $0, fileURL: url) }
                case .recording: ClipboardWriter.Entry(fileURL: url)
                }
            }
            guard let self, generation == self.copyGeneration else { return }
            let live = self.apply(results)
            let copied = live.compactMap { r in r.value.map { (id: r.item.id, entry: $0) } }
            guard let markID = copied.last?.id else {
                if results.contains(where: { $0.status.isGone }) {
                    self.showToast("File not found", isError: true)
                } else if !live.isEmpty {
                    self.showToast("Couldn't read the file", isError: true)
                }
                return
            }
            // Screenshots alone, as a capture writes them; with a recording, its file has no PNG. A Pasteboard shot's
            // copy is watched for a paste while "Delete screenshots after pasting" is on (spec §14.2).
            let pngs = copied.compactMap(\.entry.png)
            let changeCount = self.writeWatchedCopy?(copied) ?? (pngs.count == copied.count
                ? ClipboardWriter.write(pngs: pngs, fileURLs: copied.map(\.entry.fileURL), to: self.pasteboard)
                : ClipboardWriter.write(copied.map(\.entry), to: self.pasteboard))
            self.setClipboardMark(markID)
            self.showToast("Copied")
            self.onCopied?(markID, changeCount)
            self.onClipboardFiles?(copied.compactMap(\.entry.fileURL), changeCount)
        }
    }

    func open(_ id: UUID) {
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

    /// Space: Quick Look for the key targets, or closes it.
    func toggleQuickLook() {
        if root.isQuickLookOpen { closeQuickLook(); return }
        quickLook(keyTargets)
    }

    /// Quick Look for these shots. It takes the keyboard from the shelf, without activating Margin (see
    /// `ShelfRootView.showQuickLook`): Space and Esc close it, and the arrows step through the shots.
    func quickLook(_ ids: [UUID]) {
        let items = ordered(ids).filter { !pending.contains($0) }.compactMap { item(for: $0) }
        guard !items.isEmpty else { NSSound.beep(); return }
        Task { [weak self] in
            let results = await ShelfFiles.check(items) { $0 }
            guard let self else { return }
            let urls = self.apply(results).compactMap(\.value)
            guard !urls.isEmpty else {
                self.showToast("File not found", isError: true)
                return
            }
            // Clicked away meanwhile: nothing would close it.
            guard self.panel.isKeyWindow else { return }
            self.root.showQuickLook(urls)
        }
    }

    /// Space or Esc on the shelf while Quick Look is open (the shelf was ⌘-clicked since): closes it and gives
    /// the keyboard back, as Esc does. Quick Look's own Space, Esc and close button do the same
    /// (`ShelfRootView.endPreviewPanelControl`).
    func closeQuickLook() {
        releaseKeys()           // closes Quick Look with the keys
        root.closeQuickLook()   // or alone, while Margin is in front
    }

    /// Quick Look has closed: the keyboard goes back to the user's app. Its full screen made Margin the active app,
    /// which deactivating can't undo from here (`releaseKeys` leaves an active Margin alone), so activation goes back
    /// to `app`, the one the user was in when it opened. Not if one of Margin's own windows has the keys: Settings, or
    /// the overlay of a capture that closed Quick Look by taking them (handed away, activation would cancel it).
    func quickLookDidClose(returnTo app: NSRunningApplication?) {
        let ownWindowIsKey = NSApp.keyWindow.map { $0.level == .normal || $0 is OverlayPanel } ?? false
        guard let app, NSRunningApplication.current.isActive, !ownWindowIsKey, !app.isTerminated, app != .current else {
            releaseKeys()
            return
        }
        NSApp.yieldActivation(to: app)
        app.activate(from: .current, options: [])
    }

    /// Quick Look is open but neither it nor the shelf has the keyboard any more (a click in another app):
    /// nothing could close it with a key, so it closes.
    func keyWindowChanged() {
        guard root.isQuickLookOpen, !panel.isKeyWindow, !root.isQuickLookKey else { return }
        root.closeQuickLook()
    }

    /// For Quick Look's zoom: the card showing this file, in screen points.
    func screenFrame(forFileURL url: URL) -> CGRect {
        guard let item = store.items.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }),
              let card = cards[item.id], !card.isInPile, !card.isHidden, !isTucked || isPeeking else { return .zero }
        return screenRect(of: card)
    }

    // MARK: - Menu (••• and right-click)

    /// An empty card or pile menu. Once the shelf has had the keys, AppKit makes it key again when a menu closes, so
    /// a menu closed without a choice (Esc, a click elsewhere) gives them back, unless the shelf had them when it
    /// opened. A chosen item decides for itself.
    func makeMenu() -> ShelfMenu {
        ShelfMenu(onDismiss: menuOpening())
    }

    /// Any menu of Margin's is opening (a card's, the pile's, the menu bar icon's). Call the result when it has closed:
    /// it gives the keys back if the shelf has them only because AppKit made it key again as the menu closed.
    func menuOpening() -> () -> Void {
        keysWentElsewhere = false   // if the shelf gets the keys now, it's from this menu
        let hadKeys = panel.isKeyWindow || root.isQuickLookKey
        return { [weak self] in if !hadKeys { self?.releaseKeys() } }
    }

    func menu(for card: ShelfCardView) -> NSMenu {
        let id = card.id
        let ids = selection.contains(id) && selection.count > 1 ? ordered(selection) : [id]
        let menu = makeMenu()
        menu.autoenablesItems = false
        // Until the file is on disk there's nothing to act on.
        let saving = ids.contains { pending.contains($0) }
        // Move to Trash and Rename… take the keys (⌘Z, typing); Copy Path leaves them with the user's app,
        // where its ⌘V pastes the path (spec §5).
        menu.addItem(ShelfMenuItem(ids.count > 1 ? "Copy Paths" : "Copy Path") { [weak self] in self?.copyPaths(ids); self?.releaseKeys() })
        menu.addItem(ShelfMenuItem("Reveal in Finder") { [weak self] in self?.reveal(ids) })
        let rename = ShelfMenuItem("Rename…") { [weak self] in self?.beginRename(id) }
        rename.isEnabled = ids.count == 1
        menu.addItem(rename)
        menu.addItem(.separator())
        menu.addItem(ShelfMenuItem("Move to Trash") { [weak self] in self?.focusShelf(); self?.trash(ids) })
        if saving { menu.items.forEach { $0.isEnabled = false } }
        return menu
    }

    /// Copy Path: the paths as plain text. A copy like any other: the newest one from the shelf wins, and it wins
    /// over a capture still being saved (`onCopiedPaths`). A path isn't the image, so the ⌘V mark goes.
    func copyPaths(_ ids: [UUID]) {
        let items = ordered(ids).compactMap { item(for: $0) }
        guard !items.isEmpty else { return }
        queuedCopy = nil
        copyGeneration += 1
        let generation = copyGeneration
        Task { [weak self] in
            let results = await ShelfFiles.check(items) { $0.path }
            guard let self, generation == self.copyGeneration else { return }
            let paths = self.apply(results).compactMap(\.value)
            guard !paths.isEmpty else {
                self.showToast("File not found", isError: true)
                return
            }
            let changeCount = ClipboardWriter.write(paths: paths, to: self.pasteboard)
            self.setClipboardMark(nil)
            self.showToast(paths.count > 1 ? "Paths copied" : "Path copied")
            self.onCopiedPaths?()
            // A path pasted into a terminal reaches the file as surely as the file does.
            self.onClipboardFiles?(paths.map { URL(fileURLWithPath: $0) }, changeCount)
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
        if undoStack.count > ShelfUndoStep.limit {
            let expired = undoStack.prefix(undoStack.count - ShelfUndoStep.limit)
            undoStack.removeFirst(expired.count)
            onUndoExpired?(Array(expired))
        }
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
            thumbnailLoads.forget(id)
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

    /// The files of every card ⌘Z could still bring back (spec §14.2: a Pasteboard file stays while one can).
    var undoPaths: [String] { undoStack.flatMap { $0.removals.map(\.item.path) } }

    /// Whether ⌘Z could still bring this card back.
    func canBringBack(_ id: UUID) -> Bool {
        undoStack.contains { $0.removals.contains { $0.item.id == id } }
    }

    /// Pasted while "Delete screenshots after pasting" is on (spec §14.2): the cards leave as after a drop, one ⌘Z step
    /// (Restore Last Removed brings them back). A card being dragged, or already gone, stays as it is.
    func pasted(_ ids: [UUID]) {
        let dragging = Set(dragSource?.ids ?? [])
        let leaving = ids.filter { item(for: $0) != nil && !pending.contains($0) && !dragging.contains($0) }
        guard !leaving.isEmpty else { return }
        removeItems(leaving, kind: .paste, exit: .collapse)
    }

    /// ⌘Z on the shelf: bring back the last removed card(s); beeps when there's nothing to restore.
    func undo() { undo(fromMenu: false) }

    /// "Restore Last Removed" in the menu bar (`fromMenu: true`): never beeps. Works any time, even with the
    /// panel hidden: the cards come back and the panel shows. Trash moves the files back first (off main).
    /// A ⌘Z pressed while a step is still restoring runs right after it, so steps land newest first.
    func undo(fromMenu: Bool) {
        switch undoSequencer.request(available: undoStack.count) {
        case .run: runUndo()
        case .wait: break
        case .nothing: if !fromMenu { NSSound.beep() }
        }
    }

    /// Restores the newest step; when it's back, a ⌘Z that waited meanwhile runs. Files are checked first (off
    /// the main thread), so a card whose file was deleted since doesn't come back only to fade away; the step is
    /// used up either way, since those cards can't return.
    private func runUndo() {
        guard let step = undoStack.popLast() else {
            undoSequencer.reset()   // waiting ⌘Zs lost their steps (a failed save dropped them)
            return
        }
        let removals = step.removals
        let trashed = step.trashed
        let thumbnails = step.thumbnails
        // A shot still being saved has no file to check yet (and its save updates only steps on the stack):
        // its step comes back as it is.
        if step.kind != .trash, removals.contains(where: { awaitingSave.contains($0.item.id) }) {
            bringBack(removals, of: removals.count, kind: step.kind, thumbnails: thumbnails)
            undoFinished()
            return
        }
        Task { [weak self] in
            let back = step.kind == .trash ? await Self.untrash(removals, trashed) : await Self.stillThere(removals)
            guard let self else { return }
            self.bringBack(back, of: removals.count, kind: step.kind, thumbnails: thumbnails)
            self.undoFinished()
        }
    }

    private func undoFinished() {
        if undoSequencer.finished() { runUndo() }
    }

    /// Moves trashed files back (off the main thread); returns the removals whose files are home again.
    private static func untrash(_ removals: [ShelfStore.Removal], _ trashed: [UUID: ShelfUndoStep.Trashed]) async -> [ShelfStore.Removal] {
        await Task.detached(priority: .userInitiated) { () -> [ShelfStore.Removal] in
            removals.compactMap { r in
                guard let t = trashed[r.item.id], ShelfFiles.untrash(t) else { return nil }
                // Point the item back at its restored file before it rejoins the shelf.
                var item = r.item
                item.path = t.original.path
                item.refreshBookmark()
                return ShelfStore.Removal(index: r.index, item: item)
            }
        }.value
    }

    /// The removals whose files are still there, following files moved meanwhile. A file Margin can't see right
    /// now counts as there, as everywhere else; one that's definitely gone can't come back.
    private static func stillThere(_ removals: [ShelfStore.Removal]) async -> [ShelfStore.Removal] {
        let results = await ShelfFiles.statuses(removals.map(\.item))
        return zip(removals, results).compactMap { r, result in
            switch result.status {
            case .found(let fresh): ShelfStore.Removal(index: r.index, item: fresh)
            case .unknown: r
            case .gone: nil
            }
        }
    }

    /// Puts removed items back in their old places and shows them, with the panel. `removals` are the ones that
    /// can come back, out of `total` in the step.
    private func bringBack(_ removals: [ShelfStore.Removal], of total: Int, kind: ShelfUndoStep.Kind, thumbnails: [UUID: CGImage]) {
        let trash = kind == .trash
        guard !removals.isEmpty else {
            showToast(trash ? "Couldn't restore" : "File not found", isError: true)
            return
        }
        store.restore(removals)
        repend(removals.map(\.item))
        // The layout makes the cards that come back in view, with the step's thumbnails (the rest decode).
        relayout(animated: true, thumbnails: thumbnails)
        for r in removals {
            if let card = cards[r.item.id], !card.isInPile { card.appear() }
        }
        refreshFan(force: true)
        showPanel()
        // Tucked: the cards are back in the tucked shelf, like a new shot; the tab says so.
        if isTucked && !isPeeking { tab.bump() }
        refreshFiles()
        if removals.count < total {
            showToast(trash ? "Some files couldn't be restored" : "Some files weren't found", isError: true)
        } else {
            showToast("Restored")
        }
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
        let keep = ShelfDragSource.optionHeld
        if items.count == 1, let only = items.first {
            let thumb = card.thumbnail, size = card.bounds.size
            let draw = { (keep: Bool) in ShelfDragImage.single(thumb, cardSize: size, scale: scale, keep: keep) }
            let image = draw(keep)
            let di = NSDraggingItem(pasteboardWriter: only.url as NSURL)
            di.setDraggingFrame(card.bounds.insetBy(dx: -ShelfDragImage.pad, dy: -ShelfDragImage.pad), contents: image)
            let source = ShelfDragSource(ids: ids, controller: self, keep: keep, image: image, redraw: draw)
            startSession([di], source: source, from: card, event: event)
        } else {
            // Front of the stack is the card under the pointer, then the newest others.
            let others = ids.reversed().filter { $0 != id }
            let thumbs = ([id] + others).compactMap { cards[$0]?.thumbnail }
            let count = items.count
            let stack = ShelfDragImage.stack(thumbs, count: count, scale: scale, keep: keep)
            let dragItems = stackedItems(items, image: stack.image, anchor: stack.anchor, at: card.convert(event.locationInWindow, from: nil))
            let source = ShelfDragSource(ids: ids, controller: self, keep: keep, image: stack.image) {
                ShelfDragImage.stack(thumbs, count: count, scale: scale, keep: $0).image
            }
            startSession(dragItems, source: source, from: card, event: event)
        }
    }

    /// Dragging the pile sends every shot folded into it.
    func beginPileDrag(from pileView: ShelfPileView, event: NSEvent) {
        guard dragSource == nil else { return }
        let items = store.items.prefix(layout.pileCount).filter { !pending.contains($0.id) }
        guard !items.isEmpty else { return }
        let thumbs = Array(items.reversed().prefix(3).compactMap { cards[$0.id]?.thumbnail })
        let count = items.count, scale = panel.backingScaleFactor
        let keep = ShelfDragSource.optionHeld
        let stack = ShelfDragImage.stack(thumbs, count: count, scale: scale, keep: keep)
        let dragItems = stackedItems(items, image: stack.image, anchor: stack.anchor, at: pileView.convert(event.locationInWindow, from: nil))
        let source = ShelfDragSource(ids: items.map(\.id), controller: self, keep: keep, image: stack.image) {
            ShelfDragImage.stack(thumbs, count: count, scale: scale, keep: $0).image
        }
        startSession(dragItems, source: source, from: pileView, event: event)
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

    private func startSession(_ dragItems: [NSDraggingItem], source: ShelfDragSource, from view: NSView, event: NSEvent) {
        dragSource = source
        let session = view.beginDraggingSession(with: dragItems, event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        for id in source.ids { cards[id]?.setDragging(true) }
        pile.fan.setFanned(false, animated: true)
    }

    /// A non-empty operation without ⌥ means the drop landed: the card(s) leave. Otherwise they stay.
    /// While ⌥ is held, the drag image says so ("Keep on shelf").
    func dragEnded(_ source: ShelfDragSource, operation: NSDragOperation) {
        guard dragSource === source else { return }
        dragSource = nil
        pile.alphaValue = 1
        let keep = ShelfDragSource.optionHeld
        if !operation.isEmpty && !keep {
            removeItems(source.ids, kind: .dragOut, exit: .collapse)
        } else {
            for id in source.ids { cards[id]?.setDragging(false) }
            // A file found missing mid-drag was kept for the drag; check again now.
            refreshFiles()
        }
    }
}
