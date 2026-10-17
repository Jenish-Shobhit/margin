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
    /// When the key of the reads being gathered went down (the earliest, if they disagree).
    private var reportingKeyDown = Date.distantFuture
    private let keys: () -> PasteKeys
    private let readerIsSelf: () -> Bool
    private let lastActivation: () -> Date
    private let reportDelay: TimeInterval
    private let longestHold: TimeInterval
    private let activationLag: TimeInterval
    private let quiet: TimeInterval

    /// `keys` reads the keyboard at a read, and `quiet` is `PasteKeys.isPaste`'s (both injectable for tests).
    /// `readerIsSelf` says the keys went to Margin itself (in front, or with a key window): a read then is never another
    /// app's paste. `lastActivation` is when another app last came to the front: one that came after the key was
    /// ⌘Tab, not ⌘V (`report`). The report waits for ⌘ and ⌃ to be let go, up to `longestHold`, and `activationLag`
    /// after, for the activation to be heard of.
    public init(keys: @escaping () -> PasteKeys = { PasteKeys.current }, readerIsSelf: @escaping () -> Bool = { false },
                lastActivation: @escaping () -> Date = { .distantPast }, reportDelay: TimeInterval = 0.15,
                longestHold: TimeInterval = 2, activationLag: TimeInterval = 0.1,
                quiet: TimeInterval = PasteKeys.quietAfterWrite) {
        self.keys = keys
        self.readerIsSelf = readerIsSelf
        self.lastActivation = lastActivation
        self.reportDelay = reportDelay
        self.longestHold = longestHold
        self.activationLag = activationLag
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
        guard entry.watched, held.isPaste(sinceWrite: after, quiet: quiet), !readerIsSelf(),
              pasted.insert(entry.id).inserted else { return }
        if reporting.isEmpty {
            // Held until then: the pasteboard may be done with the watch before the report is.
            let started = Date()
            later(reportDelay) { self.report(started: started, releasedAt: nil) }
        }
        reporting.insert(entry.id)
        reportingKeyDown = min(reportingKeyDown, Date().addingTimeInterval(-held.sinceKeyDown))
    }

    /// Once ⌘ and ⌃ are up (or after `longestHold`), and `activationLag` later: the app switcher brings its app to the
    /// front only as ⌘ is let go, so a read that ⌘Tab's own Tab let through (a clipboard manager polling just then) is
    /// followed by an activation after the key, and a paste isn't. Then the cards are the app's to report, or kept.
    private func report(started: Date, releasedAt: Date?) {
        let now = Date()
        if releasedAt == nil {
            let held = keys()
            if (held.command || held.control) && now.timeIntervalSince(started) < longestHold {
                later(0.03) { self.report(started: started, releasedAt: nil) }
                return
            }
            if activationLag > 0 {
                later(activationLag) { self.report(started: started, releasedAt: now) }
                return
            }
        }
        let ids = items.compactMap { entries[ObjectIdentifier($0)]?.id }.filter(reporting.contains)
        let switched = lastActivation() > reportingKeyDown
        reporting = []
        reportingKeyDown = .distantFuture
        if switched {
            switchedApps += ids.count
            pasted.subtract(ids)
        } else if !ids.isEmpty {
            onPaste?(ids)
        }
    }

    /// Reads that looked like a paste but came with ⌘Tab (`report`), for the DEBUG state dump.
    public private(set) var switchedApps = 0

    private func later(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
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
