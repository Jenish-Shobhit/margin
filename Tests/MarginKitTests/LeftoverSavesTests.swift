import CoreGraphics
import Foundation
import ImageIO
import MarginKit
import Testing

@Suite struct LeftoverSavesTests {
    let utc = TimeZone(identifier: "UTC")!
    let date = Date(timeIntervalSince1970: 1_791_999_737)
    let png = try! PNGWriter.encode(makeImage(width: 30, height: 20), scale: 2)

    /// A temp file as a cut-off save leaves it, last written at `written`.
    @discardableResult
    func leftover(_ dir: TempDir, _ data: Data, written: Date) throws -> URL {
        let url = dir.url.appendingPathComponent(".margin-\(UUID().uuidString).tmp")
        try data.write(to: url)
        try FileManager.default.setAttributes([.creationDate: written, .modificationDate: written], ofItemAtPath: url.path)
        return url
    }

    func name(_ date: Date, suffix: Int = 1) -> String { FileNamer.fileName(for: date, timeZone: utc, suffix: suffix) }

    /// A card whose save never finished: no bookmark, no file.
    func waitingCard(_ dir: TempDir, at date: Date, size: CGSize = CGSize(width: 30, height: 20)) -> ShelfItem {
        ShelfItem(url: dir.url.appendingPathComponent(name(date)), createdAt: date, pixelSize: size)
    }

    func recover(_ dir: TempDir, items: [ShelfItem] = []) -> [LeftoverSaves.Outcome] {
        LeftoverSaves.recover(in: dir.url, items: items, writtenBefore: date.addingTimeInterval(600), timeZone: utc)
    }

    @Test func aCompletePNGGetsAScreenshotNameFromItsDate() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let written = date.addingTimeInterval(0.3)
        let temp = try leftover(dir, png, written: written)
        let outcomes = recover(dir)
        let url = dir.url.appendingPathComponent(name(written))
        #expect(outcomes == [.init(temp: temp, action: .recovered(url), itemID: nil)])
        #expect(dir.contents() == [name(written)])
        #expect(try Data(contentsOf: url) == png)
    }

    @Test func anIncompleteWriteIsDeleted() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let cut = try leftover(dir, png.prefix(png.count - 20), written: date)
        let empty = try leftover(dir, Data(), written: date)
        let garbage = try leftover(dir, Data(repeating: 7, count: 400), written: date)
        let outcomes = recover(dir)
        #expect(Set(outcomes.map(\.temp)) == [cut, empty, garbage])
        #expect(outcomes.allSatisfy { $0.action == .deleted })
        #expect(dir.contents().isEmpty)
    }

    @Test func aCardWaitingForItsFileGetsIt() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let card = waitingCard(dir, at: date)
        // Written a second later, so a name from its own date would differ from the card's.
        let temp = try leftover(dir, png, written: date.addingTimeInterval(1.2))
        let outcomes = recover(dir, items: [card])
        #expect(outcomes == [.init(temp: temp, action: .recovered(card.url), itemID: card.id)])
        #expect(dir.contents() == [name(date)])

        // The shelf's check finds it there, and fills in the bookmark.
        var found = card
        #expect(found.resolveFile() != nil)
        #expect(found.bookmark != nil)
    }

    @Test func theNearestCardOfTheSameSizeWins() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let other = waitingCard(dir, at: date, size: CGSize(width: 99, height: 20))
        let early = waitingCard(dir, at: date.addingTimeInterval(-30))
        let near = waitingCard(dir, at: date.addingTimeInterval(-1))
        let temp = try leftover(dir, png, written: date)
        let outcomes = recover(dir, items: [other, early, near])
        #expect(outcomes == [.init(temp: temp, action: .recovered(near.url), itemID: near.id)])
    }

    @Test func noCardOutsideTheWindowOrWithAFile() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let later = waitingCard(dir, at: date.addingTimeInterval(10))     // captured after the file was written
        let long = waitingCard(dir, at: date.addingTimeInterval(-600))    // ten minutes before
        var saved = ShelfItem(url: try dir.file("saved.png"), createdAt: date, pixelSize: CGSize(width: 30, height: 20))
        saved.bookmark = nil
        let elsewhere = ShelfItem(url: URL(fileURLWithPath: "/var/empty/\(name(date))"), createdAt: date,
                                  pixelSize: CGSize(width: 30, height: 20))
        let temp = try leftover(dir, png, written: date)
        let outcomes = recover(dir, items: [later, long, saved, elsewhere])
        let url = dir.url.appendingPathComponent(name(date))
        #expect(outcomes == [.init(temp: temp, action: .recovered(url), itemID: nil)])
    }

    @Test func aTakenNameMovesOnWithoutReplacingIt() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let card = waitingCard(dir, at: date)
        let temp = try leftover(dir, png, written: date)
        // Something else took the card's name meanwhile (but not as the card's file: the card has no bookmark).
        _ = try dir.file(name(date), contents: "someone else's")
        let outcomes = recover(dir, items: [card])
        let url = dir.url.appendingPathComponent(name(date, suffix: 2))
        // Not the card's file any more: the card was taken because its file didn't exist, so it's not matched at all.
        #expect(outcomes == [.init(temp: temp, action: .recovered(url), itemID: nil)])
        #expect(try String(contentsOf: dir.url.appendingPathComponent(name(date)), encoding: .utf8) == "someone else's")
        #expect(try Data(contentsOf: url) == png)
    }

    @Test func filesWrittenSinceLaunchAndOtherFilesAreLeftAlone() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let launch = date.addingTimeInterval(600)
        try leftover(dir, png, written: launch.addingTimeInterval(1))   // this copy's own save, in progress
        try leftover(dir, png.prefix(10), written: launch)              // not before the launch either
        _ = try dir.file(".margin-not-a-uuid.tmp")
        _ = try dir.file("notes.tmp")
        _ = try dir.file(name(date), contents: "a shot")
        let before = dir.contents()
        #expect(recover(dir).isEmpty)
        #expect(dir.contents() == before)
    }

    @Test func aMissingFolderIsNothingToDo() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("MarginKitTests-\(UUID().uuidString)")
        #expect(LeftoverSaves.recover(in: missing, items: [], writtenBefore: .now).isEmpty)
    }

    @Test func theScreenshotTagsComeAlong() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let temp = try leftover(dir, png, written: date)
        ScreenshotMetadata(kind: .window, globalRect: CGRect(x: 1, y: 2, width: 3, height: 4)).apply(to: temp)
        let outcomes = recover(dir)
        guard case .recovered(let url) = try #require(outcomes.first).action else {
            Issue.record("not recovered")
            return
        }
        #expect(getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0)
    }
}
