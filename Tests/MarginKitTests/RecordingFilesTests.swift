import Foundation
import MarginKit
import Testing

@Suite struct RecordingFilesTests {
    let utc = TimeZone(identifier: "UTC")!
    let date = Date(timeIntervalSince1970: 1_791_999_737) // 2026-10-14 17:42:17 UTC

    @Test func tempNamesAreHiddenAndOnlyRecordings() {
        let name = RecordingFiles.tempName()
        #expect(name.hasPrefix("."))
        #expect(name.hasSuffix(".mp4"))
        #expect(RecordingFiles.isTempName(name))
        #expect(RecordingFiles.tempName() != name)
        // A PNG save's temp file, and anything else, isn't one.
        #expect(!RecordingFiles.isTempName(".margin-\(UUID().uuidString).tmp"))
        #expect(!RecordingFiles.isTempName(".margin-recording-not-a-uuid.mp4"))
        #expect(!RecordingFiles.isTempName("Screen Recording 2026-10-14 at 17.42.17.mp4"))
    }

    @Test func finishedRecordingsGetTheirStartTimesName() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let temp = try dir.file(RecordingFiles.tempName(), contents: "movie")
        let url = try RecordingFiles.moveIntoPlace(temp, in: dir.url, date: date, timeZone: utc)
        #expect(url.lastPathComponent == "Screen Recording 2026-10-14 at 17.42.17.mp4")
        #expect(dir.contents() == ["Screen Recording 2026-10-14 at 17.42.17.mp4"])
        #expect(try String(contentsOf: url, encoding: .utf8) == "movie")
    }

    @Test func aTakenNameCountsUpAndNothingIsReplaced() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        _ = try dir.file("Screen Recording 2026-10-14 at 17.42.17.mp4", contents: "first")
        let temp = try dir.file(RecordingFiles.tempName(), contents: "second")
        let url = try RecordingFiles.moveIntoPlace(temp, in: dir.url, date: date, timeZone: utc)
        #expect(url.lastPathComponent == "Screen Recording 2026-10-14 at 17.42.17 (2).mp4")
        #expect(try String(contentsOf: dir.url.appendingPathComponent("Screen Recording 2026-10-14 at 17.42.17.mp4"),
                           encoding: .utf8) == "first")
    }

    @Test func leftoversFromBeforeThisLaunchGo() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let old = try dir.file(RecordingFiles.tempName())
        let current = try dir.file(RecordingFiles.tempName())
        let png = try dir.file(".margin-\(UUID().uuidString).tmp")
        let finished = try dir.file("Screen Recording 2026-10-14 at 17.42.17.mp4")
        let launch = Date()
        try FileManager.default.setAttributes([.modificationDate: launch.addingTimeInterval(-600)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: launch.addingTimeInterval(-600)], ofItemAtPath: png.path)
        try FileManager.default.setAttributes([.modificationDate: launch.addingTimeInterval(-600)], ofItemAtPath: finished.path)
        try FileManager.default.setAttributes([.modificationDate: launch.addingTimeInterval(5)], ofItemAtPath: current.path)
        let removed = RecordingFiles.removeLeftovers(in: dir.url, writtenBefore: launch)
        #expect(removed.map(\.lastPathComponent) == [old.lastPathComponent])
        // The recording under way, a PNG save's temp file (`LeftoverSaves`' business) and finished files stay.
        #expect(Set(dir.contents()) == Set([current, png, finished].map(\.lastPathComponent)))
    }

    @Test func leftoversInAMissingFolderAreNothing() {
        #expect(RecordingFiles.removeLeftovers(in: URL(fileURLWithPath: "/nonexistent/folder"), writtenBefore: Date()).isEmpty)
    }

    @Test func freeSpaceIsReadable() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let free = try #require(RecordingFiles.freeBytes(at: dir.url))
        #expect(free > 0)
        #expect(RecordingFiles.freeBytes(at: URL(fileURLWithPath: "/nonexistent/folder")) == nil)
    }
}
