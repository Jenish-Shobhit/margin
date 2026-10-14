import CoreGraphics
import MarginKit
import Testing

@Suite struct GeometryFlipTests {
    @Test func flipsAgainstPrimaryHeight() {
        let r = CGRect(x: 10, y: 20, width: 100, height: 50)
        #expect(Geometry.flip(r, primaryHeight: 1000) == CGRect(x: 10, y: 930, width: 100, height: 50))
    }

    @Test func flipIsItsOwnInverse() {
        for r in [CGRect(x: 10, y: 20, width: 100, height: 50), CGRect(x: -1920, y: -300, width: 640, height: 480),
                  CGRect(x: 0, y: 1100, width: 1, height: 1)] {
            #expect(Geometry.flip(Geometry.flip(r, primaryHeight: 982), primaryHeight: 982) == r)
        }
    }

    @Test func primaryScreenItselfMapsToOrigin() {
        let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(Geometry.flip(primary, primaryHeight: 982) == primary)
    }

    @Test func displayAbovePrimaryHasNegativeCGOrigin() {
        // A 1920×1080 display stacked on top of a 1512×982 primary.
        let above = CGRect(x: 0, y: 982, width: 1920, height: 1080)
        #expect(Geometry.flip(above, primaryHeight: 982) == CGRect(x: 0, y: -1080, width: 1920, height: 1080))
    }

    @Test func displayBelowPrimaryHasCGOriginBelowIt() {
        let below = CGRect(x: 200, y: -1080, width: 1920, height: 1080)
        #expect(Geometry.flip(below, primaryHeight: 982) == CGRect(x: 200, y: 982, width: 1920, height: 1080))
    }

    @Test func leftDisplayKeepsNegativeX() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        #expect(Geometry.flip(left, primaryHeight: 982) == CGRect(x: -1920, y: -98, width: 1920, height: 1080))
    }
}

@Suite struct GeometryPixelRectTests {
    @Test func scaleOne() {
        let r = Geometry.pixelRect(for: CGRect(x: 100, y: 200, width: 300, height: 150),
                                   displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 1,
                                   imageSize: CGSize(width: 1440, height: 900))
        #expect(r == CGRect(x: 100, y: 550, width: 300, height: 150))
    }

    @Test func scaleTwo() {
        let r = Geometry.pixelRect(for: CGRect(x: 100, y: 200, width: 300, height: 150),
                                   displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2,
                                   imageSize: CGSize(width: 2880, height: 1800))
        #expect(r == CGRect(x: 200, y: 1100, width: 600, height: 300))
    }

    @Test func secondaryLeftOfPrimary() {
        let r = Geometry.pixelRect(for: CGRect(x: -1820, y: 100, width: 200, height: 100),
                                   displayFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), scale: 1,
                                   imageSize: CGSize(width: 1920, height: 1080))
        #expect(r == CGRect(x: 100, y: 880, width: 200, height: 100))
    }

    @Test func secondaryRightOfPrimaryAtScaleTwo() {
        let r = Geometry.pixelRect(for: CGRect(x: 1540, y: 140, width: 100, height: 50),
                                   displayFrame: CGRect(x: 1440, y: 0, width: 2560, height: 1440), scale: 2,
                                   imageSize: CGSize(width: 5120, height: 2880))
        #expect(r == CGRect(x: 200, y: 2500, width: 200, height: 100))
    }

    @Test func secondaryAbovePrimary() {
        let r = Geometry.pixelRect(for: CGRect(x: 10, y: 1000, width: 50, height: 50),
                                   displayFrame: CGRect(x: 0, y: 900, width: 1920, height: 1080), scale: 1,
                                   imageSize: CGSize(width: 1920, height: 1080))
        #expect(r == CGRect(x: 10, y: 930, width: 50, height: 50))
    }

    @Test func secondaryBelowPrimary() {
        let r = Geometry.pixelRect(for: CGRect(x: 300, y: -1000, width: 100, height: 100),
                                   displayFrame: CGRect(x: 200, y: -1080, width: 1920, height: 1080), scale: 1,
                                   imageSize: CGSize(width: 1920, height: 1080))
        #expect(r == CGRect(x: 100, y: 900, width: 100, height: 100))
    }

    @Test func secondaryBelowAndLeftAtScaleTwo() {
        let r = Geometry.pixelRect(for: CGRect(x: -1000, y: -500, width: 10, height: 20),
                                   displayFrame: CGRect(x: -1512, y: -982, width: 1512, height: 982), scale: 2,
                                   imageSize: CGSize(width: 3024, height: 1964))
        // x: (−1000 + 1512) × 2 = 1024; top: (0 − (−480)) × 2 = 960.
        #expect(r == CGRect(x: 1024, y: 960, width: 20, height: 40))
    }

    @Test func edgesRoundToNearestPixel() {
        let r = Geometry.pixelRect(for: CGRect(x: 10.3, y: 20.2, width: 50.4, height: 30.1),
                                   displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2,
                                   imageSize: CGSize(width: 200, height: 200))
        // left 20.6→21, right 121.4→121, top 99.4→99, bottom 159.6→160.
        #expect(r == CGRect(x: 21, y: 99, width: 100, height: 61))
        #expect(r.minX == r.minX.rounded() && r.width == r.width.rounded() && r.height == r.height.rounded())
    }

    @Test func halfPixelsRoundAwayFromZero() {
        let r = Geometry.pixelRect(for: CGRect(x: 10.5, y: 0, width: 10, height: 10),
                                   displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1,
                                   imageSize: CGSize(width: 100, height: 100))
        #expect(r == CGRect(x: 11, y: 90, width: 10, height: 10))
    }

    @Test func clampsToImage() {
        let r = Geometry.pixelRect(for: CGRect(x: -50, y: -50, width: 200, height: 200),
                                   displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2,
                                   imageSize: CGSize(width: 200, height: 200))
        #expect(r == CGRect(x: 0, y: 0, width: 200, height: 200))
    }

    @Test func clampsPartialOverlap() {
        let r = Geometry.pixelRect(for: CGRect(x: 90, y: 90, width: 50, height: 50),
                                   displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1,
                                   imageSize: CGSize(width: 100, height: 100))
        #expect(r == CGRect(x: 90, y: 0, width: 10, height: 10))
    }

    @Test func noOverlapIsZero() {
        let r = Geometry.pixelRect(for: CGRect(x: 500, y: 500, width: 10, height: 10),
                                   displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2,
                                   imageSize: CGSize(width: 200, height: 200))
        #expect(r == .zero)
        #expect(r.isEmpty)
    }

    @Test func negativeSizeRectIsStandardized() {
        let r = Geometry.pixelRect(for: CGRect(x: 60, y: 60, width: -50, height: -50),
                                   displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1,
                                   imageSize: CGSize(width: 100, height: 100))
        #expect(r == CGRect(x: 10, y: 40, width: 50, height: 50))
    }
}

@Suite struct GeometrySnapTests {
    @Test func snapValueWithinThreshold() {
        #expect(Geometry.snapValue(103, to: [100, 200]) == 100)
        #expect(Geometry.snapValue(108, to: [100]) == 100) // exactly at the threshold
        #expect(Geometry.snapValue(108.5, to: [100]) == nil)
        #expect(Geometry.snapValue(50, to: []) == nil)
    }

    @Test func snapValuePicksNearest() {
        #expect(Geometry.snapValue(104, to: [100, 106]) == 106)
        #expect(Geometry.snapValue(103, to: [106, 100, 102]) == 102)
    }

    @Test func snapValueTieGoesToFirst() {
        #expect(Geometry.snapValue(105, to: [100, 110]) == 100)
        #expect(Geometry.snapValue(105, to: [110, 100]) == 110)
    }

    @Test func snapValueCustomThreshold() {
        #expect(Geometry.snapValue(103, to: [100], threshold: 2) == nil)
        #expect(Geometry.snapValue(103, to: [100], threshold: 3) == 100)
    }

    @Test func snapsToWindowCorner() {
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        let s = Geometry.snap(CGPoint(x: 495, y: 404), to: [window])
        #expect(s.point == CGPoint(x: 500, y: 400))
        #expect(s.snappedX && s.snappedY)
    }

    @Test func snapsOneAxisOnly() {
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        let s = Geometry.snap(CGPoint(x: 103, y: 250), to: [window])
        #expect(s.point == CGPoint(x: 100, y: 250))
        #expect(s.snappedX && !s.snappedY)
    }

    @Test func farAwayWindowDoesNotPull() {
        // Level with x = 100 but 500 pt above the window: no snap.
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        let s = Geometry.snap(CGPoint(x: 103, y: 900), to: [window])
        #expect(s.point == CGPoint(x: 103, y: 900))
        #expect(!s.snappedX && !s.snappedY)
    }

    @Test func justOutsideTheSpanStillSnaps() {
        // 6 pt above the top edge (within threshold) and 3 pt from the left edge.
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        let s = Geometry.snap(CGPoint(x: 103, y: 406), to: [window])
        #expect(s.point == CGPoint(x: 100, y: 400))
    }

    @Test func nearestOfSeveralWindows() {
        let a = CGRect(x: 0, y: 0, width: 300, height: 300)
        let b = CGRect(x: 305, y: 0, width: 300, height: 300)
        let s = Geometry.snap(CGPoint(x: 303, y: 150), to: [a, b])
        #expect(s.point.x == 305)
        #expect(s.snappedX && !s.snappedY)
    }

    @Test func noWindowsNoSnap() {
        let s = Geometry.snap(CGPoint(x: 1, y: 2), to: [])
        #expect(s.point == CGPoint(x: 1, y: 2))
        #expect(!s.snappedX && !s.snappedY)
    }
}
