import Foundation
import os

/// Logging for capture. Watch timings with:
/// `log stream --level info --predicate 'subsystem == "io.github.jenish-shobhit.margin" && category == "timing"'`
enum CaptureLog {
    static let subsystem = "io.github.jenish-shobhit.margin"
    static let timing = Logger(subsystem: subsystem, category: "timing")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let signposter = OSSignposter(logger: timing)
}

/// A monotonic stopwatch that reads in milliseconds.
struct Stopwatch: Sendable {
    private let start = ContinuousClock.now

    var ms: Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}

/// The most recent timings, in milliseconds, keyed by name (for the DEBUG `dump-state` hook).
@MainActor
final class CaptureTimings {
    private(set) var values: [String: Double] = [:]

    func record(_ name: String, _ ms: Double) {
        values[name] = (ms * 10).rounded() / 10
        CaptureLog.timing.info("\(name, privacy: .public): \(ms, format: .fixed(precision: 1), privacy: .public) ms")
    }
}
