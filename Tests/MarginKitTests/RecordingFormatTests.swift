import CoreGraphics
import Foundation
import MarginKit
import Testing

@Suite struct RecordingFormatTests {
    // MARK: Frame rate

    @Test(arguments: [(60.0, 60), (120.0, 60), (59.94, 60), (30.0, 30), (50.0, 50), (24.0, 24), (0.0, 60), (-1.0, 60)])
    func frameRateFollowsTheDisplayUpTo60(refresh: Double, fps: Int) {
        #expect(RecordingFormat.frameRate(refreshRate: refresh) == fps)
    }

    @Test func frameRateOfNonsenseIs60() {
        #expect(RecordingFormat.frameRate(refreshRate: .nan) == 60)
        #expect(RecordingFormat.frameRate(refreshRate: .infinity) == 60)
    }

    // MARK: Size

    @Test func aRetinaDisplayKeepsItsNativeSize() {
        #expect(RecordingFormat.videoSize(forPixels: CGSize(width: 2940, height: 1912), fps: 60) == CGSize(width: 2940, height: 1912))
        #expect(RecordingFormat.videoSize(forPixels: CGSize(width: 3456, height: 2234), fps: 60) == CGSize(width: 3456, height: 2234))
        #expect(RecordingFormat.videoSize(forPixels: CGSize(width: 3840, height: 2160), fps: 60) == CGSize(width: 3840, height: 2160))
    }

    @Test func sidesAreEven() {
        #expect(RecordingFormat.videoSize(forPixels: CGSize(width: 801, height: 601), fps: 60) == CGSize(width: 800, height: 600))
        #expect(RecordingFormat.videoSize(forPixels: CGSize(width: 1201.6, height: 799.5), fps: 60) == CGSize(width: 1200, height: 798))
        #expect(RecordingFormat.videoSize(forPixels: CGSize(width: 1, height: 0), fps: 60) == CGSize(width: 2, height: 2))
    }

    /// 16 × 16 blocks, rounded up, as H.264 counts them.
    func macroblocks(_ s: CGSize) -> Int { Int((s.width / 16).rounded(.up) * (s.height / 16).rounded(.up)) }

    @Test(arguments: [CGSize(width: 5120, height: 2880), CGSize(width: 6016, height: 3384), CGSize(width: 5120, height: 1440),
                      CGSize(width: 4096, height: 2304)])
    func biggerDisplaysAreScaledIntoH264sLimits(pixels: CGSize) {
        let size = RecordingFormat.videoSize(forPixels: pixels, fps: 60)
        #expect(size.width <= 4096 && size.height <= 4096)
        #expect(macroblocks(size) <= 36_864)
        #expect(macroblocks(size) * 60 <= 2_073_600)
        #expect(Int(size.width) % 2 == 0 && Int(size.height) % 2 == 0)
        // The aspect ratio stays (within the rounding to even pixels), and nothing is shrunk more than it needs.
        #expect(abs(size.width / size.height - pixels.width / pixels.height) < 0.01)
        #expect(macroblocks(size) * 60 > 2_073_600 * 9 / 10 || size.width == 4096)
    }

    @Test func aSlowerDisplayMayKeepMorePixels() {
        // At 30 fps the per-second limit allows a whole 36,864-block frame.
        let size = RecordingFormat.videoSize(forPixels: CGSize(width: 4096, height: 2304), fps: 30)
        #expect(size == CGSize(width: 4096, height: 2304))
    }

    // MARK: Bit rate

    @Test func bitRateScalesWithPixelsAndFrames() {
        let full = RecordingFormat.bitRate(width: 2940, height: 1912, fps: 60)
        #expect(full == Int((2940.0 * 1912 * 60 * 0.075).rounded()))
        #expect((24_000_000...27_000_000).contains(full))
        // Half the frames, half the bits; a quarter of the pixels, a quarter.
        #expect(RecordingFormat.bitRate(width: 2940, height: 1912, fps: 30) == Int((Double(full) / 2).rounded()))
        #expect(RecordingFormat.bitRate(width: 1470, height: 956, fps: 60) == Int((Double(full) / 4).rounded()))
    }

    @Test func bitRateHasAFloorAndACeiling() {
        #expect(RecordingFormat.bitRate(width: 200, height: 100, fps: 60) == 2_000_000)
        #expect(RecordingFormat.bitRate(width: 0, height: 0, fps: 0) == 2_000_000)
        #expect(RecordingFormat.bitRate(width: 8192, height: 8192, fps: 60) == 100_000_000)
    }

    // MARK: Durations

    @Test(arguments: [
        (0.0, "0:00"), (0.99, "0:00"), (1, "0:01"), (12.7, "0:12"), (59.999, "0:59"), (60, "1:00"), (61, "1:01"),
        (605, "10:05"), (3599, "59:59"), (3600, "1:00:00"), (3723, "1:02:03"), (36_000, "10:00:00"),
    ])
    func durationsReadAsTheMenuBarClock(seconds: Double, text: String) {
        #expect(RecordingFormat.durationText(seconds) == text)
    }

    @Test func nonsenseDurationsReadAsZero() {
        #expect(RecordingFormat.durationText(-5) == "0:00")
        #expect(RecordingFormat.durationText(.nan) == "0:00")
        #expect(RecordingFormat.durationText(.infinity) == "0:00")
    }

    @Test func cardsRoundToTheNearestSecondAndShowAtLeastOne() {
        #expect(RecordingFormat.cardDurationText(12.48) == "0:12")
        #expect(RecordingFormat.cardDurationText(12.5) == "0:13")
        #expect(RecordingFormat.cardDurationText(0.3) == "0:01")
        #expect(RecordingFormat.cardDurationText(0) == "0:00")
        #expect(RecordingFormat.cardDurationText(-1) == "0:00")
        #expect(RecordingFormat.cardDurationText(59.6) == "1:00")
    }
}
