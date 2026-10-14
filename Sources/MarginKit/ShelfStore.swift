import CoreGraphics
import Foundation

public struct ShelfItem: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var path: String
    /// Bookmark so a file moved in Finder is followed.
    public var bookmark: Data?
    public var createdAt: Date
    public var pixelWidth: Int
    public var pixelHeight: Int

    public var url: URL { URL(fileURLWithPath: path) }
    public var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }

    public init(id: UUID = UUID(), url: URL, createdAt: Date, pixelSize: CGSize) {
        self.id = id
        self.path = url.path
        self.bookmark = try? url.bookmarkData()
        self.createdAt = createdAt
        self.pixelWidth = Int(pixelSize.width)
        self.pixelHeight = Int(pixelSize.height)
    }
}

/// Ordered shelf contents (oldest → newest), persisted as JSON.
@MainActor
public final class ShelfStore {
    public struct Removal: Equatable, Sendable {
        public let index: Int
        public let item: ShelfItem
    }

    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Margin/shelf.json")
    }

    public let fileURL: URL
    public private(set) var items: [ShelfItem] = []

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) else { items = []; return }
        items = decoded
    }

    public func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: fileURL, options: .atomic) }
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
        items.removeAll { ids.contains($0.id) }
        save()
        return removals
    }

    @discardableResult
    public func removeAll() -> [Removal] { remove(ids: Set(items.map(\.id))) }

    /// Undo of `remove`: re-inserts at the original indices.
    public func restore(_ removals: [Removal]) {
        for r in removals.sorted(by: { $0.index < $1.index }) {
            items.insert(r.item, at: min(r.index, items.count))
        }
        save()
    }

    /// Follows moved files via bookmarks and drops items whose file is gone (or in the Trash). Returns dropped items.
    @discardableResult
    public func pruneMissing() -> [ShelfItem] {
        var dropped: [ShelfItem] = []
        var kept: [ShelfItem] = []
        for var item in items {
            if let bookmark = item.bookmark {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], bookmarkDataIsStale: &stale),
                   FileManager.default.fileExists(atPath: url.path), !url.path.contains("/.Trash/") {
                    if url.path != item.path || stale {
                        item.path = url.path
                        item.bookmark = (try? url.bookmarkData()) ?? item.bookmark
                    }
                    kept.append(item)
                    continue
                }
            } else if FileManager.default.fileExists(atPath: item.path) {
                kept.append(item)
                continue
            }
            dropped.append(item)
        }
        if kept != items { items = kept; save() }
        return dropped
    }
}
