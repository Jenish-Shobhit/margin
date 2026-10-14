import AppKit
import MarginKit
import ScreenCaptureKit

/// One display's frozen frame, or why it failed.
private struct FrozenFrame: Sendable {
    let displayID: CGDirectDisplayID
    let result: Result<SendableImage, any Error>
    let ms: Double
}

/// Area, window and full-screen capture (spec §2).
@MainActor
final class CaptureController: CaptureControlling {
    var onCapture: ((CaptureResult) -> Void)?
    var onPermissionMissing: (() -> Void)?
    var isCapturing: Bool { session != nil }

    /// Latest timings in ms, for the DEBUG `dump-state` hook.
    var lastTimings: [String: Double] { timings.values }
    /// The live overlay session, for tests that drive it with synthetic events.
    var currentSession: OverlaySession? { session }

    private let cache = ShareableContentCache()
    private let pool = OverlayPanelPool()
    private let timings = CaptureTimings()
    private var session: OverlaySession?
    /// The app that was frontmost when the overlay went up; it gets focus back afterwards.
    private var previousApp: NSRunningApplication?
    private var activatedForSession = false
    private var becameActiveDuringSession = false
    private var observers: [NSObjectProtocol] = []
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
                guard let self, self.session != nil else { return }
                self.becameActiveDuringSession = true
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
    }

    // MARK: Prewarm

    func prewarm() async {
        let clock = Stopwatch()
        // The overlay panels exist from now on: the hotkey only orders them in, and owning windows keeps
        // Margin listed in SCShareableContent (needed to exclude it).
        pool.sync()
        pool.warmUp()
        do {
            try await cache.refresh()
            let main = CGMainDisplayID()
            if let target = cache.targets[main] ?? cache.targets.values.first {
                try await ScreenGrabber.warmUp(target)
            }
            permissionConfirmed = true
            timings.record("prewarm", clock.ms)
        } catch {
            CaptureLog.capture.error("prewarm failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: ⌘⇧4

    func beginInteractiveCapture() {
        guard session == nil else { return }
        let clock = Stopwatch()
        let signpost = CaptureLog.signposter.beginInterval("freeze")
        guard hasPermission() else {
            CaptureLog.signposter.endInterval("freeze", signpost)
            onPermissionMissing?()
            return
        }
        let displays = Displays.all
        guard !displays.isEmpty else { return }

        // Start the captures first: they run off the main thread while the panels go up.
        let targets = displays.compactMap { cache.targets[$0.id] }
        let warm = cache.hasMarginApp && targets.count == displays.count
        let early = warm ? Self.captureAll(targets) : nil

        pool.sync()
        let session = OverlaySession(panels: pool.panels(for: displays), cache: cache,
                                     showsHUD: Preferences.shared.completedCaptures < 5)
        session.onArea = { [weak self] rect, display, image, pixelRect, scale in
            self?.finishArea(rect, display: display, image: image, pixelRect: pixelRect, scale: scale)
        }
        session.onWindow = { [weak self] window, keepShadow in
            self?.finishWindow(window, keepShadow: keepShadow)
        }
        session.onCancel = { [weak self] in self?.endSession() }
        self.session = session
        previousApp = NSWorkspace.shared.frontmostApplication
        activatedForSession = false
        becameActiveDuringSession = false
        session.show()
        timings.record("hotkeyToOverlay", clock.ms)

        Task { [weak self] in
            await self?.freeze(session, displays: displays, early: early, clock: clock)
            CaptureLog.signposter.endInterval("freeze", signpost)
        }
    }

    /// Draws each display's frozen frame as it arrives, then takes keyboard focus.
    private func freeze(_ session: OverlaySession, displays: [DisplayInfo], early: AsyncStream<FrozenFrame>?, clock: Stopwatch) async {
        var stream = early
        if stream == nil {
            // Cold cache (or Margin missing from it): fetch once, off the fast path.
            CaptureLog.capture.info("freeze: cache cold, fetching shareable content first")
            do {
                try await cache.refresh()
            } catch {
                fail(error, session: session)
                return
            }
            guard self.session === session else { return }
            stream = Self.captureAll(displays.compactMap { cache.targets[$0.id] })
        }
        guard let stream else { return }

        // Never leave a transparent overlay eating clicks if SCK stalls.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.session === session, session.frozenCount == 0 else { return }
            CaptureLog.capture.error("freeze: no frame after 3 s, cancelling")
            self.endSession()
        }

        var first = true
        for await frame in stream {
            guard self.session === session else { return }
            switch frame.result {
            case let .success(image):
                session.setFrozen(image.image, for: frame.displayID) {
                    if first {
                        first = false
                        timings.record("hotkeyToFirstFrozen", clock.ms)
                    }
                }
                timings.record("freezeCapture.\(frame.displayID)", frame.ms)
            case let .failure(error):
                fail(error, session: session)
                return
            }
        }
        guard self.session === session else { return }
        timings.record("hotkeyToAllFrozen", clock.ms)
        if session.frozenCount == 0 {
            endSession()
            return
        }

        // The frames are in, so activating can't change what was frozen (window focus looks, open menus).
        NSApp.activate()
        session.makeKey()
        activatedForSession = true
        // Window frames may have moved since the last refresh: update them for snapping and window mode.
        cache.scheduleRefresh(after: .zero)
    }

    /// Captures every target in parallel; yields frames as they finish.
    private nonisolated static func captureAll(_ targets: [DisplayTarget]) -> AsyncStream<FrozenFrame> {
        let (stream, continuation) = AsyncStream.makeStream(of: FrozenFrame.self)
        Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: Void.self) { group in
                for target in targets {
                    group.addTask {
                        let clock = Stopwatch()
                        do {
                            let image = try await ScreenGrabber.capture(target)
                            continuation.yield(FrozenFrame(displayID: target.displayID, result: .success(image), ms: clock.ms))
                        } catch {
                            continuation.yield(FrozenFrame(displayID: target.displayID, result: .failure(error), ms: clock.ms))
                        }
                    }
                }
            }
            continuation.finish()
        }
        return stream
    }

    private func finishArea(_ rect: CGRect, display: DisplayInfo, image: CGImage, pixelRect: CGRect, scale: CGFloat) {
        let clock = Stopwatch()
        let date = Date()
        // Overlay first: the shelf's fly-in starts from the selection, over the live screen.
        endSession()
        Preferences.shared.lastArea = LastArea(rect: rect, displayID: display.id)
        let source = SendableImage(image: image)
        Task {
            guard let cropped = await Self.crop(source, to: pixelRect) else {
                CaptureLog.capture.error("area crop was empty: \(String(describing: pixelRect), privacy: .public)")
                return
            }
            timings.record("releaseToResult", clock.ms)
            onCapture?(CaptureResult(image: cropped.image, scale: scale, sourceRect: rect, displayID: display.id, kind: .area, date: date))
        }
    }

    private func finishWindow(_ window: CapturableWindow, keepShadow: Bool) {
        let clock = Stopwatch()
        let wasActive = activatedForSession
        let previous = previousApp
        endSession()
        Task {
            // Margin took focus for the keys; give it back first so the window is shot with its own focus look.
            if wasActive, let previous { await Self.waitUntilActive(previous) }
            do {
                let (image, scale) = try await ScreenGrabber.captureWindow(window.target, keepShadow: keepShadow)
                timings.record("windowCapture", clock.ms)
                let displayID = Displays.display(bestFor: window.frame)?.id ?? CGMainDisplayID()
                onCapture?(CaptureResult(image: image.image, scale: scale, sourceRect: window.frame, displayID: displayID, kind: .window, date: Date()))
            } catch {
                fail(error, session: nil)
            }
        }
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
                let target = try await cache.target(for: display.id)
                let image = try await ScreenGrabber.capture(target)
                timings.record("screenCapture", clock.ms)
                onCapture?(CaptureResult(image: image.image, scale: target.scale, sourceRect: display.frame, displayID: display.id, kind: .screen, date: Date()))
            } catch {
                fail(error, session: nil)
            }
        }
    }

    // MARK: ⌘⇧2 and direct areas

    func repeatLastArea() {
        guard session == nil else { return }
        guard let last = Preferences.shared.lastArea,
              let display = Displays.all.first(where: { $0.id == last.displayID }) else {
            beginInteractiveCapture()
            return
        }
        let rect = last.rect.intersection(display.frame)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else {
            beginInteractiveCapture()
            return
        }
        captureArea(rect, on: display, flash: true)
    }

    func captureArea(_ rect: CGRect) {
        guard let display = Displays.display(bestFor: rect) else {
            CaptureLog.capture.error("captureArea: no display for \(String(describing: rect), privacy: .public)")
            return
        }
        captureArea(rect.intersection(display.frame), on: display, flash: false)
    }

    private func captureArea(_ rect: CGRect, on display: DisplayInfo, flash: Bool) {
        guard session == nil else { return }
        guard hasPermission() else { onPermissionMissing?(); return }
        let clock = Stopwatch()
        pool.sync()
        Task {
            do {
                let target = try await cache.target(for: display.id)
                let image = try await ScreenGrabber.capture(target)
                let size = CGSize(width: image.image.width, height: image.image.height)
                let pixelRect = Geometry.pixelRect(for: rect, displayFrame: display.frame, scale: target.scale, imageSize: size)
                guard let cropped = await Self.crop(image, to: pixelRect) else { throw CaptureError.emptyCrop }
                timings.record("areaCapture", clock.ms)
                if flash { AreaFlash.show(rect) }
                Preferences.shared.lastArea = LastArea(rect: rect, displayID: display.id)
                onCapture?(CaptureResult(image: cropped.image, scale: target.scale, sourceRect: rect, displayID: display.id, kind: .area, date: Date()))
            } catch {
                fail(error, session: nil)
            }
        }
    }

    // MARK: Helpers

    @concurrent
    private nonisolated static func crop(_ image: SendableImage, to pixelRect: CGRect) async -> SendableImage? {
        ScreenGrabber.crop(image.image, to: pixelRect).map(SendableImage.init)
    }

    /// Waits (briefly) until `app` is active again and has had a frame or two to redraw.
    private static func waitUntilActive(_ app: NSRunningApplication) async {
        for _ in 0..<15 where !app.isActive {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(35))
    }

    private func hasPermission() -> Bool {
        if !permissionConfirmed { permissionConfirmed = CGPreflightScreenCaptureAccess() }
        return permissionConfirmed
    }

    private func fail(_ error: Error, session failed: OverlaySession?) {
        if let failed, session === failed { endSession() }
        if ScreenGrabber.isPermissionError(error) {
            permissionConfirmed = false
            CaptureLog.capture.error("capture failed: Screen Recording permission missing")
            onPermissionMissing?()
        } else {
            CaptureLog.capture.error("capture failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Takes the overlay down and hands focus back to the app that had it.
    private func endSession(restoreFocus: Bool = true) {
        guard let s = session else { return }
        session = nil
        s.close()
        if activatedForSession, restoreFocus, let previous = previousApp,
           previous.processIdentifier != ProcessInfo.processInfo.processIdentifier, !previous.isTerminated {
            NSApp.yieldActivation(to: previous)
            previous.activate(from: .current, options: [])
        }
        activatedForSession = false
        becameActiveDuringSession = false
        previousApp = nil
    }
}
