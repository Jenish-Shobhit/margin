import AppKit
import Carbon.HIToolbox

/// The keyboard when another app reads Margin's clipboard item, as a background app sees it without Input Monitoring
/// or Accessibility (`CGEventSource`, combined session state: the keyboard and posted events, such as automation that
/// pastes for the user). It sees the modifiers and how long ago some key went down, but not which key: checked on
/// macOS 27.0.1, `keyState` reports V only to the app in front, which a background Margin never is when another app
/// pastes. `v` is kept for the record.
public struct PasteKeys: Equatable, Sendable {
    public var command: Bool
    public var control: Bool
    /// Seconds since a key last went down (any key; ⌘ and ⌃ themselves don't count).
    public var sinceKeyDown: TimeInterval
    public var v: Bool

    public init(command: Bool = false, control: Bool = false, sinceKeyDown: TimeInterval = .infinity, v: Bool = false) {
        self.command = command
        self.control = control
        self.sinceKeyDown = sinceKeyDown
        self.v = v
    }

    public static var current: PasteKeys {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return PasteKeys(command: flags.contains(.maskCommand), control: flags.contains(.maskControl),
                         sinceKeyDown: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown),
                         v: CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_ANSI_V)))
    }

    /// The longest a paste's read comes after its key went down: an app reads the clipboard as it handles ⌘V, within a
    /// few milliseconds (Ghostty 2–10 ms, an AppKit menu's key equivalent 35 ms), slower ones within a frame or two.
    public static let keyWindow: TimeInterval = 0.3
    /// Reads this soon after the write never count: what reads every change does it then (the system, measured
    /// 15–60 ms after a write it can see), and no one pastes that fast on purpose.
    public static let quietAfterWrite: TimeInterval = 0.15

    /// Spec §14.2's "pasted": a read of the image or the file while ⌘ or ⌃ is held, within `keyWindow` of a key going
    /// down after Margin wrote the clipboard (the V of ⌘V or ⌃V), and not in its first `quiet` seconds. Anything else is
    /// someone looking, not pasting: a clipboard manager or history keeping every copy, another device fetching it, an
    /// app peeking at what's there, a paste from the Edit menu. The card stays then: deleting a shot before the user
    /// pasted it would lose it, keeping one costs a click.
    public func isPaste(sinceWrite: TimeInterval, quiet: TimeInterval = quietAfterWrite) -> Bool {
        (command || control) && sinceKeyDown <= Self.keyWindow && sinceKeyDown < sinceWrite && sinceWrite >= quiet
    }
}

/// Watches who reads one clipboard write (spec §14.2). Each item's `public.png` and `public.file-url` are promised
/// rather than written (`NSPasteboardItem.setDataProvider`), so the pasteboard asks Margin for them the first time
/// another app reads them, and the item is kept on this Mac (`currentHostOnly`): offered to other devices, the
/// pasteboard server fetches every file URL the moment it's written, which would use up the promise before any paste.
/// The pasteboard keeps what it was given, so only the first read of each type reaches the watch.
///
/// Measured on macOS 27.0.1 with Handoff off: written normally, `pboard` reads the file URL 15–45 ms after the write,
/// and Spotlight's clipboard history (in "Siri AI") reads it about 60 ms after; nothing reads the PNG. Written
/// `currentHostOnly`, neither reads anything (Spotlight skips promised data) until an app pastes.
@MainActor
public final class PasteWatch: NSObject, NSPasteboardItemDataProvider {
    /// One pasteboard item: an image and its file, or a recording's file alone. Only `watched` items report pastes.
    public struct Entry: Sendable {
        public var id: UUID
        public var png: Data?
        public var fileURL: URL?
        public var watched: Bool

        public init(id: UUID, png: Data?, fileURL: URL?, watched: Bool = true) {
            self.id = id
            self.png = png
            self.fileURL = fileURL
            self.watched = watched
        }
    }

    /// The pasteboard's change count after the write: the watch is current while the pasteboard still has it.
    public private(set) var changeCount = -1
    /// When it was written: how long after it a read comes is part of telling a paste (`PasteKeys.isPaste`).
    public private(set) var writtenAt = Date.distantPast
    /// The watched items that have been pasted.
    public private(set) var pasted: Set<UUID> = []
    /// The pasteboard has everything, or has moved on (something else was copied): nothing more will be asked.
    public private(set) var isFinished = false
    /// Every read so far, oldest first, for the DEBUG state dump.
    public private(set) var reads: [(type: String, id: UUID, after: TimeInterval, keys: PasteKeys)] = []
    /// Pasted items, a moment after the paste: the reads of one paste (several items, two types) come together.
    public var onPaste: (([UUID]) -> Void)?

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var items: [NSPasteboardItem] = []
    private var reporting: Set<UUID> = []
    private let keys: () -> PasteKeys
    private let reportDelay: TimeInterval
    private let quiet: TimeInterval

    /// `keys` reads the keyboard at a read, and `quiet` is `PasteKeys.isPaste`'s (both injectable for tests).
    public init(keys: @escaping () -> PasteKeys = { PasteKeys.current }, reportDelay: TimeInterval = 0.15,
                quiet: TimeInterval = PasteKeys.quietAfterWrite) {
        self.keys = keys
        self.reportDelay = reportDelay
        self.quiet = quiet
    }

    /// Writes one promised item per entry, in order, kept to this Mac, and returns the new change count. A watch writes
    /// once.
    @discardableResult
    public func write(_ entries: [Entry], to pasteboard: NSPasteboard = .general) -> Int {
        precondition(items.isEmpty, "a PasteWatch writes once")
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        items = entries.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            var types: [NSPasteboard.PasteboardType] = []
            if entry.png != nil { types.append(.png) }
            if let url = entry.fileURL, url.isFileURL { types.append(.fileURL) }
            item.setDataProvider(self, forTypes: types)
            self.entries[ObjectIdentifier(item)] = entry
            return item
        }
        pasteboard.writeObjects(items)
        changeCount = pasteboard.changeCount
        writtenAt = Date()
        return changeCount
    }

    public nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                                       provideDataForType type: NSPasteboard.PasteboardType) {
        // AppKit asks on the main thread, where the item lives.
        nonisolated(unsafe) let item = item
        MainActor.assumeIsolated { provide(type, for: item) }
    }

    /// Everything promised has been given, or the pasteboard has moved on: the images can go (the pasteboard has them).
    public nonisolated func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        MainActor.assumeIsolated {
            isFinished = true
            for key in entries.keys { entries[key]?.png = nil }
        }
    }

    private func provide(_ type: NSPasteboard.PasteboardType, for item: NSPasteboardItem) {
        guard let entry = entries[ObjectIdentifier(item)] else { return }
        // The data first: the reading app is waiting for it.
        switch type {
        case .png: if let png = entry.png { item.setData(png, forType: .png) }
        case .fileURL: if let url = entry.fileURL { item.setString(url.absoluteURL.absoluteString, forType: .fileURL) }
        default: return
        }
        let held = keys(), after = Date().timeIntervalSince(writtenAt)
        reads.append((type.rawValue, entry.id, after, held))
        guard entry.watched, held.isPaste(sinceWrite: after, quiet: quiet), pasted.insert(entry.id).inserted else { return }
        if reporting.isEmpty {
            // Held until then: the pasteboard may be done with the watch before the report is.
            DispatchQueue.main.asyncAfter(deadline: .now() + reportDelay) {
                MainActor.assumeIsolated { self.report() }
            }
        }
        reporting.insert(entry.id)
    }

    private func report() {
        let ids = items.compactMap { entries[ObjectIdentifier($0)]?.id }.filter(reporting.contains)
        reporting = []
        if !ids.isEmpty { onPaste?(ids) }
    }

    /// Gives the pasteboard everything still promised, so the clipboard keeps the shot once Margin has quit. Call
    /// while the watch is current (`changeCount` is the pasteboard's); once it's finished there's nothing left to give.
    public func fulfil() {
        guard !isFinished else { return }
        for item in items {
            guard let entry = entries[ObjectIdentifier(item)] else { continue }
            if let png = entry.png { item.setData(png, forType: .png) }
            if let url = entry.fileURL, url.isFileURL { item.setString(url.absoluteURL.absoluteString, forType: .fileURL) }
        }
    }
}
