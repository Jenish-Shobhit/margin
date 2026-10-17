import Darwin
import Foundation
import ImageIO
import MarginKit
import os

/// The shelf's disk access, which always runs off the main thread. The first access to ~/Desktop can block
/// on the privacy prompt, and a folder Margin may not read must never empty the shelf: only a file that's
/// definitely gone (ENOENT on a mounted volume, or moved to the Trash) counts as missing.
enum ShelfFiles {
    enum Status: Sendable, Equatable {
        /// The file is there. The item follows a file moved in Finder and has a fresh bookmark.
        case found(ShelfItem)
        /// Definitely gone: no such file on its (mounted) volume, or it's in the Trash.
        case gone
        /// Couldn't tell (access denied, privacy prompt refused, I/O error, volume not mounted). Keep the item.
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
        await check(items) { _, url in work(url) }
    }

    /// `check`, with each item handed to `work` along with its file (a screenshot and a recording are copied differently).
    static func check<Value: Sendable>(
        _ items: [ShelfItem], then work: @escaping @Sendable (ShelfItem, URL) -> Value?
    ) async -> [Result<Value>] {
        await Task.detached(priority: .userInitiated) {
            items.map { item in
                let status = status(of: item)
                let url: URL? = switch status {
                case .found(let fresh): fresh.url
                case .unknown: item.url
                case .gone: nil
                }
                return Result(item: item, status: status, value: url.flatMap { work(item, $0) })
            }
        }.value
    }

    /// `LeftoverSaves.recover` in each folder, once each, off the main thread.
    static func recoverLeftovers(in folders: [URL], items: [ShelfItem], writtenBefore: Date) async -> [LeftoverSaves.Outcome] {
        await Task.detached(priority: .userInitiated) {
            var seen = Set<String>()
            return folders.filter { seen.insert($0.standardizedFileURL.path).inserted }.flatMap {
                LeftoverSaves.recover(in: $0, items: items, writtenBefore: writtenBefore)
            }
        }.value
    }

    /// `PasteboardShots.cleanUp` of the Pasteboard folder, off the main thread, and what it deleted in the log.
    static func cleanUpPasteboard(items: [ShelfItem], keeping: Set<String>, writtenBefore: Date) async {
        await Task.detached(priority: .utility) {
            for url in PasteboardShots.cleanUp(items: items, keeping: keeping, writtenBefore: writtenBefore) {
                log.notice("Deleted a pasted or dismissed shot no card holds: \(url.lastPathComponent, privacy: .public)")
            }
        }.value
    }

    /// Deletes Pasteboard files whose time has come (`PasteboardShots.Retention`), off the main thread. Only files in
    /// that folder, whatever is asked, and none while it's a link to another (`PasteboardShots.isRealFolder`).
    static func deletePasteboardFiles(_ paths: [String]) {
        Task.detached(priority: .utility) {
            guard PasteboardShots.isRealFolder() else {
                log.notice("Kept \(paths.count) shot(s): the Pasteboard folder is a link to another folder")
                return
            }
            for path in paths where PasteboardShots.isInFolder(path) {
                let failed = unlink(path) == 0 ? 0 : errno
                let name = URL(fileURLWithPath: path).lastPathComponent
                if failed == 0 {
                    log.notice("Deleted \(name, privacy: .public): pasted or dismissed, and ⌘Z can't bring it back")
                } else if failed != ENOENT {
                    log.error("Couldn't delete \(name, privacy: .public): \(String(cString: strerror(failed)), privacy: .public)")
                }
            }
        }
    }

    private static let log = Logger(subsystem: "io.github.jenish-shobhit.margin", category: "pasteboard")

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
        // On an unplugged disk or a disconnected share, "no such file" only means the volume is away.
        case .absent: return item.isOnUnmountedVolume ? .unknown : .gone
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

    /// Moves a trashed file back, unless something else took its place meanwhile. A file already put back
    /// (Finder's Put Back) counts as restored. Blocking.
    static func untrash(_ t: ShelfUndoStep.Trashed) -> Bool {
        TrashedFile.putBack(t.trashed, to: t.original)
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
