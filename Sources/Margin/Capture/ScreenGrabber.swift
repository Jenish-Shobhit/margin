import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A CGImage that crosses actor boundaries. CGImage is immutable once made.
struct SendableImage: @unchecked Sendable {
    let image: CGImage
}

/// Everything needed to capture one display, built ahead of time so the hotkey path only calls SCK.
/// The SCK objects are never mutated after construction, so sharing them across tasks is safe.
struct DisplayTarget: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration
    /// Pixels per point (`SCShareableContent.info(for:).pointPixelScale`).
    let scale: CGFloat
    /// Pixel size of the captured image.
    let pixelSize: CGSize
}

/// A window to capture on its own. Wraps the non-Sendable SCWindow.
struct WindowTarget: @unchecked Sendable {
    let window: SCWindow
}

/// ScreenCaptureKit calls and pixel work. Everything here runs off the main thread.
enum ScreenGrabber {
    /// The freeze filter for a display: everything except Margin's own windows.
    static func makeDisplayTarget(display: SCDisplay, excluding apps: [SCRunningApplication]) -> DisplayTarget {
        let filter = SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
        let scale = CGFloat(SCShareableContent.info(for: filter).pointPixelScale)
        let config = SCStreamConfiguration()
        let width = Int((CGFloat(display.width) * scale).rounded())
        let height = Int((CGFloat(display.height) * scale).rounded())
        config.width = width
        config.height = height
        config.showsCursor = false
        config.captureResolution = .best
        config.scalesToFit = false
        return DisplayTarget(displayID: display.displayID, filter: filter, configuration: config, scale: scale,
                             pixelSize: CGSize(width: width, height: height))
    }

    /// One full-resolution frame of the display.
    static func capture(_ target: DisplayTarget) async throws -> SendableImage {
        let state = CaptureLog.signposter.beginInterval("captureDisplay")
        defer { CaptureLog.signposter.endInterval("captureDisplay", state) }
        let image = try await SCScreenshotManager.captureImage(contentFilter: target.filter, configuration: target.configuration)
        return SendableImage(image: image)
    }

    /// A tiny capture that warms up the ScreenCaptureKit pipeline (the first call is slow).
    static func warmUp(_ target: DisplayTarget) async throws {
        let config = SCStreamConfiguration()
        config.width = 16
        config.height = 16
        config.showsCursor = false
        _ = try await SCScreenshotManager.captureImage(contentFilter: target.filter, configuration: config)
    }

    /// Just this window, with transparent rounded corners.
    /// Without the shadow, `captureImage` at frame × scale is exact. With the shadow, the image must be
    /// larger than the frame by the shadow's extent, which only the macOS 26 screenshot API sizes for us.
    static func captureWindow(_ target: WindowTarget, keepShadow: Bool) async throws -> (SendableImage, CGFloat) {
        let state = CaptureLog.signposter.beginInterval("captureWindow")
        defer { CaptureLog.signposter.endInterval("captureWindow", state) }
        let filter = SCContentFilter(desktopIndependentWindow: target.window)
        let info = SCShareableContent.info(for: filter)
        let scale = CGFloat(info.pointPixelScale)
        if keepShadow {
            let config = SCScreenshotConfiguration()
            config.showsCursor = false
            config.ignoreShadows = false
            let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config)
            guard let image = output.sdrImage else { throw CaptureError.noImage }
            return (SendableImage(image: image), scale)
        }
        let config = SCStreamConfiguration()
        config.width = Int((info.contentRect.width * scale).rounded())
        config.height = Int((info.contentRect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        config.shouldBeOpaque = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (SendableImage(image: image), scale)
    }

    /// Copies `pixelRect` (origin top-left) out of `image` into its own buffer, so the result
    /// doesn't keep the whole frozen display alive. Keeps the color space and alpha layout.
    static func crop(_ image: CGImage, to pixelRect: CGRect) -> CGImage? {
        let state = CaptureLog.signposter.beginInterval("crop")
        defer { CaptureLog.signposter.endInterval("crop", state) }
        let r = pixelRect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !r.isNull, r.width >= 1, r.height >= 1, let sub = image.cropping(to: r) else { return nil }
        if r.width == CGFloat(image.width), r.height == CGFloat(image.height) { return image }
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: Int(r.width), height: Int(r.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: info) else { return sub }
        ctx.interpolationQuality = .none
        ctx.setBlendMode(.copy)
        ctx.draw(sub, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        return ctx.makeImage() ?? sub
    }

    /// True when an error means Screen Recording permission is missing.
    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain, ns.code == SCStreamError.userDeclined.rawValue { return true }
        return !CGPreflightScreenCaptureAccess()
    }
}

enum CaptureError: Error {
    case noImage
    case noDisplay
    case emptyCrop
}
