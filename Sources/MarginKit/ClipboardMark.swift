import AppKit

/// Which shelf item is on the clipboard (the ⌘V mark). Pure bookkeeping around `NSPasteboard.changeCount`.
public struct ClipboardMark: Equatable, Sendable {
    public private(set) var itemID: UUID?
    public private(set) var changeCount: Int = -1

    public init() {}

    /// Call right after Margin writes an item's image to the pasteboard.
    public mutating func didWrite(itemID: UUID, changeCount: Int) {
        self.itemID = itemID
        self.changeCount = changeCount
    }

    /// Call about once a second with the pasteboard's current changeCount.
    /// Returns true when the mark was just cleared because something else was copied.
    public mutating func observe(changeCount current: Int) -> Bool {
        guard itemID != nil, current != changeCount else { return false }
        itemID = nil
        return true
    }

    /// The marked item left the shelf: the mark goes with it.
    public mutating func itemRemoved(_ id: UUID) {
        if itemID == id { itemID = nil }
    }

    public mutating func clear() {
        itemID = nil
    }
}

/// Puts screenshot images on the pasteboard the way macOS does.
///
/// Checked on macOS 27.0.1: `screencapture -c` leaves exactly one pasteboard item with one type,
/// `public.png` (Display P3 profile, DPI 144 on Retina). No TIFF and no file URL, so Margin writes the
/// same: the PNG bytes it saved to disk, as `public.png`.
public enum ClipboardWriter {
    /// One pasteboard item per image. Returns the new changeCount.
    @MainActor @discardableResult
    public static func write(pngs: [Data], to pasteboard: NSPasteboard = .general) -> Int {
        pasteboard.clearContents()
        let items = pngs.map { data -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setData(data, forType: .png)
            return item
        }
        pasteboard.writeObjects(items)
        return pasteboard.changeCount
    }
}
