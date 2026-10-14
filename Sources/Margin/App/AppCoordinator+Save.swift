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
        var url: URL?
        var bookmark: Data?
        var usedFallback = false
        var error: String?
        var encodeMs: Double?
        var writeMs: Double?
        var finishedAt: Date?
    }
}

/// The moment of release (spec §3): sound, name, thumbnail on the shelf, then one PNG encode
/// off the main actor that feeds both the file and the clipboard.
extension AppCoordinator {
    /// `~/Library/Application Support/Margin/Unsaved/`, used when the save folder can't be written.
    nonisolated static var unsavedFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Margin/Unsaved", isDirectory: true)
    }

    func handleCapture(_ result: CaptureResult) {
        let signpost = Self.signposter.beginInterval("thumbnail")

        // 1. Sound, immediately.
        if prefs.shutterSound { ShutterSound.play() }

        // 2. The file name, reserved now so the shelf item can point at it.
        let pending = pendingPaths
        let url = FileNamer.uniqueURL(in: prefs.saveFolder, for: result.date) {
            pending.contains($0.path) || FileManager.default.fileExists(atPath: $0.path)
        }
        pendingPaths.insert(url.path)

        // 3–4. Thumbnail from the in-memory image, onto the shelf.
        let pixelSize = CGSize(width: result.image.width, height: result.image.height)
        let thumbStart = ContinuousClock.now
        let thumbnail = Self.makeThumbnail(result.image, pixelSize: pixelSize)
        let thumbnailMs = Self.milliseconds(since: thumbStart)
        let item = ShelfItem(url: url, createdAt: result.date, pixelSize: pixelSize)
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
        let itemID = item.id
        let fallbackFolder = Self.unsavedFolder

        // 5. Encode + write off the main actor; the clipboard gets the same bytes as soon as they exist.
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
                await self?.copyCapture(data, itemID: itemID, sequence: sequence)
                let writeStart = ContinuousClock.now
                Self.write(data, preferredURL: url, date: result.date, fallbackFolder: fallbackFolder, into: &outcome)
                outcome.writeMs = Self.milliseconds(since: writeStart)
                outcome.finishedAt = Date()
            }
            Self.signposter.endInterval("save", saveSignpost)
            await self?.finishSave(
                itemID: itemID, reservedPath: url.path, releaseDate: result.date, timings: timings, outcome: outcome)
        }
    }

    /// 6. Clipboard + ⌘V mark. Only the newest capture may overwrite the clipboard.
    private func copyCapture(_ data: Data, itemID: UUID, sequence: Int) {
        guard prefs.copyEachCapture, sequence > lastClipboardSequence else { return }
        lastClipboardSequence = sequence
        let changeCount = ClipboardWriter.write(pngs: [data])
        if shelf.itemIDs.contains(itemID) {
            mark.didWrite(itemID: itemID, changeCount: changeCount)
            shelf.setClipboardMark(itemID)
        } else if mark.observe(changeCount: changeCount) {
            // The card was dismissed before its PNG was ready; the old mark is stale now.
            shelf.setClipboardMark(nil)
        }
    }

    private func finishSave(
        itemID: UUID, reservedPath: String, releaseDate: Date, timings: Timings, outcome: SaveOutcome
    ) {
        pendingPaths.remove(reservedPath)

        var timings = timings
        timings.encodeMs = outcome.encodeMs
        timings.writeMs = outcome.writeMs
        timings.usedFallback = outcome.usedFallback
        timings.error = outcome.error

        guard let savedURL = outcome.url else {
            Self.log.error("Capture not saved: \(outcome.error ?? "unknown error", privacy: .public)")
            // TODO(contract): ShelfControlling has no way to drop the card or show an error toast.
            lastTimings = timings
            return
        }

        lastSavedPath = savedURL.path
        let releaseToFileMs = (outcome.finishedAt ?? Date()).timeIntervalSince(releaseDate) * 1000
        timings.releaseToFileMs = releaseToFileMs
        timings.savedPath = savedURL.path
        lastTimings = timings
        Self.timingLog.notice(
            "release→file \(releaseToFileMs, format: .fixed(precision: 1)) ms (encode \(outcome.encodeMs ?? 0, format: .fixed(precision: 1)) ms, write \(outcome.writeMs ?? 0, format: .fixed(precision: 1)) ms) \(savedURL.lastPathComponent, privacy: .public)")

        if outcome.usedFallback {
            // TODO(contract): spec §3 wants the shelf toast "Saved to Unsaved — folder not writable",
            // but ShelfControlling has no toast API yet.
            Self.log.error(
                "Saved to Unsaved — folder not writable (\(outcome.error ?? "", privacy: .public)): \(savedURL.path, privacy: .public)")
        }

        // Now the file exists: point the item at its final path and give it a bookmark.
        if var item = store.items.first(where: { $0.id == itemID }) {
            item.path = savedURL.path
            item.bookmark = outcome.bookmark ?? item.bookmark
            store.update(item)
        }

        // 7. Bookkeeping.
        prefs.completedCaptures += 1
        FirstRunWindowController.shared.captureSucceeded()
    }

    // MARK: - Off-main helpers

    /// Writes into the preferred folder (a fresh ` (n)` name if another capture took this one),
    /// falling back to the Unsaved folder when the preferred folder can't be written.
    nonisolated static func write(
        _ data: Data, preferredURL: URL, date: Date, fallbackFolder: URL, into outcome: inout SaveOutcome
    ) {
        do {
            let url = try writeUnique(data, first: preferredURL, date: date)
            outcome.url = url
            outcome.bookmark = try? url.bookmarkData()
            return
        } catch {
            outcome.error = "\(preferredURL.deletingLastPathComponent().path): \(error.localizedDescription)"
        }
        do {
            let first = FileNamer.uniqueURL(in: fallbackFolder, for: date)
            let url = try writeUnique(data, first: first, date: date)
            outcome.url = url
            outcome.bookmark = try? url.bookmarkData()
            outcome.usedFallback = true
        } catch {
            outcome.error = (outcome.error ?? "") + "; Unsaved: \(error.localizedDescription)"
        }
    }

    private nonisolated static func writeUnique(_ data: Data, first: URL, date: Date) throws -> URL {
        var url = first
        for _ in 0..<20 {
            do {
                try PNGWriter.writeAtomically(data, to: url)
                return url
            } catch let error as POSIXError where error.code == .EEXIST {
                url = FileNamer.uniqueURL(in: first.deletingLastPathComponent(), for: date)
            }
        }
        throw POSIXError(.EEXIST)
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
