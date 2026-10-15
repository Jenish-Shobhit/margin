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
        Task { [weak self] in
            let results = await ShelfFiles.statuses(snapshot)
            guard let self else { return }
            self.fileRefreshRunning = false
            self.apply(results, quiet: Date() < quietUntil)
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
    func recoverLeftoverSavesThenRefresh(quietWithin: TimeInterval) {
        let items = store.items
        // Not the save folder as such: on the Desktop, looking into it at launch raises the Desktop folder's privacy
        // prompt if it hasn't been answered yet. A cut-off save always leaves its card waiting (the card is stored before
        // the PNG is written), and its folder is one Margin was writing to.
        let folders = [Preferences.fallbackSaveFolder] + items.filter { $0.bookmark == nil }.map { $0.url.deletingLastPathComponent() }
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
        }
    }

    /// Applies a background check: a moved file's new path and bookmark go to the store, and a file that's
    /// definitely gone takes its card off the shelf (not undoable). Items that changed since the check
    /// started, pending items and cards being dragged are left alone. Returns the results for items still
    /// on the shelf, in the order given.
    @discardableResult
    func apply<Value>(_ results: [ShelfFiles.Result<Value>], quiet: Bool = false) -> [ShelfFiles.Result<Value>] {
        var gone: [UUID] = []
        var live: [ShelfFiles.Result<Value>] = []
        let dragging = Set(dragSource?.ids ?? [])
        for r in results {
            let id = r.item.id
            guard let current = item(for: id), !pending.contains(id) else { continue }
            let unchanged = current == r.item
            switch r.status {
            case .found(let fresh):
                if unchanged, fresh != current {
                    store.update(fresh)
                    cards[id]?.update(item: fresh)
                }
                // A card still without its shot (the file was renamed or moved before the thumbnail loaded from
                // the old path, or was unreadable until now) loads it from where the file is.
                if unchanged, let card = cards[id], card.thumbnail == nil { loadThumbnail(for: fresh) }
                live.append(r)
            case .gone:
                if unchanged, !dragging.contains(id) { gone.append(id) } else { live.append(r) }
            case .unknown:
                live.append(r)
            }
        }
        if !gone.isEmpty {
            store.remove(ids: Set(gone))
            detach(gone, exit: .fade, animated: !quiet)
        }
        return live
    }
}
