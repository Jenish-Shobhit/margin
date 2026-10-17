import AppKit
import AVFoundation
import IOKit.pwr_mgt
import MarginKit
import os
import ScreenCaptureKit

/// What ⇧⌘5 records (spec §14.4).
enum RecordingTarget {
    case display(DisplayInfo)
    /// AppKit global points, on that display.
    case area(CGRect, DisplayInfo)
    case window(CapturableWindow)

    /// Where it was on screen when the recording started, in AppKit global points: the card's fly-in starts here.
    var frame: CGRect {
        switch self {
        case .display(let d): d.frame
        case .area(let rect, _): rect
        case .window(let w): w.frame
        }
    }

    /// The display a display or area recording stops with when it goes; nil for a window, which moves to another.
    var displayID: CGDirectDisplayID? {
        switch self {
        case .display(let d), .area(_, let d): d.id
        case .window: nil
        }
    }

    var name: String {
        switch self {
        case .display: "display"
        case .area: "area"
        case .window: "window"
        }
    }
}

/// A recording that's finished and in place, for the shelf.
struct FinishedRecording {
    let item: ShelfItem
    /// The poster frame (the first frame), downsampled for the card; nil if it couldn't be read back.
    let thumbnail: CGImage?
    let sourceRect: CGRect
    let displayID: CGDirectDisplayID
    /// The save folder couldn't be written: it went to the Unsaved folder.
    let usedFallback: Bool
    /// Why it stopped, when it wasn't asked to: shown as a toast.
    let note: String?
}

/// ⇧⌘5's recordings, one at a time: starts the `ScreenRecorder` for a chosen target, keeps the menu bar's clock, stops
/// it (⇧⌘5 again, the menu, or something that ends it: the display or window going, sleep, a nearly full disk, an
/// error) and puts the finished file in place. Nothing of it runs, and nothing observes anything, until a recording
/// starts.
@MainActor
final class RecordingController {
    enum State: Equatable { case idle, starting, recording, stopping }

    /// Why a recording stopped, and what the toast says when it wasn't the user (MarginKit, tested).
    typealias StopReason = RecordingStop

    private(set) var state: State = .idle
    var isActive: Bool { state != .idle }
    /// The first frame, from which the menu bar's clock counts.
    private(set) var startedAt: Date?
    var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }
    private(set) var target: RecordingTarget?
    /// What's being recorded, for the DEBUG state dump.
    private(set) var source: RecordingSource?
    private(set) var recorder: ScreenRecorder?
    /// The last recording's numbers, for the DEBUG state dump.
    private(set) var lastOutcome: ScreenRecorder.Outcome?

    /// The state changed, or the clock ticked over a second: the menu bar follows.
    var onChange: (() -> Void)?
    var onFinished: ((FinishedRecording) -> Void)?
    /// A short message for a recording that couldn't start or be saved.
    var onFailure: ((String) -> Void)?
    var onPermissionMissing: (() -> Void)?

    private let cache: ShareableContentCache
    /// When the recording was asked for: the file's name.
    private var startDate = Date()
    private var folder: URL?
    private var usedFallback = false
    private var saveError: String?
    /// A stop asked for while starting, done as soon as it has.
    private var pendingStop: StopReason?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var ticker: Timer?
    private var lastShownSecond = -1
    private var noSleep: IOPMAssertionID = 0
    private var checkingSpace = false

    init(cache: ShareableContentCache) {
        self.cache = cache
    }

    // MARK: Start

    /// Starts recording `target` once the overlay has closed. The tick plays when the first frame is in.
    func start(_ target: RecordingTarget) {
        guard state == .idle else { return }
        state = .starting
        self.target = target
        startDate = Date()
        pendingStop = nil
        onChange?()
        let prefs = Preferences.shared
        let saveFolder = prefs.saveFolder, fallbackFolder = Preferences.fallbackSaveFolder
        let recordsWindow = if case .window = target { true } else { false }
        let callbacks = ScreenRecorder.Callbacks(
            firstFrame: { [weak self] in Task { @MainActor in self?.firstFrame() } },
            interrupted: { [weak self] error in
                let reason = Self.stopReason(for: error, recordsWindow: recordsWindow)
                Task { @MainActor in self?.stop(reason) }
            })
        Task {
            do {
                let microphone = await Self.microphoneAllowed(wanted: prefs.recordsMicrophone)
                if prefs.recordsMicrophone, !microphone {
                    onFailure?("Recording without the microphone: allow Margin in Privacy & Security › Microphone")
                }
                let source = try await source(for: target, systemAudio: prefs.recordsSystemAudio, microphone: microphone)
                let opened = try await Self.open(source, saveFolder: saveFolder, fallbackFolder: fallbackFolder,
                                                 callbacks: callbacks)
                started(opened.recorder, source: source, folder: opened.folder, usedFallback: opened.usedFallback,
                        saveError: opened.saveError)
            } catch {
                failedToStart(error)
            }
        }
    }

    /// What `target` is in ScreenCaptureKit's terms. A display or an area records the display with Margin's capture UI
    /// left out, as screenshots do (`ShareableContentCache`'s target: Settings and Margin's other ordinary windows stay
    /// in); a window records just that window, wherever it goes.
    private func source(for target: RecordingTarget, systemAudio: Bool, microphone: Bool) async throws -> RecordingSource {
        switch target {
        case .display(let d):
            let t = try await cache.target(for: d)
            return RecordingSource(filter: t.filter, sourceRect: nil, pixels: t.pixelSize, fps: Self.frameRate(of: d.id),
                                   isWindow: false, systemAudio: systemAudio, microphone: microphone)
        case .area(let rect, let d):
            let t = try await cache.target(for: d)
            // ScreenCaptureKit takes the area in the display's points, from its top-left corner.
            let local = CGRect(x: rect.minX - d.frame.minX, y: d.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
            let pixels = CGSize(width: (rect.width * t.scale).rounded(), height: (rect.height * t.scale).rounded())
            return RecordingSource(filter: t.filter, sourceRect: local, pixels: pixels, fps: Self.frameRate(of: d.id),
                                   isWindow: false, systemAudio: systemAudio, microphone: microphone)
        case .window(let w):
            let displayID = Displays.display(bestFor: w.frame)?.id ?? CGMainDisplayID()
            let (filter, pixels) = await Self.windowFilter(w.target)
            return RecordingSource(filter: filter, sourceRect: nil, pixels: pixels, fps: Self.frameRate(of: displayID),
                                   isWindow: true, systemAudio: systemAudio, microphone: microphone)
        }
    }

    /// The window on its own, and its size in pixels (`SCShareableContent.info` takes a few ms: off the main thread).
    @concurrent
    private nonisolated static func windowFilter(_ target: WindowTarget) async -> (SCContentFilter, CGSize) {
        let filter = SCContentFilter(desktopIndependentWindow: target.window)
        let info = SCShareableContent.info(for: filter)
        let scale = CGFloat(info.pointPixelScale)
        return (filter, CGSize(width: (info.contentRect.width * scale).rounded(), height: (info.contentRect.height * scale).rounded()))
    }

    /// The display's refresh rate, at most 60 (`RecordingFormat.frameRate`).
    private static func frameRate(of displayID: CGDirectDisplayID) -> Int {
        RecordingFormat.frameRate(refreshRate: Double(Displays.screen(for: displayID)?.maximumFramesPerSecond ?? 0))
    }

    /// Whether the microphone can be recorded: wanted and allowed. Asks the first time (the system prompt); Settings asks
    /// already when it's turned on, so a recording rarely waits for the answer.
    private static func microphoneAllowed(wanted: Bool) async -> Bool {
        guard wanted else { return false }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private struct Opened: @unchecked Sendable {
        let recorder: ScreenRecorder
        let folder: URL
        let usedFallback: Bool
        let saveError: String?
    }

    /// Creates the temp file in the save folder (or, if that can't be written or is nearly full, in Unsaved, as a
    /// screenshot would) and starts the recorder. Off the main thread: the first write to ~/Desktop can wait on its privacy
    /// prompt. Leftovers of an earlier run go first: a finished movie gets its name, one cut off is removed.
    @concurrent
    private nonisolated static func open(_ source: RecordingSource, saveFolder: URL, fallbackFolder: URL,
                                         callbacks: ScreenRecorder.Callbacks) async throws -> Opened {
        var saveError: String?
        for (folder, isFallback) in [(saveFolder, false), (fallbackFolder, true)] {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for leftover in RecordingFiles.handleLeftovers(in: folder, writtenBefore: ProcessLaunch.date ?? Date()) {
                    RecordingLog.log.notice("Leftover recording: \(String(describing: leftover), privacy: .public)")
                }
                // A recording that would stop at once for lack of space doesn't start there.
                if let free = RecordingFiles.freeBytes(at: folder), free < RecordingFiles.minimumFreeBytes {
                    throw ScreenRecorder.RecorderError.full
                }
                let temp = folder.appendingPathComponent(RecordingFiles.tempName())
                let recorder = try await ScreenRecorder.start(source, to: temp, callbacks: callbacks)
                return Opened(recorder: recorder, folder: folder, usedFallback: isFallback, saveError: saveError)
            } catch let error as ScreenRecorder.RecorderError {
                guard error.isAboutTheFolder, !isFallback else { throw error }
                saveError = "\(folder.path): \(error.localizedDescription)"
            } catch let error as CocoaError where !isFallback {
                // The folder couldn't be created.
                saveError = "\(folder.path): \(error.localizedDescription)"
            }
        }
        throw ScreenRecorder.RecorderError.file(saveError ?? "No folder can be written")
    }

    private func started(_ recorder: ScreenRecorder, source: RecordingSource, folder: URL, usedFallback: Bool, saveError: String?) {
        self.recorder = recorder
        self.source = source
        self.folder = folder
        self.usedFallback = usedFallback
        self.saveError = saveError
        state = .recording
        observe()
        RecordingLog.log.notice("Recording \(self.target?.name ?? "?", privacy: .public) at \(Int(source.videoSize.width))×\(Int(source.videoSize.height)) \(source.fps) fps\(source.systemAudio ? " + system audio" : "", privacy: .public)\(source.microphone ? " + microphone" : "", privacy: .public)")
        onChange?()
        if let reason = pendingStop {
            pendingStop = nil
            stop(reason)
        }
    }

    /// Can come before `started` has run: the stream is going by the time its start returns.
    private func firstFrame() {
        guard state == .starting || state == .recording, startedAt == nil else { return }
        startedAt = Date()
        if Preferences.shared.shutterSound { ShutterSound.playRecordingStart() }
        CaptureTimings.shared.record("recordingStart", Date().timeIntervalSince(startDate) * 1000)
        onChange?()
    }

    private func failedToStart(_ error: any Error) {
        RecordingLog.log.error("Recording didn't start: \(String(describing: error), privacy: .public)")
        reset()
        if ScreenGrabber.isPermissionError(error) {
            RuntimeStatus.shared.screenRecordingRevoked = true
            onPermissionMissing?()
        } else if case ScreenRecorder.RecorderError.full = error {
            onFailure?("Can't record: the disk is almost full")
        } else if case ScreenRecorder.RecorderError.file = error {
            onFailure?("Couldn't save the recording: no folder can be written")
        } else {
            onFailure?("Couldn't start recording")
        }
    }

    /// What ScreenCaptureKit (or the writer) stopping the stream means.
    nonisolated static func stopReason(for error: any Error, recordsWindow: Bool) -> StopReason {
        let ns = error as NSError
        RecordingLog.log.notice("Recording interrupted: \(ns.domain, privacy: .public) \(ns.code)")
        let domain = ns.domain == SCStreamErrorDomain ? RecordingStop.streamErrorDomain : ns.domain
        return RecordingStop.forStreamError(domain: domain, code: ns.code, description: ns.localizedDescription,
                                            recordsWindow: recordsWindow)
    }

    // MARK: While recording

    /// Only while recording: what ends it, the menu bar's clock, and the display kept awake (a long recording of a video
    /// shouldn't end because nobody touched the Mac).
    private func observe() {
        let ws = NSWorkspace.shared.notificationCenter
        for (name, reason) in [
            (NSWorkspace.willSleepNotification, StopReason.sleep),
            (NSWorkspace.screensDidSleepNotification, .sleep),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionChanged),
        ] {
            let token = ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop(reason) }
            }
            observers.append((ws, token))
        }
        let app = NotificationCenter.default
        let token = app.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysChanged() }
        }
        observers.append((app, token))
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        _ = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Margin is recording the screen" as CFString,
                                        &noSleep)
    }

    private func stopObserving() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        ticker?.invalidate()
        ticker = nil
        if noSleep != 0 {
            IOPMAssertionRelease(noSleep)
            noSleep = 0
        }
    }

    /// A quarter of a second, so the clock ticks over close to each full second; the menu bar changes once a second.
    private func tick() {
        guard state == .recording else { return }
        let second = Int(elapsed)
        if second != lastShownSecond {
            lastShownSecond = second
            onChange?()
            secondPassed()
        }
    }

    /// Once a second, off the main thread: a recorded window that has closed, and the space left on the disk.
    private func secondPassed() {
        guard let folder, !checkingSpace else { return }
        checkingSpace = true
        let window: CGWindowID? = if case .window(let w)? = target { w.id } else { nil }
        Task {
            let (exists, free) = await Task.detached(priority: .utility) {
                (window.map(Self.windowExists) ?? true, RecordingFiles.freeBytes(at: folder))
            }.value
            checkingSpace = false
            if !exists {
                stop(.windowClosed)
            } else if let free, free < RecordingFiles.minimumFreeBytes {
                stop(.diskFull)
            }
        }
    }

    /// Whether the window still exists, on screen or not: minimized, its app hidden or on another Space, it's still
    /// recorded (its last frame held). `.optionIncludingWindow` lists only on-screen windows, so the whole list (a few
    /// ms, hence off the main thread).
    private nonisolated static func windowExists(_ id: CGWindowID) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }
    }

    private func displaysChanged() {
        guard let id = target?.displayID, !Displays.all.contains(where: { $0.id == id }) else { return }
        stop(.displayGone)
    }

    /// The cache rebuilt its display targets with other ordinary windows of Margin's in them (Settings opened or closed):
    /// a display or area recording takes the new filter, so Settings opened meanwhile is in it, as in a screenshot.
    func targetsChanged() {
        guard state == .recording, let id = target?.displayID, let filter = cache.targets[id]?.filter else { return }
        RecordingLog.log.info("Margin's ordinary windows changed: the recording takes the new filter")
        recorder?.update(filter)
    }

    // MARK: Stop

    /// Stops and saves what was recorded. While starting, it stops as soon as the recording has started.
    func stop(_ reason: StopReason = .user) {
        switch state {
        case .idle, .stopping: return
        case .starting:
            pendingStop = pendingStop ?? reason
            return
        case .recording: break
        }
        guard let recorder, let folder, let target else { return }
        state = .stopping
        stopObserving()
        onChange?()
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        let date = startDate, usedFallback = usedFallback, saveError = saveError
        let displayID = target.displayID ?? Displays.display(bestFor: target.frame)?.id ?? CGMainDisplayID()
        RecordingLog.log.notice("Recording stopping (\(String(describing: reason), privacy: .public))")
        Task {
            let clock = Stopwatch()
            let outcome = await recorder.stop(at: end)
            let finishMs = clock.ms
            let placed = await Self.place(outcome, in: folder, date: date)
            CaptureTimings.shared.record("recordingFinish", finishMs)
            CaptureTimings.shared.record("recordingStopToFile", clock.ms)
            // The card first, then idle: a quit waiting for this recording goes ahead when it's idle, with the card stored.
            defer { reset() }
            guard let placed else {
                RecordingLog.log.error("Recording not saved: \(outcome.error ?? "unknown", privacy: .public)")
                onFailure?(reason == .user || reason == .quit ? "Couldn't save the recording" : (reason.note ?? "Couldn't save the recording"))
                return
            }
            RecordingLog.log.notice("Recording saved: \(placed.item.path, privacy: .public), \(outcome.duration, format: .fixed(precision: 2)) s, \(outcome.framesWritten) frames, \(outcome.framesDropped) dropped\(usedFallback ? " (Unsaved: \(saveError ?? ""))" : "", privacy: .public)")
            lastOutcome = outcome
            onFinished?(FinishedRecording(item: placed.item, thumbnail: placed.thumbnail, sourceRect: target.frame,
                                          displayID: displayID, usedFallback: usedFallback, note: reason.note))
        }
    }

    private struct Placed: @unchecked Sendable {
        let item: ShelfItem
        let thumbnail: CGImage?
    }

    /// The finished temp file under its name, its shelf item (bookmarked) and its poster frame. Off the main thread.
    @concurrent
    private nonisolated static func place(_ outcome: ScreenRecorder.Outcome, in folder: URL, date: Date) async -> Placed? {
        guard let temp = outcome.url else { return nil }
        let url: URL
        do {
            url = try RecordingFiles.moveIntoPlace(temp, in: folder, date: date)
        } catch {
            RecordingLog.log.error("Couldn't name the recording: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let asset = AVURLAsset(url: url)
        let track = try? await asset.loadTracks(withMediaType: .video).first
        let size = (try? await track?.load(.naturalSize)) ?? .zero
        let item = ShelfItem(url: url, createdAt: date, pixelSize: size, kind: .recording, duration: outcome.duration)
        let poster = await ShelfThumbnails.poster(url: url, pixelSize: size)
        return Placed(item: item, thumbnail: poster?.image)
    }

    private func reset() {
        stopObserving()
        state = .idle
        recorder = nil
        source = nil
        target = nil
        folder = nil
        startedAt = nil
        lastShownSecond = -1
        onChange?()
    }
}

enum RecordingLog {
    static let log = Logger(subsystem: AppCoordinator.subsystem, category: "recording")
}
