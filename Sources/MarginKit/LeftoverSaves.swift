import CoreGraphics
import Foundation
import ImageIO
import os

/// A save cut off between its temp file and the rename (a crash, a forced quit, the quit's 3 s timeout) leaves a
/// hidden `.margin-<uuid>.tmp` in the folder, often a complete PNG, and its card pointing at a file that never
/// appeared. At launch, before the shelf checks its files, `recover` puts each complete one back: under the name its
/// card is waiting for, so the card stays, or else under a new name from its date. Anything else is deleted.
public enum LeftoverSaves {
    public struct Outcome: Equatable, Sendable {
        public enum Action: Equatable, Sendable {
            /// Renamed to a visible PNG at this URL.
            case recovered(URL)
            /// Not a complete PNG (the write itself was cut short): removed.
            case deleted
        }

        public let temp: URL
        public let action: Action
        /// The card whose file it became.
        public let itemID: UUID?

        public init(temp: URL, action: Action, itemID: UUID?) {
            self.temp = temp
            self.action = action
            self.itemID = itemID
        }
    }

    private static let log = Logger(subsystem: "io.github.jenish-shobhit.margin", category: "LeftoverSaves")

    /// How long after a card's capture its temp file can have been written (encoding, a slow volume, the quit timeout).
    static let matchWindow: ClosedRange<TimeInterval> = -2...120

    /// Recovers or removes the leftover temp files in `folder`. Blocking: call off the main thread (the save folder
    /// may be on the Desktop, or on a slow volume).
    /// - Parameters:
    ///   - items: the shelf. One without a bookmark whose file doesn't exist never finished saving: a complete PNG
    ///     of its pixel size, written within `matchWindow` of its capture, goes to its path.
    ///   - writtenBefore: only temp files last written before this are touched. At launch that's the launch itself:
    ///     a file this copy writes can't be older, and no other copy is running.
    public static func recover(
        in folder: URL, items: [ShelfItem], writtenBefore: Date, timeZone: TimeZone = .current
    ) -> [Outcome] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .creationDateKey, .contentModificationDateKey]
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        let leftovers = names.filter(PNGWriter.isTempName).compactMap { name -> (url: URL, created: Date)? in
            let url = folder.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified < writtenBefore
            else { return nil }
            return (url, values.creationDate ?? modified)
        }.sorted { $0.created < $1.created }
        guard !leftovers.isEmpty else { return [] }

        var waiting = items.filter { item in
            item.bookmark == nil && ShelfItem.samePath(item.url.deletingLastPathComponent(), folder)
                && !FileManager.default.fileExists(atPath: item.path)
        }
        var outcomes: [Outcome] = []
        for (temp, created) in leftovers {
            guard let size = completePNGSize(at: temp) else {
                if unlink(temp.path) == 0 {
                    log.notice("Removed an incomplete leftover save: \(temp.lastPathComponent, privacy: .public)")
                    outcomes.append(Outcome(temp: temp, action: .deleted, itemID: nil))
                }
                continue
            }
            // A save is written after its capture: the nearest card captured before the file was written, if any.
            let rank = { (item: ShelfItem) in
                let offset = created.timeIntervalSince(item.createdAt)
                return (offset < 0 ? 1 : 0, abs(offset))
            }
            let card = waiting.enumerated()
                .filter { $0.element.pixelSize == size && matchWindow.contains(created.timeIntervalSince($0.element.createdAt)) }
                .min { rank($0.element) < rank($1.element) }
            do {
                let url: URL
                if let card {
                    waiting.remove(at: card.offset)
                    url = try place(temp, at: card.element.url, orNameFor: card.element.createdAt, in: folder, timeZone: timeZone)
                } else {
                    url = try PNGWriter.moveUnique(from: temp, in: folder, date: created, timeZone: timeZone)
                }
                log.notice("Recovered a leftover save as \(url.lastPathComponent, privacy: .public)\(card == nil ? "" : " (its card stays)", privacy: .public)")
                outcomes.append(Outcome(temp: temp, action: .recovered(url), itemID: card?.element.id))
            } catch {
                log.error("Couldn't recover \(temp.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return outcomes
    }

    /// Renames `temp` to `url`, or, if that name was taken since, to the next free name for `date`.
    private static func place(_ temp: URL, at url: URL, orNameFor date: Date, in folder: URL, timeZone: TimeZone) throws -> URL {
        do {
            try PNGWriter.moveExclusively(from: temp, to: url)
            return url
        } catch let error as POSIXError where error.code == .EEXIST {
            return try PNGWriter.moveUnique(from: temp, in: folder, date: date, timeZone: timeZone)
        }
    }

    /// The pixel size of the PNG at `url` if it's complete: it ends with its `IEND` chunk (a write cut short doesn't),
    /// and ImageIO reads it as complete and can make an image of it.
    static func completePNGSize(at url: URL) -> CGSize? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let length = try? handle.seekToEnd(), length > 12, (try? handle.seek(toOffset: length - 12)) != nil,
              let tail = try? handle.read(upToCount: 12), tail == pngEnd
        else { return nil }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetType(source) as String? == "public.png",
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              CGImageSourceCreateImageAtIndex(source, 0, options) != nil
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// A PNG's last 12 bytes: the empty `IEND` chunk and its CRC.
    private static let pngEnd = Data([0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
}
