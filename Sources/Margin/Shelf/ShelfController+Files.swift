import AppKit
import MarginKit

/// Keeping the shelf in step with the disk without the main thread ever touching it (see `ShelfFiles`).
/// Cards always show from the store right away; checks run in the background and their results are
/// applied here, to items that haven't changed meanwhile.
extension ShelfController {
    /// Spec §4: re-check every saved item's file (at launch, when the shelf appears, when a press may become
    /// a drag). Follows files moved in Finder; drops only files that are definitely gone. One check runs at
    /// a time; asking again meanwhile runs one more afterwards.
    /// - Parameter quietWithin: if the check finishes within this many seconds, gone cards vanish without
    ///   animation (at launch, before anyone has looked at them).
    func refreshFiles(quietWithin: TimeInterval = 0) {
        guard !fileRefreshRunning else { fileRefreshQueued = true; return }
        let snapshot = store.items.filter { !pending.contains($0.id) }
        guard !snapshot.isEmpty else { return }
        fileRefreshRunning = true
        let quietUntil = Date().addingTimeInterval(quietWithin)
        let clock = Stopwatch()
        Task { [weak self] in
            let results = await ShelfFiles.statuses(snapshot)
            CaptureTimings.shared.record("shelfFileCheck", clock.ms)
            guard let self else { return }
            self.fileRefreshRunning = false
            let applying = Stopwatch()
            self.apply(results, quiet: Date() < quietUntil)
            CaptureTimings.shared.record("shelfFileCheck.apply", applying.ms)
            if self.fileRefreshQueued {
                self.fileRefreshQueued = false
                self.refreshFiles()
            }
        }
    }

    /// At launch, before the first check: a save cut off between its temp file and the rename (a crash, a forced quit,
    /// the quit timeout) left its PNG hidden in the folder, and its card waiting for a file that never appeared.
    /// `LeftoverSaves` puts each back, under its card's name when one is waiting (so the card stays), in the Unsaved
    /// folder and any folder a waiting card points into. The check waits for it.
    ///
    /// Then, once the longest grace is over (`PasteboardShots.launchCleanupDelay`), the Pasteboard folder of "Delete
    /// screenshots after pasting" (spec §14.2) loses the files no card holds: last session's ⌘Z steps are gone, so
    /// nothing can bring their cards back. Files still on the clipboard stay (`keeping`).
    func recoverLeftoverSavesThenRefresh(quietWithin: TimeInterval, keeping: Set<String> = []) {
        let items = store.items
        // Not the save folder as such: on the Desktop, looking into it at launch raises the Desktop folder's privacy
        // prompt if it hasn't been answered yet. A cut-off save always leaves its card waiting (the card is stored before
        // the PNG is written), and its folder is one Margin was writing to. The Unsaved and Pasteboard folders are
        // Margin's own, and never prompt.
        let folders = [Preferences.fallbackSaveFolder, Preferences.pasteboardFolder]
            + items.filter { $0.bookmark == nil }.map { $0.url.deletingLastPathComponent() }
        // Nothing this copy writes can be older: saves start only once the shelf is restored.
        let launch = Date()
        fileRefreshRunning = true
        Task { [weak self] in
            let outcomes = await ShelfFiles.recoverLeftovers(in: folders, items: items, writtenBefore: launch)
            guard let self else { return }
            self.fileRefreshRunning = false
            self.fileRefreshQueued = false
            if !outcomes.isEmpty { self.onLeftoversRecovered?() }
            self.refreshFiles(quietWithin: quietWithin)
            self.cleanUpPasteboardLater(launchItems: items, keeping: keeping, launch: launch)
        }
    }

    /// The launch's cleanup of the Pasteboard folder waits out the longest grace: a shot pasted or dropped just before a
    /// quit (Install and Relaunch, say) may still be read by the app that took it. Whatever a card or a ⌘Z step holds
    /// by then stays too, as do the files named in a set-aside shelf list (`ShelfStore.setAsideFiles`).
    private func cleanUpPasteboardLater(launchItems: [ShelfItem], keeping: Set<String>, launch: Date) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(PasteboardShots.launchCleanupDelay))
            guard let self else { return }
            await ShelfFiles.cleanUpPasteboard(items: launchItems + self.store.items, keeping: keeping.union(self.undoPaths),
                                               shelfFile: self.store.fileURL, writtenBefore: launch)
        }
    }

    /// Applies a background check: a moved file's new path and bookmark go to the store (all in one write: a moved
    /// folder updates every card), and a file that's definitely gone takes its card off the shelf (not undoable).
    /// Items that changed since the check started, pending items and cards being dragged are left alone. Returns
    /// the results for items still on the shelf, in the order given.
    @discardableResult
    func apply<Value>(_ results: [ShelfFiles.Result<Value>], quiet: Bool = false) -> [ShelfFiles.Result<Value>] {
        var gone: [UUID] = []
        var moved: [ShelfItem] = []
        var live: [ShelfFiles.Result<Value>] = []
        let dragging = Set(dragSource?.ids ?? [])
        let items = Dictionary(store.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for r in results {
            let id = r.item.id
            guard let current = items[id], !pending.contains(id) else { continue }
            let unchanged = current == r.item
            switch r.status {
            case .found(let fresh):
                if unchanged, fresh != current {
                    moved.append(fresh)
                    cards[id]?.update(item: fresh)
                }
                // A card still without its shot (the file was renamed or moved before the thumbnail loaded from
                // the old path, or was unreadable until now) loads it from where the file is, if it's in view.
                if unchanged, let card = cards[id], card.thumbnail == nil { thumbnailLoads.retry(id) }
                live.append(r)
            case .gone:
                if unchanged, !dragging.contains(id) { gone.append(id) } else { live.append(r) }
            case .unknown:
                live.append(r)
            }
        }
        if !moved.isEmpty { store.update(moved) }
        if !gone.isEmpty {
            store.remove(ids: Set(gone))
            detach(gone, exit: .fade, animated: !quiet)
        }
        loadThumbnails()
        return live
    }
}
