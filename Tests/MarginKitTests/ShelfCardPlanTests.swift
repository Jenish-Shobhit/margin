import MarginKit
import Testing

@Suite struct ShelfCardPlanTests {
    @Test func emptyShelfKeepsNothing() {
        #expect(ShelfCardPlan.keptIndices(count: 0, pileCount: 0).isEmpty)
    }

    @Test func withoutAPileEveryCardIsKeptNewestFirst() {
        #expect(ShelfCardPlan.keptIndices(count: 3, pileCount: 0) == [2, 1, 0])
    }

    @Test func aBigShelfKeepsTheVisibleCardsTheFanAndTheNextFew() {
        // 200 cards, 6 visible: those, the fan's 3 and 6 more, whatever the shelf's size.
        let kept = ShelfCardPlan.keptIndices(count: 200, pileCount: 194)
        #expect(kept == Array((185...199).reversed()))
        #expect(kept.count == 6 + ShelfCardPlan.fanCount + ShelfCardPlan.aheadCount)
        #expect(kept.first == 199)
        #expect(ShelfCardPlan.keptIndices(count: 2000, pileCount: 1994).count == kept.count)
    }

    @Test func aShortScreenShowsFewerCardsAndKeepsAsManyBeyondThem() {
        // One visible card (a short display): it, then the pile's newest 9.
        #expect(ShelfCardPlan.keptIndices(count: 50, pileCount: 49) == Array((40...49).reversed()))
    }

    @Test func aSmallPileIsKeptWhole() {
        #expect(ShelfCardPlan.keptIndices(count: 6, pileCount: 2) == [5, 4, 3, 2, 1, 0])
    }

    @Test func outOfRangePileCountsAreClamped() {
        #expect(ShelfCardPlan.keptIndices(count: 3, pileCount: -1) == [2, 1, 0])
        #expect(ShelfCardPlan.keptIndices(count: 3, pileCount: 9) == [2, 1, 0])
    }
}

@Suite struct ThumbnailLoadsTests {
    typealias Load = ThumbnailLoads<Int>.Load

    func loads(_ ids: [Int]) -> [Load] { ids.map { Load(id: $0, path: "/s/\($0).png") } }

    @Test func startsAtMostTheLimitInPriorityOrder() {
        var q = ThumbnailLoads<Int>(limit: 2)
        #expect(q.isIdle)
        #expect(q.start(loads([9, 8, 7, 6]), hasImage: { _ in false }) == loads([9, 8]))
        #expect(!q.isIdle)
        // Full: nothing more until one ends.
        #expect(q.start(loads([9, 8, 7, 6]), hasImage: { _ in false }).isEmpty)
        q.finish(Load(id: 9, path: "/s/9.png"), succeeded: true)
        #expect(q.start(loads([9, 8, 7, 6]), hasImage: { $0 == 9 }) == loads([7]))
        #expect(q.inFlight == [8: "/s/8.png", 7: "/s/7.png"])
    }

    @Test func skipsItemsThatHaveAnImage() {
        var q = ThumbnailLoads<Int>(limit: 3)
        #expect(q.start(loads([1, 2, 3]), hasImage: { $0 == 2 }) == loads([1, 3]))
    }

    @Test func aFailedFileIsNotTriedAgainUntilItMovesOrIsRetried() {
        var q = ThumbnailLoads<Int>(limit: 2)
        let first = q.start(loads([1]), hasImage: { _ in false })
        q.finish(first[0], succeeded: false)
        #expect(q.isIdle)
        #expect(q.start(loads([1]), hasImage: { _ in false }).isEmpty)
        // Found elsewhere (moved in Finder): tried at the new path.
        let moved = Load(id: 1, path: "/elsewhere/1.png")
        #expect(q.start([moved], hasImage: { _ in false }) == [moved])
        q.finish(moved, succeeded: false)
        // Readable now, maybe: `retry` tries the same path again.
        q.retry(1)
        #expect(q.start([moved], hasImage: { _ in false }) == [moved])
    }

    @Test func aLoadFromAnOldPathEndingDoesNotEndTheNewOne() {
        var q = ThumbnailLoads<Int>(limit: 2)
        let old = q.start(loads([1]), hasImage: { _ in false })[0]
        // While it loads the item can't start again, even at a new path.
        #expect(q.start([Load(id: 1, path: "/new.png")], hasImage: { _ in false }).isEmpty)
        q.finish(old, succeeded: true)
        #expect(q.isIdle)
    }

    @Test func forgettingAnItemClearsItsFailure() {
        var q = ThumbnailLoads<Int>(limit: 1)
        let l = q.start(loads([4]), hasImage: { _ in false })[0]
        q.finish(l, succeeded: false)
        q.forget(4)
        #expect(q.start(loads([4]), hasImage: { _ in false }) == loads([4]))
    }

    @Test func theLimitIsAtLeastOne() {
        var q = ThumbnailLoads<Int>(limit: 0)
        #expect(q.limit == 1)
        #expect(q.start(loads([1, 2]), hasImage: { _ in false }) == loads([1]))
    }
}
