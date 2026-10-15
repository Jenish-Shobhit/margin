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

/// A PNG encoded off the main thread (`PNGWriter.encode`): its bytes, nil if the encode failed, and how long it took.
struct EncodedPNG: Sendable {
    let data: Data?
    let ms: Double
    /// No bytes because the capture itself failed after its stand-in went to the shelf (`CaptureResult.windowShot`):
    /// what the toast that takes the card away says.
    var failure: String? = nil
}

/// Window mode's shot, replacing the stand-in on the shelf (`CaptureResult.windowShot`): its card thumbnail and its
/// pixel size.
struct ShotThumbnail: @unchecked Sendable {
    let thumbnail: CGImage
    let pixelSize: CGSize
}

/// A shot on its way to the shelf: the image, its card thumbnail and its PNG, all made off the main thread and started
/// together as soon as the image is ready.
struct Shot: @unchecked Sendable {
    let image: CGImage
    /// Pixels per point: the PNG's DPI.
    let scale: CGFloat
    let thumbnail: CGImage
    /// The one encode that feeds both the file and the clipboard, running alongside the thumbnail.
    let png: Task<EncodedPNG, Never>
    /// When the image was ready, before the thumbnail: a shot without the overlay starts its release clock here.
    let date: Date
    let ready: ContinuousClock.Instant
    /// How long the thumbnail took.
    let thumbnailMs: Double

    /// Starts the encode, then makes the thumbnail: never on the main thread (a full display takes about 19 ms).
    init(_ image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        date = Date()
        ready = .now
        let source = SendableImage(image: image)
        png = Task.detached(priority: .userInitiated) {
            let clock = Stopwatch()
            let data = try? PNGWriter.encode(source.image, scale: scale)
            return EncodedPNG(data: data, ms: clock.ms)
        }
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
    /// `timing` names the log lines (`<timing>.filter`, `<timing>.sck`): window mode's stand-in has its own.
    static func captureWindow(_ target: WindowTarget, keepShadow: Bool,
                              timing: String = "windowCapture") async throws -> (SendableImage, CGFloat) {
        let state = CaptureLog.signposter.beginInterval("captureWindow")
        defer { CaptureLog.signposter.endInterval("captureWindow", state) }
        let setup = Stopwatch()
        let filter = SCContentFilter(desktopIndependentWindow: target.window)
        let info = SCShareableContent.info(for: filter)
        let scale = CGFloat(info.pointPixelScale)
        CaptureTimings.log("\(timing).filter", setup.ms)
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
        CaptureTimings.log("\(timing).sck", sck.ms)
        return (SendableImage(image: image), scale)
    }

    /// `pixelRect` (origin top-left) of `image`, sharing its pixels (and so its color space and alpha layout).
    /// Copying them out took 8 ms for a medium area, on the way to the thumbnail. The crop keeps the whole frozen
    /// display alive, but only until its PNG is written: the shelf keeps just the thumbnail, always a bitmap of its own.
    static func crop(_ image: CGImage, to pixelRect: CGRect) -> CGImage? {
        let state = CaptureLog.signposter.beginInterval("crop")
        defer { CaptureLog.signposter.endInterval("crop", state) }
        let r = pixelRect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
        if r.width == CGFloat(image.width), r.height == CGFloat(image.height) { return image }
        return image.cropping(to: r)
    }

    /// Downsampled to cover the shelf card at 2× (aspect-fill), for the shelf's thumbnail and fly-in. Always a bitmap of
    /// its own, even when `image` is small enough as it is: a crop shares the whole frozen display's pixels (`crop`),
    /// and the card keeps its thumbnail.
    static func thumbnail(of image: CGImage) -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0 else { return image }
        let cardHeight = ShelfLayout.cardHeight(forPixelSize: CGSize(width: w, height: h))
        var scale = min(1, max(ShelfLayout.cardWidth * 2 / w, cardHeight * 2 / h))
        if scale >= 0.9 { scale = 1 }
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
