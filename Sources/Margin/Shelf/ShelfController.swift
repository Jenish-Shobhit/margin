import AppKit
import MarginKit

/// STUB — replaced by the Shelf agent. Keep the class name and `init(store:)`.
@MainActor
final class ShelfController: ShelfControlling {
    var onCopied: ((UUID, Int) -> Void)?
    var onRemoved: (([UUID]) -> Void)?
    private(set) var isTucked = false
    private(set) var markedItemID: UUID?
    var itemIDs: [UUID] { store.items.map(\.id) }

    private let store: ShelfStore

    init(store: ShelfStore) {
        self.store = store
    }

    func restore() { store.load() }
    func add(_ item: ShelfItem, thumbnail: CGImage, flyInFrom sourceRect: CGRect, displayID: CGDirectDisplayID) { store.append(item) }
    func toggleTucked() { isTucked.toggle() }
    func setClipboardMark(_ itemID: UUID?) { markedItemID = itemID }
}
