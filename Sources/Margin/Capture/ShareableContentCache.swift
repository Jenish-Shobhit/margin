import AppKit
import MarginKit
import ScreenCaptureKit

/// A normal on-screen window from another app, for snapping and window mode.
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
/// Refreshed on display, app and Space changes, and never fetched on the hotkey path.
@MainActor
final class ShareableContentCache {
    /// Freeze targets per display, built with Margin excluded.
    private(set) var targets: [CGDirectDisplayID: DisplayTarget] = [:]
    /// Front-to-back.
    private(set) var windows: [CapturableWindow] = []
    private(set) var hasMarginApp = false
    private(set) var isLoaded = false

    private var requested = 0
    private var applied = 0
    private var debounce: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
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
    }

    /// Coalesces bursts of notifications into one fetch.
    func scheduleRefresh(after delay: Duration = .milliseconds(150)) {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            try? await self?.refresh()
        }
    }

    /// Fetches fresh content now. Later requests win over earlier ones that finish late.
    func refresh() async throws {
        requested += 1
        let ticket = requested
        let state = CaptureLog.signposter.beginInterval("shareableContent")
        let clock = Stopwatch()
        let box = try await Self.fetch()
        CaptureLog.signposter.endInterval("shareableContent", state)
        guard ticket > applied else { return }
        applied = ticket
        apply(box.content)
        CaptureLog.timing.debug("shareable content refreshed in \(clock.ms, format: .fixed(precision: 1), privacy: .public) ms")
    }

    private nonisolated static func fetch() async throws -> ContentBox {
        // All windows, not just on-screen ones: Margin is listed only if it owns a window, and its
        // overlay panels exist (ordered out) from prewarm on.
        ContentBox(content: try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false))
    }

    /// The freeze target for a display, refreshing first if the cache is cold, stale, or lacks Margin.
    func target(for displayID: CGDirectDisplayID) async throws -> DisplayTarget {
        if let t = targets[displayID], hasMarginApp { return t }
        try await refresh()
        guard let t = targets[displayID] else { throw CaptureError.noDisplay }
        return t
    }

    /// The topmost window under a point (AppKit global points).
    func window(at point: CGPoint) -> CapturableWindow? {
        windows.first { $0.frame.contains(point) }
    }

    private func apply(_ content: SCShareableContent) {
        let pid = getpid()
        let margin = content.applications.filter { $0.processID == pid }
        hasMarginApp = !margin.isEmpty
        if !hasMarginApp { CaptureLog.capture.error("Margin is not in SCShareableContent; its windows would not be excluded") }

        var t: [CGDirectDisplayID: DisplayTarget] = [:]
        for display in content.displays {
            t[display.displayID] = ScreenGrabber.makeDisplayTarget(display: display, excluding: margin)
        }
        targets = t

        // SCShareableContent's window order isn't z-order; CGWindowList's is (front to back).
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var rank: [CGWindowID: Int] = [:]
        for (i, info) in list.enumerated() {
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0 else { continue }
            rank[id] = i
        }
        let primaryHeight = Displays.primaryHeight
        windows = content.windows
            .filter { w in
                w.isOnScreen && w.windowLayer == 0 && rank[w.windowID] != nil
                    && w.owningApplication?.processID != pid
                    && w.frame.width >= 24 && w.frame.height >= 24
            }
            .sorted { rank[$0.windowID]! < rank[$1.windowID]! }
            .map { w in
                CapturableWindow(target: WindowTarget(window: w), id: w.windowID,
                                 frame: Geometry.flip(w.frame, primaryHeight: primaryHeight),
                                 appName: w.owningApplication?.applicationName ?? "Window")
            }
        isLoaded = true
    }
}
