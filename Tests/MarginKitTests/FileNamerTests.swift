import Foundation
import MarginKit
import Testing

@Test func fileNameIs24HourWithPlainSpaces() {
    let date = Date(timeIntervalSince1970: 1_791_999_737) // 2026-10-14 17:42:17 UTC
    let name = FileNamer.fileName(for: date, timeZone: TimeZone(identifier: "UTC")!)
    #expect(name == "Screenshot 2026-10-14 at 17.42.17.png")
    #expect(!name.unicodeScalars.contains { $0.value == 0x202F })
}
