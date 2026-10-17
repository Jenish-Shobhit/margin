import Foundation
import MarginKit
import Testing

@Suite struct FileNamerTests {
    let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-14 00:00:00 UTC.
    let midnightUTC: TimeInterval = 1_791_936_000

    @Test func fileNameIs24HourWithPlainSpaces() {
        let date = Date(timeIntervalSince1970: 1_791_999_737) // 2026-10-14 17:42:17 UTC
        let name = FileNamer.fileName(for: date, timeZone: utc)
        #expect(name == "Screenshot 2026-10-14 at 17.42.17.png")
        #expect(!name.unicodeScalars.contains { $0.value == 0x202F })
    }

    static let clockCases: [(TimeInterval, String)] = [
        (309, "Screenshot 2026-10-14 at 00.05.09.png"),
        (43_200, "Screenshot 2026-10-14 at 12.00.00.png"),
        (46_801, "Screenshot 2026-10-14 at 13.00.01.png"),
        (86_399, "Screenshot 2026-10-14 at 23.59.59.png"),
    ]

    @Test(arguments: clockCases)
    func twentyFourHourClock(offset: TimeInterval, expected: String) {
        #expect(FileNamer.fileName(for: Date(timeIntervalSince1970: midnightUTC + offset), timeZone: utc) == expected)
    }

    @Test func nameIsPlainASCIIWithNoAMPM() {
        let name = FileNamer.fileName(for: Date(timeIntervalSince1970: midnightUTC + 15 * 3600), timeZone: utc)
        #expect(name.unicodeScalars.allSatisfy { $0.isASCII })
        #expect(!name.contains("PM") && !name.contains("AM"))
        // Only plain U+0020 spaces: "Screenshot", date, "at", time.
        #expect(name.split(separator: " ").count == 4)
        #expect(!name.unicodeScalars.contains { $0.properties.isWhitespace && $0 != " " })
    }

    @Test func suffixes() {
        let date = Date(timeIntervalSince1970: midnightUTC)
        #expect(FileNamer.fileName(for: date, timeZone: utc, suffix: 1) == "Screenshot 2026-10-14 at 00.00.00.png")
        #expect(FileNamer.fileName(for: date, timeZone: utc, suffix: 2) == "Screenshot 2026-10-14 at 00.00.00 (2).png")
        #expect(FileNamer.fileName(for: date, timeZone: utc, suffix: 3) == "Screenshot 2026-10-14 at 00.00.00 (3).png")
        #expect(FileNamer.fileName(for: date, timeZone: utc, suffix: 0) == "Screenshot 2026-10-14 at 00.00.00.png")
    }

    @Test func collisionsCountUp() {
        let folder = URL(fileURLWithPath: "/tmp/shots", isDirectory: true)
        let date = Date(timeIntervalSince1970: midnightUTC)
        let base = "Screenshot 2026-10-14 at 00.00.00"
        #expect(FileNamer.uniqueURL(in: folder, for: date, timeZone: utc) { _ in false }.lastPathComponent == "\(base).png")

        var taken: Set<String> = ["\(base).png"]
        #expect(FileNamer.uniqueURL(in: folder, for: date, timeZone: utc) { taken.contains($0.lastPathComponent) }
            .lastPathComponent == "\(base) (2).png")

        taken.insert("\(base) (2).png")
        let third = FileNamer.uniqueURL(in: folder, for: date, timeZone: utc) { taken.contains($0.lastPathComponent) }
        #expect(third.lastPathComponent == "\(base) (3).png")
        #expect(third.deletingLastPathComponent().path == folder.path)
    }

    @Test func collisionsOnDisk() throws {
        let folder = try TempDir()
        defer { folder.remove() }
        let date = Date(timeIntervalSince1970: midnightUTC)
        let first = FileNamer.uniqueURL(in: folder.url, for: date, timeZone: utc)
        try Data("1".utf8).write(to: first)
        let second = FileNamer.uniqueURL(in: folder.url, for: date, timeZone: utc)
        try Data("2".utf8).write(to: second)
        let third = FileNamer.uniqueURL(in: folder.url, for: date, timeZone: utc)
        #expect(second.lastPathComponent == "Screenshot 2026-10-14 at 00.00.00 (2).png")
        #expect(third.lastPathComponent == "Screenshot 2026-10-14 at 00.00.00 (3).png")
    }

    @Test(arguments: [
        ("UTC", "Screenshot 2026-10-14 at 20.00.00.png"),
        ("Asia/Kolkata", "Screenshot 2026-10-15 at 01.30.00.png"),       // +5:30, next day
        ("America/Los_Angeles", "Screenshot 2026-10-14 at 13.00.00.png"), // PDT, −7
        ("Asia/Tokyo", "Screenshot 2026-10-15 at 05.00.00.png"),          // +9
        ("Pacific/Chatham", "Screenshot 2026-10-15 at 09.45.00.png"),     // +13:45 (daylight time)
    ])
    func timeZones(identifier: String, expected: String) {
        let date = Date(timeIntervalSince1970: 1_792_008_000) // 2026-10-14 20:00:00 UTC
        #expect(FileNamer.fileName(for: date, timeZone: TimeZone(identifier: identifier)!) == expected)
    }

    @Test func defaultTimeZoneIsLocal() {
        let date = Date(timeIntervalSince1970: 1_792_008_000)
        #expect(FileNamer.fileName(for: date) == FileNamer.fileName(for: date, timeZone: .current))
    }

    // MARK: Screen recordings

    @Test func recordingsAreNamedLikeMacOSScreenRecordings() {
        let date = Date(timeIntervalSince1970: 1_791_999_737) // 2026-10-14 17:42:17 UTC
        let name = FileNamer.fileName(for: date, kind: .recording, timeZone: utc)
        #expect(name == "Screen Recording 2026-10-14 at 17.42.17.mp4")
        #expect(name.unicodeScalars.allSatisfy { $0.isASCII })
        #expect(FileNamer.fileName(for: date, kind: .recording, timeZone: utc, suffix: 2)
            == "Screen Recording 2026-10-14 at 17.42.17 (2).mp4")
        // The default is a screenshot, as before.
        #expect(FileNamer.fileName(for: date, kind: .screenshot, timeZone: utc) == FileNamer.fileName(for: date, timeZone: utc))
        #expect(ShelfItem.Kind.recording.pathExtension == "mp4")
        #expect(ShelfItem.Kind.screenshot.pathExtension == "png")
    }

    @Test func recordingCollisionsCountUpOnTheirOwnNames() throws {
        let folder = try TempDir()
        defer { folder.remove() }
        let date = Date(timeIntervalSince1970: midnightUTC)
        // A screenshot taken the same second doesn't take the recording's name.
        try Data("png".utf8).write(to: FileNamer.uniqueURL(in: folder.url, for: date, timeZone: utc))
        let first = FileNamer.uniqueURL(in: folder.url, for: date, kind: .recording, timeZone: utc)
        #expect(first.lastPathComponent == "Screen Recording 2026-10-14 at 00.00.00.mp4")
        try Data("mp4".utf8).write(to: first)
        let second = FileNamer.uniqueURL(in: folder.url, for: date, kind: .recording, timeZone: utc)
        #expect(second.lastPathComponent == "Screen Recording 2026-10-14 at 00.00.00 (2).mp4")
    }
}
