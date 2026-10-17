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

/// Puts screenshot images on the pasteboard: the image for apps that take images, the saved file for terminals. A screen
/// recording goes as its file alone.
///
/// Checked on macOS 27.0.1: `screencapture -c` leaves exactly one pasteboard item with one type,
/// `public.png` (Display P3 profile, DPI 144 on Retina). Margin writes the same PNG bytes it saved to disk as
/// `public.png`, and, since 0.0.2, the saved file as `public.file-url` on the same item. A terminal's ⌘V
/// pastes only text: Ghostty pastes a file URL as its shell-escaped path, so Claude Code gets the screenshot.
public enum ClipboardWriter {
    /// One pasteboard item per image: `public.png` first, then `public.file-url` when `fileURLs` has a file
    /// URL at the same index (nil, a missing entry or a non-file URL means PNG only). Returns the new changeCount.
    @MainActor @discardableResult
    public static func write(pngs: [Data], fileURLs: [URL?], to pasteboard: NSPasteboard = .general) -> Int {
        pasteboard.clearContents()
        let items = pngs.indices.map { i -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setData(pngs[i], forType: .png)
            if i < fileURLs.count, let url = fileURLs[i], url.isFileURL {
                item.setString(url.absoluteURL.absoluteString, forType: .fileURL)
            }
            return item
        }
        pasteboard.writeObjects(items)
        return pasteboard.changeCount
    }

    /// PNG only, one pasteboard item per image (what `screencapture -c` writes). Returns the new changeCount.
    @MainActor @discardableResult
    public static func write(pngs: [Data], to pasteboard: NSPasteboard = .general) -> Int {
        write(pngs: pngs, fileURLs: [], to: pasteboard)
    }

    /// One pasteboard item: a screenshot's PNG and its file, or a screen recording's file alone (a video isn't copied as
    /// data: apps that take a pasted video take its file).
    public struct Entry: Sendable, Equatable {
        public var png: Data?
        public var fileURL: URL?

        public init(png: Data? = nil, fileURL: URL?) {
            self.png = png
            self.fileURL = fileURL
        }
    }

    /// One pasteboard item per entry: `public.png` when it has one, then `public.file-url` when it has a file URL. For
    /// copies with a recording in them; screenshots alone go through `write(pngs:fileURLs:)`, which writes the same.
    /// Returns the new changeCount.
    @MainActor @discardableResult
    public static func write(_ entries: [Entry], to pasteboard: NSPasteboard = .general) -> Int {
        pasteboard.clearContents()
        let items = entries.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            if let png = entry.png { item.setData(png, forType: .png) }
            if let url = entry.fileURL, url.isFileURL { item.setString(url.absoluteURL.absoluteString, forType: .fileURL) }
            return item
        }
        pasteboard.writeObjects(items)
        return pasteboard.changeCount
    }

    /// Copy Path: the paths as plain text, one per line, and no image. Returns the new changeCount.
    @MainActor @discardableResult
    public static func write(paths: [String], to pasteboard: NSPasteboard = .general) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
        return pasteboard.changeCount
    }
}
