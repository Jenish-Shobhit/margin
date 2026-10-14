import AppKit
import MarginKit
import os

extension AppCoordinator {
    /// What happened to one capture, for the timing log and the DEBUG state dump.
    struct Timings: Sendable {
        var kind: String
        var pixelWidth: Int
        var pixelHeight: Int
        /// `CaptureResult.date` (the release) → `shelf.add` returned.
        var releaseToThumbnailMs: Double
        /// Cost of the downsample alone.
        var thumbnailMs: Double
        var encodeMs: Double?
        var writeMs: Double?
        /// `CaptureResult.date` → PNG renamed into place.
        var releaseToFileMs: Double?
        var savedPath: String?
        var usedFallback = false
        var error: String?
    }

    /// The result of encoding + writing one capture off the main actor.
    struct SaveOutcome: Sendable {
        var data: Data?
        /// The item with its final path and a fresh bookmark (nil when nothing was written).
        var saved: ShelfItem?
        var usedFallback = false
        var error: String?
        var encodeMs: Double?
        var writeMs: Double?
        var finishedAt: Date?
    }

    static let saveFailedMessage = "Couldn't save the screenshot"
    static let fallbackToast = "Saved to Unsaved — folder not writable"
}

/// The moment of release (spec §3): sound, name, thumbnail on the shelf, then one PNG encode off the
/// main actor that feeds both the file and the clipboard. The main actor never touches the save
/// folder: the first access to ~/Desktop can block on the Desktop-folder privacy prompt.
extension AppCoordinator {
    func handleCapture(_ result: CaptureResult) {
        let signpost = Self.signposter.beginInterval("thumbnail")
        // A capture worked, so Screen Recording does: clears a revoked-permission warning.
        screenRecordingWorked()

        // 1. Sound, immediately.
        if prefs.shutterSound { ShutterSound.play() }

        // 2. The predicted file name, reserved in memory so two captures in the same second differ.
        // A name already taken on disk is resolved by the writer, and the shelf hears the final path.
        let reserved = reservedPaths
        let url = FileNamer.uniqueURL(in: prefs.saveFolder, for: result.date) { reserved.contains($0.path) }
        reservedPaths.insert(url.path)

        // 3–4. Thumbnail from the in-memory image, onto the shelf (pending until `itemDidSave`).
        let pixelSize = CGSize(width: result.image.width, height: result.image.height)
        let thumbStart = ContinuousClock.now
        let thumbnail = Self.makeThumbnail(result.image, pixelSize: pixelSize)
        let thumbnailMs = Self.milliseconds(since: thumbStart)
        let item = Self.pendingItem(at: url, createdAt: result.date, pixelSize: pixelSize)
        shelf.add(item, thumbnail: thumbnail, flyInFrom: result.sourceRect, displayID: result.displayID)
        let releaseToThumbnailMs = Date().timeIntervalSince(result.date) * 1000
        Self.signposter.endInterval("thumbnail", signpost)

        let kind = "\(result.kind)"
        Self.timingLog.notice(
            "release→thumbnail \(releaseToThumbnailMs, format: .fixed(precision: 1)) ms (downsample \(thumbnailMs, format: .fixed(precision: 1)) ms, \(result.image.width)×\(result.image.height) \(kind, privacy: .public))")
        let timings = Timings(
            kind: kind, pixelWidth: result.image.width, pixelHeight: result.image.height,
            releaseToThumbnailMs: releaseToThumbnailMs, thumbnailMs: thumbnailMs)
        lastTimings = timings

        captureSequence += 1
        let sequence = captureSequence
        let fallbackFolder = Preferences.fallbackSaveFolder
        savesInFlight += 1 // `finishSave` always runs, on success and failure alike

        // 5. Encode + write off the main actor; the clipboard gets the same bytes once the file is in place.
        Task.detached(priority: .userInitiated) { [weak self] in
            let saveSignpost = Self.signposter.beginInterval("save")
            var outcome = SaveOutcome()
            let encodeStart = ContinuousClock.now
            do {
                outcome.data = try PNGWriter.encode(result.image, scale: result.scale)
            } catch {
                outcome.error = "PNG encode failed"
            }
            outcome.encodeMs = Self.milliseconds(since: encodeStart)

            if let data = outcome.data {
                let writeStart = ContinuousClock.now
                Self.write(data, item: item, date: result.date, fallbackFolder: fallbackFolder, into: &outcome)
                outcome.writeMs = Self.milliseconds(since: writeStart)
                outcome.finishedAt = Date()
            }
            Self.signposter.endInterval("save", saveSignpost)
            await self?.finishSave(
                itemID: item.id, sequence: sequence, releaseDate: result.date, timings: timings, outcome: outcome)
        }
    }

    /// 6. Clipboard + ⌘V mark, once the PNG is renamed into place: the PNG plus the file at its *final* URL
    /// (it can differ from the predicted one: " (2)", the Unsaved folder), so ⌘V in a terminal pastes its
    /// path. If saving failed, the PNG alone. Only the newest capture may overwrite the clipboard, and a
    /// shelf copy since this capture began wins (`shelfDidCopy`).
    private func copyCapture(_ data: Data, fileURL: URL?, itemID: UUID, sequence: Int, releaseDate: Date) {
        guard prefs.copyEachCapture, sequence > lastClipboardSequence else { return }
        lastClipboardSequence = sequence
        let changeCount = ClipboardWriter.write(pngs: [data], fileURLs: [fileURL])
        let releaseToClipboardMs = Date().timeIntervalSince(releaseDate) * 1000
        Self.timingLog.notice(
            "release→clipboard \(releaseToClipboardMs, format: .fixed(precision: 1)) ms (\(fileURL == nil ? "PNG only" : "PNG + file URL", privacy: .public))")
        if fileURL != nil, shelf.itemIDs.contains(itemID) {
            mark.didWrite(itemID: itemID, changeCount: changeCount)
            shelf.setClipboardMark(itemID)
        } else if mark.itemID != nil {
            // The card was dismissed while saving, or is going away because saving failed: whatever was
            // marked isn't on the clipboard now.
            mark.clear()
            shelf.setClipboardMark(nil)
        }
    }

    private func finishSave(itemID: UUID, sequence: Int, releaseDate: Date, timings: Timings, outcome: SaveOutcome) {
        // Last, so a quit waiting on this save goes ahead only after shelf.json has the final path.
        defer { saveFinished() }
        // First, so the clipboard isn't kept waiting by the store and the shelf.
        if let data = outcome.data {
            copyCapture(data, fileURL: outcome.saved?.url, itemID: itemID, sequence: sequence, releaseDate: releaseDate)
        }
        var timings = timings
        timings.encodeMs = outcome.encodeMs
        timings.writeMs = outcome.writeMs
        timings.usedFallback = outcome.usedFallback
        timings.error = outcome.error

        guard let saved = outcome.saved else {
            lastTimings = timings
            Self.log.error("Capture not saved: \(outcome.error ?? "unknown error", privacy: .public)")
            // The PNG may be on the clipboard now; the mark mustn't point at a card that's going away.
            if mark.itemID == itemID {
                mark.clear()
                shelf.setClipboardMark(nil)
            }
            shelf.itemSaveFailed(itemID, message: Self.saveFailedMessage)
            return
        }

        lastSavedPath = saved.path
        let releaseToFileMs = (outcome.finishedAt ?? Date()).timeIntervalSince(releaseDate) * 1000
        timings.releaseToFileMs = releaseToFileMs
        timings.savedPath = saved.path
        lastTimings = timings
        Self.timingLog.notice(
            "release→file \(releaseToFileMs, format: .fixed(precision: 1)) ms (encode \(outcome.encodeMs ?? 0, format: .fixed(precision: 1)) ms, write \(outcome.writeMs ?? 0, format: .fixed(precision: 1)) ms) \(saved.url.lastPathComponent, privacy: .public)")

        // The file exists: give the store the final path and bookmark, then tell the shelf it's real.
        // The shelf hears about it even if the card was dismissed while pending: it points that card's
        // undo record at the real file (the predicted name may have been taken) and stops treating it
        // as pending. Only an item still on the shelf is written to the store.
        if var current = store.items.first(where: { $0.id == itemID }) {
            current.path = saved.path
            current.bookmark = saved.bookmark
            store.update(current)
            shelf.itemDidSave(current)
        } else {
            shelf.itemDidSave(saved)
        }
        if outcome.usedFallback {
            Self.log.error(
                "Saved to Unsaved — folder not writable (\(outcome.error ?? "", privacy: .public)): \(saved.path, privacy: .public)")
            shelf.showToast(Self.fallbackToast)
        }

        // 7. Bookkeeping.
        prefs.completedCaptures += 1
        FirstRunWindowController.shared.captureSucceeded()
    }

    /// `ShelfItem.init(url:…)` checks the disk for the file (to bookmark it), and the file doesn't exist
    /// yet. Build it from a harmless placeholder so the main actor never touches the save folder; it gets
    /// its real bookmark (`refreshBookmark()`) once the PNG is written.
    private static func pendingItem(at url: URL, createdAt: Date, pixelSize: CGSize) -> ShelfItem {
        let placeholder = URL(fileURLWithPath: "/var/empty/margin-pending.png")
        var item = ShelfItem(url: placeholder, createdAt: createdAt, pixelSize: pixelSize)
        item.path = url.path
        item.bookmark = nil
        return item
    }

    // MARK: - Off-main helpers

    /// Writes to the predicted name (keeps names stable when several captures share a second), moving
    /// to the next free name if it's taken on disk, and falls back to the Unsaved folder when the save
    /// folder can't be written. On success `outcome.saved` has the final path and a fresh bookmark.
    nonisolated static func write(
        _ data: Data, item: ShelfItem, date: Date, fallbackFolder: URL, into outcome: inout SaveOutcome
    ) {
        let predicted = item.url
        do {
            let url: URL
            do {
                try PNGWriter.writeAtomically(data, to: predicted)
                url = predicted
            } catch let error as POSIXError where error.code == .EEXIST {
                url = try PNGWriter.writeUnique(data, in: predicted.deletingLastPathComponent(), date: date)
            }
            outcome.saved = savedItem(item, at: url)
            return
        } catch {
            outcome.error = "\(predicted.deletingLastPathComponent().path): \(error.localizedDescription)"
        }
        do {
            let url = try PNGWriter.writeUnique(data, in: fallbackFolder, date: date)
            outcome.saved = savedItem(item, at: url)
            outcome.usedFallback = true
        } catch {
            outcome.error = (outcome.error ?? "") + "; Unsaved: \(error.localizedDescription)"
        }
    }

    private nonisolated static func savedItem(_ item: ShelfItem, at url: URL) -> ShelfItem {
        var saved = item
        saved.path = url.path
        saved.refreshBookmark()
        return saved
    }

    /// Downsampled to cover the shelf card at 2× (aspect-fill), from the in-memory image.
    nonisolated static func makeThumbnail(_ image: CGImage, pixelSize: CGSize) -> CGImage {
        let w = pixelSize.width, h = pixelSize.height
        guard w > 0, h > 0 else { return image }
        let cardHeight = ShelfLayout.cardHeight(forPixelSize: pixelSize)
        let scale = min(1, max(ShelfLayout.cardWidth * 2 / w, cardHeight * 2 / h))
        guard scale < 0.9 else { return image }
        let tw = max(1, Int((w * scale).rounded())), th = max(1, Int((h * scale).rounded()))

        var space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if space.model != .rgb || !space.supportsOutput { space = CGColorSpace(name: CGColorSpace.sRGB)! }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage() ?? image
    }

    nonisolated static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}
