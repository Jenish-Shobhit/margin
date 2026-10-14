import AppKit

/// One display in AppKit terms.
struct DisplayInfo: Equatable, Sendable {
    let id: CGDirectDisplayID
    /// AppKit global points.
    let frame: CGRect
    /// Pixels per point.
    let scale: CGFloat
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    var displayInfo: DisplayInfo? {
        displayID.map { DisplayInfo(id: $0, frame: frame, scale: backingScaleFactor) }
    }
}

@MainActor
enum Displays {
    static var all: [DisplayInfo] {
        let screens = NSScreen.screens.compactMap(\.displayInfo)
        #if DEBUG
        return screens + CaptureSimulation.extraDisplays
        #else
        return screens
        #endif
    }

    /// Height of the primary (menu bar) screen, for AppKit ↔ CG flips.
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == id }
    }

    static func display(containing point: CGPoint) -> DisplayInfo? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }?.displayInfo
            ?? NSScreen.main?.displayInfo
    }

    /// The display that holds the largest part of `rect` (AppKit global points).
    static func display(bestFor rect: CGRect) -> DisplayInfo? {
        var best: DisplayInfo?
        var bestArea: CGFloat = 0
        for d in all {
            let i = d.frame.intersection(rect)
            guard !i.isNull else { continue }
            let area = i.width * i.height
            if area > bestArea { best = d; bestArea = area }
        }
        return best
    }
}
