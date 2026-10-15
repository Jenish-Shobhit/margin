import AppKit
import QuartzCore
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

/// The most recent timings, in milliseconds, keyed by name (for the DEBUG `dump-state` hook). Each one is also
/// an info line in the `timing` category, `name: 12.3 ms`, which `scripts/bench.sh` collects.
@MainActor
final class CaptureTimings {
    /// For the parts with no timings of their own (the save pipeline, the shelf, hotkeys, launch).
    static let shared = CaptureTimings()

    private(set) var values: [String: Double] = [:]

    func record(_ name: String, _ ms: Double) {
        values[name] = (ms * 10).rounded() / 10
        CaptureLog.timing.info("\(name, privacy: .public): \(ms, format: .fixed(precision: 1), privacy: .public) ms")
    }

    /// Only the log line, from any thread (off the main actor there's no `values` to keep).
    nonisolated static func log(_ name: String, _ ms: Double) {
        CaptureLog.timing.info("\(name, privacy: .public): \(ms, format: .fixed(precision: 1), privacy: .public) ms")
    }

    /// A size, logged as `name: 123.4 KB`.
    func recordSize(_ name: String, bytes: Int) {
        CaptureLog.timing.info("\(name, privacy: .public): \(Double(bytes) / 1024, format: .fixed(precision: 1), privacy: .public) KB")
    }
}

/// When something drawn on the main thread can first be on screen. Cheap: one run-loop observer and one
/// display-link callback per measurement.
@MainActor
enum FrameTiming {
    /// Runs `body` once this run-loop turn's Core Animation commit is done (Core Animation commits in a
    /// before-waiting observer of order 2,000,000; this one runs after it), so `body` sees everything the main
    /// thread did before the screen could change, including work queued after the change itself.
    static func afterCommit(_ body: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 2_000_001
        ) { _, _ in
            MainActor.assumeIsolated { body() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// The first refresh of `screen` at or after `time` (`CACurrentMediaTime`): the earliest frame that can show
    /// what was committed at `time`. Worked out from the refresh grid of one display-link callback, so a callback
    /// that comes late (a busy main thread) still dates the first refresh after `time`.
    static func nextRefresh(of screen: NSScreen?, after time: CFTimeInterval,
                            _ report: @escaping @MainActor (CFTimeInterval) -> Void) {
        guard let screen = screen ?? NSScreen.main else { return }
        let probe = RefreshProbe(time: time, report: report)
        screen.displayLink(target: probe, selector: #selector(RefreshProbe.tick(_:))).add(to: .main, forMode: .common)
    }

    /// Milliseconds from `start` (a `Date`) to the next refresh after a commit happening now.
    static func measure(from start: Date, on screen: NSScreen?, commit: @escaping @MainActor (Double) -> Void,
                        frame: @escaping @MainActor (Double) -> Void) {
        afterCommit {
            let committed = CACurrentMediaTime()
            let committedMs = Date().timeIntervalSince(start) * 1000
            commit(committedMs)
            nextRefresh(of: screen, after: committed) { refresh in
                frame(committedMs + (refresh - committed) * 1000)
            }
        }
    }
}

@MainActor
private final class RefreshProbe: NSObject {
    let time: CFTimeInterval
    let report: @MainActor (CFTimeInterval) -> Void

    init(time: CFTimeInterval, report: @escaping @MainActor (CFTimeInterval) -> Void) {
        self.time = time
        self.report = report
    }

    @objc func tick(_ link: CADisplayLink) {
        link.invalidate() // the link retains its target until then
        let period = link.targetTimestamp - link.timestamp
        var refresh = link.targetTimestamp
        if period > 0 {
            while refresh - period >= time { refresh -= period }
        }
        report(max(refresh, time))
    }
}

/// When this process started, from the kernel (for launch timings).
enum ProcessLaunch {
    static let date: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }()

    /// Milliseconds since the process started.
    static var ms: Double? { date.map { Date().timeIntervalSince($0) * 1000 } }
}
