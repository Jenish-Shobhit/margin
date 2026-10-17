import CoreGraphics
import Foundation

/// The rules a screen recording is encoded by (spec §14.4): its frame rate, its size and bit rate as H.264, and how its
/// length reads on the shelf and in the menu bar.
public enum RecordingFormat {
    /// The fastest a recording goes.
    public static let maxFrameRate = 60

    /// Frames per second for a display refreshing at `refreshRate` Hz: its own rate, at most 60 (a 120 Hz ProMotion
    /// display records at 60). An unknown rate (0, as some displays report) means 60.
    public static func frameRate(refreshRate: Double) -> Int {
        guard refreshRate.isFinite, refreshRate >= 1 else { return maxFrameRate }
        return min(maxFrameRate, max(1, Int(refreshRate.rounded())))
    }

    /// H.264 level 5.2, the most Apple silicon's hardware encoder takes: at most 36,864 macroblocks (16 × 16 pixels) a
    /// frame and 2,073,600 a second, and 4,096 pixels on a side.
    static let maxMacroblocksPerFrame = 36_864
    static let maxMacroblocksPerSecond = 2_073_600
    static let maxSide = 4096

    /// The encoded size for `pixels` (the display's, the area's or the window's, at the display's native scale) at `fps`.
    /// The same size wherever H.264 allows it, which covers any display up to 4K at 60 fps (a 2940 × 1912 Retina display
    /// is 22,080 macroblocks); bigger ones (5K, 6K) are scaled down to fit, keeping the aspect ratio. Sides are even
    /// (4:2:0 halves the colour planes), at least 2.
    public static func videoSize(forPixels pixels: CGSize, fps: Int) -> CGSize {
        var w = max(2, pixels.width.rounded(.down)), h = max(2, pixels.height.rounded(.down))
        let perFrame = Double(min(maxMacroblocksPerFrame, maxMacroblocksPerSecond / max(1, fps)))
        var scale = min(1, Double(maxSide) / Double(max(w, h)))
        let macroblocks = { (w: Double, h: Double) in (w / 16).rounded(.up) * (h / 16).rounded(.up) }
        // Shrink until it fits: the macroblock count rounds up, so the first guess can be a little over.
        while macroblocks(Double(w) * scale, Double(h) * scale) > perFrame {
            scale = min(scale * 0.995, scale * (perFrame / macroblocks(Double(w) * scale, Double(h) * scale)).squareRoot())
        }
        w = (w * scale).rounded(.down)
        h = (h * scale).rounded(.down)
        return CGSize(width: max(2, w - w.truncatingRemainder(dividingBy: 2)),
                      height: max(2, h - h.truncatingRemainder(dividingBy: 2)))
    }

    /// Bits per pixel per frame: enough for UI text to stay sharp in H.264 (fine type is what blurs first), and since
    /// ScreenCaptureKit sends a frame only when something on screen changed, a still screen costs far less.
    static let bitsPerPixel = 0.075
    /// A small area still gets enough for its text; a huge one stays a size a disk and an upload can take.
    static let bitRateRange = 2_000_000...100_000_000

    /// The target bit rate (bits per second) for `width` × `height` at `fps`: scaled to pixels × frames, so a full
    /// 2940 × 1912 display at 60 fps gets about 25 Mbit/s and a 1200 × 800 area at 60 about 4.3.
    public static func bitRate(width: Int, height: Int, fps: Int) -> Int {
        let bits = Double(max(0, width)) * Double(max(0, height)) * Double(max(1, fps)) * bitsPerPixel
        return min(bitRateRange.upperBound, max(bitRateRange.lowerBound, Int(bits.rounded())))
    }

    /// A length as the shelf and the menu bar show it: `0:12`, `12:05`, `1:02:03`. Whole seconds, rounded down (the
    /// menu bar's clock ticks over when a second is full); nothing negative.
    public static func durationText(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let h = total / 3600, m = (total / 60) % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// The length a recording's card shows: to the nearest second, and at least `0:01` for anything recorded at all.
    public static func cardDurationText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return durationText(0) }
        return durationText(max(1, seconds.rounded()))
    }
}
