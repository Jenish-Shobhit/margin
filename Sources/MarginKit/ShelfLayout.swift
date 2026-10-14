import CoreGraphics

/// Shelf geometry. Shelf-local points, origin bottom-left of the shelf panel. Newest card at the bottom.
public enum ShelfLayout {
    public static let cardWidth: CGFloat = 176
    public static let minCardHeight: CGFloat = 64
    public static let maxCardHeight: CGFloat = 176
    public static let gap: CGFloat = 10
    public static let edgeInset: CGFloat = 14
    public static let maxVisible = 4
    public static let pileHeight: CGFloat = 30
    public static let panelWidth: CGFloat = cardWidth + edgeInset * 2

    /// Card height follows the shot's aspect ratio, clamped.
    public static func cardHeight(forPixelSize size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 110 }
        return min(max(cardWidth * size.height / size.width, minCardHeight), maxCardHeight)
    }

    public struct Result: Equatable, Sendable {
        /// Visible card frames keyed by item index (0 = oldest).
        public var cardFrames: [Int: CGRect]
        /// Older items folded into the pile (0 = no pile).
        public var pileCount: Int
        public var pileFrame: CGRect?
        /// Height needed for everything, including insets (0 when empty).
        public var contentHeight: CGFloat
    }

    /// `heights` is ordered oldest → newest. Shows up to `maxVisible` newest cards that fit in
    /// `availableHeight` (at least one when non-empty); the rest go into the pile.
    public static func layout(heights: [CGFloat], availableHeight: CGFloat) -> Result {
        let n = heights.count
        guard n > 0 else { return Result(cardFrames: [:], pileCount: 0, pileFrame: nil, contentHeight: 0) }

        func needed(_ k: Int) -> CGFloat {
            let cards = heights.suffix(k).reduce(0, +) + gap * CGFloat(k - 1)
            let pile = k < n ? gap + pileHeight : 0
            return edgeInset * 2 + cards + pile
        }
        var k = min(n, maxVisible)
        while k > 1, needed(k) > availableHeight { k -= 1 }

        var frames: [Int: CGRect] = [:]
        var y = edgeInset
        for j in 0..<k {
            let i = n - 1 - j
            frames[i] = CGRect(x: edgeInset, y: y, width: cardWidth, height: heights[i])
            y += heights[i] + gap
        }
        let pileCount = n - k
        let pileFrame = pileCount > 0 ? CGRect(x: edgeInset, y: y, width: cardWidth, height: pileHeight) : nil
        let contentHeight = pileCount > 0 ? y + pileHeight + edgeInset : y - gap + edgeInset
        return Result(cardFrames: frames, pileCount: pileCount, pileFrame: pileFrame, contentHeight: contentHeight)
    }
}
