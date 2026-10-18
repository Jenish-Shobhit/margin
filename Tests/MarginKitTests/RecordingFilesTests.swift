import Foundation
@testable import MarginKit
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

    /// An MP4's top-level boxes: each a 4-byte big-endian size (or 1, then a 64-bit size) and a 4-byte type.
    func box(_ type: String, payload: Int = 8, size: UInt32? = nil, large: Bool = false) -> Data {
        var d = Data()
        func be32(_ v: UInt32) { d.append(contentsOf: [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]) }
        if large {
            be32(1)
            d.append(contentsOf: Array(type.utf8))
            let total = UInt64(16 + payload)
            d.append(contentsOf: (0..<8).reversed().map { UInt8(total >> (8 * UInt64($0)) & 0xff) })
        } else {
            be32(size ?? UInt32(8 + payload))
            d.append(contentsOf: Array(type.utf8))
        }
        d.append(Data(repeating: 0xAB, count: payload))
        return d
    }

    func movie(_ dir: TempDir, _ name: String, _ boxes: [Data]) throws -> URL {
        let url = dir.url.appendingPathComponent(name)
        try boxes.reduce(Data(), +).write(to: url)
        return url
    }

    @Test func aMoviePlaysWithItsIndex() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        // As AVAssetWriter finishes one with the index at the front, and at the end.
        #expect(RecordingFiles.isPlayableMovie(at: try movie(dir, "a.mp4", [box("ftyp"), box("moov", payload: 40), box("mdat", payload: 500)])))
        #expect(RecordingFiles.isPlayableMovie(at: try movie(dir, "b.mp4", [box("ftyp"), box("mdat", payload: 500, large: true), box("moov")])))
        // Written in fragments and cut off, or left by a writer that failed: the first fragment's media and the index,
        // then each later fragment's media and its `moof`, the last one's media still being written.
        #expect(RecordingFiles.isPlayableMovie(at: try movie(dir, "g.mp4", [
            box("ftyp"), box("mdat", payload: 300), box("moov", payload: 60), box("mdat", payload: 300), box("moof"),
            box("wide", payload: 0), box("mdat", payload: 100, size: 0),
        ])))
        // Cut off before the first fragment was out: the media runs to the end of the file (size 0), or the file ends
        // before the index, or within it.
        #expect(!RecordingFiles.isPlayableMovie(at: try movie(dir, "c.mp4", [box("ftyp"), box("mdat", payload: 500, size: 0)])))
        #expect(!RecordingFiles.isPlayableMovie(at: try movie(dir, "d.mp4", [box("ftyp"), box("mdat", payload: 500)])))
        #expect(!RecordingFiles.isPlayableMovie(at: try movie(dir, "e.mp4", [box("ftyp"), box("mdat", payload: 100, size: 9000)])))
        #expect(!RecordingFiles.isPlayableMovie(at: try movie(dir, "h.mp4", [box("ftyp"), box("mdat", payload: 300), box("moov", payload: 10, size: 90)])))
        #expect(!RecordingFiles.isPlayableMovie(at: try dir.file("f.mp4", contents: "")))
        #expect(!RecordingFiles.isPlayableMovie(at: dir.url.appendingPathComponent("missing.mp4")))
    }

    @Test func leftoversFromBeforeThisLaunch() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let fm = FileManager.default
        let empty = try movie(dir, RecordingFiles.tempName(), [box("ftyp"), box("mdat", payload: 200, size: 0)])
        let finished = try movie(dir, RecordingFiles.tempName(), [box("ftyp"), box("mdat", payload: 200), box("moov")])
        let cutOff = try movie(dir, RecordingFiles.tempName(), [
            box("ftyp"), box("mdat", payload: 200), box("moov"), box("mdat", payload: 200), box("moof"),
            box("mdat", payload: 50, size: 0),
        ])
        let current = try dir.file(RecordingFiles.tempName())
        let png = try dir.file(".margin-\(UUID().uuidString).tmp")
        let named = try dir.file("Screen Recording 2026-10-14 at 17.42.17.mp4")
        let launch = Date()
        for url in [empty, finished, cutOff, png, named] {
            try fm.setAttributes([.modificationDate: launch.addingTimeInterval(-600)], ofItemAtPath: url.path)
        }
        try fm.setAttributes([.creationDate: date], ofItemAtPath: finished.path)
        try fm.setAttributes([.creationDate: date.addingTimeInterval(3600)], ofItemAtPath: cutOff.path)
        try fm.setAttributes([.modificationDate: launch.addingTimeInterval(5)], ofItemAtPath: current.path)
        let outcomes = RecordingFiles.handleLeftovers(in: dir.url, writtenBefore: launch, timeZone: utc)
        // Each one that plays gets the name of when it was started (the finished one next to one already there; the
        // one cut off by a crash plays up to its last fragment); the one with nothing that plays goes.
        let recovered = dir.url.appendingPathComponent("Screen Recording 2026-10-14 at 17.42.17 (2).mp4")
        let recoveredCut = dir.url.appendingPathComponent("Screen Recording 2026-10-14 at 18.42.17.mp4")
        #expect(Set(outcomes) == [.recovered(recovered), .recovered(recoveredCut), .removed(empty)])
        // The recording under way, a PNG save's temp file (`LeftoverSaves`' business) and finished files stay.
        #expect(Set(dir.contents()) == Set([current, png, named, recovered, recoveredCut].map(\.lastPathComponent)))
    }

    @Test func aLeftoverThatPlaysIsNeverDeleted() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let finished = try movie(dir, RecordingFiles.tempName(), [box("ftyp"), box("mdat", payload: 200), box("moov")])
        let launch = Date()
        try FileManager.default.setAttributes([.modificationDate: launch.addingTimeInterval(-600)], ofItemAtPath: finished.path)
        // Its rename fails (the folder became read-only, say): it stays as it is, for the next time.
        let outcomes = RecordingFiles.handleLeftovers(in: dir.url, writtenBefore: launch) { _, _ in throw POSIXError(.EACCES) }
        #expect(outcomes == [.unnamed(finished)])
        #expect(dir.contents() == [finished.lastPathComponent])
    }

    @Test func leftoversInAMissingFolderAreNothing() {
        #expect(RecordingFiles.handleLeftovers(in: URL(fileURLWithPath: "/nonexistent/folder"), writtenBefore: Date()).isEmpty)
    }

    @Test func freeSpaceIsReadable() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let free = try #require(RecordingFiles.freeBytes(at: dir.url))
        #expect(free > 0)
        #expect(RecordingFiles.freeBytes(at: URL(fileURLWithPath: "/nonexistent/folder")) == nil)
        // The open file's own volume, the same one.
        let temp = try dir.file(RecordingFiles.tempName(), contents: "movie")
        let file = try #require(RecordingFile(temp))
        #expect(try #require(file.freeBytes) > 0)
        #expect(file.size == 5)
    }

    @Test func purgeableSpaceCountsOnlyOnANearlyFullDisk() {
        let gb: Int64 = 1 << 30
        var asked = 0
        let important = { () -> Int64? in
            asked += 1
            return 20 * gb
        }
        // Plenty free: what statfs says, without asking for the slow figure.
        #expect(RecordingFiles.usableBytes(free: 5 * gb, important: important) == 5 * gb)
        #expect(asked == 0)
        // Nearly full, with purgeable space: what macOS would make room for.
        #expect(RecordingFiles.usableBytes(free: 100 << 20, important: important) == 20 * gb)
        #expect(asked == 1)
        // FAT and exFAT say 0; a figure that can't be read is none.
        #expect(RecordingFiles.usableBytes(free: 100 << 20) { 0 } == 100 << 20)
        #expect(RecordingFiles.usableBytes(free: 100 << 20) { nil } == 100 << 20)
    }

    @Test func aFAT32DisksFileSizeLimitStopsARecordingShortOfIt() throws {
        let fat32: Int64 = 4_294_967_295
        #expect(!RecordingFiles.isNearSizeLimit(fat32 - 200 * 1024 * 1024, limit: fat32))
        #expect(RecordingFiles.isNearSizeLimit(fat32 - 100 * 1024 * 1024, limit: fat32))
        #expect(!RecordingFiles.isNearSizeLimit(fat32 * 4, limit: nil))
        // APFS's is far beyond any recording.
        let dir = try TempDir()
        defer { dir.remove() }
        #expect(try #require(RecordingFiles.maximumFileSize(at: dir.url)) > 1 << 50)
    }
}
