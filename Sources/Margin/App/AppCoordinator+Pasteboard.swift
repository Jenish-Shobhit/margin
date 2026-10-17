import AppKit
import MarginKit

/// "Delete screenshots after pasting" (spec §14.2). While it's on, screenshots are written to the Pasteboard folder
/// (`AppCoordinator+Save`). A file there is deleted only once nothing can reach it: its card has left the shelf, the ⌘Z
/// step that would bring it back has been pushed out, its grace after a paste or a drop is over, and the clipboard no
/// longer holds it. Anything left over at quit goes at the next launch (`PasteboardShots.cleanUp`). Off, and with no
/// Pasteboard files about, none of this does anything.
extension AppCoordinator {
    /// Before `shelf.restore()`: the files the clipboard still holds from the last session stay through the launch's
    /// cleanup, until the clipboard moves on.
    func wirePasteboardShots() {
        let current = NSPasteboard.general.changeCount
        if let files = prefs.pasteboardClipboard {
            if files.changeCount == current { clipboardFiles = files } else { prefs.pasteboardClipboard = nil }
        }
        shelf.pasteboardFilesOnClipboard = clipboardFiles?.paths(at: current) ?? []
        shelf.onUndoExpired = { [weak self] steps in self?.undoStepsExpired(steps) }
        shelf.onClipboardFiles = { [weak self] files, changeCount in self?.clipboardHolds(files, changeCount: changeCount) }
        shelf.writeWatchedCopy = { [weak self] copied in self?.writeWatchedCopy(copied) }
    }

    // MARK: - Pasted

    /// Writes `entries` to the clipboard watched for a paste (`PasteWatch`: promised, kept on this Mac) and returns the
    /// change count. A paste takes the pasted cards off the shelf.
    func writeWatched(_ entries: [PasteWatch.Entry]) -> Int {
        let watch = PasteWatch()
        watch.onPaste = { [weak self] ids in self?.pasted(ids) }
        let changeCount = watch.write(entries)
        pasteWatch = watch
        return changeCount
    }

    /// A shelf copy (click, ⌘C) with a Pasteboard screenshot in it, while the option is on, is watched again; any other
    /// copy is left to the shelf, written as always.
    func writeWatchedCopy(_ copied: [(id: UUID, entry: ClipboardWriter.Entry)]) -> Int? {
        guard prefs.deletesAfterPasting else { return nil }
        let watched = copied.map { $0.entry.png != nil && $0.entry.fileURL.map { PasteboardShots.isInFolder($0.path) } == true }
        guard watched.contains(true) else { return nil }
        return writeWatched(zip(copied, watched).map { copy, watched in
            PasteWatch.Entry(id: copy.id, png: copy.entry.png, fileURL: copy.entry.fileURL, watched: watched)
        })
    }

    /// Another app pasted these: they leave the shelf as after a drop (Restore Last Removed brings them back). Not once
    /// the option is off: turning it off changes nothing on the shelf.
    func pasted(_ ids: [UUID]) {
        guard prefs.deletesAfterPasting else { return }
        Self.log.notice("Pasted into another app: \(ids.count) card(s) leave the shelf")
        shelf.pasted(ids)
    }

    /// After `shelf.restore()`: a file kept because the clipboard holds it, with no card, goes once the clipboard moves on.
    func retainClipboardFilesWithoutCards() {
        guard let files = clipboardFiles else { return }
        let onShelf = Set(store.items.map(\.path))
        for path in files.paths where !onShelf.contains(path) { retention.add(path, notBefore: Date()) }
    }

    /// ⌘Z steps pushed out by newer ones: their cards can't come back, so their Pasteboard files wait out their grace
    /// and go. Not a trashed card's: its file is in the Trash, the user's to empty.
    func undoStepsExpired(_ steps: [ShelfUndoStep]) {
        for step in steps where step.kind != .trash {
            let notBefore = step.removedAt.addingTimeInterval(Self.departure(step.kind).grace)
            for removal in step.removals { retention.add(removal.item.path, notBefore: notBefore) }
        }
        deletePasteboardFilesDue()
    }

    static func departure(_ kind: ShelfUndoStep.Kind) -> PasteboardShots.Departure {
        switch kind {
        case .paste: .pasted
        case .dragOut: .dropped
        case .dismiss, .clear, .trash: .removed
        }
    }

    /// The files whose time has come and that nothing holds, deleted off the main thread. On every expiry, and once a
    /// second (the ⌘V mark's tick) while any wait.
    func deletePasteboardFilesDue() {
        guard !retention.isEmpty else { return }
        let referenced = Set(store.items.map(\.path) + shelf.undoPaths)
        let onClipboard = clipboardFiles?.paths(at: NSPasteboard.general.changeCount) ?? []
        let due = retention.due(at: Date(), referenced: referenced, onClipboard: onClipboard)
        if !due.isEmpty { ShelfFiles.deletePasteboardFiles(due) }
    }

    /// Margin wrote the clipboard with these files (or their paths). The Pasteboard ones among them stay while it holds
    /// them, across a relaunch too: a terminal pastes their paths, a browser uploads them.
    func clipboardHolds(_ files: [URL], changeCount: Int) {
        let held = files.map(\.path).filter { PasteboardShots.isInFolder($0) }
        if !held.isEmpty {
            clipboardFiles = PasteboardShots.ClipboardFiles(changeCount: changeCount, paths: held)
            prefs.pasteboardClipboard = clipboardFiles
        } else if clipboardFiles != nil {
            clipboardFiles = nil
            prefs.pasteboardClipboard = nil
        }
    }

    /// The tick: something else was copied, so the clipboard no longer holds Margin's files.
    func clipboardMoved(to changeCount: Int) {
        guard let files = clipboardFiles, files.changeCount != changeCount else { return }
        clipboardFiles = nil
        prefs.pasteboardClipboard = nil
    }

    /// A shot whose card left while it was being saved, and whose ⌘Z step is gone too: its file has nothing to hold it.
    func savedWithoutCard(_ saved: ShelfItem) {
        guard !shelf.canBringBack(saved.id) else { return }
        retention.add(saved.path, notBefore: Date())
        deletePasteboardFilesDue()
    }
}
