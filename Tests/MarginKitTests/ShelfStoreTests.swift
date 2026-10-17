import CoreGraphics
import Foundation
import MarginKit
import Testing

@MainActor @Suite struct ShelfStoreTests {
    func makeStore(_ dir: TempDir) -> ShelfStore {
        ShelfStore(fileURL: dir.url.appendingPathComponent("state/shelf.json"))
    }

    func samePath(_ a: String, _ b: URL) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }

    @Test func jsonRoundTrip() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        let date = Date(timeIntervalSince1970: 1_791_999_737.25)
        let a = ShelfItem(url: try dir.file("a.png"), createdAt: date, pixelSize: CGSize(width: 3024, height: 1964))
        let b = ShelfItem(url: try dir.file("b.png"), createdAt: date.addingTimeInterval(5), pixelSize: CGSize(width: 80, height: 60))
        let c = ShelfItem(url: dir.url.appendingPathComponent("not-yet.png"), createdAt: date, pixelSize: CGSize(width: 1, height: 1))
        store.append(a)
        store.append(b)
        store.append(c)

        let reloaded = makeStore(dir)
        reloaded.load()
        #expect(reloaded.items == [a, b, c])
        #expect(reloaded.items[0].pixelSize == CGSize(width: 3024, height: 1964))
        #expect(reloaded.items[1].createdAt == date.addingTimeInterval(5))
        #expect(reloaded.items[0].bookmark != nil)
        #expect(reloaded.items[2].bookmark == nil)
    }

    @Test func recordingsRoundTripWithTheirKindAndDuration() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        let date = Date(timeIntervalSince1970: 1_791_999_737)
        let shot = ShelfItem(url: try dir.file("a.png"), createdAt: date, pixelSize: CGSize(width: 30, height: 20))
        let movie = ShelfItem(url: try dir.file("b.mp4"), createdAt: date, pixelSize: CGSize(width: 2940, height: 1912),
                              kind: .recording, duration: 12.48)
        #expect(shot.kind == .screenshot && shot.duration == nil)
        store.append(shot)
        store.append(movie)
        let reloaded = makeStore(dir)
        reloaded.load()
        #expect(reloaded.items == [shot, movie])
        #expect(reloaded.items[1].kind == .recording)
        #expect(reloaded.items[1].duration == 12.48)
        // A screenshot has no duration in the file.
        let list = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [[String: Any]])
        #expect(list[0]["kind"] as? String == "screenshot" && list[0]["duration"] == nil)
        #expect(list[1]["kind"] as? String == "recording")
    }

    @Test func itemsFromBeforeRecordingsAreScreenshots() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // shelf.json as 0.0.18 wrote it: no kind, no duration.
        let id = UUID()
        let json = """
            [{"id":"\(id.uuidString)","path":"/tmp/Screenshot 2026-10-14 at 17.42.17.png","createdAt":813692537,\
            "pixelWidth":3024,"pixelHeight":1964}]
            """
        try Data(json.utf8).write(to: store.fileURL)
        store.load()
        #expect(store.items.count == 1)
        #expect(store.items.first?.id == id)
        #expect(store.items.first?.kind == .screenshot)
        #expect(store.items.first?.duration == nil)
        #expect(store.items.first?.pixelSize == CGSize(width: 3024, height: 1964))
        // Nothing unreadable, so nothing set aside.
        #expect(stateFiles(dir) == ["shelf.json"])
    }

    @Test func aKindFromANewerMarginIsSkipped() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        let date = Date(timeIntervalSince1970: 1_791_999_737)
        let a = ShelfItem(url: try dir.file("a.png"), createdAt: date, pixelSize: CGSize(width: 30, height: 20))
        store.append(a)
        var list = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [Any])
        var gif = try #require(list[0] as? [String: Any])
        gif["id"] = UUID().uuidString
        gif["kind"] = "gif"
        list.append(gif)
        try JSONSerialization.data(withJSONObject: list).write(to: store.fileURL)
        store.load()
        #expect(store.items == [a])
        #expect(stateFiles(dir) == ["shelf.json", "shelf.json.bad"])
    }

    @Test func loadMissingFileIsEmpty() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        store.load()
        #expect(store.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(stateFiles(dir).isEmpty)
    }

    /// The files next to shelf.json.
    func stateFiles(_ dir: TempDir) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.url.appendingPathComponent("state").path))?.sorted() ?? []
    }

    func stateFile(_ dir: TempDir, _ name: String) throws -> Data {
        try Data(contentsOf: dir.url.appendingPathComponent("state/\(name)"))
    }

    @Test func corruptFileIsSetAsideNeverOverwritten() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        store.append(ShelfItem(url: try dir.file("a.png"), createdAt: .now, pixelSize: CGSize(width: 1, height: 1)))
        let first = Data("{ not json".utf8)
        try first.write(to: store.fileURL)
        store.load()
        #expect(store.items.isEmpty)
        #expect(stateFiles(dir) == ["shelf.json.bad"])
        #expect(try stateFile(dir, "shelf.json.bad") == first)

        // The next change starts a new shelf.json; the one set aside stays as it was.
        let b = ShelfItem(url: try dir.file("b.png"), createdAt: .now, pixelSize: CGSize(width: 1, height: 1))
        store.append(b)
        #expect(stateFiles(dir) == ["shelf.json", "shelf.json.bad"])
        #expect(try stateFile(dir, "shelf.json.bad") == first)

        // A second bad file doesn't replace the first.
        let second = Data([0xFF, 0xFE, 0x00])
        try second.write(to: store.fileURL)
        store.load()
        #expect(store.items.isEmpty)
        #expect(stateFiles(dir) == ["shelf.json.bad", "shelf.json.bad 2"])
        #expect(try stateFile(dir, "shelf.json.bad") == first)
        #expect(try stateFile(dir, "shelf.json.bad 2") == second)
    }

    @Test func fileThatIsNotAListIsSetAside() throws {
        // A newer Margin could wrap the list in an object.
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = Data(#"{"version": 2, "items": []}"#.utf8)
        try json.write(to: store.fileURL)
        store.load()
        #expect(store.items.isEmpty)
        #expect(stateFiles(dir) == ["shelf.json.bad"])
        #expect(try stateFile(dir, "shelf.json.bad") == json)
    }

    @Test func unreadableItemsAreSkippedAndTheRestKept() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        let date = Date(timeIntervalSince1970: 1_791_999_737)
        let a = ShelfItem(url: try dir.file("a.png"), createdAt: date, pixelSize: CGSize(width: 30, height: 20))
        let b = ShelfItem(url: try dir.file("b.png"), createdAt: date, pixelSize: CGSize(width: 40, height: 10))
        store.append(a)
        store.append(b)
        // Between them: an item with a field of the wrong type (as a newer Margin might write it), and one that isn't
        // an object at all.
        var list = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [Any])
        var changed = try #require(list[0] as? [String: Any])
        changed["pixelWidth"] = "30 px"
        list.insert(changed, at: 1)
        list.insert(42, at: 2)
        let mixed = try JSONSerialization.data(withJSONObject: list)
        try mixed.write(to: store.fileURL)

        store.load()
        #expect(store.items == [a, b])
        // Everything as it was is set aside, and what could be read is saved in its place.
        #expect(stateFiles(dir) == ["shelf.json", "shelf.json.bad"])
        #expect(try stateFile(dir, "shelf.json.bad") == mixed)
        let reloaded = makeStore(dir)
        reloaded.load()
        #expect(reloaded.items == [a, b])
        #expect(stateFiles(dir) == ["shelf.json", "shelf.json.bad"])
    }

    @Test func noReadableItemLeavesNoShelfFile() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = Data(#"[{"id": "not a uuid", "path": "/a.png"}]"#.utf8)
        try json.write(to: store.fileURL)
        store.load()
        #expect(store.items.isEmpty)
        #expect(stateFiles(dir) == ["shelf.json.bad"])
    }

    @Test func everySaveReportsItsSize() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        var reports: [(ms: Double, bytes: Int)] = []
        var saves: [Double] = []
        store.didWrite = { reports.append(($0, $1)) }
        store.didSave = { saves.append($0) }
        let a = ShelfItem(url: try dir.file("a.png"), createdAt: .now, pixelSize: CGSize(width: 10, height: 10))
        store.append(a)
        store.update(a)
        let size = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.size] as? Int
        #expect(reports.count == 2)
        #expect(reports.last?.bytes == size)
        #expect(reports.allSatisfy { $0.ms >= 0 })
        #expect(saves.count == 2)
    }

    @Test func updateReplacesByID() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        var a = ShelfItem(url: try dir.file("a.png"), createdAt: .now, pixelSize: CGSize(width: 10, height: 10))
        store.append(a)
        a.path = try dir.file("renamed.png").path
        store.update(a)
        store.update(ShelfItem(url: dir.url, createdAt: .now, pixelSize: .zero)) // unknown id: ignored
        let reloaded = makeStore(dir)
        reloaded.load()
        #expect(reloaded.items == [a])
    }

    @Test func updatingManyItemsSavesOnce() throws {
        // A moved folder: every card gets a new path, in one write.
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        var items = try (0..<5).map { ShelfItem(url: try dir.file("\($0).png"), createdAt: .now, pixelSize: CGSize(width: 10, height: 10)) }
        for item in items { store.append(item) }
        var saves = 0
        store.didSave = { _ in saves += 1 }
        items[1].path = "/moved/1.png"
        items[3].path = "/moved/3.png"
        let stranger = ShelfItem(url: dir.url.appendingPathComponent("x.png"), createdAt: .now, pixelSize: .zero)
        store.update([items[3], stranger, items[1]])
        #expect(saves == 1)
        #expect(store.items == items) // in shelf order; the unknown item is skipped
        let reloaded = makeStore(dir)
        reloaded.load()
        #expect(reloaded.items == items)

        // Nothing of the shelf's in it: no write at all.
        store.update([stranger])
        store.update([])
        #expect(saves == 1)
    }

    @Test func removeAndRestoreKeepIndices() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        let items = try (0..<5).map { ShelfItem(url: try dir.file("\($0).png"), createdAt: .now, pixelSize: CGSize(width: 1, height: 1)) }
        items.forEach(store.append)

        let removals = store.remove(ids: [items[1].id, items[3].id])
        #expect(removals.map(\.index) == [1, 3])
        #expect(removals.map(\.item) == [items[1], items[3]])
        #expect(store.items == [items[0], items[2], items[4]])

        store.restore(removals)
        #expect(store.items == items)

        // Restoring twice doesn't duplicate.
        store.restore(removals)
        #expect(store.items == items)

        let reloaded = makeStore(dir)
        reloaded.load()
        #expect(reloaded.items == items)
    }

    @Test func removeFirstAndLast() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        let items = try (0..<4).map { ShelfItem(url: try dir.file("\($0).png"), createdAt: .now, pixelSize: CGSize(width: 1, height: 1)) }
        items.forEach(store.append)
        let removals = store.remove(ids: [items[0].id, items[3].id])
        #expect(removals.map(\.index) == [0, 3])
        store.restore(removals.reversed()) // order of the array doesn't matter
        #expect(store.items == items)
    }

    @Test func removeUnknownIDsIsNoOp() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        let a = ShelfItem(url: try dir.file("a.png"), createdAt: .now, pixelSize: CGSize(width: 1, height: 1))
        store.append(a)
        #expect(store.remove(ids: [UUID()]).isEmpty)
        #expect(store.items == [a])
    }

    @Test func undoAfterNewCapture() throws {
        // Dismiss B, then a new shot C arrives, then ⌘Z: B goes back to its slot, C stays newest.
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        let a = ShelfItem(url: try dir.file("a.png"), createdAt: .now, pixelSize: CGSize(width: 1, height: 1))
        let b = ShelfItem(url: try dir.file("b.png"), createdAt: .now, pixelSize: CGSize(width: 1, height: 1))
        let c = ShelfItem(url: try dir.file("c.png"), createdAt: .now, pixelSize: CGSize(width: 1, height: 1))
        store.append(a)
        store.append(b)
        let removals = store.remove(ids: [b.id])
        store.append(c)
        store.restore(removals)
        #expect(store.items == [a, b, c])
    }

    @Test func removeAllAndRestore() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        let items = try (0..<3).map { ShelfItem(url: try dir.file("\($0).png"), createdAt: .now, pixelSize: CGSize(width: 1, height: 1)) }
        items.forEach(store.append)
        let removals = store.removeAll()
        #expect(removals.map(\.index) == [0, 1, 2])
        #expect(store.items.isEmpty)
        let reloaded = makeStore(dir)
        reloaded.load()
        #expect(reloaded.items.isEmpty)
        store.restore(removals)
        #expect(store.items == items)
        #expect(store.removeAll().count == 3)
        #expect(store.removeAll().isEmpty)
    }

    @Test func pruneDropsDeletedFile() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        let keep = ShelfItem(url: try dir.file("keep.png"), createdAt: .now, pixelSize: CGSize(width: 1, height: 1))
        let goneURL = try dir.file("gone.png")
        let gone = ShelfItem(url: goneURL, createdAt: .now, pixelSize: CGSize(width: 1, height: 1))
        store.append(keep)
        store.append(gone)
        try FileManager.default.removeItem(at: goneURL)

        let dropped = store.pruneMissing()
        #expect(dropped.map(\.id) == [gone.id])
        #expect(store.items.map(\.id) == [keep.id])
        let reloaded = makeStore(dir)
        reloaded.load()
        #expect(reloaded.items.map(\.id) == [keep.id])
    }

    @Test func pruneFollowsMovedFile() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        let original = try dir.file("shot.png")
        let item = ShelfItem(url: original, createdAt: .now, pixelSize: CGSize(width: 1, height: 1))
        #expect(item.bookmark != nil)
        store.append(item)

        let sub = dir.url.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let moved = sub.appendingPathComponent("renamed shot.png")
        try FileManager.default.moveItem(at: original, to: moved)

        #expect(store.pruneMissing().isEmpty)
        #expect(store.items.count == 1)
        #expect(samePath(store.items[0].path, moved))
        #expect(store.items[0].id == item.id)

        // The new path is persisted, and the refreshed bookmark still resolves.
        let reloaded = makeStore(dir)
        reloaded.load()
        #expect(samePath(reloaded.items[0].path, moved))
        #expect(reloaded.pruneMissing().isEmpty)
    }

    @Test func pruneDropsFileInTrash() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        let file = try dir.file("Margin test \(UUID().uuidString).png")
        let item = ShelfItem(url: file, createdAt: .now, pixelSize: CGSize(width: 1, height: 1))
        store.append(item)

        var trashed: NSURL?
        try FileManager.default.trashItem(at: file, resultingItemURL: &trashed)
        defer { if let trashed { try? FileManager.default.removeItem(at: trashed as URL) } }
        let trashedURL = try #require(trashed as URL?)
        #expect(ShelfItem.isInTrash(trashedURL))

        let dropped = store.pruneMissing()
        #expect(dropped.map(\.id) == [item.id])
        #expect(store.items.isEmpty)
    }

    @Test func pruneKeepsItemWithoutBookmarkAndFillsItIn() throws {
        // The coordinator creates the item before the PNG is renamed into place.
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        let url = dir.url.appendingPathComponent("later.png")
        let item = ShelfItem(url: url, createdAt: .now, pixelSize: CGSize(width: 1, height: 1))
        #expect(item.bookmark == nil)
        store.append(item)

        #expect(store.pruneMissing().map(\.id) == [item.id]) // not written yet → dropped
        store.append(item)
        try Data("png".utf8).write(to: url)
        #expect(store.pruneMissing().isEmpty)
        #expect(store.items[0].bookmark != nil)
    }

    @Test func pruneWithBrokenBookmarkFallsBackToPath() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        var item = ShelfItem(url: try dir.file("a.png"), createdAt: .now, pixelSize: CGSize(width: 1, height: 1))
        item.bookmark = Data("garbage".utf8)
        store.append(item)
        #expect(store.pruneMissing().isEmpty)
        #expect(store.items[0].bookmark != Data("garbage".utf8))
    }

    @Test func pruneOfAnUnchangedShelfDoesNotRewriteIt() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        store.append(ShelfItem(url: try dir.file("a.png"), createdAt: .now, pixelSize: CGSize(width: 1, height: 1)))
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        try FileManager.default.removeItem(at: store.fileURL)
        #expect(store.pruneMissing().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path)) // nothing changed → no save
    }
}

@Suite struct ShelfItemTests {
    @Test func refreshBookmarkOnceTheFileExists() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let url = dir.url.appendingPathComponent("pending.png")
        var item = ShelfItem(url: url, createdAt: .now, pixelSize: CGSize(width: 2, height: 3))
        #expect(item.bookmark == nil)
        let early = item.refreshBookmark()
        #expect(early == false)
        #expect(item.bookmark == nil)

        try Data("png".utf8).write(to: url)
        let later = item.refreshBookmark()
        #expect(later)
        #expect(item.bookmark != nil)
        #expect(item.pixelWidth == 2 && item.pixelHeight == 3)
    }

    @Test func resolveFileFollowsRename() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let url = try dir.file("a.png")
        var item = ShelfItem(url: url, createdAt: .now, pixelSize: CGSize(width: 1, height: 1))
        let renamed = dir.url.appendingPathComponent("b.png")
        try FileManager.default.moveItem(at: url, to: renamed)
        let found = item.resolveFile()
        let resolved = try #require(found)
        #expect(resolved.resolvingSymlinksInPath().path == renamed.resolvingSymlinksInPath().path)
        #expect(item.url.resolvingSymlinksInPath().path == renamed.resolvingSymlinksInPath().path)
    }

    @Test func resolveFileNilWhenGone() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let url = try dir.file("a.png")
        var item = ShelfItem(url: url, createdAt: .now, pixelSize: CGSize(width: 1, height: 1))
        try FileManager.default.removeItem(at: url)
        let found = item.resolveFile()
        #expect(found == nil)
    }

    @Test func trashPaths() {
        #expect(ShelfItem.isInTrash(URL(fileURLWithPath: "/Users/me/.Trash/shot.png")))
        #expect(ShelfItem.isInTrash(URL(fileURLWithPath: "/Volumes/Disk/.Trashes/501/shot.png")))
        #expect(!ShelfItem.isInTrash(URL(fileURLWithPath: "/Users/me/Desktop/Screenshots/shot.png")))
        #expect(!ShelfItem.isInTrash(URL(fileURLWithPath: "/Users/me/Desktop/.Trash notes/shot.png")))
        #expect(!ShelfItem.isInTrash(URL(fileURLWithPath: "/Users/me/Desktop/My.Trash/shot.png")))
    }

    @Test func fileOnAMissingVolume() throws {
        // Saved to an external disk that's now unplugged: its folder under /Volumes is gone.
        let away = ShelfItem(url: URL(fileURLWithPath: "/Volumes/Margin test \(UUID().uuidString)/Shots/a.png"),
                             createdAt: .now, pixelSize: CGSize(width: 1, height: 1))
        #expect(away.bookmark == nil)
        #expect(away.isOnUnmountedVolume)
        // /Volumes itself is on the startup disk.
        let volumes = ShelfItem(url: URL(fileURLWithPath: "/Volumes"), createdAt: .now, pixelSize: .zero)
        #expect(!volumes.isOnUnmountedVolume)
    }

    @Test func fileOnTheStartupDiskIsNeverOnAnUnmountedVolume() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let url = try dir.file("a.png")
        let item = ShelfItem(url: url, createdAt: .now, pixelSize: CGSize(width: 1, height: 1))
        #expect(item.bookmark != nil)
        #expect(!item.isOnUnmountedVolume)
        // Deleted: gone for good, not "volume away".
        try FileManager.default.removeItem(at: url)
        #expect(!item.isOnUnmountedVolume)
    }

    /// The real thing: a disk image attached, then detached, as an unplugged SSD would be. It mounts a volume,
    /// so it only runs with `MARGIN_DISK_IMAGE_TESTS=1 scripts/test.sh`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MARGIN_DISK_IMAGE_TESTS"] == "1"))
    func fileOnADetachedDiskImage() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let image = dir.url.appendingPathComponent("disk.dmg").path
        let mount = dir.url.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try hdiutil("create", "-quiet", "-size", "2m", "-fs", "HFS+", "-volname", "MarginTest", image)
        try hdiutil("attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image)
        var attached = true
        defer { if attached { try? hdiutil("detach", "-force", "-quiet", mount.path) } }

        let file = mount.appendingPathComponent("a.png")
        try Data("png".utf8).write(to: file)
        var item = ShelfItem(url: file, createdAt: .now, pixelSize: CGSize(width: 1, height: 1))
        #expect(item.bookmark != nil)
        #expect(!item.isOnUnmountedVolume)

        try hdiutil("detach", "-quiet", mount.path)
        attached = false
        // Neither the bookmark nor the path finds the file now…
        #expect(item.resolveFile() == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // …because its volume is away, not because the file was deleted.
        #expect(item.isOnUnmountedVolume)
    }

    private struct HdiutilFailed: Error { let arguments: [String] }

    private func hdiutil(_ arguments: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = arguments
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw HdiutilFailed(arguments: arguments) }
    }

    @Test func pixelSizeTruncatesToInts() {
        let item = ShelfItem(url: URL(fileURLWithPath: "/nope.png"), createdAt: .now, pixelSize: CGSize(width: 99.9, height: 10))
        #expect(item.pixelWidth == 99 && item.pixelSize == CGSize(width: 99, height: 10))
    }
}
