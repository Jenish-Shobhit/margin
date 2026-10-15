/// Which shelf cards are live (a view and a decoded thumbnail), and when to decode thumbnails. Pure bookkeeping: the
/// shelf makes the views and decodes, off the main thread.
///
/// A decoded thumbnail is about 0.3 MB, and decoding one from its PNG takes 15–200 ms of CPU, so a big shelf can't
/// decode every card at launch: 200 cards took 1.2–5.5 s of every core, held ScreenCaptureKit's prewarm back as long,
/// and kept 130–180 MB. A card's view costs too (about 0.05 MB and 0.08 ms each, 200 of them hidden in the pile). So
/// only what can be seen, or soon could be, is live: the visible cards, the pile's fan, and the next few pile shots a
/// removal would bring out. The rest of the pile is just items, and a card goes when it folds deeper into it.
public enum ShelfCardPlan {
    /// The newest pile shots the fan shows on hover (and a pile drag's stacked image).
    public static let fanCount = 3
    /// How many pile shots beyond the fan stay live: enough for a whole row of visible cards removed at once to be
    /// replaced by cards that already have their view and image, and slide out of the pile as before.
    public static let aheadCount = ShelfLayout.maxVisible

    /// Indices (0 = oldest) of the items whose cards are live, by priority: the visible cards newest first, then the
    /// fan, then the next `aheadCount` in the pile.
    public static func keptIndices(count: Int, pileCount: Int) -> [Int] {
        guard count > 0 else { return [] }
        let pile = min(max(pileCount, 0), count)
        let first = max(0, pile - fanCount - aheadCount)
        return Array((first..<count).reversed())
    }
}

/// Thumbnail loads in flight: at most `limit` at a time (so a launch never fills every core with decodes), in the
/// order asked for. A file that couldn't be read isn't tried again at the same path until `retry`.
public struct ThumbnailLoads<ID: Hashable & Sendable>: Sendable {
    public struct Load: Equatable, Sendable {
        public let id: ID
        public let path: String

        public init(id: ID, path: String) {
            self.id = id
            self.path = path
        }
    }

    public let limit: Int
    /// The path each loading item's thumbnail is coming from.
    public private(set) var inFlight: [ID: String] = [:]
    /// The path each item's last load failed at.
    private var failed: [ID: String] = [:]

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public var isIdle: Bool { inFlight.isEmpty }

    /// The loads to start now, which count as in flight from here on: the first of `wanted` (by priority, at each
    /// item's current path) that have no image (`hasImage`), aren't loading and didn't fail at that path, up to
    /// `limit` in flight.
    public mutating func start(_ wanted: [Load], hasImage: (ID) -> Bool) -> [Load] {
        var started: [Load] = []
        for load in wanted where inFlight.count < limit {
            guard inFlight[load.id] == nil, failed[load.id] != load.path, !hasImage(load.id) else { continue }
            inFlight[load.id] = load.path
            started.append(load)
        }
        return started
    }

    /// A load ended. One that failed isn't tried again at that path (a file moved since is: at its new path).
    public mutating func finish(_ load: Load, succeeded: Bool) {
        if inFlight[load.id] == load.path { inFlight[load.id] = nil }
        if succeeded { failed[load.id] = nil } else { failed[load.id] = load.path }
    }

    /// Try the item again even at the path it failed at (its file may be readable now).
    public mutating func retry(_ id: ID) {
        failed[id] = nil
    }

    /// The item left the shelf: forget its failure (a load in flight still ends with `finish`).
    public mutating func forget(_ id: ID) {
        failed[id] = nil
    }
}
