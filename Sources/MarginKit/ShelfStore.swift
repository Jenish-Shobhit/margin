import CoreGraphics
import Foundation
import os

public struct ShelfItem: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var path: String
    /// Bookmark so a file moved in Finder is followed. Nil until the file exists (see `refreshBookmark()`).
    public var bookmark: Data?
    public var createdAt: Date
    public var pixelWidth: Int
    public var pixelHeight: Int

    public var url: URL { URL(fileURLWithPath: path) }
    public var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }

    /// The bookmark is only created if the file already exists. If you create the item before the PNG is
    /// renamed into place, call `refreshBookmark()` afterwards (`ShelfStore.pruneMissing()` also fills it in).
    public init(id: UUID = UUID(), url: URL, createdAt: Date, pixelSize: CGSize) {
        self.id = id
        self.path = url.path
        self.bookmark = Self.makeBookmark(for: url)
        self.createdAt = createdAt
        self.pixelWidth = Int(pixelSize.width)
        self.pixelHeight = Int(pixelSize.height)
    }

    /// Re-creates the bookmark from `path`. Call once the file exists on disk (or after renaming it).
    /// Returns false, and keeps the old bookmark, if the file isn't there.
    @discardableResult
    public mutating func refreshBookmark() -> Bool {
        guard let data = Self.makeBookmark(for: url) else { return false }
        bookmark = data
        return true
    }

    /// Finds the file: follows the bookmark first (so a file moved or renamed in Finder is found), then
    /// falls back to `path`. Updates `path` and `bookmark` when the file moved, and fills in a missing
    /// bookmark. Returns nil when the file is gone or in the Trash.
    public mutating func resolveFile() -> URL? {
        if let bookmark, let resolved = Self.resolve(bookmark), FileManager.default.fileExists(atPath: resolved.url.path) {
            let url = resolved.url
            if Self.isInTrash(url) { return nil }
            if resolved.stale || !Self.samePath(url, self.url) {
                path = url.path
                refreshBookmark()
            }
            return url
        }
        let url = self.url
        guard FileManager.default.fileExists(atPath: url.path), !Self.isInTrash(url) else { return nil }
        refreshBookmark()
        return url
    }

    /// True for anything inside a Trash folder: `~/.Trash`, `/Volumes/X/.Trashes/501`, iCloud Drive's `.Trash`.
    public static func isInTrash(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    static func makeBookmark(for url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? url.bookmarkData()
    }

    static func resolve(_ bookmark: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }

    /// Compares paths after resolving symlinks (`/var` vs `/private/var`).
    static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }
}

extension ShelfItem {
    /// True when the file's volume isn't mounted: an external disk that's unplugged, a network share that's
    /// disconnected. "No such file" then says nothing about the file, which comes back with its volume, so the
    /// item must stay. Blocking: it looks at the file system.
    public var isOnUnmountedVolume: Bool {
        Self.volumeRoots(path: path, bookmark: bookmark).contains { !Self.isMountPoint($0) }
    }

    /// Where the file's volume is (or was) mounted, other than the startup disk: the volume the bookmark
    /// recorded (it keeps it while the volume is away), and `/Volumes/<name>` for a path under `/Volumes`.
    static func volumeRoots(path: String, bookmark: Data?) -> [String] {
        var roots: [String] = []
        if let bookmark, let volume = URL.resourceValues(forKeys: [.volumeURLKey], fromBookmarkData: bookmark)?.volume {
            roots.append(volume.path)
        }
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        if parts.count > 2, parts[1] == "Volumes" { roots.append("/Volumes/" + parts[2]) }
        return roots.filter { $0 != "/" }
    }

    /// True when a volume is mounted right at `path` (after symlinks: `/Volumes/Macintosh HD` is `/`).
    /// A missing folder, or a leftover empty one, isn't a mount point.
    static func isMountPoint(_ path: String) -> Bool {
        guard let real = realpath(path, nil) else { return false }
        defer { free(real) }
        var fs = statfs()
        guard statfs(real, &fs) == 0 else { return false }
        let mountedOn = withUnsafeBytes(of: &fs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return mountedOn == String(cString: real)
    }
}

/// One element of a JSON array, decoded on its own: a bad element doesn't fail the whole array.
private struct Lenient<Value: Decodable>: Decodable {
    let result: Result<Value, Error>

    init(from decoder: Decoder) throws {
        result = Result { try decoder.singleValueContainer().decode(Value.self) }
    }
}

/// Ordered shelf contents (oldest → newest), persisted as JSON.
@MainActor
public final class ShelfStore {
    public struct Removal: Equatable, Sendable {
        public let index: Int
        public let item: ShelfItem

        public init(index: Int, item: ShelfItem) {
            self.index = index
            self.item = item
        }
    }

    private static let log = Logger(subsystem: "io.github.jenish-shobhit.margin", category: "ShelfStore")

    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Margin/shelf.json")
    }

    public let fileURL: URL
    public private(set) var items: [ShelfItem] = []

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Replaces `items` with the file's contents (empty if the file is missing). Items are read one by one: one
    /// that can't be (damaged, or written by a newer Margin) is skipped, not the whole shelf. A file with any
    /// unreadable part is first set aside (`setAside`) with everything in it, so the next save can't overwrite
    /// it, and what could be read is saved in its place.
    public func load() {
        items = []
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return
        } catch {
            Self.log.error("shelf.json unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
            setAside()
            return
        }
        let entries: [Lenient<ShelfItem>]
        do {
            entries = try JSONDecoder().decode([Lenient<ShelfItem>].self, from: data)
        } catch {
            Self.log.error("shelf.json isn't a list of items, starting empty: \(error.localizedDescription, privacy: .public)")
            setAside()
            return
        }
        var skipped = 0
        for (index, entry) in entries.enumerated() {
            switch entry.result {
            case .success(let item):
                items.append(item)
            case .failure(let error):
                skipped += 1
                Self.log.error("shelf.json item \(index) skipped: \(String(describing: error), privacy: .public)")
            }
        }
        if skipped > 0, setAside(), !items.isEmpty { save() }
    }

    /// Moves shelf.json out of the way, to `shelf.json.bad`, or `shelf.json.bad 2`, `3`… if an earlier one is
    /// still there (never replacing it). Returns false if it couldn't be moved.
    @discardableResult
    private func setAside() -> Bool {
        for n in 1...100 {
            let name = fileURL.lastPathComponent + (n == 1 ? ".bad" : ".bad \(n)")
            let url = fileURL.deletingLastPathComponent().appendingPathComponent(name)
            do {
                try PNGWriter.moveExclusively(from: fileURL, to: url)
                Self.log.notice("shelf.json set aside as \(name, privacy: .public)")
                return true
            } catch let error as POSIXError where error.code == .EEXIST {
                continue
            } catch {
                Self.log.error("shelf.json couldn't be set aside: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        return false
    }

    /// Called after every save with how long it took (ms) and the file's size, for the timing log.
    public var didSave: ((_ milliseconds: Double, _ bytes: Int) -> Void)?

    public func save() {
        do {
            let start = ContinuousClock.now
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
            if let didSave {
                let d = ContinuousClock.now - start
                didSave(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15, data.count)
            }
        } catch {
            Self.log.error("shelf.json not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func append(_ item: ShelfItem) {
        items.append(item)
        save()
    }

    public func update(_ item: ShelfItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i] = item
        save()
    }

    /// Removes the given items; returns what's needed to undo, in ascending index order.
    @discardableResult
    public func remove(ids: Set<UUID>) -> [Removal] {
        let removals = items.enumerated().filter { ids.contains($0.element.id) }.map { Removal(index: $0.offset, item: $0.element) }
        guard !removals.isEmpty else { return [] }
        items.removeAll { ids.contains($0.id) }
        save()
        return removals
    }

    @discardableResult
    public func removeAll() -> [Removal] { remove(ids: Set(items.map(\.id))) }

    /// Undo of `remove`: re-inserts at the original indices. Items already on the shelf are skipped.
    public func restore(_ removals: [Removal]) {
        var present = Set(items.map(\.id))
        for r in removals.sorted(by: { $0.index < $1.index }) where !present.contains(r.item.id) {
            items.insert(r.item, at: min(max(r.index, 0), items.count))
            present.insert(r.item.id)
        }
        save()
    }

    /// Follows moved files via bookmarks, fills in missing bookmarks, and drops items whose file is gone
    /// or in the Trash. Returns the dropped items.
    @discardableResult
    public func pruneMissing() -> [ShelfItem] {
        var dropped: [ShelfItem] = []
        var kept: [ShelfItem] = []
        for var item in items {
            if item.resolveFile() != nil { kept.append(item) } else { dropped.append(item) }
        }
        if kept != items { items = kept; save() }
        return dropped
    }
}
