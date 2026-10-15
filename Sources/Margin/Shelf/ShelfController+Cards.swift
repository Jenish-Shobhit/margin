import AppKit
import MarginKit

/// Live cards (`ShelfCardPlan`): only the items that can be seen, or soon could be, have a card view and a decoded
/// thumbnail. The rest of the pile is items in the store: a card is made when its item comes forward (a removal, ⌘Z,
/// a taller screen) and goes when it folds deep into the pile again.
extension ShelfController {
    /// At most this many thumbnails decode at once, so a launch leaves the other cores to ScreenCaptureKit's prewarm.
    static let thumbnailLoadLimit = 2

    /// The items with live cards, by priority: the visible cards (newest first), the pile's fan, the next few in the
    /// pile, then any selected or last-clicked card (the keys and a drag of the selection act on them).
    var liveItems: [ShelfItem] {
        let items = store.items
        var live = ShelfCardPlan.keptIndices(count: items.count, pileCount: layout.pileCount).map { items[$0] }
        let extra = focusedID.map { selection.union([$0]) } ?? selection
        if !extra.isEmpty {
            let ids = Set(live.map(\.id))
            live += items.filter { extra.contains($0.id) && !ids.contains($0.id) }
        }
        return live
    }

    /// Before a layout places the cards: makes the cards that came forward, with the thumbnails at hand (an undo
    /// step's).
    func makeLiveCards(thumbnails: [UUID: CGImage]) {
        for item in liveItems where cards[item.id] == nil {
            let card = makeCard(item)
            if let thumb = thumbnails[item.id] { card.setThumbnail(thumb) }
        }
    }

    /// After a layout: cards that folded deep into the pile go (once they're out of sight), and the live ones without
    /// a thumbnail decode theirs.
    func dropHiddenCards(lookAgain: Bool = true) {
        let live = Set(liveItems.map(\.id))
        var folding = false
        for (id, card) in cards where !live.contains(id) && card.isInPile {
            guard card.isHidden else { folding = true; continue }
            card.removeFromSuperview()
            cards[id] = nil
        }
        // A card still folding away hides when its fold ends (`ShelfCardView.setInPile`): it goes then, not at
        // whatever layout comes next.
        if folding, lookAgain { ShelfMotion.after(0.45) { [weak self] in self?.dropHiddenCards(lookAgain: false) } }
        loadThumbnails()
    }

    /// Starts decoding the live cards that have no thumbnail yet, a few at a time, most important first.
    func loadThumbnails() {
        let items = liveItems
        let wanted = items.map { ThumbnailLoads.Load(id: $0.id, path: $0.path) }
        for load in thumbnailLoads.start(wanted, hasImage: { cards[$0]?.thumbnail != nil }) {
            let size = items.first { $0.id == load.id }?.pixelSize ?? .zero
            Task { [weak self] in
                let box = await ShelfThumbnails.load(url: URL(fileURLWithPath: load.path), pixelSize: size)
                self?.thumbnailLoaded(load, box)
            }
        }
        // The launch's thumbnails are in (or couldn't be read): for the timing log.
        if thumbnailLoads.isIdle, let clock = restoreThumbnailsClock {
            restoreThumbnailsClock = nil
            CaptureTimings.shared.record("shelfRestoreThumbnails", clock.ms)
        }
    }

    private func thumbnailLoaded(_ load: ThumbnailLoads<UUID>.Load, _ box: ShelfImageBox?) {
        thumbnailLoads.finish(load, succeeded: box != nil)
        // Only onto a card still live (it may have gone deep into the pile meanwhile) and still without an image.
        if let box, let card = cards[load.id], card.thumbnail == nil {
            card.setThumbnail(box.image)
            if fanIDs.contains(load.id) { refreshFan(force: true) }
        }
        loadThumbnails()
    }
}
