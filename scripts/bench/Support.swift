import AppKit
import Darwin
import IOKit

// The parts of the bench driver that talk to Margin and to macOS: the timing log, the control hook, installing
// and launching, the frontmost-app gate, and statistics. See main.swift.

let marginBundleID = "io.github.jenish-shobhit.margin"
let installedApp = "/Applications/Margin.app"
let hookName = Notification.Name("io.github.jenish-shobhit.margin.debug")

func say(_ text: String) {
    FileHandle.standardError.write(Data("bench: \(text)\n".utf8))
}

func fail(_ text: String) -> Never {
    say(text)
    exit(1)
}

func sleep(ms: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(max(0, ms) * 1_000_000))
}

/// Runs a tool and returns its standard output (trimmed). Throws on a non-zero exit.
@discardableResult
func shell(_ path: String, _ args: [String]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    try p.run()
    // Read both pipes while it runs (a full pipe would block it).
    var errData = Data()
    let errReader = Thread { errData = err.fileHandleForReading.readDataToEndOfFile() }
    errReader.start()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    while !errReader.isFinished { usleep(1000) }
    guard p.terminationStatus == 0, p.terminationReason == .exit else {
        let how = p.terminationReason == .uncaughtSignal ? "was killed by signal" : "exited"
        let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw NSError(domain: "bench", code: Int(p.terminationStatus), userInfo: [
            NSLocalizedDescriptionKey: "\(path) \(args.joined(separator: " ")) \(how) \(p.terminationStatus): \(message)"])
    }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - The timing log

/// One line of Margin's `timing` category: `name: 12.3 ms`, `name: 45.6 KB` or `mark: text`.
struct LogEvent {
    let seq: Int
    let name: String
    let value: Double
    let unit: String
    let text: String
    let pid: Int32
    let time: Date
}

/// Streams Margin's timing log (`log stream --level info`) into memory. Info lines aren't kept by the log store,
/// so they have to be streamed while the captures run.
final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [LogEvent] = []
    private let process = Process()
    private var buffer = Data()
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return f
    }()

    func start() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--level", "info", "--style", "ndjson", "--predicate",
                             "subsystem == \"\(marginBundleID)\" && category == \"timing\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.buffer.append(data) // the handler runs on one serial queue
            while let nl = self.buffer.firstIndex(of: 0x0A) {
                let line = self.buffer[self.buffer.startIndex..<nl]
                self.buffer.removeSubrange(self.buffer.startIndex...nl)
                self.parse(Data(line))
            }
        }
        try process.run()
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    private func parse(_ line: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = json["eventMessage"] as? String else { return }
        let pid = Int32((json["processID"] as? Int) ?? 0)
        let time = (json["timestamp"] as? String).flatMap(stamp.date(from:)) ?? Date()
        var name = "", value = 0.0, unit = "", text = ""
        if message.hasPrefix("mark: ") {
            name = "mark"
            text = String(message.dropFirst("mark: ".count))
        } else {
            // name: 12.3 ms
            let parts = message.split(separator: " ")
            guard parts.count == 3, parts[0].hasSuffix(":"), let v = Double(parts[1]) else { return }
            name = String(parts[0].dropLast())
            value = v
            unit = String(parts[2])
        }
        lock.lock()
        events.append(LogEvent(seq: events.count, name: name, value: value, unit: unit, text: text, pid: pid, time: time))
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }

    func events(since seq: Int) -> [LogEvent] {
        lock.lock()
        defer { lock.unlock() }
        return seq < events.count ? Array(events[seq...]) : []
    }

    /// Waits until every name in `names` has appeared since `seq`. Returns the events since `seq`, or nil on timeout.
    func wait(for names: Set<String>, since seq: Int, timeout: Double) async -> [LogEvent]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let evs = events(since: seq)
            if names.isSubset(of: Set(evs.map(\.name))) { return evs }
            await sleep(ms: 4)
        }
        return nil
    }

    /// Logs `mark: <text>` through Margin and waits for it: the events after it belong to what comes next.
    /// Returns the mark's sequence number, or nil if Margin didn't answer (not a bench or debug build, or not running).
    func mark(_ text: String, timeout: Double = 3) async -> Int? {
        let since = count
        post("mark \(text)")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let e = events(since: since).first(where: { $0.name == "mark" && $0.text == text }) { return e.seq + 1 }
            await sleep(ms: 4)
        }
        return nil
    }
}

/// A command for Margin's control hook (bench and debug builds only).
func post(_ command: String) {
    DistributedNotificationCenter.default().postNotificationName(
        hookName, object: command, userInfo: nil, deliverImmediately: true)
}

// MARK: - Margin's process, prefs and files

enum Margin {
    static var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: marginBundleID).first
    }

    static var pid: pid_t? { running?.processIdentifier }

    /// True when the app's binary has the control hook (its notification name is in no other code).
    static func hasHook(_ app: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: app + "/Contents/MacOS/Margin") else { return false }
        return data.range(of: Data("margin.debug".utf8)) != nil
    }

    static func quit() async {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: marginBundleID) { app.terminate() }
        for _ in 0..<50 where running != nil { await sleep(ms: 100) }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: marginBundleID) { app.forceTerminate() }
        for _ in 0..<20 where running != nil { await sleep(ms: 100) }
    }

    /// Opens /Applications/Margin.app without activating it. Returns when it was asked to open.
    static func launch() async throws -> Date {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        let asked = Date()
        _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: installedApp), configuration: config)
        return asked
    }

    /// Replaces /Applications/Margin.app with `app` (Margin must have quit), as `scripts/build.sh --install` does.
    /// Tries twice; the caller puts the backup back if both fail.
    static func install(_ app: String) throws {
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                try shell("/bin/rm", ["-rf", installedApp])
                try shell("/usr/bin/ditto", [app, installedApp])
                return
            } catch {
                lastError = error
                say("install attempt \(attempt + 1) failed: \(error.localizedDescription)")
                usleep(1_000_000)
            }
        }
        throw lastError!
    }

    static var shelfURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Margin/shelf.json")
    }

    /// Margin's physical footprint in MB (what Activity Monitor calls Memory).
    static func footprintMB(_ pid: pid_t) -> Double? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : nil
    }
}

/// Everything the bench changes, put back at the end: the installed app, Margin's preferences, shelf.json and the
/// clipboard (the bench turns Copy each capture off, so it shouldn't change, but it's checked).
final class Backup {
    let dir: URL
    private var hadShelf = false
    private var clipboard: [[(NSPasteboard.PasteboardType, Data)]] = []
    private var clipboardCount = 0

    init(dir: URL) { self.dir = dir }

    func save() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = dir.appendingPathComponent("Margin.app")
        if fm.fileExists(atPath: app.path) { try fm.removeItem(at: app) }
        if fm.fileExists(atPath: installedApp) { try shell("/usr/bin/ditto", [installedApp, app.path]) }
        try shell("/usr/bin/defaults", ["export", marginBundleID, dir.appendingPathComponent("prefs.plist").path])
        let shelf = dir.appendingPathComponent("shelf.json")
        if fm.fileExists(atPath: shelf.path) { try fm.removeItem(at: shelf) }
        hadShelf = fm.fileExists(atPath: Margin.shelfURL.path)
        if hadShelf { try fm.copyItem(at: Margin.shelfURL, to: shelf) }
        let pb = NSPasteboard.general
        clipboardCount = pb.changeCount
        clipboard = (pb.pasteboardItems ?? []).map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } }
        say("backed up the app, prefs and shelf.json to \(dir.path)")
    }

    /// Margin must have quit. Reinstalls the app as it was; doesn't launch it.
    func restore() throws {
        let fm = FileManager.default
        try? shell("/usr/bin/defaults", ["delete", marginBundleID])
        try shell("/usr/bin/defaults", ["import", marginBundleID, dir.appendingPathComponent("prefs.plist").path])
        if fm.fileExists(atPath: Margin.shelfURL.path) { try fm.removeItem(at: Margin.shelfURL) }
        if hadShelf { try fm.copyItem(at: dir.appendingPathComponent("shelf.json"), to: Margin.shelfURL) }
        let app = dir.appendingPathComponent("Margin.app")
        if fm.fileExists(atPath: app.path) { try Margin.install(app.path) }
        guard fm.fileExists(atPath: installedApp + "/Contents/MacOS/Margin") else {
            throw NSError(domain: "bench", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(installedApp) is missing after the restore"])
        }
        let pb = NSPasteboard.general
        if pb.changeCount != clipboardCount, !clipboard.isEmpty {
            pb.clearContents()
            pb.writeObjects(clipboard.map { pairs in
                let item = NSPasteboardItem()
                for (t, d) in pairs { item.setData(d, forType: t) }
                return item
            })
            say("the clipboard changed during the run; put it back")
        }
        say("restored the app, prefs and shelf.json")
    }
}

// MARK: - The frontmost-app gate

/// The bench only acts while its own window or Margin is in front. Checked with LaunchServices (`lsappinfo`) and
/// AppKit, before every step that could touch the screen.
enum Gate {
    static func frontPID() -> pid_t? {
        guard let asn = try? shell("/usr/bin/lsappinfo", ["front"]), !asn.isEmpty,
              let info = try? shell("/usr/bin/lsappinfo", ["info", "-only", "pid", asn]) else { return nil }
        // "pid"=12345, or for an app without a bundle (the bench itself): … pid = 12345 …
        return pidValue(in: info)
    }

    /// The number after `pid` and `=` in `lsappinfo` output.
    static func pidValue(in info: String) -> pid_t? {
        guard let key = info.range(of: "pid") else { return nil }
        let rest = info[key.upperBound...].drop { $0 == "\"" || $0 == " " }
        guard rest.first == "=" else { return nil }
        return pid_t(String(rest.dropFirst().drop { $0 == " " }.prefix { $0.isNumber }))
    }

    /// Seconds since the last keyboard or mouse input (IOKit's HIDIdleTime). The bench posts no input itself,
    /// except the real ⇧⌘4 of --real-hotkey (see `lastPost`).
    static func idleSeconds() -> Double {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        defer { IOObjectRelease(service) }
        guard service != 0, let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return .infinity }
        return value.doubleValue / 1e9
    }

    /// When the bench last posted input of its own.
    nonisolated(unsafe) static var lastPost = Date.distantPast

    /// Someone used the keyboard or mouse in the last second (not the bench's own ⇧⌘4).
    static func userActive() -> Bool {
        let idle = idleSeconds()
        return idle < 1 && Date().timeIntervalSince(lastPost) > idle + 0.3
    }

    static func allowed(_ pid: pid_t?) -> Bool {
        guard let pid else { return false }
        return pid == getpid() || pid == Margin.pid
    }

    static func frontName(_ pid: pid_t?) -> String {
        pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "another app"
    }

    /// Waits until the bench or Margin is in front and nobody is using the Mac: after any keyboard or mouse input,
    /// until there's been none for `idle` seconds. False after `maxWait` seconds, or when `stop()` says so.
    @MainActor
    static func wait(idle: Double, maxWait: Double, stop: () -> Bool) async -> Bool {
        var announced = ""
        let start = Date()
        var mustIdle = userActive()
        while !stop() {
            if userActive() { mustIdle = true }
            let front = frontPID()
            let inFront = allowed(front) && allowed(NSWorkspace.shared.frontmostApplication?.processIdentifier)
            let quiet = !mustIdle || idleSeconds() >= idle
            if inFront, quiet {
                if !announced.isEmpty {
                    say("resumed")
                    await sleep(ms: 1000)
                }
                return true
            }
            let why = !inFront ? "\(frontName(front)) is in front; click the bench window to go on"
                : "the Mac is in use; going on after \(Int(idle)) s without input"
            if why != announced {
                say("paused: \(why)")
                announced = why
            }
            if Date().timeIntervalSince(start) > maxWait { return false }
            await sleep(ms: 500)
        }
        return false
    }
}

// MARK: - Statistics

struct Sample: Codable {
    var build: String
    var suite: String
    var trial: Int
    var metric: String
    var value: Double
    var unit: String
}

enum Stats {
    /// Linear interpolation between closest ranks (R-7).
    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        let h = Double(sorted.count - 1) * q
        let lo = Int(h.rounded(.down)), hi = min(lo + 1, sorted.count - 1)
        return sorted[lo] + (h - Double(lo)) * (sorted[hi] - sorted[lo])
    }

    /// Two-sided Mann–Whitney U test, normal approximation with tie correction. Returns the p-value.
    static func mannWhitney(_ a: [Double], _ b: [Double]) -> Double {
        let n1 = Double(a.count), n2 = Double(b.count)
        guard n1 > 0, n2 > 0 else { return .nan }
        let all = (a.map { ($0, 0) } + b.map { ($0, 1) }).sorted { $0.0 < $1.0 }
        var ranks = [Double](repeating: 0, count: all.count)
        var tie = 0.0
        var i = 0
        while i < all.count {
            var j = i
            while j + 1 < all.count, all[j + 1].0 == all[i].0 { j += 1 }
            let r = Double(i + j) / 2 + 1
            for k in i...j { ranks[k] = r }
            let t = Double(j - i + 1)
            tie += t * t * t - t
            i = j + 1
        }
        let r1 = zip(all, ranks).filter { $0.0.1 == 0 }.reduce(0) { $0 + $1.1 }
        let u = r1 - n1 * (n1 + 1) / 2
        let n = n1 + n2
        let sigma = sqrt(n1 * n2 / 12 * ((n + 1) - tie / (n * (n - 1))))
        guard sigma > 0 else { return 1 }
        let z = (abs(u - n1 * n2 / 2) - 0.5) / sigma
        return erfc(z / sqrt(2))
    }

    /// The spec's targets (spec §3).
    static let targets: [String: Double] = [
        "hotkeyToFirstFrozen": 80, "hotkeyToFirstFrozenFrame": 80, "e2e.keyToFirstFrozenFrame": 80,
        "releaseToThumbnail": 100, "releaseToThumbnailCommit": 100, "releaseToThumbnailFrame": 100,
        "e2e.toThumbnailFrame": 100, "releaseToFile": 200, "e2e.toFile": 200,
    ]

    static func fmt(_ v: Double) -> String {
        v.isNaN ? "–" : v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }

    /// The table: one block per suite, a row per metric. With two builds, side by side with the change and p.
    static func report(_ samples: [Sample]) -> String {
        var out = ""
        let builds = samples.reduce(into: [String]()) { if !$0.contains($1.build) { $0.append($1.build) } }
        let suites = samples.reduce(into: [String]()) { if !$0.contains($1.suite) { $0.append($1.suite) } }
        for suite in suites {
            let rows = samples.filter { $0.suite == suite }
            let metrics = rows.reduce(into: [String]()) { if !$0.contains($1.metric) { $0.append($1.metric) } }
            out += "\n## \(suite)\n"
            if builds.count == 2 {
                let (a, b) = (builds[0], builds[1])
                out += pad("metric", 34) + pad("n", 5) + pad("\(a) med", 10) + pad("p90", 9) + pad("\(b) med", 10)
                    + pad("p90", 9) + pad("Δ med", 9) + pad("p", 7) + "\n"
                for m in metrics {
                    let va = rows.filter { $0.metric == m && $0.build == a }.map(\.value).sorted()
                    let vb = rows.filter { $0.metric == m && $0.build == b }.map(\.value).sorted()
                    let ma = quantile(va, 0.5), mb = quantile(vb, 0.5)
                    let delta = ma != 0 ? (mb - ma) / ma * 100 : .nan
                    let p = mannWhitney(va, vb)
                    out += pad(m, 34) + pad("\(min(va.count, vb.count))", 5) + pad(fmt(ma), 10) + pad(fmt(quantile(va, 0.9)), 9)
                        + pad(fmt(mb), 10) + pad(fmt(quantile(vb, 0.9)), 9)
                        + pad(delta.isNaN ? "–" : String(format: "%+.0f%%", delta), 9) + pad(p.isNaN ? "–" : String(format: "%.3f", p), 7) + "\n"
                }
            } else {
                out += pad("metric", 34) + pad("n", 5) + pad("median", 9) + pad("p90", 9) + pad("min", 9) + pad("max", 9)
                    + pad("unit", 5) + "target\n"
                for m in metrics {
                    let vs = rows.filter { $0.metric == m }.map(\.value).sorted()
                    let unit = rows.first { $0.metric == m }?.unit ?? ""
                    let target = targets[m].map { t in "≤ \(Int(t))" + (quantile(vs, 0.5) <= t ? "" : "  MISSED") } ?? ""
                    out += pad(m, 34) + pad("\(vs.count)", 5) + pad(fmt(quantile(vs, 0.5)), 9) + pad(fmt(quantile(vs, 0.9)), 9)
                        + pad(fmt(vs.first ?? .nan), 9) + pad(fmt(vs.last ?? .nan), 9) + pad(unit, 5) + target + "\n"
                }
            }
        }
        return out
    }

    private static func pad(_ s: String, _ w: Int) -> String {
        s.count >= w ? s + " " : s + String(repeating: " ", count: w - s.count)
    }
}
