import CoreGraphics
import CoreVideo
import Dispatch
import Foundation
import IOSurface
import VideoToolbox

/// The frozen frame as the overlay's layers show it: a copy of ScreenCaptureKit's image in an IOSurface of its own.
///
/// `captureImage`'s CGImage wraps its IOSurface in a data provider, which Core Animation can't see through: handed to a
/// layer, a full display's 22.5 MB were copied on the main thread in the commit (about 4 ms). An image VideoToolbox
/// makes over an IOSurface is one Core Animation takes as the surface itself (a commit of about 0.1 ms), so the copy is
/// made here instead, off the main thread.
///
/// Only the layers get the copy. Crops, the loupe, thumbnails and PNGs keep using ScreenCaptureKit's image: its pixels
/// aren't what `captureSampleBuffer` gives (up to 2 levels apart where macOS dithers gradients and photos), so a frame
/// captured as a sample buffer would have changed the files.
public enum SurfaceImage {
    /// ScreenCaptureKit's layout: 8-bit BGRA, premultiplied first, little-endian.
    static let bgra = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

    /// A copy: the image the layers show, and the surface under it (for `discard`).
    public struct Copy: @unchecked Sendable {
        public let image: CGImage
        public let surface: IOSurfaceRef
    }

    /// `image`'s pixels in an IOSurface of its own (its colour space attached), as an image over that surface: the same
    /// bytes, layout and colour space. nil for any layout but ScreenCaptureKit's, or if the surface can't be made; then
    /// the layers show `image` itself, as before. `step` gets the time of each part, in ms.
    public static func copy(of image: CGImage, bands: Int = 4,
                            step: (String, Double) -> Void = { _, _ in }) -> Copy? {
        var clock = ContinuousClock.now
        func lap(_ name: String) {
            let now = ContinuousClock.now
            let d = (now - clock).components
            step(name, Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15)
            clock = now
        }
        let width = image.width, height = image.height, rowBytes = width * 4, sourceStride = image.bytesPerRow
        guard width > 0, height > 0, image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.decode == nil,
              image.bitmapInfo == bgra, let space = image.colorSpace, space.model == .rgb, sourceStride >= rowBytes,
              let data = image.dataProvider?.data, CFDataGetLength(data) >= sourceStride * (height - 1) + rowBytes,
              let source = CFDataGetBytePtr(data)
        else { return nil }
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &made) == kCVReturnSuccess,
              let buffer = made, let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue(),
              CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess
        else { return nil }
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return nil
        }
        lap("surface")
        let destination = UnsafeMutableRawPointer(base), stride = CVPixelBufferGetBytesPerRow(buffer)
        let count = max(1, min(bands, height)), rowsPerBand = (height + count - 1) / count
        withExtendedLifetime(data) {
            // Reading ScreenCaptureKit's surface and touching the new one's pages is most of the time: a few cores share it.
            DispatchQueue.concurrentPerform(iterations: count) { k in
                let rows = (k * rowsPerBand)..<min(height, (k + 1) * rowsPerBand)
                guard !rows.isEmpty else { return }
                if stride == sourceStride {
                    memcpy(destination + rows.lowerBound * stride, source + rows.lowerBound * stride,
                           (rows.count - 1) * stride + rowBytes)
                } else {
                    for y in rows { memcpy(destination + y * stride, source + y * sourceStride, rowBytes) }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        lap("memcpy")
        var copied: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &copied) == noErr, let copied else { return nil }
        return Copy(image: copied, surface: surface)
    }

    /// Throws a copy's pixels away once no layer shows it, `delay` from now (off the main thread).
    ///
    /// The window server keeps the last frame of a window that's ordered out until the window is next shown, and an
    /// IOSurface counts in the footprint of the process that made it: without this, each display's last frozen frame
    /// (22.5 MB for a full one) stayed in Margin's footprint between captures. Discarded straight after the layers let
    /// go, a few in 16 stayed anyway (the window server still had it in use); 0.3 s later none did.
    public static func discard(_ surface: IOSurfaceRef, after delay: Double = 0.5) {
        let box = Box(surface: surface)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            IOSurfaceSetPurgeable(box.surface, purgeableEmpty, nil)
        }
    }

    /// `kIOSurfacePurgeableEmpty` (IOSurfaceTypes.h), which Swift doesn't import: throw the contents away now.
    static let purgeableEmpty: UInt32 = 2

    /// Hands a surface to another queue (IOSurface's own calls are thread-safe).
    private struct Box: @unchecked Sendable {
        let surface: IOSurfaceRef
    }
}
