import CoreGraphics
import Dispatch
import Foundation
@testable import MarginKit
import os
import Testing

/// shelf.json written off the main actor (`ShelfStore(fileURL:writesInBackground:)`).
@MainActor @Suite struct ShelfFileWriterTests {
    func makeStore(_ dir: TempDir) -> ShelfStore {
        ShelfStore(fileURL: dir.url.appendingPathComponent("state/shelf.json"), writesInBackground: true)
    }

    func item(_ dir: TempDir, _ name: String) throws -> ShelfItem {
        ShelfItem(url: try dir.file(name), createdAt: Date(timeIntervalSince1970: 1_791_999_737), pixelSize: CGSize(width: 30, height: 20))
    }

    func onDisk(_ store: ShelfStore) throws -> [ShelfItem] {
        try JSONDecoder().decode([ShelfItem].self, from: Data(contentsOf: store.fileURL))
    }

    @Test func theFileEndsWithTheNewestList() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        let a = try item(dir, "a.png"), b = try item(dir, "b.png"), c = try item(dir, "c.png")
        store.append(a)
        store.append(b)
        store.append(c)
        var moved = b
        moved.path = "/elsewhere/b.png"
        store.update([moved])
        store.remove(ids: [a.id])
        store.flush()
        #expect(try onDisk(store) == [moved, c])
        #expect(store.items == [moved, c])
    }

    @Test func waitingCoversEverySaveBeforeIt() async throws {
        // What the save pipeline relies on: once it has waited, the card is in the file (no flush).
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        let a = try item(dir, "a.png")
        store.append(a)
        await store.waitForWrites()
        #expect(try onDisk(store) == [a])
    }

    @Test func loadReadsWhatWasOnItsWay() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        let a = try item(dir, "a.png"), b = try item(dir, "b.png")
        store.append(a)
        store.append(b)
        store.load()
        #expect(store.items == [a, b])
    }

    @Test func savesReportTheMainActorsPartAtOnceAndTheWriteLater() async throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = makeStore(dir)
        var saves = 0
        var writes: [Int] = []
        store.didSave = { _ in saves += 1 }
        store.didWrite = { _, bytes in writes.append(bytes) }
        store.append(try item(dir, "a.png"))
        #expect(saves == 1)
        await store.waitForWrites()
        for _ in 0..<200 where writes.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let size = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.size] as? Int
        #expect(writes == [size])
    }

    @Test func aBurstOfSavesIsOneWrite() throws {
        // While the queue is busy (held here), every save replaces the list waiting to be written.
        let dir = try TempDir()
        defer { dir.remove() }
        let queue = DispatchQueue(label: "test.shelf-json")
        let writer = ShelfFileWriter(fileURL: dir.url.appendingPathComponent("shelf.json"), queue: queue)
        let reports = OSAllocatedUnfairLock(initialState: 0)
        var list: [ShelfItem] = []
        queue.suspend()
        for i in 0..<50 {
            list.append(try item(dir, "\(i).png"))
            writer.write(list) { _, _ in reports.withLock { $0 += 1 } }
        }
        queue.resume()
        writer.flush()
        #expect(reports.withLock { $0 } == 1)
        let written = try JSONDecoder().decode([ShelfItem].self, from: Data(contentsOf: writer.fileURL))
        #expect(written == list)

        // A save after that write is its own write.
        list.removeFirst()
        writer.write(list) { _, _ in reports.withLock { $0 += 1 } }
        writer.flush()
        #expect(reports.withLock { $0 } == 2)
        #expect(try JSONDecoder().decode([ShelfItem].self, from: Data(contentsOf: writer.fileURL)) == list)
    }

    @Test func withoutBackgroundWritesFlushAndWaitingAreFree() async throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = ShelfStore(fileURL: dir.url.appendingPathComponent("shelf.json"))
        let a = try item(dir, "a.png")
        store.append(a)
        // Written already, synchronously.
        #expect(try onDisk(store) == [a])
        store.flush()
        await store.waitForWrites()
    }
}
