import Darwin
import Foundation
import ImageIO
import MarginKit

/// The shelf's disk access, which always runs off the main thread. The first access to ~/Desktop can block
/// on the privacy prompt, and a folder Margin may not read must never empty the shelf: only a file that's
/// definitely gone (ENOENT, or moved to the Trash) counts as missing.
enum ShelfFiles {
    enum Status: Sendable, Equatable {
        /// The file is there. The item follows a file moved in Finder and has a fresh bookmark.
        case found(ShelfItem)
        /// Definitely gone: no such file, or it's in the Trash.
        case gone
        /// Couldn't tell (access denied, privacy prompt refused, I/O error). Keep the item.
        case unknown

        var isGone: Bool { self == .gone }
    }

    /// One item's check, plus what `work` made of its file.
    struct Result<Value: Sendable>: Sendable {
        /// The item as it was when the check started.
        let item: ShelfItem
        let status: Status
        let value: Value?
    }

    /// Checks each item's file on a background thread, then runs `work` there on the file found (or, when
    /// access is unclear, on the stored path, since other apps may still reach it). Results keep `items`' order.
    static func check<Value: Sendable>(
        _ items: [ShelfItem], then work: @escaping @Sendable (URL) -> Value?
    ) async -> [Result<Value>] {
        await Task.detached(priority: .userInitiated) {
            items.map { item in
                let status = status(of: item)
                let url: URL? = switch status {
                case .found(let fresh): fresh.url
                case .unknown: item.url
                case .gone: nil
                }
                return Result(item: item, status: status, value: url.flatMap(work))
            }
        }.value
    }

    /// Statuses only (prune, existence checks).
    static func statuses(_ items: [ShelfItem]) async -> [Result<Bool>] {
        await check(items) { _ in true }
    }

    /// Blocking: call off the main thread only.
    static func status(of item: ShelfItem) -> Status {
        var fresh = item
        if fresh.resolveFile() != nil { return .found(fresh) }
        // `resolveFile` can't tell "gone" from "not allowed to look", so look again and keep the errno.
        if let bookmark = item.bookmark, let target = resolve(bookmark) {
            switch probe(target) {
            case .exists: return ShelfItem.isInTrash(target) ? .gone : .unknown
            case .absent: break
            case .unknown: return .unknown
            }
        }
        switch probe(item.url) {
        case .exists: return ShelfItem.isInTrash(item.url) ? .gone : .unknown
        case .absent: return .gone
        case .unknown: return .unknown
        }
    }

    /// The file's PNG bytes (re-encoded if the file isn't a PNG any more). Blocking.
    static func pngData(at url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return try? PNGWriter.encode(image, scale: 1)
    }

    enum RenameOutcome: Sendable {
        case renamed(ShelfItem), unchanged, exists(String), gone, failed
    }

    /// Renames the item's file in its folder, keeping the extension. Blocking.
    static func rename(_ item: ShelfItem, to rawName: String) -> RenameOutcome {
        let status = status(of: item)
        guard case .found(var fresh) = status else { return status.isGone ? .gone : .failed }
        let url = fresh.url
        var name = rawName
        let ext = url.pathExtension
        if !ext.isEmpty, (name as NSString).pathExtension.lowercased() != ext.lowercased() { name += "." + ext }
        let dest = url.deletingLastPathComponent().appendingPathComponent(name)
        guard dest.path != url.path else { return .unchanged }
        let caseOnly = dest.path.lowercased() == url.path.lowercased()
        if !caseOnly, FileManager.default.fileExists(atPath: dest.path) { return .exists(name) }
        do {
            try FileManager.default.moveItem(at: url, to: dest)
        } catch {
            return .failed
        }
        fresh.path = dest.path
        fresh.refreshBookmark()
        return .renamed(fresh)
    }

    /// Moves the file to the Trash and says where it went. Blocking.
    static func trash(_ url: URL) -> ShelfUndoStep.Trashed? {
        var result: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        } catch {
            return nil
        }
        return result.map { .init(original: url, trashed: $0 as URL) }
    }

    /// Moves a trashed file back, unless something else took its place meanwhile. Blocking.
    static func untrash(_ t: ShelfUndoStep.Trashed) -> Bool {
        guard !FileManager.default.fileExists(atPath: t.original.path) else { return false }
        return (try? FileManager.default.moveItem(at: t.trashed, to: t.original)) != nil
    }

    /// True when something exists at `path` (blocking). Unreadable counts as not there.
    static func exists(_ path: String) -> Bool {
        probe(URL(fileURLWithPath: path)) == .exists
    }

    private enum Probe { case exists, absent, unknown }

    private static func probe(_ url: URL) -> Probe {
        var st = stat()
        if stat(url.path, &st) == 0 { return .exists }
        return errno == ENOENT || errno == ENOTDIR ? .absent : .unknown
    }

    private static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
