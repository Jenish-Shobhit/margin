import AppKit
import MarginKit
import ScreenCaptureKit

/// An on-screen window window mode can pick (another app's, or Margin's Settings, First run or About), floating ones
/// included (`WindowPicking`), for snapping and window mode.
struct CapturableWindow {
    let target: WindowTarget
    let id: CGWindowID
    /// AppKit global points.
    let frame: CGRect
    let appName: String
}

/// The fetched content, boxed so it can come back from a nonisolated fetch.
private struct ContentBox: @unchecked Sendable {
    let content: SCShareableContent
}

/// Cached `SCShareableContent`: displays, windows and Margin's own `SCRunningApplication`.
/// Refreshed on display, app and Space changes once Screen Recording is confirmed (`startObserving`), and for
/// the windows during each ⌘⇧4, once the first display is frozen; never on the hotkey path itself.
@MainActor
final class ShareableContentCache {
    /// Freeze targets per display, built with Margin excluded.
    private(set) var targets: [CGDirectDisplayID: DisplayTarget] = [:]
    /// Front to back: the windows window mode can pick, and the system UI in front of them (the Dock, the menu bar),
    /// which hides them without being picked itself (`window` nil).
    private var stack: [(frame: CGRect, window: CapturableWindow?)] = []
    /// Frames to snap to: the windows that can be picked, minus any entirely hidden behind a single one in front of it,
    /// so invisible edges don't pull the selection.
    private(set) var snapFrames: [CGRect] = []
    private(set) var hasMarginApp = false
    private(set) var isLoaded = false
    /// Margin's ordinary windows the targets keep in shots (see `apply`).
    private var keptWindowIDs: Set<CGWindowID> = []
    /// The displays (NSScreen) that existed when the applied fetch started, with their pixel size then. One of
    /// these without a target is a display ScreenCaptureKit can't list (Sidecar, AirPlay, DisplayLink…), not one it
    /// hasn't been asked about. One whose size or scale has changed since has a target for the old size.
    private var knownDisplays: [CGDirectDisplayID: CGSize] = [:]
    /// Retries after a scheduled fetch that failed, or that came back before ScreenCaptureKit caught up with a
    /// display change: 0.5 s, 1 s, then 2 s apart.
    private static let refreshRetries = 3

    private var requested = 0
    private var applied = 0
    private var debounce: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// Starts refreshing on display, app and Space changes. Call only once Screen Recording is confirmed (a
    /// successful prewarm or capture): any ScreenCaptureKit call without it can raise the system prompt at a
    /// random moment, long before the user reaches "Allow…".
    func startObserving() {
        guard observers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        let app = NotificationCenter.default
        for (center, name) in [
            (app, NSApplication.didChangeScreenParametersNotification),
            (ws, NSWorkspace.didLaunchApplicationNotification),
            (ws, NSWorkspace.didTerminateApplicationNotification),
            (ws, NSWorkspace.activeSpaceDidChangeNotification),
        ] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
            observers.append((center, token))
        }
        // Margin's own windows appearing (made key, or shown in the background).
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            let token = app.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // Posted on the main thread (queue .main), where the window lives.
                nonisolated(unsafe) let object = note.object
                MainActor.assumeIsolated {
                    guard let window = object as? NSWindow else { return }
                    self?.marginWindowChanged(window)
                }
            }
            observers.append((app, token))
        }
    }

    /// Whether a Margin window at this level is one of its ordinary windows, kept in shots: below the pop-up menu
    /// level, where the capture chrome starts.
    nonisolated static func isOrdinary(level: Int) -> Bool {
        level < Int(CGWindowLevelForKey(.popUpMenuWindow))
    }

    /// An ordinary window the targets don't know yet (Settings opened for the first time since the last fetch)
    /// would be cut out of shots: fetch again.
    private func marginWindowChanged(_ window: NSWindow) {
        // Read once, and checked: a window can lose its number (-1) between two reads, as it closes.
        guard isLoaded, let id = CGWindowID(exactly: window.windowNumber), id > 0, window.isVisible,
              Self.isOrdinary(level: window.level.rawValue), !keptWindowIDs.contains(id) else { return }
        scheduleRefresh()
    }

    /// Screen Recording was lost (a capture, the prewarm or a background refresh said so): no more background fetches
    /// until a capture works again, and drop the targets so the next capture fetches fresh content (changes went
    /// unobserved in between).
    func stopObserving() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        debounce?.cancel()
        debounce = nil
        targets = [:]
        hasMarginApp = false
        isLoaded = false
        knownDisplays = [:]
        keptWindowIDs = []
    }

    /// Coalesces bursts of notifications into one fetch. A fetch that fails (displays still reconfiguring after
    /// a wake, say), or whose targets don't match the displays yet, is retried a few times; a capture in between
    /// still fetches first if its display changed (`needsRefresh`).
    func scheduleRefresh(after delay: Duration = .milliseconds(150)) {
        debounce?.cancel()
        debounce = Task { [weak self] in
            var wait = delay
            for attempt in 0...Self.refreshRetries {
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled, let self else { return }
                do {
                    try await self.refresh()
                    if self.targetsMatchDisplays { return }
                    CaptureLog.capture.info("refresh: a display target doesn't match its display yet")
                } catch {
                    // Without permission, any further call could raise the system prompt: stop listening for changes
                    // too (an app launching, a Space switch) until a capture works again (`startObserving`).
                    if ScreenGrabber.isPermissionError(error) {
                        CaptureLog.capture.error("refresh failed: Screen Recording permission missing; not refreshing until a capture works")
                        self.stopObserving()
                        return
                    }
                    CaptureLog.capture.error("refresh failed: \(error.localizedDescription, privacy: .public)")
                }
                guard attempt < Self.refreshRetries else {
                    CaptureLog.capture.error("refresh: giving up after \(attempt + 1) tries")
                    return
                }
                wait = .milliseconds(500 << attempt)
            }
        }
    }

    /// Fetches fresh content now. Later requests win over earlier ones that finish late.
    ///
    /// `onScreenOnly` is for a refresh while the overlay is up: listing on-screen windows only is quicker (33 vs
    /// 57 ms here), and everything the cache keeps is on screen anyway (snapping and window mode want on-screen
    /// windows, and Margin is listed through its overlay). Should the overlay be gone by the time the fetch runs
    /// and Margin with it, only the windows are taken from it.
    func refresh(onScreenOnly: Bool = false) async throws {
        requested += 1
        let ticket = requested
        let state = CaptureLog.signposter.beginInterval("shareableContent")
        let clock = Stopwatch()
        // Before the fetch: a display that appears, or changes, while it runs must not count as "asked about".
        let screens = Dictionary(Displays.all.map { ($0.id, $0.pixelSize) }, uniquingKeysWith: { a, _ in a })
        let box = try await Self.fetch(onScreenOnly: onScreenOnly)
        CaptureLog.signposter.endInterval("shareableContent", state)
        guard ticket > applied else { return }
        applied = ticket
        if apply(box.content, onScreenOnly: onScreenOnly) { knownDisplays = screens }
        CaptureLog.timing.debug("shareable content refreshed in \(clock.ms, format: .fixed(precision: 1), privacy: .public) ms")
    }

    private nonisolated static func fetch(onScreenOnly: Bool) async throws -> ContentBox {
        // All windows by default, not just on-screen ones: Margin is listed only if it owns a window, and its
        // overlay panels exist (ordered out) from prewarm on.
        ContentBox(content: try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: onScreenOnly))
    }

    /// True when a capture of these displays must fetch first: nothing cached, Margin missing (its windows
    /// wouldn't be excluded), or a display that appeared, or changed size or scale, since the last fetch (a
    /// change whose background refresh hasn't run yet, or failed). Its target would capture at the old size.
    /// A known display without a target can't be captured, and refetching on every capture wouldn't change that.
    func needsRefresh(for displays: [DisplayInfo]) -> Bool {
        !isLoaded || !hasMarginApp || displays.contains { knownDisplays[$0.id] != $0.pixelSize }
    }

    /// The freeze target for a display, refreshing first if the cache is cold, lacks Margin, or predates the
    /// display as it is now. Throws `noDisplay` for a display ScreenCaptureKit doesn't list.
    func target(for display: DisplayInfo) async throws -> DisplayTarget {
        if needsRefresh(for: [display]) { try await refresh() }
        guard let t = targets[display.id] else { throw CaptureError.noDisplay }
        return t
    }

    /// False while a display's target was built for another pixel size than the display has now.
    private var targetsMatchDisplays: Bool {
        Displays.all.allSatisfy { d in targets[d.id].map { $0.pixelSize == d.pixelSize } ?? true }
    }

    /// The topmost window under a point (AppKit global points); nil over system UI such as the Dock.
    func window(at point: CGPoint) -> CapturableWindow? {
        stack.first { $0.frame.contains(point) }?.window
    }

    /// Takes the windows and rebuilds the targets, except from an on-screen-only fetch that doesn't list Margin (its
    /// overlay closed before the fetch ran): the targets there are stay. Returns whether the targets were rebuilt.
    private func apply(_ content: SCShareableContent, onScreenOnly: Bool) -> Bool {
        let pid = getpid()
        let margin = content.applications.filter { $0.processID == pid }
        let rebuildTargets = !margin.isEmpty || !onScreenOnly || !isLoaded
        if rebuildTargets { applyTargets(content, margin: margin) }
        applyWindows(content)
        isLoaded = true
        return rebuildTargets
    }

    private func applyTargets(_ content: SCShareableContent, margin: [SCRunningApplication]) {
        let pid = getpid()
        hasMarginApp = !margin.isEmpty
        if !hasMarginApp { CaptureLog.capture.error("Margin is not in SCShareableContent; its windows would not be excluded") }

        // Margin is excluded as an app, so a window it makes later (each fly-in, a ⇧⌘2 outline) is never in a shot.
        // Its ordinary windows are kept, like any app's: Settings, First run, About, an open panel, Quick Look, and
        // the menu bar icon where AppKit draws status items in-process (macOS 27 draws them in MenuBarAgent's menu
        // bar instead). The capture chrome all sits at the pop-up menu level or above: menus, the shelf and fly-in
        // (.screenSaver), the overlay and outline (.screenSaver + 1). One opened since this fetch is excluded
        // until the refresh it schedules (`marginWindowChanged`).
        let kept = content.windows.filter { $0.owningApplication?.processID == pid && Self.isOrdinary(level: $0.windowLayer) }
        keptWindowIDs = Set(kept.map(\.windowID))
        var t: [CGDirectDisplayID: DisplayTarget] = [:]
        for display in content.displays {
            t[display.displayID] = ScreenGrabber.makeDisplayTarget(display: display, excluding: margin, keeping: kept)
        }
        targets = t
    }

    private func applyWindows(_ content: SCShareableContent) {
        // SCShareableContent's window order isn't z-order; CGWindowList's is (front to back). Each window's place in it
        // decides what it is (`WindowPicking`), and a window to pick must also be one ScreenCaptureKit can capture.
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let capturable = Dictionary(content.windows.filter(\.isOnScreen).map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        let primaryHeight = Displays.primaryHeight
        let displays = Displays.all.map(\.frame)
        stack = []
        for info in list {
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) })
            else { continue }
            let frame = Geometry.flip(bounds, primaryHeight: primaryHeight)
            guard frame.width >= 24, frame.height >= 24 else { continue }
            switch WindowPicking.role(layer: layer, frame: frame, displays: displays) {
            case .ignored:
                continue
            case .cover:
                stack.append((frame, nil))
            case .pickable:
                // Margin's own Settings, First run and About windows included: they're in shots, so they can be picked.
                guard let w = capturable[id] else { continue }
                let window = CapturableWindow(target: WindowTarget(window: w), id: id,
                                              frame: Geometry.flip(w.frame, primaryHeight: primaryHeight),
                                              appName: w.owningApplication?.applicationName ?? "Window")
                stack.append((window.frame, window))
            }
        }
        let frames = stack.compactMap { $0.window?.frame }
        snapFrames = frames.enumerated()
            .filter { i, f in !frames[..<i].contains { $0.contains(f) } }
            .map(\.element)
    }
}
