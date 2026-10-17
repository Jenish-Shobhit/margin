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
        let cutOff = try movie(dir, RecordingFiles.tempName(), [box("ftyp"), box("mdat", payload: 200, size: 0)])
        let finished = try movie(dir, RecordingFiles.tempName(), [box("ftyp"), box("moov"), box("mdat", payload: 200)])
        let current = try dir.file(RecordingFiles.tempName())
        let png = try dir.file(".margin-\(UUID().uuidString).tmp")
        let named = try dir.file("Screen Recording 2026-10-14 at 17.42.17.mp4")
        let launch = Date()
        for url in [cutOff, finished, png, named] {
            try fm.setAttributes([.modificationDate: launch.addingTimeInterval(-600)], ofItemAtPath: url.path)
        }
        try fm.setAttributes([.creationDate: date], ofItemAtPath: finished.path)
        try fm.setAttributes([.modificationDate: launch.addingTimeInterval(5)], ofItemAtPath: current.path)
        let outcomes = RecordingFiles.handleLeftovers(in: dir.url, writtenBefore: launch, timeZone: utc)
        // The finished one gets the name of when it was started, next to one already there; the cut-off one goes.
        let recovered = dir.url.appendingPathComponent("Screen Recording 2026-10-14 at 17.42.17 (2).mp4")
        #expect(Set(outcomes) == [.recovered(recovered), .removed(cutOff)])
        // The recording under way, a PNG save's temp file (`LeftoverSaves`' business) and finished files stay.
        #expect(Set(dir.contents()) == Set([current, png, named, recovered].map(\.lastPathComponent)))
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
    }
}
