import Foundation

/// "Delete screenshots after pasting" (spec §14.2). While it's on, a screenshot is written to Margin's own Pasteboard
/// folder (`Preferences.pasteboardFolder`) rather than the save folder, goes on the shelf and the clipboard as usual,
/// and leaves the shelf once it's pasted into another app. A file in that folder lives as long as something can still
/// reach it: its card, the ⌘Z step that would bring the card back, or the clipboard.
public enum PasteboardShots {
    /// Where a new capture of `kind` goes. A screen recording always goes to the save folder: the option is about
    /// screenshots that are pasted and forgotten, and a movie is pasted as its file, which has to stay.
    public static func folder(for kind: ShelfItem.Kind, deletesAfterPasting: Bool, saveFolder: URL,
                              pasteboardFolder: URL = Preferences.pasteboardFolder) -> URL {
        deletesAfterPasting && kind == .screenshot ? pasteboardFolder : saveFolder
    }

    /// Whether `path` names a file directly inside `folder`. Only files there are ever deleted: a shot that fell back to
    /// Unsaved, or was moved out in Finder, is a normal file. Compares the paths alone (after `.` and `..`), never the
    /// disk, so the main actor can ask about a path in the save folder: Margin builds the Pasteboard folder's paths itself.
    public static func isInFolder(_ path: String, folder: URL = Preferences.pasteboardFolder) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent().path == folder.standardizedFileURL.path
    }
}

// MARK: - When a file may go

extension PasteboardShots {
    /// How a card left the shelf, which says how long its file stays at least once nothing else holds it: an app that
    /// took a paste or a drop may read the file a little later (a terminal pastes its path, a browser uploads it).
    public enum Departure: Sendable {
        case pasted, dropped, removed

        public var grace: TimeInterval {
            switch self {
            case .pasted: 10
            case .dropped: 30
            case .removed: 0
            }
        }
    }

    /// Files in the Pasteboard folder waiting to be deleted: their card has left the shelf and its ⌘Z step has gone
    /// too (pushed out by newer ones). Each goes once its time has come, unless something can reach it again: a card
    /// for it (back by some other way), or the clipboard, while Margin's copy of it is still what's there.
    public struct Retention: Equatable, Sendable {
        /// Path → the earliest it may be deleted.
        public private(set) var waiting: [String: Date] = [:]

        public init() {}

        public var isEmpty: Bool { waiting.isEmpty }

        /// `path` has nothing left that could bring its card back; it may go from `notBefore` on. Files outside the
        /// Pasteboard folder never wait here.
        public mutating func add(_ path: String, notBefore: Date, folder: URL = Preferences.pasteboardFolder) {
            guard PasteboardShots.isInFolder(path, folder: folder) else { return }
            let key = Self.key(path)
            waiting[key] = max(waiting[key] ?? notBefore, notBefore)
        }

        /// The paths to delete now, which stop waiting. `referenced` are the paths cards and ⌘Z steps point at: one of
        /// those stops waiting without being deleted (its card is back). `onClipboard` keep waiting.
        public mutating func due(at now: Date, referenced: Set<String>, onClipboard: Set<String>) -> [String] {
            guard !waiting.isEmpty else { return [] }
            let referenced = Set(referenced.map(Self.key)), onClipboard = Set(onClipboard.map(Self.key))
            var due: [String] = []
            for (path, notBefore) in waiting {
                if referenced.contains(path) {
                    waiting[path] = nil
                } else if notBefore <= now, !onClipboard.contains(path) {
                    waiting[path] = nil
                    due.append(path)
                }
            }
            return due.sorted()
        }

        static func key(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
    }
}

// MARK: - At launch

extension PasteboardShots {
    /// The Pasteboard files on the clipboard as Margin last left it, and the pasteboard's change count then. Kept across
    /// a relaunch (`Preferences.pasteboardClipboard`): while the count hasn't moved, the clipboard still offers those
    /// files (a terminal pastes their paths), so they stay even without a card.
    public struct ClipboardFiles: Codable, Equatable, Sendable {
        public var changeCount: Int
        public var paths: [String]

        public init(changeCount: Int, paths: [String]) {
            self.changeCount = changeCount
            self.paths = paths
        }

        /// The paths still on the clipboard when its change count is `current`.
        public func paths(at current: Int) -> Set<String> {
            current == changeCount ? Set(paths) : []
        }
    }

    /// Deletes the files in `folder` that no card can reach any more: at launch, after the cut-off saves are dealt with
    /// (`LeftoverSaves`), the ⌘Z steps of the last session are gone, so a file is kept only if a shelf item points at it
    /// (its path, or where its bookmark leads: a file renamed in Finder while Margin was quit), or it's in `keeping` (on
    /// the clipboard). Only visible files last written before `writtenBefore` are looked at: hidden ones are Finder's
    /// or a save's, and a capture of this launch's can't be older. Blocking. Returns what was deleted.
    @discardableResult
    public static func cleanUp(folder: URL = Preferences.pasteboardFolder, items: [ShelfItem], keeping: Set<String> = [],
                               writtenBefore: Date) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let candidates = names.filter { !$0.hasPrefix(".") }.map { folder.appendingPathComponent($0) }.filter { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let modified = values.contentModificationDate else { return false }
            return modified < writtenBefore
        }
        guard !candidates.isEmpty else { return [] }
        // Off the main thread, so symlinks can be followed: a bookmark leads to `/private/var`, a path may say `/var`.
        let real = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
        var kept = Set((items.map(\.path) + keeping).map(real))
        var unclaimed = candidates.filter { !kept.contains(real($0.path)) }
        // Only then follow bookmarks, which is slower: a card renamed in Finder still holds its file.
        if !unclaimed.isEmpty {
            for item in items {
                guard let bookmark = item.bookmark, let resolved = ShelfItem.resolve(bookmark) else { continue }
                kept.insert(real(resolved.url.path))
            }
            unclaimed = unclaimed.filter { !kept.contains(real($0.path)) }
        }
        return unclaimed.filter { (try? FileManager.default.removeItem(at: $0)) != nil }
    }
}
