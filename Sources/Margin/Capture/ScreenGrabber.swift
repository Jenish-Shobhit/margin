import CoreGraphics
import Foundation
import MarginKit
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

/// A shot on its way to the shelf: the image and its card thumbnail, both made off the main thread.
struct Shot: @unchecked Sendable {
    let image: CGImage
    let thumbnail: CGImage
    /// When the image was ready, before the thumbnail: a shot without the overlay starts its release clock here.
    let date: Date
    let ready: ContinuousClock.Instant
    /// How long the thumbnail took.
    let thumbnailMs: Double

    /// Makes the thumbnail: never on the main thread (a full display takes about 19 ms).
    init(_ image: CGImage) {
        self.image = image
        date = Date()
        ready = .now
        let clock = Stopwatch()
        thumbnail = ScreenGrabber.thumbnail(of: image)
        thumbnailMs = clock.ms
    }
}

/// A window to capture on its own. Wraps the non-Sendable SCWindow.
struct WindowTarget: @unchecked Sendable {
    let window: SCWindow
}

/// ScreenCaptureKit calls and pixel work. Everything here runs off the main thread.
enum ScreenGrabber {
    /// The freeze filter for a display: everything except Margin's windows, but with `keeping` (its ordinary
    /// windows and menu bar icon) left in.
    static func makeDisplayTarget(display: SCDisplay, excluding apps: [SCRunningApplication], keeping: [SCWindow]) -> DisplayTarget {
        let filter = SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: keeping)
        let scale = CGFloat(SCShareableContent.info(for: filter).pointPixelScale)
        let config = SCStreamConfiguration()
        let size = Geometry.pixelSize(points: CGSize(width: display.width, height: display.height), scale: scale)
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.showsCursor = false
        config.captureResolution = .best
        config.scalesToFit = false
        return DisplayTarget(displayID: display.displayID, filter: filter, configuration: config, scale: scale,
                             pixelSize: size)
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
        let setup = Stopwatch()
        let filter = SCContentFilter(desktopIndependentWindow: target.window)
        let info = SCShareableContent.info(for: filter)
        let scale = CGFloat(info.pointPixelScale)
        CaptureTimings.log("windowCapture.filter", setup.ms)
        if keepShadow {
            let config = SCScreenshotConfiguration()
            config.showsCursor = false
            config.ignoreShadows = false
            // Like `ignoreGlobalClipSingleWindow` below: a window partly off-screen comes out whole. (macOS 27
            // doesn't clip it either way; SCStream documents clipping as the default.)
            config.ignoreClipping = true
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
        let sck = Stopwatch()
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        CaptureTimings.log("windowCapture.sck", sck.ms)
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

    /// Downsampled to cover the shelf card at 2× (aspect-fill), for the shelf's thumbnail and fly-in.
    static func thumbnail(of image: CGImage) -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0 else { return image }
        let cardHeight = ShelfLayout.cardHeight(forPixelSize: CGSize(width: w, height: h))
        let scale = min(1, max(ShelfLayout.cardWidth * 2 / w, cardHeight * 2 / h))
        guard scale < 0.9 else { return image }
        let tw = max(1, Int((w * scale).rounded())), th = max(1, Int((h * scale).rounded()))

        var space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if space.model != .rgb || !space.supportsOutput { space = CGColorSpace(name: CGColorSpace.sRGB)! }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage() ?? image
    }

    /// True when an error means Screen Recording permission is missing.
    static func isPermissionError(_ error: Error) -> Bool {
        isPermissionDenial(error) || !CGPreflightScreenCaptureAccess()
    }

    /// True when the error itself says permission was denied. Cheap (no preflight), so fine per display.
    static func isPermissionDenial(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.userDeclined.rawValue
    }
}

enum CaptureError: Error {
    case noImage
    /// ScreenCaptureKit doesn't list the display.
    case noDisplay
    case emptyCrop
}
