// Margin's benchmark driver. Build and run it through scripts/bench.sh, which compiles this folder together with
// Sources/MarginKit (for the offline timings).
//
// It drives a bench build of Margin (release optimisation plus the control hook: scripts/build.sh --bench)
// through the same calls a shortcut or a drag makes, collects the `timing` log lines each capture writes, and
// prints median / p90 / min / max per metric. Two builds can be compared, interleaved in blocks.
//
// Safety: it backs up and restores the installed app, Margin's preferences, shelf.json and the clipboard; saves
// go to a scratch folder with Copy each capture and the sound off; and it acts only while its own window or Margin
// is in front (checked before every capture; it pauses otherwise).
import AppKit
import CoreGraphics

let usage = """
usage: bench <command> [options]

  run                    N captures of each kind with the installed (or --app) bench build
  ab <A.app> <B.app>     the same for two bench builds, interleaved in blocks (--block)
  launch                 quit and launch N times: launch → ready, and memory once the shelf is up
  report <file>…         the table again from results files (two files, or two builds in one: A/B)
  encode <png>…          PNG encode options on real captures, offline (time, size, thumbnail decode)
  micro                  offline timings of small steps on the main thread (names, prefs, shelf.json…)
  make-shelf <dir> <n>   <dir>/shelf.json with n cards (APFS clones of one busy 2940×1912 PNG) for launch --shelf

options for run / ab / launch:
  --app <path>           install this bench build first (run, launch)
  --n <count>            trials per suite and build (default 30; launch: 10)
  --suites <list>        area-small,area-medium,area-full,screen,repeat,window (default: all)
  --content ui|photo     what the bench window shows: a flat app UI (default) or a busy photo-like image
  --real-hotkey          area suites: post a real ⇧⌘4 (needs Accessibility; macOS's own ⇧⌘4 must be off)
  --sound                leave the shutter sound on
  --block <count>        ab: trials per build before switching (default 5)
  --warmup <count>       untimed captures per suite after each launch (default 1)
  --shelf <file|empty>   launch: the shelf.json to launch with
  --scratch <dir>        where shots, backups and results go (default .build/bench-scratch)
  --out <file>           results file (default <scratch>/results-<time>.jsonl)
  --keep-shots           don't delete the captured PNGs
  --idle <s>             seconds without keyboard or mouse input before the bench takes the screen, and before it
                         goes on after anyone touched either (default 20)
  --max-pause <s>        give up after waiting this long for the bench window to be in front (default 600)
"""

// MARK: - Options

struct Options {
    var command = ""
    var positional: [String] = []
    var app: String?
    var n: Int?
    var suites = Suite.allCases
    var content = Content.ui
    var realHotkey = false
    var sound = false
    var block = 5
    var warmup = 1
    var shelf: String?
    var scratch = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bench-scratch")
    var out: URL?
    var keepShots = false
    var maxPause = 600.0
    var idle = 20.0

    init(_ args: [String]) {
        var it = args.makeIterator()
        command = it.next() ?? "help"
        func value(_ flag: String) -> String {
            guard let v = it.next() else { fail("\(flag) needs a value") }
            return v
        }
        while let a = it.next() {
            switch a {
            case "--app": app = URL(fileURLWithPath: value(a)).standardizedFileURL.path
            case "--n": n = Int(value(a))
            case "--suites":
                suites = value(a).split(separator: ",").map { s in
                    guard let suite = Suite(rawValue: String(s)) else {
                        fail("unknown suite \(s); one of \(Suite.allCases.map(\.rawValue))")
                    }
                    return suite
                }
            case "--content":
                guard let c = Content(rawValue: value(a)) else { fail("--content ui or photo") }
                content = c
            case "--real-hotkey": realHotkey = true
            case "--sound": sound = true
            case "--block": block = Int(value(a)) ?? 5
            case "--warmup": warmup = Int(value(a)) ?? 1
            case "--shelf": shelf = value(a)
            case "--scratch": scratch = URL(fileURLWithPath: value(a)).standardizedFileURL
            case "--out": out = URL(fileURLWithPath: value(a)).standardizedFileURL
            case "--keep-shots": keepShots = true
            case "--max-pause": maxPause = Double(value(a)) ?? 600
            case "--idle": idle = Double(value(a)) ?? 20
            case "-h", "--help": command = "help"
            default: positional.append(a)
            }
        }
    }
}

enum Suite: String, CaseIterable {
    case areaSmall = "area-small", areaMedium = "area-medium", areaFull = "area-full", screen, repeatArea = "repeat", window
}

enum Content: String {
    case ui, photo
}

// MARK: - The bench window

/// What every capture sees: a window over the whole main display (and a smaller one in front, for window mode),
/// drawn the same way every time, so encode and copy times don't depend on what happens to be on screen.
final class CanvasView: NSView {
    let content: Content
    let photo: CGImage?
    let title: String

    init(frame: NSRect, content: Content, photo: CGImage?, title: String) {
        self.content = content
        self.photo = photo
        self.title = title
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if content == .photo, let photo, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.interpolationQuality = .none
            ctx.draw(photo, in: bounds)
        } else {
            drawUI()
        }
        let banner = "\(title) · Margin benchmark running. Switch to another app to pause it."
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white,
            .backgroundColor: NSColor(calibratedRed: 0.1, green: 0.35, blue: 0.85, alpha: 1),
        ]
        banner.draw(at: CGPoint(x: 12, y: bounds.height - 24), withAttributes: attrs)
    }

    /// A plain app window: sidebar, toolbar, a list and paragraphs of text.
    private func drawUI() {
        NSColor.white.setFill()
        bounds.fill()
        NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 220, height: bounds.height).fill()
        NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
        NSRect(x: 220, y: bounds.height - 52, width: bounds.width - 220, height: 52).fill()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1)]
        let dim: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1)]
        let head: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: NSColor.black]
        let items = ["Inbox", "Today", "Upcoming", "Projects", "Design review", "Release notes", "Screenshots",
                     "Archive", "Shared with me", "Recently deleted", "Tags", "Settings"]
        var y = bounds.height - 90
        for (i, item) in items.enumerated() {
            if i == 2 {
                NSColor(calibratedRed: 0.2, green: 0.45, blue: 0.95, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 8, y: y - 5, width: 204, height: 26), xRadius: 6, yRadius: 6).fill()
            }
            item.draw(at: CGPoint(x: 24, y: y), withAttributes: i == 2 ? [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white] : body)
            y -= 30
        }
        for (i, label) in ["New", "Share", "Export", "Delete"].enumerated() {
            let r = NSRect(x: 240 + CGFloat(i) * 84, y: bounds.height - 40, width: 74, height: 26)
            NSColor(calibratedWhite: 1, alpha: 1).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            label.draw(at: CGPoint(x: r.minX + 14, y: r.minY + 5), withAttributes: body)
        }
        "Weekly planning".draw(at: CGPoint(x: 250, y: bounds.height - 100), withAttributes: head)
        let words = "the quick brown fox jumps over a lazy dog while seven bright screenshots land on the shelf and wait to be dragged into another app".split(separator: " ")
        y = bounds.height - 140
        var line = 0
        while y > 20 {
            var text = ""
            for k in 0..<14 { text += words[(line * 5 + k * 3) % words.count] + " " }
            text.draw(at: CGPoint(x: 250, y: y), withAttributes: line % 6 == 5 ? dim : body)
            if line % 6 == 5 { y -= 14 }
            y -= 22
            line += 1
        }
    }
}

/// A busy, photo-like image: fractal value noise in colour with per-pixel grain. Deterministic.
func makePhoto(width: Int, height: Int) -> CGImage {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    @inline(__always) func hash(_ x: Int, _ y: Int, _ s: Int) -> Double {
        var h = UInt64(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263 &+ s &* 1_442_695_041)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Double(h & 0xFFFF) / 65535
    }
    @inline(__always) func noise(_ x: Double, _ y: Double, _ s: Int) -> Double {
        let xi = Int(x), yi = Int(y)
        let fx = x - Double(xi), fy = y - Double(yi)
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let a = hash(xi, yi, s), b = hash(xi + 1, yi, s), c = hash(xi, yi + 1, s), d = hash(xi + 1, yi + 1, s)
        return a + (b - a) * sx + (c - a) * sy + (a - b - c + d) * sx * sy
    }
    for y in 0..<height {
        for x in 0..<width {
            var v = 0.0, amp = 0.5, f = 1.0 / 180
            for o in 0..<5 {
                v += amp * noise(Double(x) * f, Double(y) * f, o)
                amp *= 0.5
                f *= 2.1
            }
            let hue = noise(Double(x) / 400, Double(y) / 400, 7)
            let i = (y * width + x) * 4
            let grain = (hash(x, y, 9) - 0.5) * 0.035
            let r = v * (0.6 + 0.6 * hue) + grain, g = v * 0.9 + grain * 0.8, b = v * (1.2 - 0.7 * hue) + grain
            pixels[i] = UInt8(max(0, min(255, b * 255))) // BGRA, little-endian premultiplied-first
            pixels[i + 1] = UInt8(max(0, min(255, g * 255)))
            pixels[i + 2] = UInt8(max(0, min(255, r * 255)))
        }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

final class CanvasWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class Canvas {
    let screen: NSScreen
    let main: NSWindow
    let document: NSWindow

    init(content: Content) {
        screen = NSScreen.screens[0]
        let photo = content == .photo
            ? makePhoto(width: Int(screen.frame.width * screen.backingScaleFactor), height: Int(screen.frame.height * screen.backingScaleFactor))
            : nil
        let frame = screen.visibleFrame
        main = CanvasWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        main.contentView = CanvasView(frame: CGRect(origin: .zero, size: frame.size), content: content, photo: photo, title: "Bench")
        main.isReleasedWhenClosed = false
        let doc = CGRect(x: frame.midX - 450, y: frame.midY - 300, width: 900, height: 600)
        document = NSWindow(contentRect: doc, styleMask: [.titled], backing: .buffered, defer: false)
        document.title = "Bench window"
        document.contentView = CanvasView(frame: CGRect(origin: .zero, size: doc.size), content: content, photo: photo, title: "Window")
        document.isReleasedWhenClosed = false
    }

    func show() {
        main.orderFront(nil)
        document.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        document.orderOut(nil)
        main.orderOut(nil)
    }

    /// Area rects in AppKit global points on the main display.
    func rect(for suite: Suite) -> CGRect {
        let f = screen.frame
        switch suite {
        case .areaSmall: return CGRect(x: f.minX + 200, y: f.minY + 200, width: 400, height: 300)
        case .areaFull: return f
        default:
            let w = min(1200, f.width - 40), h = min(800, f.height - 60)
            return CGRect(x: f.midX - w / 2, y: f.minY + (f.height - 34 - h) / 2, width: w, height: h)
        }
    }

    /// Where window mode clicks: the middle of the smaller window.
    var windowPoint: CGPoint { CGPoint(x: document.frame.midX, y: document.frame.midY - 40) }
}

// MARK: - The bench

@MainActor
final class Bench {
    let options: Options
    let collector = Collector()
    let backup: Backup
    var canvas: Canvas?
    var results: [Sample] = []
    var stopRequested = false
    var marginPID: pid_t?
    /// When the last real ⇧⌘4 was posted (`mach_continuous_time`).
    var lastKeyPost: UInt64?
    let shots: URL
    let outURL: URL

    init(_ options: Options) {
        self.options = options
        backup = Backup(dir: options.scratch.appendingPathComponent("backup"))
        shots = options.scratch.appendingPathComponent("shots")
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        outURL = options.out ?? options.scratch.appendingPathComponent("results-\(stamp).jsonl")
    }

    // MARK: Setup and teardown

    /// Backs everything up, points Margin at the scratch folder, starts the log stream and shows the bench window.
    func setUp(showCanvas: Bool = true) async {
        if Margin.hasHook(installedApp) {
            say("note: \(installedApp) is a bench or debug build already; that's what the restore will put back")
        }
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        do { try backup.save() } catch { fail("backup failed: \(error.localizedDescription)") }
        do { try collector.start() } catch { fail("log stream failed: \(error.localizedDescription)") }
        await sleep(ms: 1000) // log stream takes a moment to attach
        if showCanvas {
            canvas = Canvas(content: options.content)
            await waitForIdle()
            canvas?.show()
            await sleep(ms: 500)
        }
    }

    func tearDown() async {
        say("cleaning up")
        canvas?.close()
        await Margin.quit()
        do { try backup.restore() } catch { say("RESTORE FAILED: \(error.localizedDescription). Backup: \(backup.dir.path)") }
        _ = try? await Margin.launch()
        collector.stop()
        if !options.keepShots { try? FileManager.default.removeItem(at: shots) }
        say("results: \(outURL.path)")
    }

    /// Stops for good: restores everything first, then exits.
    func abort(_ message: String) async -> Never {
        say(message)
        await tearDown()
        exit(1)
    }

    /// Quits Margin and installs `app`. On failure, the backed-up app goes back and the bench stops.
    func install(_ app: String) async {
        guard Margin.hasHook(app) else { await abort("\(app) has no control hook: build it with scripts/bench.sh build") }
        await Margin.quit()
        do {
            try Margin.install(app)
        } catch {
            await abort("install failed: \(error.localizedDescription)")
        }
    }

    /// Quits Margin, installs `app` (if any), sets the bench prefs and shelf, launches it and waits until it's ready.
    func relaunch(app: String?, shelf: String? = "empty") async -> Bool {
        if let app {
            await install(app)
        } else if !Margin.hasHook(installedApp) {
            await abort("\(installedApp) has no control hook: pass --app with a bench build (scripts/bench.sh build)")
        }
        await Margin.quit()
        let defaults = ["write", marginBundleID]
        _ = try? shell("/usr/bin/defaults", defaults + ["saveFolder", "-string", shots.path])
        _ = try? shell("/usr/bin/defaults", defaults + ["copyEachCapture", "-bool", "false"])
        _ = try? shell("/usr/bin/defaults", defaults + ["shutterSound", "-bool", options.sound ? "true" : "false"])
        if let shelf {
            try? FileManager.default.removeItem(at: Margin.shelfURL)
            if shelf == "empty" {
                try? Data("[]".utf8).write(to: Margin.shelfURL)
            } else {
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: shelf), to: Margin.shelfURL)
            }
        }
        let since = collector.count
        guard (try? await Margin.launch()) != nil else { return false }
        guard await collector.wait(for: ["launchToPrewarmed"], since: since, timeout: 20) != nil else {
            say("Margin didn't report ready in 20 s")
            return false
        }
        marginPID = Margin.pid
        await sleep(ms: 1500) // let the launch's background work (file checks, thumbnails) settle
        return true
    }

    /// Nobody has touched the keyboard or mouse for `--idle` seconds.
    func waitForIdle() async {
        var told = false
        while Gate.idleSeconds() < options.idle, !stopRequested {
            if !told {
                say("waiting for \(Int(options.idle)) s without keyboard or mouse input before taking the screen")
                told = true
            }
            await sleep(ms: 500)
        }
    }

    /// Before each capture: Margin is still the copy we launched, and the bench window or Margin is in front.
    func ready() async -> Bool {
        if stopRequested { return false }
        guard Margin.pid == marginPID else {
            say("Margin was relaunched or quit by someone else (scripts/release.sh?). Stopping; rerun when it's done.")
            stopRequested = true
            return false
        }
        if await Gate.wait(idle: options.idle, maxWait: options.maxPause, stop: { self.stopRequested }) { return true }
        if !stopRequested { say("the bench window wasn't in front for \(Int(options.maxPause)) s; stopping") }
        stopRequested = true
        return false
    }

    // MARK: Trials

    /// One capture of `suite`. Returns its metrics (name → value, unit), or nil if it didn't complete.
    func trial(_ suite: Suite, label: String) async -> [(String, Double, String)]? {
        guard let canvas, await ready(), let start = await collector.mark(label) else { return nil }
        let finish: Set<String> = ["releaseToFile", "releaseToThumbnailFrame", "finishSave.main"]
        var events: [LogEvent]?
        switch suite {
        case .areaSmall, .areaMedium, .areaFull:
            guard await beginOverlay(windowMode: false, since: start) else { return nil }
            await sleep(ms: 400) // a user takes this long to start dragging; the window list lands meanwhile
            let r = canvas.rect(for: suite)
            post("select \(r.minX) \(r.minY) \(r.width) \(r.height)")
            events = await collector.wait(for: finish, since: start, timeout: 6)
        case .window:
            guard await beginOverlay(windowMode: true, since: start) else { return nil }
            await sleep(ms: 400)
            let p = canvas.windowPoint
            post("click \(p.x) \(p.y)")
            events = await collector.wait(for: finish.union(["windowCapture"]), since: start, timeout: 6)
        case .screen:
            post("hotkey captureScreen")
            events = await collector.wait(for: finish.union(["screenCapture"]), since: start, timeout: 6)
        case .repeatArea:
            post("hotkey repeatArea")
            events = await collector.wait(for: finish.union(["areaCapture"]), since: start, timeout: 6)
        }
        guard let events else {
            say("\(label): incomplete (timed out); cancelling any overlay")
            post("cancel")
            await sleep(ms: 500)
            return nil
        }
        await sleep(ms: 150) // late lines (the frame after the commit, shelf.json)
        let all = collector.events(since: start).filter { $0.name != "mark" }
        var metrics: [(String, Double, String)] = []
        var seen: [String: (count: Int, sum: Double)] = [:]
        for e in all {
            // One display's freeze capture: the same name for any display, so suites compare across machines.
            let name = e.name.hasPrefix("freezeCapture.") ? "freezeCapture" : e.name
            if let s = seen[name] {
                seen[name] = (s.count + 1, s.sum + e.value)
            } else {
                seen[name] = (1, e.value)
                metrics.append((name, e.value, e.unit))
            }
        }
        // A line logged more than once per capture (each shelf.json save): how often, and the total.
        for (name, s) in seen.sorted(by: { $0.key < $1.key }) where s.count > 1 && name != "freezeCapture" {
            metrics.append(("\(name).count", Double(s.count), "×"))
            metrics.append(("\(name).sum", s.sum, all.first { $0.name == name }?.unit ?? ""))
        }
        _ = events
        let v = Dictionary(metrics.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        // From the user's action, for the kinds whose release clock starts after the capture.
        let action = v["screenCapture"] ?? v["areaCapture"] ?? v["windowCapture"]
        if let action {
            if let f = v["releaseToThumbnailFrame"] { metrics.append(("e2e.toThumbnailFrame", action + f, "ms")) }
            if let f = v["releaseToFile"] { metrics.append(("e2e.toFile", action + f, "ms")) }
        }
        // A real ⇧⌘4: from posting the key press to Margin's handler (the window server's hand-over), on the mach clock.
        if let posted = lastKeyPost, let handler = all.first(where: { $0.name == "hotkeyEventToHandler" }), handler.mach > posted {
            var tb = mach_timebase_info_data_t()
            mach_timebase_info(&tb)
            let press = Double(handler.mach - posted) * Double(tb.numer) / Double(tb.denom) / 1e6
            metrics.append(("keyPressToHandler", press, "ms"))
            if let f = v["hotkeyToFirstFrozenFrame"] { metrics.append(("e2e.keyToFirstFrozenFrame", press + f, "ms")) }
        }
        lastKeyPost = nil
        let main = ["release.endSession", "release.main", "release.lastArea", "release.focusBack", "finishSave.main", "areaFlash"]
            .compactMap { v[$0] }
        if !main.isEmpty { metrics.append(("release.mainThreadTotal", main.reduce(0, +), "ms")) }
        return metrics
    }

    /// ⇧⌘4 (or Capture Window): waits for every display to be frozen.
    private func beginOverlay(windowMode: Bool, since start: Int) async -> Bool {
        if windowMode {
            post("capture-window")
        } else if options.realHotkey {
            guard await ready() else { return false }
            postShiftCommand4()
        } else {
            post("hotkey captureArea")
        }
        guard await collector.wait(for: ["hotkeyToAllFrozen"], since: start, timeout: 4) != nil else {
            say("the overlay didn't freeze in 4 s; cancelling")
            post("cancel")
            await sleep(ms: 500)
            return false
        }
        return true
    }

    /// A real ⇧⌘4 through the window server, only with the bench window or Margin in front.
    private func postShiftCommand4() {
        guard Gate.allowed(Gate.frontPID()) else { return }
        Gate.lastPost = Date()
        lastKeyPost = mach_continuous_time()
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: 0x15, keyDown: down)
            e?.flags = [.maskCommand, .maskShift]
            e?.post(tap: .cghidEventTap)
            usleep(20_000)
        }
    }

    /// Captures `suite` `count` times, untimed `warmup` first. Clears the shelf every 10 captures.
    func runSuite(_ suite: Suite, build: String, count: Int, trialOffset: Int) async {
        if suite == .repeatArea {
            // ⇧⌘2 repeats the last area: make it the medium one.
            _ = await trial(.areaMedium, label: "setup-repeat")
            await sleep(ms: 800)
        }
        for w in 0..<options.warmup {
            _ = await trial(suite, label: "warmup-\(suite.rawValue)-\(w)")
            await sleep(ms: 800)
        }
        var done = 0
        var attempts = 0
        while done < count, attempts < count * 2, !stopRequested {
            attempts += 1
            if done > 0, done % 10 == 0 { await clearShelf() }
            let label = "\(build)-\(suite.rawValue)-\(trialOffset + done)"
            if let metrics = await trial(suite, label: label) {
                for (m, v, u) in metrics {
                    let s = Sample(build: build, suite: suite.rawValue, trial: trialOffset + done, metric: m, value: v, unit: u)
                    results.append(s)
                    append(s)
                }
                done += 1
                let line = metrics.first { $0.0 == "releaseToThumbnailFrame" }.map { String(format: "%.1f", $0.1) } ?? "–"
                let file = metrics.first { $0.0 == "releaseToFile" }.map { String(format: "%.1f", $0.1) } ?? "–"
                say("\(label): thumbnail frame \(line) ms, file \(file) ms")
            }
            await sleep(ms: 800) // the fly-in lands (0.45 s) before the next capture
        }
        await clearShelf()
        if let pid = Margin.pid, let mb = Margin.footprintMB(pid) {
            let s = Sample(build: build, suite: suite.rawValue, trial: trialOffset, metric: "memory.footprintAfter", value: mb, unit: "MB")
            results.append(s)
            append(s)
        }
    }

    func clearShelf() async {
        post("clear")
        await sleep(ms: 700)
    }

    private func append(_ s: Sample) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        if !FileManager.default.fileExists(atPath: outURL.path) {
            try? FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: outURL.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: outURL) {
            h.seekToEndOfFile()
            h.write(data + Data("\n".utf8))
            try? h.close()
        }
    }

    // MARK: Commands

    func run() async {
        let n = options.n ?? 30
        if options.realHotkey { checkRealHotkey() }
        await setUp()
        if await relaunch(app: options.app) {
            for suite in options.suites where !stopRequested {
                await runSuite(suite, build: "A", count: n, trialOffset: 0)
            }
        }
        await tearDown()
        print(Stats.report(results))
    }

    func ab(_ a: String, _ b: String) async {
        let n = options.n ?? 30
        let blocks = Int((Double(n) / Double(max(1, options.block))).rounded(.up))
        if options.realHotkey { checkRealHotkey() }
        await setUp()
        outer: for blockIndex in 0..<blocks {
            let order = blockIndex % 2 == 0 ? [("A", a), ("B", b)] : [("B", b), ("A", a)]
            for (label, app) in order {
                if stopRequested { break outer }
                say("block \(blockIndex + 1)/\(blocks): build \(label) (\(app))")
                guard await relaunch(app: app) else { stopRequested = true; break outer }
                let count = min(options.block, n - blockIndex * options.block)
                for suite in options.suites where !stopRequested {
                    await runSuite(suite, build: label, count: count, trialOffset: blockIndex * options.block)
                }
            }
        }
        await tearDown()
        print("A = \(a)\nB = \(b)")
        print(Stats.report(results))
    }

    func launch() async {
        let n = options.n ?? 10
        await setUp(showCanvas: false)
        if let app = options.app { await install(app) }
        let suite = "launch-" + (options.shelf.map { $0 == "empty" ? "empty" : URL(fileURLWithPath: $0).lastPathComponent } ?? "current")
        for i in 0..<n where !stopRequested {
            await Margin.quit()
            await sleep(ms: 1000)
            let defaults = ["write", marginBundleID]
            _ = try? shell("/usr/bin/defaults", defaults + ["saveFolder", "-string", shots.path])
            _ = try? shell("/usr/bin/defaults", defaults + ["copyEachCapture", "-bool", "false"])
            if let shelf = options.shelf {
                try? FileManager.default.removeItem(at: Margin.shelfURL)
                if shelf == "empty" {
                    try? Data("[]".utf8).write(to: Margin.shelfURL)
                } else {
                    try? FileManager.default.copyItem(at: URL(fileURLWithPath: shelf), to: Margin.shelfURL)
                }
            }
            let since = collector.count
            guard let asked = try? await Margin.launch() else { say("launch failed"); break }
            let cards = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: Margin.shelfURL))) as? [Any])?.count ?? 0
            var wanted: Set<String> = ["launchToPrewarmed", "shelfRestore"]
            if cards > 0 { wanted.insert("shelfRestoreThumbnails") }
            guard let events = await collector.wait(for: wanted, since: since, timeout: 30) else {
                say("launch \(i): Margin didn't report ready in 30 s")
                continue
            }
            await sleep(ms: 3000)
            var metrics: [(String, Double, String)] = []
            for e in events where e.name != "mark" { metrics.append((e.name, e.value, e.unit)) }
            if let ready = events.first(where: { $0.name == "launchToPrewarmed" }) {
                metrics.append(("launch.openToPrewarmed", ready.time.timeIntervalSince(asked) * 1000, "ms"))
            }
            if let pid = Margin.pid, let mb = Margin.footprintMB(pid) { metrics.append(("memory.footprint", mb, "MB")) }
            var seen = Set<String>()
            for (m, v, u) in metrics where seen.insert(m).inserted {
                let s = Sample(build: "A", suite: suite, trial: i, metric: m, value: v, unit: u)
                results.append(s)
                append(s)
            }
            say("launch \(i): ready in \(metrics.first { $0.0 == "launchToPrewarmed" }.map { String(format: "%.0f", $0.1) } ?? "–") ms, footprint \(metrics.first { $0.0 == "memory.footprint" }.map { String(format: "%.1f", $0.1) } ?? "–") MB (\(cards) cards)")
        }
        await tearDown()
        print(Stats.report(results))
    }

    /// A real ⇧⌘4 reaches Margin only if macOS's own screenshot shortcut is off (it takes the combo first).
    private func checkRealHotkey() {
        let shortcuts = SystemShortcuts.current()
        if shortcuts.contains(where: { $0.id == 30 && $0.enabled }) {
            fail("--real-hotkey: macOS's own ⇧⌘4 is on, and would take the key press. Turn it off in Margin's first run, or drop --real-hotkey.")
        }
    }
}

// MARK: - Main

let options = Options(Array(CommandLine.arguments.dropFirst()))

switch options.command {
case "help":
    print(usage)
    exit(0)
case "report":
    guard !options.positional.isEmpty else { fail("report <results.jsonl>…") }
    var samples: [Sample] = []
    for (i, path) in options.positional.enumerated() {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("can't read \(path)") }
        for line in text.split(separator: "\n") {
            guard var s = try? JSONDecoder().decode(Sample.self, from: Data(line.utf8)) else { continue }
            if options.positional.count > 1 { s.build = ["A", "B", "C", "D"][min(i, 3)] }
            samples.append(s)
        }
    }
    print(Stats.report(samples))
    exit(0)
case "encode":
    Offline.encode(options.positional)
    exit(0)
case "micro":
    MainActor.assumeIsolated { Offline.micro() }
    exit(0)
case "make-shelf":
    guard options.positional.count == 2, let count = Int(options.positional[1]) else { fail("make-shelf <dir> <count>") }
    MainActor.assumeIsolated {
        Offline.makeShelf(dir: URL(fileURLWithPath: options.positional[0]).standardizedFileURL, count: count)
    }
    exit(0)
case "run", "ab", "launch":
    if options.command == "ab", options.positional.count != 2 { fail("ab <A.app> <B.app>") }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let bench = MainActor.assumeIsolated { Bench(options) }
    // Ctrl-C: finish the capture under way, then restore everything.
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler {
        say("stopping after this capture…")
        MainActor.assumeIsolated { bench.stopRequested = true }
    }
    interrupt.resume()
    Task { @MainActor in
        switch options.command {
        case "run": await bench.run()
        case "ab": await bench.ab(URL(fileURLWithPath: options.positional[0]).standardizedFileURL.path,
                                  URL(fileURLWithPath: options.positional[1]).standardizedFileURL.path)
        default: await bench.launch()
        }
        exit(0)
    }
    app.run()
default:
    print(usage)
    exit(2)
}
