import Foundation
import MarginKit
import Testing

@MainActor @Suite struct PasteboardShotsFolderTests {
    let save = URL(fileURLWithPath: "/Users/me/Desktop/Screenshots", isDirectory: true)
    let pasteboard = URL(fileURLWithPath: "/Users/me/Library/Application Support/Margin/Pasteboard", isDirectory: true)

    @Test func screenshotsGoToThePasteboardFolderOnlyWhileOn() {
        #expect(PasteboardShots.folder(for: .screenshot, deletesAfterPasting: true, saveFolder: save, pasteboardFolder: pasteboard) == pasteboard)
        #expect(PasteboardShots.folder(for: .screenshot, deletesAfterPasting: false, saveFolder: save, pasteboardFolder: pasteboard) == save)
    }

    @Test func recordingsAreAlwaysSaved() {
        #expect(PasteboardShots.folder(for: .recording, deletesAfterPasting: true, saveFolder: save, pasteboardFolder: pasteboard) == save)
        #expect(PasteboardShots.folder(for: .recording, deletesAfterPasting: false, saveFolder: save, pasteboardFolder: pasteboard) == save)
    }

    @Test func theDefaultFolderIsMarginsOwn() {
        #expect(Preferences.pasteboardFolder.path.hasSuffix("/Library/Application Support/Margin/Pasteboard"))
        #expect(Preferences.pasteboardFolder.deletingLastPathComponent() == Preferences.fallbackSaveFolder.deletingLastPathComponent())
    }

    @Test func onlyFilesDirectlyInTheFolderCount() {
        #expect(PasteboardShots.isInFolder(pasteboard.path + "/Screenshot 2026-10-17 at 10.00.00.png", folder: pasteboard))
        #expect(PasteboardShots.isInFolder(pasteboard.path + "/../Pasteboard/a.png", folder: pasteboard))
        #expect(!PasteboardShots.isInFolder(pasteboard.path + "/sub/a.png", folder: pasteboard))
        #expect(!PasteboardShots.isInFolder(pasteboard.path, folder: pasteboard))
        #expect(!PasteboardShots.isInFolder(save.path + "/Screenshot 2026-10-17 at 10.00.00.png", folder: pasteboard))
        #expect(!PasteboardShots.isInFolder(Preferences.fallbackSaveFolder.path + "/a.png", folder: pasteboard))
        // A folder whose name starts the same isn't it.
        #expect(!PasteboardShots.isInFolder(pasteboard.path + " 2/a.png", folder: pasteboard))
    }
}

@MainActor @Suite struct PasteboardRetentionTests {
    let folder = URL(fileURLWithPath: "/Users/me/Library/Application Support/Margin/Pasteboard", isDirectory: true)
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var a: String { folder.path + "/a.png" }
    var b: String { folder.path + "/b.png" }

    @Test func departuresWaitAsTheSpecSays() {
        #expect(PasteboardShots.Departure.pasted.grace == 10)
        #expect(PasteboardShots.Departure.dropped.grace == 30)
        #expect(PasteboardShots.Departure.removed.grace == 0)
    }

    @Test func aFileGoesOnceItsTimeHasCome() {
        var r = PasteboardShots.Retention()
        r.add(a, notBefore: t0.addingTimeInterval(10), folder: folder)
        #expect(!r.isEmpty)
        #expect(r.due(at: t0.addingTimeInterval(9.9), referenced: [], onClipboard: []).isEmpty)
        #expect(r.due(at: t0.addingTimeInterval(10), referenced: [], onClipboard: []) == [a])
        #expect(r.isEmpty)
        #expect(r.due(at: t0.addingTimeInterval(20), referenced: [], onClipboard: []).isEmpty) // only once
    }

    @Test func filesOutsideTheFolderNeverWait() {
        var r = PasteboardShots.Retention()
        r.add("/Users/me/Desktop/Screenshots/a.png", notBefore: t0, folder: folder)
        r.add(Preferences.fallbackSaveFolder.path + "/a.png", notBefore: t0, folder: folder)
        #expect(r.isEmpty)
        #expect(r.due(at: t0.addingTimeInterval(60), referenced: [], onClipboard: []).isEmpty)
    }

    @Test func aFileOnTheClipboardWaitsUntilItIsnt() {
        var r = PasteboardShots.Retention()
        r.add(a, notBefore: t0, folder: folder)
        #expect(r.due(at: t0.addingTimeInterval(60), referenced: [], onClipboard: [a]).isEmpty)
        #expect(!r.isEmpty)
        #expect(r.due(at: t0.addingTimeInterval(61), referenced: [], onClipboard: []) == [a])
    }

    @Test func aFileWithACardAgainStopsWaitingAndStays() {
        var r = PasteboardShots.Retention()
        r.add(a, notBefore: t0, folder: folder)
        r.add(b, notBefore: t0, folder: folder)
        #expect(r.due(at: t0.addingTimeInterval(1), referenced: [a], onClipboard: []) == [b])
        #expect(r.isEmpty)
    }

    @Test func pathsAreComparedStandardized() {
        var r = PasteboardShots.Retention()
        r.add(folder.path + "/./a.png", notBefore: t0, folder: folder)
        #expect(r.due(at: t0, referenced: [], onClipboard: [a]).isEmpty)
        #expect(r.due(at: t0, referenced: [folder.path + "/x/../a.png"], onClipboard: []).isEmpty)
        #expect(r.isEmpty)
    }

    @Test func addingAgainKeepsTheLaterTime() {
        var r = PasteboardShots.Retention()
        r.add(a, notBefore: t0.addingTimeInterval(30), folder: folder)
        r.add(a, notBefore: t0, folder: folder)
        #expect(r.due(at: t0.addingTimeInterval(10), referenced: [], onClipboard: []).isEmpty)
        #expect(r.due(at: t0.addingTimeInterval(30), referenced: [], onClipboard: []) == [a])
    }

    @Test func clipboardFilesHoldOnlyWhileTheCountIsTheSame() {
        let files = PasteboardShots.ClipboardFiles(changeCount: 41, paths: [a, b])
        #expect(files.paths(at: 41) == [a, b])
        #expect(files.paths(at: 42).isEmpty)
    }
}

@Suite struct PasteboardCleanUpTests {
    let launch = Date()

    /// A file last written `age` seconds before the launch.
    func file(_ name: String, in dir: TempDir, age: TimeInterval = 60) throws -> URL {
        let url = try dir.file(name)
        try FileManager.default.setAttributes([.modificationDate: launch.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    func item(at url: URL) -> ShelfItem {
        ShelfItem(url: url, createdAt: launch.addingTimeInterval(-60), pixelSize: CGSize(width: 4, height: 4))
    }

    @Test func filesWithoutACardGo() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let kept = try file("Screenshot 2026-10-17 at 10.00.00.png", in: dir)
        let orphan = try file("Screenshot 2026-10-17 at 10.00.01.png", in: dir)
        let deleted = PasteboardShots.cleanUp(folder: dir.url, items: [item(at: kept)], writtenBefore: launch)
        #expect(deleted.map(\.lastPathComponent) == [orphan.lastPathComponent])
        #expect(dir.contents() == [kept.lastPathComponent])
    }

    @Test func aCardRenamedWhileQuitKeepsItsFile() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let original = try file("Screenshot 2026-10-17 at 10.00.00.png", in: dir)
        let card = item(at: original)   // its bookmark is made now, while the file has its old name
        let renamed = dir.url.appendingPathComponent("Renamed.png")
        try FileManager.default.moveItem(at: original, to: renamed)
        #expect(PasteboardShots.cleanUp(folder: dir.url, items: [card], writtenBefore: launch).isEmpty)
        #expect(dir.contents() == ["Renamed.png"])
    }

    @Test func aFileOnTheClipboardStays() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let pasted = try file("Screenshot 2026-10-17 at 10.00.00.png", in: dir)
        #expect(PasteboardShots.cleanUp(folder: dir.url, items: [], keeping: [pasted.path], writtenBefore: launch).isEmpty)
        #expect(dir.contents() == [pasted.lastPathComponent])
    }

    @Test func newerAndHiddenFilesAndFoldersAreLeftAlone() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        _ = try file("Screenshot of this launch.png", in: dir, age: -1)
        _ = try file(".DS_Store", in: dir)
        _ = try file(".margin-\(UUID().uuidString).tmp", in: dir)
        try FileManager.default.createDirectory(at: dir.url.appendingPathComponent("folder"), withIntermediateDirectories: false)
        #expect(PasteboardShots.cleanUp(folder: dir.url, items: [], writtenBefore: launch).isEmpty)
        #expect(dir.contents().count == 4)
    }

    @Test func aMissingFolderIsNothingToDo() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        #expect(PasteboardShots.cleanUp(folder: dir.url.appendingPathComponent("Pasteboard"), items: [], writtenBefore: launch).isEmpty)
    }

    /// A Pasteboard folder that's a link (made by hand, to keep the shots somewhere) leads elsewhere: nothing there goes.
    @Test func aLinkedFolderIsLeftAlone() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let elsewhere = dir.url.appendingPathComponent("Screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        let kept = elsewhere.appendingPathComponent("Screenshot 2026-10-17 at 10.00.00.png")
        try Data([1]).write(to: kept)
        try FileManager.default.setAttributes([.modificationDate: launch.addingTimeInterval(-60)], ofItemAtPath: kept.path)
        let link = dir.url.appendingPathComponent("Pasteboard", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        #expect(!PasteboardShots.isRealFolder(link))
        #expect(PasteboardShots.isRealFolder(elsewhere))
        #expect(!PasteboardShots.isRealFolder(kept))
        #expect(PasteboardShots.cleanUp(folder: link, items: [], writtenBefore: launch).isEmpty)
        #expect(FileManager.default.fileExists(atPath: kept.path))
        // A link above the folder (a linked Application Support) is followed as usual.
        let linkedParent = dir.url.appendingPathComponent("Linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: dir.url)
        let below = linkedParent.appendingPathComponent("Screenshots", isDirectory: true)
        #expect(PasteboardShots.isRealFolder(below))
        #expect(PasteboardShots.cleanUp(folder: below, items: [], writtenBefore: launch).count == 1)
    }

    /// A shelf.json that couldn't all be read is set aside with its cards (`ShelfStore.load`): the files it names stay,
    /// even when it's too damaged to decode.
    @Test func filesNamedInASetAsideShelfStay() throws {
        let dir = try TempDir(), lists = try TempDir()
        defer { dir.remove(); lists.remove() }
        let named = try file("Screenshot 2026-10-17 at 10.00.00.png", in: dir)
        let damaged = try file("Screenshot 2026-10-17 at 10.00.01.png", in: dir)
        let orphan = try file("Screenshot 2026-10-17 at 10.00.02.png", in: dir)
        let shelf = lists.url.appendingPathComponent("shelf.json")
        try JSONEncoder().encode([item(at: named)]).write(to: lists.url.appendingPathComponent("shelf.json.bad"))
        // Cut off just after the name: no longer JSON.
        let whole = try JSONEncoder().encode([item(at: damaged)])
        let name = try #require(whole.range(of: Data(damaged.lastPathComponent.utf8)))
        let cut = whole.prefix(upTo: name.upperBound + 2)
        #expect((try? JSONDecoder().decode([ShelfItem].self, from: cut)) == nil)
        try cut.write(to: lists.url.appendingPathComponent("shelf.json.bad 2"))
        try Data("[]".utf8).write(to: lists.url.appendingPathComponent("shelf.json.bak"))
        let setAside = ShelfStore.setAsideFiles(of: shelf)
        #expect(setAside.map(\.lastPathComponent) == ["shelf.json.bad", "shelf.json.bad 2"])
        let deleted = PasteboardShots.cleanUp(folder: dir.url, items: [], setAside: setAside, writtenBefore: launch)
        #expect(deleted.map(\.lastPathComponent) == [orphan.lastPathComponent])
        #expect(Set(dir.contents()) == [named.lastPathComponent, damaged.lastPathComponent])
    }

    @Test func cardsElsewhereDontKeepAnything() throws {
        let dir = try TempDir(), other = try TempDir()
        defer { dir.remove(); other.remove() }
        _ = try file("Screenshot 2026-10-17 at 10.00.00.png", in: dir)
        let elsewhere = try file("Screenshot 2026-10-17 at 10.00.00.png", in: other)
        #expect(PasteboardShots.cleanUp(folder: dir.url, items: [item(at: elsewhere)], writtenBefore: launch).count == 1)
        #expect(other.contents().count == 1)
    }
}

/// Close Shelf moves the Pasteboard shots it takes off the shelf into the save folder (spec §5).
@Suite struct PasteboardKeepTests {
    @Test func aShotMovesIntoTheSaveFolderUnderItsName() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let pasteboard = dir.url.appendingPathComponent("Pasteboard")
        let save = dir.url.appendingPathComponent("Screenshots")   // missing: it's created
        try FileManager.default.createDirectory(at: pasteboard, withIntermediateDirectories: true)
        let shot = pasteboard.appendingPathComponent("Screenshot 2026-10-18 at 10.00.00.png")
        try Data("png".utf8).write(to: shot)

        let kept = try PasteboardShots.keep(shot.path, in: save, pasteboardFolder: pasteboard)
        #expect(kept?.lastPathComponent == "Screenshot 2026-10-18 at 10.00.00.png")
        #expect(kept?.deletingLastPathComponent().standardizedFileURL == save.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: shot.path))
        #expect(try Data(contentsOf: try #require(kept)) == Data("png".utf8))
    }

    @Test func aTakenNameGetsANumberAndNothingIsReplaced() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let pasteboard = dir.url.appendingPathComponent("Pasteboard")
        let save = dir.url.appendingPathComponent("Screenshots")
        for folder in [pasteboard, save] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let name = "Screenshot 2026-10-18 at 10.00.00.png"
        try Data("old".utf8).write(to: save.appendingPathComponent(name))
        try Data("old 2".utf8).write(to: save.appendingPathComponent("Screenshot 2026-10-18 at 10.00.00 (2).png"))
        try Data("new".utf8).write(to: pasteboard.appendingPathComponent(name))

        let kept = try PasteboardShots.keep(pasteboard.appendingPathComponent(name).path, in: save, pasteboardFolder: pasteboard)
        #expect(kept?.lastPathComponent == "Screenshot 2026-10-18 at 10.00.00 (3).png")
        #expect(try Data(contentsOf: save.appendingPathComponent(name)) == Data("old".utf8))
        #expect(try Data(contentsOf: try #require(kept)) == Data("new".utf8))
    }

    @Test func onlyPasteboardFilesThatAreStillThereMove() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let pasteboard = dir.url.appendingPathComponent("Pasteboard")
        let save = dir.url.appendingPathComponent("Screenshots")
        for folder in [pasteboard, save] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        // A normal file (in Save to, in Unsaved) stays where it is.
        let normal = save.appendingPathComponent("a.png")
        try Data("a".utf8).write(to: normal)
        #expect(try PasteboardShots.keep(normal.path, in: save, pasteboardFolder: pasteboard) == nil)
        #expect(FileManager.default.fileExists(atPath: normal.path))
        // Gone already (moved by an earlier close): nothing to do.
        #expect(try PasteboardShots.keep(pasteboard.appendingPathComponent("b.png").path, in: save, pasteboardFolder: pasteboard) == nil)
    }

    @Test func aLinkedPasteboardFolderIsLeftAlone() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let save = dir.url.appendingPathComponent("Screenshots")
        try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
        let link = dir.url.appendingPathComponent("Pasteboard")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: save)
        try Data("a".utf8).write(to: save.appendingPathComponent("a.png"))
        #expect(try PasteboardShots.keep(link.appendingPathComponent("a.png").path, in: save, pasteboardFolder: link) == nil)
        #expect(FileManager.default.fileExists(atPath: save.appendingPathComponent("a.png").path))
    }

    @Test func aFolderThatCantBeWrittenThrows() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let pasteboard = dir.url.appendingPathComponent("Pasteboard")
        try FileManager.default.createDirectory(at: pasteboard, withIntermediateDirectories: true)
        let shot = pasteboard.appendingPathComponent("a.png")
        try Data("a".utf8).write(to: shot)
        // A file where the folder should be.
        let blocked = try dir.file("Screenshots")
        #expect(throws: (any Error).self) { try PasteboardShots.keep(shot.path, in: blocked, pasteboardFolder: pasteboard) }
        #expect(FileManager.default.fileExists(atPath: shot.path))
    }
}
