import CoreGraphics
import MarginKit
import Testing

@Suite struct ShelfLayoutTests {
    typealias L = ShelfLayout

    @Test func constants() {
        #expect(L.cardWidth == 176 && L.gap == 10 && L.edgeInset == 14 && L.maxVisible == 4)
        #expect(L.panelWidth == CGFloat(176 + 28))
    }

    @Test(arguments: [
        (CGSize(width: 1920, height: 1080), 99.0),  // 16:9 follows the aspect ratio
        (CGSize(width: 3024, height: 1964), 176.0 * 1964 / 3024),
        (CGSize(width: 4000, height: 100), 64.0),   // very wide → min
        (CGSize(width: 100, height: 4000), 176.0),  // very tall → max
        (CGSize(width: 500, height: 500), 176.0),   // square → max
        (CGSize(width: 0, height: 0), 110.0),       // degenerate → fallback
        (CGSize(width: 100, height: 0), 110.0),
    ])
    func cardHeightClamping(size: CGSize, expected: CGFloat) {
        #expect(abs(L.cardHeight(forPixelSize: size) - expected) < 0.0001)
    }

    @Test func cardHeightAlwaysInRange() {
        for w in stride(from: 1, through: 5000, by: 397) {
            for h in stride(from: 1, through: 5000, by: 409) {
                let c = L.cardHeight(forPixelSize: CGSize(width: w, height: h))
                #expect(c >= L.minCardHeight && c <= L.maxCardHeight)
            }
        }
    }

    @Test func empty() {
        let r = L.layout(heights: [], availableHeight: 800)
        #expect(r.cardFrames.isEmpty)
        #expect(r.pileCount == 0 && r.pileFrame == nil && r.contentHeight == 0)
    }

    @Test func oneItem() {
        let r = L.layout(heights: [99], availableHeight: 800)
        #expect(r.cardFrames == [0: CGRect(x: 14, y: 14, width: 176, height: 99)])
        #expect(r.pileCount == 0 && r.pileFrame == nil)
        #expect(r.contentHeight == CGFloat(14 + 99 + 14))
    }

    @Test func fourItemsNewestAtBottom() {
        let r = L.layout(heights: [100, 80, 120, 64], availableHeight: 1000)
        #expect(r.cardFrames.count == 4)
        #expect(r.cardFrames[3] == CGRect(x: 14, y: 14, width: 176, height: 64))   // newest
        #expect(r.cardFrames[2] == CGRect(x: 14, y: 88, width: 176, height: 120))
        #expect(r.cardFrames[1] == CGRect(x: 14, y: 218, width: 176, height: 80))
        #expect(r.cardFrames[0] == CGRect(x: 14, y: 308, width: 176, height: 100)) // oldest
        #expect(r.pileCount == 0 && r.pileFrame == nil)
        #expect(r.contentHeight == CGFloat(308 + 100 + 14))
    }

    @Test func fiveItemsMakeAPileOfOne() {
        let r = L.layout(heights: Array(repeating: 100, count: 5), availableHeight: 1000)
        #expect(Set(r.cardFrames.keys) == [1, 2, 3, 4])
        #expect(r.pileCount == 1)
        #expect(r.pileFrame == CGRect(x: 14, y: 14 + 4 * 110, width: 176, height: L.pileHeight))
        #expect(r.contentHeight == CGFloat(14 + 4 * 110) + L.pileHeight + 14)
    }

    @Test func fiftyItems() {
        let r = L.layout(heights: Array(repeating: 99, count: 50), availableHeight: 1200)
        #expect(Set(r.cardFrames.keys) == [46, 47, 48, 49])
        #expect(r.pileCount == 46)
        #expect(r.pileFrame?.minY == CGFloat(14 + 4 * (99 + 10)))
        #expect(r.contentHeight <= 1200)
    }

    @Test func smallScreenShowsFewer() {
        // needed(4) = 498, needed(3) = 388, needed(2) = 278.
        let r = L.layout(heights: Array(repeating: 100, count: 5), availableHeight: 300)
        #expect(Set(r.cardFrames.keys) == [3, 4])
        #expect(r.pileCount == 3)
        #expect(r.pileFrame == CGRect(x: 14, y: 234, width: 176, height: L.pileHeight))
        #expect(r.contentHeight == 278)
        #expect(r.contentHeight <= 300)
    }

    @Test func fitWithoutPileVersusWithPile() {
        // Four 100-pt cards need exactly 458 without a pile.
        #expect(L.layout(heights: Array(repeating: 100, count: 4), availableHeight: 458).cardFrames.count == 4)
        // One pt less: three cards plus a pile (28 + 320 + 40 = 388).
        let r = L.layout(heights: Array(repeating: 100, count: 4), availableHeight: 457)
        #expect(r.cardFrames.count == 3 && r.pileCount == 1)
    }

    @Test func alwaysAtLeastOneCard() {
        let r = L.layout(heights: [176, 176, 176], availableHeight: 50)
        #expect(Set(r.cardFrames.keys) == [2])
        #expect(r.pileCount == 2)
        #expect(r.contentHeight > 50) // overflows rather than showing nothing
    }

    @Test func visibleCountNeverExceedsMax() {
        for n in 0...12 {
            let r = L.layout(heights: Array(repeating: 64, count: n), availableHeight: 10_000)
            #expect(r.cardFrames.count == min(n, 4))
            #expect(r.pileCount == max(n - 4, 0))
            #expect(r.cardFrames.count + r.pileCount == n)
        }
    }

    @Test func contentHeightCoversEverything() {
        let heights: [CGFloat] = [70, 176, 64, 120, 99, 150]
        let r = L.layout(heights: heights, availableHeight: 2000)
        let top = max(r.cardFrames.values.map(\.maxY).max() ?? 0, r.pileFrame?.maxY ?? 0)
        #expect(r.contentHeight == top + L.edgeInset)
    }

    @Test func cardsDoNotOverlapAndKeepTheGap() {
        let r = L.layout(heights: [70, 176, 64, 120, 99], availableHeight: 2000)
        let frames = r.cardFrames.sorted { $0.key > $1.key }.map(\.value) // newest (bottom) first
        for (a, b) in zip(frames, frames.dropFirst()) {
            #expect(b.minY - a.maxY == L.gap)
        }
        if let pile = r.pileFrame, let top = frames.last { #expect(pile.minY - top.maxY == L.gap) }
    }
}
