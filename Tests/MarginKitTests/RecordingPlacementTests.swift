import Foundation
import MarginKit
import Testing

/// A recording's temp file held open (`RecordingFile`) and put in place (`RecordingFiles.place`) wherever its folder went
/// while it was recorded.
@Suite struct RecordingPlacementTests {
    let utc = TimeZone(identifier: "UTC")!
    let date = Date(timeIntervalSince1970: 1_791_999_737) // 2026-10-14 17:42:17 UTC
    let name = "Screen Recording 2026-10-14 at 17.42.17.mp4"
    let fm = FileManager.default

    /// A save folder and an Unsaved folder in `dir`, and a temp file in the save folder, open.
    func setUp(_ dir: TempDir) throws -> (folder: URL, unsaved: URL, temp: URL, file: RecordingFile) {
        let folder = dir.url.appendingPathComponent("Screenshots", isDirectory: true)
        let unsaved = dir.url.appendingPathComponent("Unsaved", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent(RecordingFiles.tempName())
        try Data("movie".utf8).write(to: temp)
        return (folder, unsaved, temp, try #require(RecordingFile(temp)))
    }

    func contents(_ folder: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }

    @Test func theFileIsFollowedWhereverItGoes() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let (folder, _, temp, file) = try setUp(dir)
        #expect(file.currentURL?.resolvingSymlinksInPath().path == temp.resolvingSymlinksInPath().path)
        let renamed = dir.url.appendingPathComponent("Renamed", isDirectory: true)
        try fm.moveItem(at: folder, to: renamed)
        #expect(file.currentURL?.resolvingSymlinksInPath().path
            == renamed.appendingPathComponent(temp.lastPathComponent).resolvingSymlinksInPath().path)
        // Deleted: no name left, but its contents can still be copied out.
        try fm.removeItem(at: renamed)
        #expect(file.currentURL == nil)
        let copy = dir.url.appendingPathComponent("copy.mp4")
        try file.copy(to: copy)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "movie")
        // Never over another file.
        #expect(throws: POSIXError.self) { try file.copy(to: copy) }
        #expect(RecordingFile(dir.url.appendingPathComponent("missing.mp4")) == nil)
    }

    @Test func inItsOwnFolder() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let (folder, unsaved, _, file) = try setUp(dir)
        let placed = try RecordingFiles.place(file, recordedIn: folder, fallback: unsaved, date: date, timeZone: utc)
        #expect(placed.folder == .same)
        #expect(placed.url.lastPathComponent == name)
        #expect(contents(folder) == [name])
        #expect(placed.toast(saveFolder: folder) == nil)
    }

    @Test func inItsFolderRenamedOrMoved() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let (folder, unsaved, _, file) = try setUp(dir)
        let moved = dir.url.appendingPathComponent("Elsewhere/Old shots", isDirectory: true)
        try fm.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: folder, to: moved)
        // A screenshot meanwhile makes the save folder again: the movie stays with its own folder.
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let placed = try RecordingFiles.place(file, recordedIn: folder, fallback: unsaved, date: date, timeZone: utc)
        #expect(placed.folder == .moved)
        #expect(contents(moved) == [name])
        #expect(contents(folder).isEmpty)
        #expect(placed.toast(saveFolder: folder) == "Saved to “Old shots”: the save folder was renamed or moved while recording")
    }

    @Test func toUnsavedWhenItsFolderIsInTheTrash() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let (folder, unsaved, _, file) = try setUp(dir)
        let trash = dir.url.appendingPathComponent(".Trash", isDirectory: true)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try fm.moveItem(at: folder, to: trash.appendingPathComponent("Screenshots"))
        let placed = try RecordingFiles.place(file, recordedIn: folder, fallback: unsaved, date: date, timeZone: utc)
        #expect(placed.folder == .unsaved(.trashed))
        #expect(contents(unsaved) == [name])
        #expect(contents(trash.appendingPathComponent("Screenshots")).isEmpty)
        #expect(placed.toast(saveFolder: folder)?.hasPrefix("“Screenshots” is in the Trash. Saved to Unsaved") == true)
    }

    @Test func copiedToUnsavedWhenItsFolderWasDeleted() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let (folder, unsaved, _, file) = try setUp(dir)
        try fm.createDirectory(at: unsaved, withIntermediateDirectories: true)
        try Data("older".utf8).write(to: unsaved.appendingPathComponent(name))
        try fm.removeItem(at: folder)
        let placed = try RecordingFiles.place(file, recordedIn: folder, fallback: unsaved, date: date, timeZone: utc)
        #expect(placed.folder == .unsaved(.deleted))
        // Next to one of that name, never over it, and no temp file left.
        #expect(placed.url.lastPathComponent == "Screen Recording 2026-10-14 at 17.42.17 (2).mp4")
        #expect(Set(contents(unsaved)) == [name, placed.url.lastPathComponent])
        #expect(try String(contentsOf: placed.url, encoding: .utf8) == "movie")
    }

    @Test func toUnsavedWhenItsFolderTakesNoRename() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let (folder, unsaved, temp, file) = try setUp(dir)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let placed = try RecordingFiles.place(file, recordedIn: folder, fallback: unsaved, date: date, timeZone: utc)
        #expect(placed.folder == .unsaved(.notWritable))
        #expect(try String(contentsOf: placed.url, encoding: .utf8) == "movie")
        // A copy: the read-only folder keeps its temp file (the next recording there names it).
        #expect(fm.fileExists(atPath: temp.path))
        #expect(placed.toast(saveFolder: folder)?.hasPrefix("Can't write to “Screenshots”.") == true)
    }
}
