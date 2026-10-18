import AppKit
import MarginKit

/// "Delete screenshots after pasting" (spec §14.2). While it's on, screenshots are written to the Pasteboard folder
/// (`AppCoordinator+Save`). A file there is deleted only once nothing can reach it: its card has left the shelf, the ⌘Z
/// step that would bring it back has been pushed out, its grace after a paste or a drop is over, and the clipboard no
/// longer holds it. Anything left over at quit goes half a minute into the next launch (`PasteboardShots.cleanUp`). Off, and with no
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
        shelf.onClosed = { [weak self] items in self?.keepClosedShots(items) }
    }

    // MARK: - Closed

    /// Close Shelf keeps every file it takes off the shelf (spec §5), so the Pasteboard shots among them, which would go
    /// once undo can't bring their cards back, move into the save folder (Unsaved if it can't take them) and are normal
    /// files from then on, whether or not the option is still on. Their ⌘Z step (or their cards, if ⌘Z has brought them
    /// back meanwhile) and the clipboard follow. A shot still being saved follows when its save lands (`finishSave`).
    func keepClosedShots(_ items: [ShelfItem]) {
        let shots = items.filter { PasteboardShots.isInFolder($0.path) }
        guard !shots.isEmpty else { return }
        let folder = prefs.saveFolder, fallback = Preferences.fallbackSaveFolder
        // A quit waits for the moves as for a save: a shot left in the Pasteboard folder, with no card, would go at the
        // next launch.
        savesInFlight += 1
        Task { [weak self] in
            let kept = await ShelfFiles.keep(shots, in: folder, fallback: fallback)
            guard let self else { return }
            defer { saveFinished() }
            guard !kept.isEmpty else { return }
            for k in kept {
                shelf.relocate(k.item.id, to: k.item)
                pasteWatch?.relocate(from: k.old, to: k.item.url)
            }
            // They're no longer Pasteboard files: nothing to keep for the clipboard.
            let moved = Set(kept.map(\.old.path))
            if let files = clipboardFiles, files.paths.contains(where: moved.contains) {
                let rest = files.paths.filter { !moved.contains($0) }
                clipboardFiles = rest.isEmpty ? nil : PasteboardShots.ClipboardFiles(changeCount: files.changeCount, paths: rest)
                prefs.pasteboardClipboard = clipboardFiles
            }
            if kept.contains(where: \.inUnsaved) {
                didSaveToUnsaved()
                shelf.showToast(UnsavedShots.fallbackToast(saveFolder: folder), isError: true, duration: Self.fallbackToastDuration)
            }
        }
    }

    // MARK: - Pasted

    /// Writes `entries` to the clipboard watched for a paste (`PasteWatch`: promised, kept on this Mac) and returns the
    /// change count. A paste takes the pasted cards off the shelf.
    func writeWatched(_ entries: [PasteWatch.Entry]) -> Int {
        watchAppActivations()
        // Margin in front reads its own clipboard (⌘V in Rename…): keys go to the app in front, so no other app pasted.
        let watch = PasteWatch(readerIsSelf: { NSApp.isActive || NSApp.keyWindow != nil },
                               lastActivation: { [weak self] in self?.lastAppActivation ?? .distantPast })
        watch.onPaste = { [weak self] ids in self?.pasted(ids) }
        let changeCount = watch.write(entries)
        pasteWatch = watch
        return changeCount
    }

    /// Other apps coming to the front, from the first watched write on (never while the option has been off all along).
    private func watchAppActivations() {
        guard appActivationObserver == nil else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != me else { return }
            MainActor.assumeIsolated { self?.lastAppActivation = Date() }
        }
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

    /// After `shelf.restore()`: a file kept because the clipboard holds it, with no card, goes once the clipboard moves on,
    /// but not before the launch's cleanup would (`PasteboardShots.launchCleanupDelay`): it may have just been pasted.
    func retainClipboardFilesWithoutCards() {
        guard let files = clipboardFiles else { return }
        let onShelf = Set(store.items.map(\.path))
        let notBefore = Date().addingTimeInterval(PasteboardShots.launchCleanupDelay)
        for path in files.paths where !onShelf.contains(path) { retention.add(path, notBefore: notBefore) }
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
        case .dismiss, .close, .trash: .removed
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
