import Foundation
import Synchronization

/// File names for captures: `Screenshot 2026-10-14 at 17.42.17.png`.
/// 24-hour time, `en_US_POSIX`, plain ASCII spaces (no U+202F), ` (2)` on collision.
public enum FileNamer {
    /// One formatter per time zone, made once: making one for every name cost the release about 1 ms of the main
    /// thread's time before the thumbnail.
    private static let formatters = Mutex<[TimeZone: DateFormatter]>([:])

    public static func fileName(for date: Date, timeZone: TimeZone = .current, suffix: Int = 1) -> String {
        let stamp = formatters.withLock { formatters in
            let f = formatters[timeZone] ?? {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.calendar = Calendar(identifier: .gregorian)
                f.timeZone = timeZone
                f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
                formatters[timeZone] = f
                return f
            }()
            return f.string(from: date)
        }
        let base = "Screenshot \(stamp)"
        return suffix > 1 ? "\(base) (\(suffix)).png" : "\(base).png"
    }

    /// First URL in `folder` that doesn't exist yet: the base name, then ` (2)`, ` (3)`, …
    public static func uniqueURL(
        in folder: URL,
        for date: Date,
        timeZone: TimeZone = .current,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        var n = 1
        while true {
            let url = folder.appendingPathComponent(fileName(for: date, timeZone: timeZone, suffix: n))
            if !exists(url) { return url }
            n += 1
        }
    }
}
