import AppKit
import MarginKit

/// Card thumbnails on demand (`ShelfThumbnailPlan`): only the cards that can be seen, or soon could be, hold a decoded
/// image. Every card exists from launch, but a card deep in the pile has none until it comes forward (a removal, ⌘Z,
/// a taller screen), and gives its image back when it folds deep into the pile again.
extension ShelfController {
    /// At most this many thumbnails decode at once, so a launch leaves the other cores to ScreenCaptureKit's prewarm.
    static let thumbnailLoadLimit = 2

    /// The items whose thumbnails stay decoded, by priority: the visible cards (newest first), the pile's fan, the
    /// next few in the pile, then any selected card (dragging a selected card drags the selection, stacked).
    var thumbnailItems: [ShelfItem] {
        let items = store.items
        var kept = ShelfThumbnailPlan.keptIndices(count: items.count, pileCount: layout.pileCount).map { items[$0] }
        if !selection.isEmpty {
            let ids = Set(kept.map(\.id))
            kept += items.filter { selection.contains($0.id) && !ids.contains($0.id) }
        }
        return kept
    }

    /// After every layout: cards that folded deep into the pile give their images back, and the ones that came
    /// forward decode theirs.
    func updateThumbnails() {
        let kept = Set(thumbnailItems.map(\.id))
        for (id, card) in cards where card.thumbnail != nil && !kept.contains(id) {
            card.setThumbnail(nil)
        }
        loadThumbnails()
    }

    /// Starts decoding the kept cards that have no image yet, a few at a time, most important first.
    func loadThumbnails() {
        let items = thumbnailItems
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
        // Only onto a card that's still kept (it may have folded deep into the pile meanwhile) and has no image.
        if let box, let card = cards[load.id], card.thumbnail == nil, thumbnailItems.contains(where: { $0.id == load.id }) {
            card.setThumbnail(box.image)
            if fanIDs.contains(load.id) { refreshFan(force: true) }
        }
        loadThumbnails()
    }
}
