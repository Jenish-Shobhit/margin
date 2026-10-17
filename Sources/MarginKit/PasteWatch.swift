import AppKit
import Carbon.HIToolbox

/// The keys held when another app reads Margin's clipboard item: a paste is V with ⌘ (or ⌃, which terminals and
/// Claude Code use). `CGEventSource` reports them without Input Monitoring or Accessibility.
public struct PasteKeys: Equatable, Sendable {
    public var v: Bool
    public var command: Bool
    public var control: Bool

    public init(v: Bool = false, command: Bool = false, control: Bool = false) {
        self.v = v
        self.command = command
        self.control = control
    }

    /// As the event system sees them now: the keyboard and any posted events (automation that pastes for the user).
    public static var current: PasteKeys {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return PasteKeys(v: CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_ANSI_V)),
                         command: flags.contains(.maskCommand), control: flags.contains(.maskControl))
    }

    /// Spec §14.2's "pasted": a read of the image or the file while ⌘V or ⌃V is held. A read with no such keys is
    /// someone looking, not pasting: a clipboard manager or history keeping every copy, a Mac or iPhone fetching it,
    /// an app peeking at what's there. Those don't count, so the card stays: deleting a shot before the user pasted it
    /// would lose it, keeping one costs a click. A paste from the Edit menu doesn't count either.
    public var isPaste: Bool { v && (command || control) }
}

/// Watches who reads one clipboard write (spec §14.2). Each item's `public.png` and `public.file-url` are promised
/// rather than written (`NSPasteboardItem.setDataProvider`), so the pasteboard asks Margin for them the first time
/// another app reads them, and the item is kept on this Mac (`currentHostOnly`): offered to other devices, the
/// pasteboard server fetches every file URL the moment it's written, which would use up the promise before any paste.
/// The pasteboard keeps what it was given, so only the first read of each type reaches the watch.
///
/// Measured on macOS 27.0.1 with Handoff off: written normally, `pboard` reads the file URL about 15 ms after the
/// write, and Spotlight's clipboard history (in "Siri AI") reads it 50 ms after; nothing reads the PNG. Written
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
    /// When it was written, for the log.
    public private(set) var writtenAt = Date.distantPast
    /// The watched items that have been pasted.
    public private(set) var pasted: Set<UUID> = []
    /// The pasteboard has moved on (something else was copied): nothing more will be asked.
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

    /// `keys` reads the keys held at a read (injectable for tests).
    public init(keys: @escaping () -> PasteKeys = { PasteKeys.current }, reportDelay: TimeInterval = 0.15) {
        self.keys = keys
        self.reportDelay = reportDelay
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

    public nonisolated func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        MainActor.assumeIsolated { isFinished = true }
    }

    private func provide(_ type: NSPasteboard.PasteboardType, for item: NSPasteboardItem) {
        guard let entry = entries[ObjectIdentifier(item)] else { return }
        // The data first: the reading app is waiting for it.
        switch type {
        case .png: if let png = entry.png { item.setData(png, forType: .png) }
        case .fileURL: if let url = entry.fileURL { item.setString(url.absoluteURL.absoluteString, forType: .fileURL) }
        default: return
        }
        let held = keys()
        reads.append((type.rawValue, entry.id, Date().timeIntervalSince(writtenAt), held))
        guard entry.watched, held.isPaste, pasted.insert(entry.id).inserted else { return }
        if reporting.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + reportDelay) { [weak self] in
                MainActor.assumeIsolated { self?.report() }
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
    /// while the watch is current (`changeCount` is the pasteboard's).
    public func fulfil() {
        for item in items {
            guard let entry = entries[ObjectIdentifier(item)] else { continue }
            if let png = entry.png, !item.types.isEmpty { item.setData(png, forType: .png) }
            if let url = entry.fileURL, url.isFileURL { item.setString(url.absoluteURL.absoluteString, forType: .fileURL) }
        }
    }
}
