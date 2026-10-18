import AppKit
import MarginKit
import ScreenCaptureKit

/// One display's frozen frame, or why it failed.
private struct FrozenFrame: Sendable {
    let displayID: CGDirectDisplayID
    let result: Result<SendableImage, any Error>
    let ms: Double
}

/// Captures one display's frozen frame; the target is nil when ScreenCaptureKit doesn't list the display.
private typealias FrameGrabber = @Sendable (CGDirectDisplayID, DisplayTarget?) async throws -> SendableImage

/// Window mode's stand-in for the shot (`CaptureController.standIn`): the window cut from the frozen frame (sharing its
/// pixels), or captured before its app has focus back, and its card thumbnail, all made off the main thread.
private struct StandIn: @unchecked Sendable {
    let image: CGImage
    let thumbnail: CGImage
    let scale: CGFloat
    /// When the cut was made, before the thumbnail: the release clock starts here, as it does at a shot's image.
    let date: Date
    let ready: ContinuousClock.Instant
    let thumbnailMs: Double

    init?(cutting pixelRect: CGRect, from frozen: SendableImage, scale: CGFloat) {
        guard let image = ScreenGrabber.crop(frozen.image, to: pixelRect) else { return nil }
        self.init(image, scale: scale)
    }

    init(_ image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        date = Date()
        ready = .now
        let clock = Stopwatch()
        thumbnail = ScreenGrabber.thumbnail(of: image)
        thumbnailMs = clock.ms
    }
}

/// Area, window and full-screen capture (spec §2).
@MainActor
final class CaptureController: CaptureControlling {
    var onCapture: ((CaptureResult) -> Void)?
    var onPermissionMissing: (() -> Void)?
    /// Called on the main actor with a short message when a capture fails for any reason but permission: the
    /// window closed, a display ScreenCaptureKit can't capture… Not part of `CaptureControlling`: the
    /// coordinator holds this class itself.
    var onFailure: ((String) -> Void)?
    /// ⇧⌘5's choice of what to record, made in the same overlay (spec §14.4), once it has closed. Not part of
    /// `CaptureControlling` either.
    var onRecord: ((RecordingTarget) -> Void)?
    var isCapturing: Bool { session != nil }

    /// Latest timings in ms, for the DEBUG `dump-state` hook.
    var lastTimings: [String: Double] { timings.values }
    /// The live overlay session, for tests that drive it with synthetic events.
    var currentSession: OverlaySession? { session }

    private let cache = ShareableContentCache()
    /// The cached displays and windows, with Margin's capture UI excluded: what a recording records too.
    var shareableContent: ShareableContentCache { cache }
    private let pool = OverlayPanelPool()
    private let timings = CaptureTimings.shared
    private var session: OverlaySession?
    /// The app that was frontmost when the overlay went up; it gets focus back afterwards.
    private var previousApp: NSRunningApplication?
    private var activatedForSession = false
    private var becameActiveDuringSession = false
    /// When `takeFocus` last asked to activate Margin, and when AppKit's didBecomeActive said it had (`giveFocusBack`).
    private var activation: (requested: ContinuousClock.Instant, landed: ContinuousClock.Instant?)?
    /// The app a `giveFocusBack` that's still waiting, or an area's release that hasn't given focus back yet
    /// (`finishArea`), will hand focus to. A capture started meanwhile takes it as its own previous app (Margin is
    /// frontmost by then), so a quick second ⌘⇧4 still ends with focus back there.
    private var pendingFocusReturn: NSRunningApplication?
    /// This capture took `previousApp` over from a waiting `giveFocusBack`: Margin is active from the last one, so
    /// focus goes back even if this one ends before it activates itself (Esc before the first frame).
    private var inheritedFocusReturn = false
    /// Margin has (or is taking) focus that this capture has to give back.
    private var owesFocus: Bool { activatedForSession || inheritedFocusReturn }
    /// The overlay's keys from the moment the capture starts, before it can be key (see `OverlayHotkeys`).
    private lazy var hotkeys = OverlayHotkeys { [weak self] event in
        guard let session = self?.session else { return }
        if event.type == .keyDown { session.keyDown(event) } else { session.keyUp(event) }
    }
    private var observers: [NSObjectProtocol] = []
    /// What `onFailure` says.
    private enum FailureText {
        static let screen = "Couldn't capture the screen"
        static let display = "Couldn't capture this display"
        static let window = "Couldn't capture that window"
        static let area = "Couldn't capture that area"
    }

    /// Screen Recording confirmed (by preflight or a successful capture). `CGPreflightScreenCaptureAccess`
    /// costs 6–10 ms, too much for the hotkey path, so it only runs until access is confirmed; a revoked
    /// permission then shows up as a capture error instead.
    private var permissionConfirmed = false

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A display change while selecting cancels; the panels are rebuilt next time.
                if self.session != nil {
                    CaptureLog.capture.info("display change: cancelling the overlay")
                    self.endSession()
                }
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.activation?.landed == nil { self.activation?.landed = .now }
                guard let session = self.session else { return }
                self.becameActiveDuringSession = true
                // Only the frontmost app may set the cursor, and a cursor set while activation is still under way is
                // dropped: set the crosshair again now, or it shows only once the mouse moves.
                session.updateCursor()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Switching apps (⌘Tab) while selecting would leave the overlay over the new app.
                guard let self, self.session != nil, self.becameActiveDuringSession else { return }
                CaptureLog.capture.info("app resigned active: cancelling the overlay")
                self.endSession(restoreFocus: false)
            }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        // The frozen frame no longer matches the screen: another Space came forward (the panels join every Space, so
        // the old one's frame would sit over it), the Mac or its displays went to sleep, or another user took over.
        // Focus goes back after sleep. Not after a Space switch, which would switch back: the app in front on the new
        // Space gets it instead (unless one of Margin's own windows is key there), as it would without the overlay.
        for (name, restoreFocus) in [
            (NSWorkspace.activeSpaceDidChangeNotification, false),
            (NSWorkspace.willSleepNotification, true),
            (NSWorkspace.screensDidSleepNotification, true),
            (NSWorkspace.sessionDidResignActiveNotification, false),
        ] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.session != nil else { return }
                    CaptureLog.capture.info("\(name.rawValue, privacy: .public): cancelling the overlay")
                    let owed = self.owesFocus
                    self.endSession(restoreFocus: restoreFocus)
                    if !restoreFocus, owed, NSApp.keyWindow == nil {
                        self.giveFocusBack(to: Self.frontmostWindowOwner())
                    }
                }
            })
        }
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                // Margin is frontmost: the crosshair again, as soon as it can be (didBecomeActive sets it once more
                // when AppKit is done, which can reset it).
                guard let self, pid == ProcessInfo.processInfo.processIdentifier else { return }
                self.session?.updateCursor()
            }
        })
    }

    // MARK: Prewarm

    func prewarm() async {
        let clock = Stopwatch()
        // The overlay panels exist from now on: the hotkey only orders them in, and owning windows keeps
        // Margin listed in SCShareableContent (needed to exclude it).
        pool.sync()
        pool.warmUp()
        hotkeys.prepare()
        do {
            try await cache.refresh()
            let main = CGMainDisplayID()
            if let target = cache.targets[main] ?? cache.targets.values.first {
                try await ScreenGrabber.warmUp(target)
            }
            permissionWorked()
            timings.record("prewarm", clock.ms)
            if let launched = ProcessLaunch.ms { timings.record("launchToPrewarmed", launched) }
        } catch {
            CaptureLog.capture.error("prewarm failed: \(error.localizedDescription, privacy: .public)")
            if ScreenGrabber.isPermissionError(error) { permissionLost() }
        }
    }

    // MARK: ⌘⇧4 and Capture Window

    func beginInteractiveCapture() {
        begin(in: .area)
    }

    /// Menu "Capture Window": the same frozen overlay, starting in window mode (Space switches to area).
    func beginWindowCapture() {
        begin(in: .window)
    }

    /// ⇧⌘5: the same frozen overlay, choosing what to record: an area, a window (Space), or the whole display (a click).
    func beginRecordingChoice() {
        begin(in: .area, purpose: .record)
    }

    private func begin(in mode: OverlaySession.Mode, purpose: OverlaySession.Purpose = .capture) {
        guard session == nil else { return }
        let clock = Stopwatch()
        // The overlay can be key only with the first frame; until then its keys would reach the frontmost app (Space
        // typed into a document, Esc taking a full-screen app out of full screen). They're caught as hotkeys instead,
        // Esc and Space before anything else: once the captures have started, the window server is slow to take them.
        hotkeys.registerFirst()
        let signpost = CaptureLog.signposter.beginInterval("freeze")
        guard hasPermission() else {
            hotkeys.unregister()
            CaptureLog.signposter.endInterval("freeze", signpost)
            onPermissionMissing?()
            return
        }
        let displays = Displays.all
        guard !displays.isEmpty else {
            hotkeys.unregister()
            return
        }

        // Start the captures first: they run off the main thread while the panels go up. A display that
        // ScreenCaptureKit didn't list at the last refresh (Sidecar, AirPlay, DisplayLink…) just fails in the
        // stream; only a display the cache hasn't seen yet, or has seen at another size or scale, sends the
        // freeze down the cold path.
        let grab = Self.frameGrabber()
        let early = cache.needsRefresh(for: displays) ? nil : Self.captureAll(jobs(for: displays), grab: grab)

        pool.sync()
        let session = OverlaySession(panels: pool.panels(for: displays), cache: cache, mode: mode, purpose: purpose,
                                     showsHUD: Preferences.shared.showsCaptureHints)
        switch purpose {
        case .capture:
            session.onArea = { [weak self] rect, display, image, pixelRect, scale in
                self?.finishArea(rect, display: display, image: image, pixelRect: pixelRect, scale: scale)
            }
            session.onWindow = { [weak self] window, keepShadow in
                self?.finishWindow(window, keepShadow: keepShadow)
            }
        case .record:
            session.onArea = { [weak self] rect, display, _, _, _ in self?.finishRecordingChoice(.area(rect, display)) }
            session.onWindow = { [weak self] window, _ in self?.finishRecordingChoice(.window(window)) }
            session.onScreen = { [weak self] display in self?.finishRecordingChoice(.display(display)) }
        }
        session.onCancel = { [weak self] in self?.endSession() }
        self.session = session
        previousApp = pendingFocusReturn ?? NSWorkspace.shared.frontmostApplication
        inheritedFocusReturn = pendingFocusReturn != nil
        pendingFocusReturn = nil
        activatedForSession = false
        becameActiveDuringSession = false
        session.show()
        timings.record("hotkeyToOverlay", clock.ms)
        // The other overlay keys, now that it's on screen (they'd hold it back by 2–10 ms).
        hotkeys.register()

        Task { [weak self] in
            await self?.freeze(session, displays: displays, early: early, grab: grab, clock: clock)
            CaptureLog.signposter.endInterval("freeze", signpost)
        }
    }

    /// What to capture for each display; `nil` where ScreenCaptureKit doesn't list it.
    private func jobs(for displays: [DisplayInfo]) -> [(CGDirectDisplayID, DisplayTarget?)] {
        displays.map { ($0.id, cache.targets[$0.id]) }
    }

    /// Draws each display's frozen frame as it arrives and takes keyboard focus with the first one. A display
    /// that can't be captured is dimmed and refuses selections; the session ends only if none could be.
    private func freeze(_ session: OverlaySession, displays: [DisplayInfo], early: AsyncStream<FrozenFrame>?,
                        grab: @escaping FrameGrabber, clock: Stopwatch) async {
        // Never leave a transparent overlay eating clicks if SCK stalls: with no frame at all, cancel; otherwise
        // stop waiting for the displays still blank.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.session === session else { return }
            if session.frozenCount == 0 {
                CaptureLog.capture.error("freeze: no frame after 3 s, cancelling")
                self.endSession()
                self.onFailure?(FailureText.screen)
            } else if session.abandonPendingDisplays() > 0 {
                CaptureLog.capture.error("freeze: a display gave no frame in 3 s; dimmed")
            }
        }

        var stream = early
        if stream == nil {
            // Cold cache, Margin missing from it, or a display that's new or changed: fetch once, off the fast path.
            CaptureLog.capture.info("freeze: cache cold, fetching shareable content first")
            do {
                try await cache.refresh()
            } catch {
                fail(error, session: session, message: FailureText.screen)
                return
            }
            guard self.session === session else { return }
            session.windowsDidRefresh()
            stream = Self.captureAll(jobs(for: displays), grab: grab)
        }
        guard let stream else { return }

        var first = true
        var firstError: (any Error)?
        // The cold path's fetch already has fresh windows.
        var windowsRequested = early == nil
        for await frame in stream {
            guard self.session === session else { return }
            switch frame.result {
            case let .success(image):
                session.setFrozen(image.image, for: frame.displayID) {
                    if first {
                        first = false
                        timings.record("hotkeyToFirstFrozen", clock.ms)
                        // Flushed to the render server just now: on screen with the display's next refresh.
                        let flushed = CACurrentMediaTime(), flushedMs = clock.ms
                        FrameTiming.nextRefresh(of: Displays.screen(for: frame.displayID), after: flushed) { [timings] refresh in
                            timings.record("hotkeyToFirstFrozenFrame", flushedMs + (refresh - flushed) * 1000)
                        }
                    }
                }
                timings.record("freezeCapture.\(frame.displayID)", frame.ms)
                permissionWorked()
                // Windows may have moved, opened or closed since the last refresh: fetch them for snapping and window
                // mode as soon as one display is frozen, not after the slowest. Not before: a fetch alongside the
                // start of the captures slows them by about 20 ms.
                if !windowsRequested {
                    windowsRequested = true
                    refreshWindows(for: session)
                }
                // The overlay takes the keyboard from the first frozen display on, not after the slowest one (until
                // then `OverlayHotkeys` stand in). Not sooner: the frontmost window would lose its focused look in
                // the frame. Every capture was already requested, so this can change at most a display still in flight.
                if !activatedForSession { takeFocus(session) }
            case let .failure(error):
                // Permission is all or nothing; any other failure costs only that display.
                if ScreenGrabber.isPermissionDenial(error) {
                    fail(error, session: session, message: FailureText.screen)
                    return
                }
                CaptureLog.capture.error("freeze: display \(frame.displayID, privacy: .public) can't be captured: \(String(describing: error), privacy: .public)")
                firstError = firstError ?? error
                session.setUnavailable(frame.displayID)
            }
        }
        guard self.session === session else { return }
        timings.record("hotkeyToAllFrozen", clock.ms)
        guard session.frozenCount > 0 else {
            fail(firstError ?? CaptureError.noImage, session: session, message: FailureText.screen)
            return
        }
    }

    /// Fetches the windows for snapping and window mode, then hands them to the session (whether or not the fetch
    /// worked: the session must stop waiting for them either way).
    private func refreshWindows(for session: OverlaySession) {
        Task { [weak self] in
            try? await self?.cache.refresh(onScreenOnly: true)
            guard let self, self.session === session else { return }
            session.windowsDidRefresh()
        }
    }

    /// Makes the overlay key, so the arrows (with key repeat), ⇧ and ⌥ reach it, and activates Margin.
    private func takeFocus(_ session: OverlaySession) {
        let clock = Stopwatch()
        // Already active (Settings or Welcome in front): no didBecomeActive will arrive, but losing activation
        // from here on (⌘Tab) must still cancel, or the frozen screen stays up with no keyboard.
        if NSApp.isActive { becameActiveDuringSession = true }
        // Key first: the non-activating panel gets keys at once. Then activate: only the frontmost app may set the
        // cursor (the crosshair is set again once that lands, see `init`).
        session.makeKey()
        hotkeys.overlayIsKey()
        activation = NSRunningApplication.current.isActive ? nil : (requested: .now, landed: nil)
        NSApp.activate()
        activatedForSession = true
        timings.record("takeFocus", clock.ms)
    }

    /// Gives focus back to `previous`, the app that had it before the overlay. Not while Margin's own activation is
    /// still landing (Esc pressed with the first frame): handed back before that app has taken in its own
    /// deactivation, it's left active without its key window, and typing goes nowhere until a click. So it waits for
    /// AppKit's didBecomeActive (at most 300 ms) and then 60 ms more; a capture that ends later gives it back at once.
    private func giveFocusBack(to previous: NSRunningApplication?) {
        let settle = Duration.milliseconds(60)
        // Margin was frontmost already, or its activation landed a while ago.
        let settled = activation.map { a in a.landed.map { ContinuousClock.now - $0 >= settle } ?? false } ?? true
        guard let previous, let requested = activation?.requested, !settled else {
            Self.restoreFocus(to: previous)
            return
        }
        pendingFocusReturn = previous
        Task { [weak self] in
            while self?.activation?.landed == nil, ContinuousClock.now - requested < .milliseconds(300) {
                try? await Task.sleep(for: .milliseconds(5))
            }
            if let landed = self?.activation?.landed { try? await Task.sleep(until: landed + settle) }
            // A capture started since then has taken it over (`begin`).
            guard let self, self.pendingFocusReturn === previous else { return }
            self.pendingFocusReturn = nil
            if self.session == nil { Self.restoreFocus(to: previous) }
        }
    }

    /// Captures every display in parallel; yields frames, or why one failed, as they finish.
    private nonisolated static func captureAll(_ jobs: [(CGDirectDisplayID, DisplayTarget?)], grab: @escaping FrameGrabber) -> AsyncStream<FrozenFrame> {
        let (stream, continuation) = AsyncStream.makeStream(of: FrozenFrame.self)
        Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: Void.self) { group in
                for (id, target) in jobs {
                    group.addTask {
                        let clock = Stopwatch()
                        do {
                            let image = try await grab(id, target)
                            continuation.yield(FrozenFrame(displayID: id, result: .success(image), ms: clock.ms))
                        } catch {
                            continuation.yield(FrozenFrame(displayID: id, result: .failure(error), ms: clock.ms))
                        }
                    }
                }
            }
            continuation.finish()
        }
        return stream
    }

    /// One display's freeze capture. A display ScreenCaptureKit doesn't list fails right away.
    private nonisolated static func grab(_ id: CGDirectDisplayID, _ target: DisplayTarget?) async throws -> SendableImage {
        guard let target else { throw CaptureError.noDisplay }
        return try await ScreenGrabber.capture(target)
    }

    /// ScreenCaptureKit, or in DEBUG builds whatever `CaptureSimulation` scripts for a display.
    private static func frameGrabber() -> FrameGrabber {
        #if DEBUG
        let faults = CaptureSimulation.faults
        if !faults.isEmpty {
            return { id, target in
                if let fault = faults[id] { return try await fault.perform() }
                return try await grab(id, target)
            }
        }
        #endif
        return { id, target in try await grab(id, target) }
    }

    private func finishArea(_ rect: CGRect, display: DisplayInfo, image: CGImage, pixelRect: CGRect, scale: CGFloat) {
        let clock = Stopwatch()
        let date = Date()
        // The crop and the thumbnail start at once, off the main thread (user-interactive: `Interactive`), while the
        // overlay comes down here.
        let source = SendableImage(image: image)
        let prepared = Interactive { Self.timedCrop(source, to: pixelRect, scale: scale) }
        // Overlay first: the shelf's fly-in starts from the selection, over the live screen.
        let previous = owesFocus ? previousApp : nil
        // Owed from the mouse-up on, not from the hand-off: a ⇧⌘4 that lands while the crop and thumbnail are being
        // made must take `previous` over (`begin`), or its overlay would hand focus back to Margin itself.
        if let previous { pendingFocusReturn = previous }
        endSession(restoreFocus: false)
        timings.record("release.endSession", clock.ms)
        Task {
            var area: LastArea?
            if case let (shot, cropMs)? = await prepared.value {
                timings.record("release.crop", cropMs)
                timings.record("thumbnail", shot.thumbnailMs)
                timings.record("releaseToResult", clock.ms)
                onCapture?(CaptureResult(image: shot.image, thumbnail: shot.thumbnail, png: shot.png, scale: scale, sourceRect: rect,
                                         displayID: display.id, kind: .area, date: date))
                area = LastArea(rect: rect, displayID: display.id, displayFrame: display.frame)
            } else {
                CaptureLog.capture.error("area crop was empty: \(String(describing: pixelRect), privacy: .public)")
                onFailure?(FailureText.area)
            }
            finishRelease(lastArea: area, focusTo: previous)
        }
    }

    /// The rest of a release, once this run-loop turn's Core Animation commit has put the thumbnail on screen: the last
    /// area (its write posts Preferences.didChange), then focus back to `previous`. AppKit's deactivation work holds the
    /// main actor for ~15 ms, and done in the same turn as the hand-off to the shelf, either would delay the commit.
    /// `previous` waits as `pendingFocusReturn` since the mouse-up (`finishArea`), so a capture started before then
    /// takes it over (`begin`).
    private func finishRelease(lastArea area: LastArea?, focusTo previous: NSRunningApplication?) {
        FrameTiming.afterCommit { [weak self] in
            guard let self else { return }
            if let area {
                let write = Stopwatch()
                Preferences.shared.lastArea = area
                timings.record("release.lastArea", write.ms)
            }
            guard let previous, pendingFocusReturn === previous else { return }
            pendingFocusReturn = nil
            let focus = Stopwatch()
            giveFocusBack(to: previous)
            timings.record("release.focusBack", focus.ms)
        }
    }

    private func finishWindow(_ window: CapturableWindow, keepShadow: Bool) {
        let clock = Stopwatch()
        let wasActive = owesFocus
        let previous = previousApp
        // Cut while the overlay comes down (which lets go of the frozen frame), or captured before focus goes back. The
        // capture runs even when the cut stands in: the shot comes 9 ms sooner after it, and encodes 5 ms faster.
        let captured = Self.captureStandIn(of: window, keepShadow: keepShadow)
        let standIn = standIn(for: window, keepShadow: keepShadow) ?? captured
        endSession()
        let displayID = Displays.display(bestFor: window.frame)?.id ?? CGMainDisplayID()
        let shot = Task { () -> Result<Shot, any Error> in
            // Margin took focus for the keys; give it back first so the window is shot with its own focus look.
            if wasActive, let previous {
                let wait = Stopwatch()
                await Self.waitUntilActive(previous)
                timings.record("windowWaitActive", wait.ms)
            }
            do {
                let shot = try await Self.captureWindow(window.target, keepShadow: keepShadow)
                permissionWorked()
                return .success(shot)
            } catch {
                return .failure(error)
            }
        }
        Task {
            if let cut = await standIn.value {
                timings.record("windowCapture", clock.ms(until: cut.ready))
                timings.record("thumbnail", cut.thumbnailMs)
                handOver(cut, standingInFor: shot, of: window, displayID: displayID, clock: clock)
                return
            }
            switch await shot.value {
            case let .success(shot):
                timings.record("windowCapture", clock.ms(until: shot.ready))
                timings.record("thumbnail", shot.thumbnailMs)
                onCapture?(CaptureResult(image: shot.image, thumbnail: shot.thumbnail, png: shot.png, scale: shot.scale,
                                         sourceRect: window.frame, displayID: displayID, kind: .window, date: shot.date))
            case let .failure(error):
                fail(error, session: nil, message: FailureText.window)
            }
        }
    }

    /// Window mode's stand-in for the shot, started now off the main thread: the window cut from the frozen frame, as it
    /// looked when it was clicked. It goes on the shelf right away, while ScreenCaptureKit waits for the window to have
    /// its focused look back (until about 130 ms after the click). Only where the frozen frame shows that window whole
    /// and nothing else: not with ⌥ (the shot is bigger, by the shadow), and not for a window that isn't all on one
    /// display, or that anything in front covers there (another window, the Dock, the menu bar).
    private func standIn(for window: CapturableWindow, keepShadow: Bool) -> Task<StandIn?, Never>? {
        guard !keepShadow, let session,
              let display = session.displays.first(where: { $0.frame.contains(window.frame) }),
              let frozen = session.frozenImage(on: display.id), display.frame.width > 0,
              cache.isUncovered(window) else { return nil }
        let scale = CGFloat(frozen.width) / display.frame.width
        let pixelRect = Geometry.pixelRect(for: window.frame, displayFrame: display.frame, scale: scale,
                                           imageSize: CGSize(width: frozen.width, height: frozen.height))
        let source = SendableImage(image: frozen)
        let cut = Interactive { StandIn(cutting: pixelRect, from: source, scale: scale) }
        return Task.detached(priority: .userInitiated) { await cut.value }
    }

    /// The stand-in for a window the frozen frame doesn't show alone (with ⌥, covered, not all on one display): the window
    /// captured right away, before its app has focus back. ScreenCaptureKit isn't held back yet then (about 30 ms), but
    /// the window may have its unfocused look, and with ⌥ the smaller shadow that goes with it: the shot puts that right.
    /// Nil if it fails; the shot then goes to the shelf as soon as it's in (or fails as it would have).
    ///
    /// It's made for every click, the frozen cut's too: after it, the shot is in about 9 ms sooner and its PNG encodes
    /// 5 ms faster (measured; ScreenCaptureKit seems to keep that window's capture going). A 16 × 16 capture did that
    /// only about half as well.
    private static func captureStandIn(of window: CapturableWindow, keepShadow: Bool) -> Task<StandIn?, Never> {
        let target = window.target
        return Task.detached(priority: .userInitiated) {
            guard let (image, scale) = try? await ScreenGrabber.captureWindow(target, keepShadow: keepShadow,
                                                                              timing: "windowStandIn") else { return nil }
            return await Interactive { StandIn(image.image, scale: scale) }.value
        }
    }

    /// The stand-in goes to the shelf now; the shot it stands in for follows. The shot's encode is the file (and the
    /// clipboard), and its thumbnail replaces the stand-in's (`CaptureResult.windowShot`). Should the shot fail, the card
    /// goes, saying so (`EncodedPNG.failure`), instead of a toast of its own.
    private func handOver(_ standIn: StandIn, standingInFor shot: Task<Result<Shot, any Error>, Never>,
                          of window: CapturableWindow, displayID: CGDirectDisplayID, clock: Stopwatch) {
        let png = Task.detached { () -> EncodedPNG in
            guard case let .success(shot) = await shot.value else {
                return EncodedPNG(data: nil, ms: 0, failure: FailureText.window)
            }
            return await shot.png.value
        }
        let windowShot = Task { () -> ShotThumbnail? in
            switch await shot.value {
            case let .success(shot):
                timings.record("windowShot", clock.ms(until: shot.ready))
                timings.record("windowShot.thumbnail", shot.thumbnailMs)
                return ShotThumbnail(thumbnail: shot.thumbnail,
                                     pixelSize: CGSize(width: shot.image.width, height: shot.image.height))
            case let .failure(error):
                fail(error, session: nil, message: nil)
                return nil
            }
        }
        onCapture?(CaptureResult(image: standIn.image, thumbnail: standIn.thumbnail, png: png, scale: standIn.scale,
                                 sourceRect: window.frame, displayID: displayID, kind: .window, date: standIn.date,
                                 windowShot: windowShot))
    }

    /// The overlay comes down and focus goes back to the app that had it, then the recording starts: by its first frame
    /// that app (a recorded window's, often) has its focused look again.
    private func finishRecordingChoice(_ target: RecordingTarget) {
        endSession()
        onRecord?(target)
    }

    // MARK: ⌘⇧3

    func captureScreenUnderPointer() {
        guard session == nil else { return }
        guard hasPermission() else { onPermissionMissing?(); return }
        guard let display = Displays.display(containing: NSEvent.mouseLocation) else { return }
        let clock = Stopwatch()
        pool.sync()  // Margin must own windows to be listed (and so excluded), even without a prewarm.
        Task {
            do {
                let target = try await cache.target(for: display)
                let shot = try await Self.capture(target)
                timings.record("screenCapture", clock.ms(until: shot.ready))
                timings.record("thumbnail", shot.thumbnailMs)
                permissionWorked()
                onCapture?(CaptureResult(image: shot.image, thumbnail: shot.thumbnail, png: shot.png, scale: target.scale,
                                         sourceRect: display.frame, displayID: display.id, kind: .screen, date: shot.date))
            } catch {
                fail(error, session: nil, message: FailureText.display)
            }
        }
    }

    // MARK: ⌘⇧2 and direct areas

    func repeatLastArea() {
        guard session == nil else { return }
        // The area is kept relative to its display, so it follows the display wherever the arrangement puts it
        // now. No area, its display gone, or the display at another resolution: choose again.
        let displays = Displays.all
        guard let last = Preferences.shared.lastArea
                ?? Preferences.shared.migrateLegacyLastArea(displays: displays.map { ($0.id, $0.frame) }),
              let display = displays.first(where: { $0.id == last.displayID }),
              let rect = last.rect(onDisplayFrame: display.frame) else {
            beginInteractiveCapture()
            return
        }
        captureArea(rect, on: display, repeating: true)
    }

    func captureArea(_ rect: CGRect) {
        guard let display = Displays.display(bestFor: rect) else {
            CaptureLog.capture.error("captureArea: no display for \(String(describing: rect), privacy: .public)")
            return
        }
        captureArea(rect.intersection(display.frame), on: display, repeating: false)
    }

    /// `repeating` (⌘⇧2) flashes the outline and leaves the last area as it was; otherwise `rect` becomes it.
    private func captureArea(_ rect: CGRect, on display: DisplayInfo, repeating: Bool) {
        guard session == nil else { return }
        guard hasPermission() else { onPermissionMissing?(); return }
        let clock = Stopwatch()
        pool.sync()
        Task {
            do {
                let target = try await cache.target(for: display)
                let image = try await ScreenGrabber.capture(target)
                timings.record("areaCapture.display", clock.ms)
                permissionWorked()
                let size = CGSize(width: image.image.width, height: image.image.height)
                let pixelRect = Geometry.pixelRect(for: rect, displayFrame: display.frame, scale: target.scale, imageSize: size)
                guard let shot = await Self.crop(image, to: pixelRect, scale: target.scale) else { throw CaptureError.emptyCrop }
                timings.record("areaCapture", clock.ms(until: shot.ready))
                timings.record("thumbnail", shot.thumbnailMs)
                if repeating {
                    let flash = Stopwatch()
                    AreaFlash.show(rect)
                    timings.record("areaFlash", flash.ms)
                }
                onCapture?(CaptureResult(image: shot.image, thumbnail: shot.thumbnail, png: shot.png, scale: target.scale,
                                         sourceRect: rect, displayID: display.id, kind: .area, date: shot.date))
                if !repeating {
                    Preferences.shared.lastArea = LastArea(rect: rect, displayID: display.id, displayFrame: display.frame)
                }
            } catch CaptureError.emptyCrop where repeating {
                // Nothing of the last area to crop from this display's image: choose again.
                CaptureLog.capture.error("repeat area: empty crop of \(String(describing: rect), privacy: .public); choosing again")
                beginInteractiveCapture()
            } catch {
                fail(error, session: nil, message: (error as? CaptureError) == .emptyCrop ? FailureText.area : FailureText.display)
            }
        }
    }

    // MARK: Helpers

    // Each of these starts the PNG encode and makes the shelf's thumbnail as well (`Shot`), on a user-interactive
    // thread (`Interactive`), before going back to the main actor.

    /// One display's frame.
    @concurrent
    private nonisolated static func capture(_ target: DisplayTarget) async throws -> Shot {
        await Shot.make(try await ScreenGrabber.capture(target).image, scale: target.scale)
    }

    @concurrent
    private nonisolated static func captureWindow(_ target: WindowTarget, keepShadow: Bool) async throws -> Shot {
        let (image, scale) = try await ScreenGrabber.captureWindow(target, keepShadow: keepShadow)
        return await Shot.make(image.image, scale: scale)
    }

    @concurrent
    private nonisolated static func crop(_ image: SendableImage, to pixelRect: CGRect, scale: CGFloat) async -> Shot? {
        await Interactive { ScreenGrabber.crop(image.image, to: pixelRect).map { Shot($0, scale: scale) } }.value
    }

    /// `crop`, and how long the crop itself took (without the thumbnail and the hops to and from the main actor).
    /// Synchronous: run it on a user-interactive thread (`Interactive`).
    private nonisolated static func timedCrop(_ image: SendableImage, to pixelRect: CGRect, scale: CGFloat) -> (Shot, Double)? {
        let clock = Stopwatch()
        guard let cropped = ScreenGrabber.crop(image.image, to: pixelRect) else { return nil }
        let cropMs = clock.ms
        return (Shot(cropped, scale: scale), cropMs)
    }

    /// Waits (briefly) until `app` is active again and has had a frame or two to redraw.
    private static func waitUntilActive(_ app: NSRunningApplication) async {
        for _ in 0..<15 where !app.isActive {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(35))
    }

    private func hasPermission() -> Bool {
        if !permissionConfirmed {
            let clock = Stopwatch()
            permissionConfirmed = CGPreflightScreenCaptureAccess()
            timings.record("preflight", clock.ms)
        }
        return permissionConfirmed
    }

    /// A capture worked, so Screen Recording is granted: from now on the cache may touch ScreenCaptureKit in
    /// the background, and an earlier revocation is over.
    private func permissionWorked() {
        permissionConfirmed = true
        cache.startObserving()
        RuntimeStatus.shared.screenRecordingRevoked = false
    }

    /// A capture failed for lack of permission: nothing touches ScreenCaptureKit until one works again.
    private func permissionLost() {
        permissionConfirmed = false
        cache.stopObserving()
    }

    /// Ends `failed` if it's still the live overlay. A missing permission goes to `onPermissionMissing`; any
    /// other failure shows `message` (if any), unless it belongs to an overlay already closed (Esc, a display change).
    private func fail(_ error: Error, session failed: OverlaySession?, message: String?) {
        let closed = failed.map { $0 !== session } ?? false
        if let failed, session === failed { endSession() }
        if ScreenGrabber.isPermissionError(error) {
            permissionLost()
            // Preflight is cached per process and may still say "granted": record the revocation for the UI.
            RuntimeStatus.shared.screenRecordingRevoked = true
            CaptureLog.capture.error("capture failed: Screen Recording permission missing")
            onPermissionMissing?()
        } else {
            CaptureLog.capture.error("capture failed: \(error.localizedDescription, privacy: .public)")
            if !closed, let message { onFailure?(message) }
        }
    }

    /// The app that owns the frontmost ordinary window on screen (on the current Space), Margin aside.
    private static func frontmostWindowOwner() -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != me else { continue }
            return NSRunningApplication(processIdentifier: pid)
        }
        return nil
    }

    /// Gives activation back to the app that had it before the overlay.
    private static func restoreFocus(to previous: NSRunningApplication?) {
        guard let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !previous.isTerminated else { return }
        NSApp.yieldActivation(to: previous)
        previous.activate(from: .current, options: [])
    }

    /// Takes the overlay down and hands focus back to the app that had it.
    private func endSession(restoreFocus: Bool = true) {
        guard let s = session else { return }
        session = nil
        let clock = Stopwatch()
        hotkeys.unregister()
        timings.record("endSession.hotkeys", clock.ms)
        let close = Stopwatch()
        s.close()
        timings.record("endSession.close", close.ms)
        if owesFocus, restoreFocus {
            giveFocusBack(to: previousApp)
        }
        activatedForSession = false
        inheritedFocusReturn = false
        becameActiveDuringSession = false
        previousApp = nil
    }
}
