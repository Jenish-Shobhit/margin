import AppKit
import ImageIO
import MarginKit

/// Card thumbnails, downsampled to 2× the card size. Work happens off the main thread.
enum ShelfThumbnails {
    /// Pixel size that aspect-fills a 2× card for an image of `pixelSize`.
    static func targetPixels(for pixelSize: CGSize) -> CGSize {
        let cardH = ShelfLayout.cardHeight(forPixelSize: pixelSize)
        return CGSize(width: ShelfLayout.cardWidth * 2, height: cardH * 2)
    }

    /// Scale (≤ 1) that makes `size` cover `target`.
    static func fillScale(_ size: CGSize, _ target: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        return min(1, max(target.width / size.width, target.height / size.height))
    }

    /// ImageIO thumbnail of a file on disk (restored items).
    nonisolated static func load(url: URL, pixelSize: CGSize, priority: TaskPriority = .userInitiated) async -> ShelfImageBox? {
        await Task.detached(priority: priority) { () -> ShelfImageBox? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            var size = pixelSize
            if size.width <= 0 || size.height <= 0,
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
                size = CGSize(width: w, height: h)
            }
            let s = fillScale(size, targetPixels(for: size))
            let maxPixel = Int(ceil(max(size.width, size.height) * s))
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 1),
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return ShelfImageBox(image: thumb)
        }.value
    }

    /// Downsample the in-memory capture (new items).
    nonisolated static func downsample(_ box: ShelfImageBox) async -> ShelfImageBox {
        await Task.detached(priority: .userInitiated) { () -> ShelfImageBox in
            let image = box.image
            let size = CGSize(width: image.width, height: image.height)
            let s = fillScale(size, targetPixels(for: size))
            guard s < 1 else { return box }
            let w = max(Int((size.width * s).rounded()), 1), h = max(Int((size.height * s).rounded()), 1)
            let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return box }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let out = ctx.makeImage() else { return box }
            return ShelfImageBox(image: out)
        }.value
    }
}
