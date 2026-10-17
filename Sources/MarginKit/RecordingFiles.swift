import Foundation

/// A screen recording's file (spec §14.4): written to a hidden temp file in the save folder while recording, in movie
/// fragments (so it plays even if it's never finished), and renamed into place, under its start time's name, when it's
/// finished.
public enum RecordingFiles {
    /// `.margin-recording-<UUID>.mp4`: hidden, an MP4 to AVFoundation, and never a PNG save's temp file (`LeftoverSaves`
    /// leaves it alone).
    public static func tempName() -> String { ".margin-recording-\(UUID().uuidString).mp4" }

    public static func isTempName(_ name: String) -> Bool {
        let prefix = ".margin-recording-", suffix = ".mp4"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count))) != nil
    }

    /// Renames the finished `temp` to the first free `Screen Recording … .mp4` name for `date` in `folder` (its own
    /// folder, normally), moving on to ` (2)`, ` (3)`, … if another writer takes a name between the check and the
    /// rename. Never replaces a file. Returns the final URL. Blocking.
    public static func moveIntoPlace(_ temp: URL, in folder: URL, date: Date, timeZone: TimeZone = .current) throws -> URL {
        var taken = Set<URL>()
        for _ in 0..<1000 {
            let url = FileNamer.uniqueURL(in: folder, for: date, kind: .recording, timeZone: timeZone) {
                taken.contains($0) || FileManager.default.fileExists(atPath: $0.path)
            }
            do {
                try PNGWriter.moveExclusively(from: temp, to: url)
                return url
            } catch let error as POSIXError where error.code == .EEXIST {
                taken.insert(url)
            }
        }
        throw POSIXError(.EEXIST)
    }

    /// Where a recording ended up (`place`).
    public struct Placement: Equatable, Sendable {
        public enum Folder: Equatable, Sendable {
            /// The folder it was recorded into.
            case same
            /// That folder, renamed or moved while recording: the movie is in it, where it is now.
            case moved
            /// Unsaved: that folder went to the Trash or was deleted while recording, or it took no rename.
            case unsaved(UnsavedShots.Reason)
        }

        public let url: URL
        public let folder: Folder

        public init(url: URL, folder: Folder) {
            self.url = url
            self.folder = folder
        }

        /// What the shelf says about where it went, if it isn't where it was recorded. `saveFolder` is the folder as
        /// the settings name it.
        public func toast(saveFolder: URL) -> String? {
            switch folder {
            case .same: nil
            case .moved:
                "Saved to “\(UnsavedShots.shortened(url.deletingLastPathComponent().lastPathComponent))”: the save folder was renamed or moved while recording"
            case .unsaved(let reason): UnsavedShots.fallbackToast(saveFolder: saveFolder, reason: reason)
            }
        }
    }

    /// Puts a recording's temp `file` in place under `date`'s name (spec §14.4), wherever its folder went while it was
    /// recorded (the writer writes on regardless). Renamed or moved, it's named in there, next to where it is now. Put
    /// in the Trash, or deleted (it's copied out of the still open file), or not taking the rename, it goes to `fallback`
    /// (Unsaved): moved if it's on the same volume, copied (and the temp file removed) if not. Never replaces a file,
    /// and leaves the movie under its hidden name only if nothing works: then it throws. Blocking.
    public static func place(_ file: RecordingFile, recordedIn folder: URL, fallback: URL, date: Date,
                             timeZone: TimeZone = .current) throws -> Placement {
        guard let current = file.currentURL else {
            let url = try copyIntoPlace(file, in: fallback, date: date, timeZone: timeZone)
            return Placement(url: url, folder: .unsaved(.deleted))
        }
        let here = current.deletingLastPathComponent()
        let trashed = ShelfItem.isInTrash(current)
        if !trashed {
            do {
                let url = try moveIntoPlace(current, in: here, date: date, timeZone: timeZone)
                return Placement(url: url, folder: ShelfItem.samePath(here, folder) ? .same : .moved)
            } catch where !ShelfItem.samePath(here, fallback) {
                // It can't be named there (the folder became read-only, say): Unsaved, below.
            }
        }
        let reason: UnsavedShots.Reason = trashed ? .trashed : .notWritable
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        do {
            return Placement(url: try moveIntoPlace(current, in: fallback, date: date, timeZone: timeZone), folder: .unsaved(reason))
        } catch {
            // Another volume, or a folder it can't be moved out of: a copy. The temp file goes if it can.
            let url = try copyIntoPlace(file, in: fallback, date: date, timeZone: timeZone)
            unlink(current.path)
            return Placement(url: url, folder: .unsaved(reason))
        }
    }

    /// A copy of `file` in `folder` under `date`'s name, by way of a temp file there, so no app sees it half-written.
    static func copyIntoPlace(_ file: RecordingFile, in folder: URL, date: Date, timeZone: TimeZone) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent(tempName())
        try file.copy(to: temp)
        do {
            return try moveIntoPlace(temp, in: folder, date: date, timeZone: timeZone)
        } catch {
            unlink(temp.path)
            throw error
        }
    }

    /// What became of a leftover temp file.
    public enum Leftover: Hashable, Sendable {
        /// A movie that plays: finished, its rename never done, or cut off (a crash, a forced quit, the quit's time
        /// limit, a stop that never finished) and playing up to its last fragment. Renamed to this.
        case recovered(URL)
        /// One that plays but couldn't be renamed: it stays as it is, for the next time.
        case unnamed(URL)
        /// Cut off in its first second, before its index was written: nothing in it plays, so it's removed.
        case removed(URL)
    }

    /// Deals with the temp files of recordings in `folder` last written before `before` (this launch: no recording of this
    /// copy's can be older). One that plays (`isPlayableMovie`: finished, or cut off after its first fragment) gets a
    /// `Screen Recording` name from when it was started, as a leftover screenshot does (`LeftoverSaves`), and is never
    /// deleted; only one with nothing that plays is removed. Runs when a recording starts, in the folder it's saved to and
    /// in Unsaved, never at launch, which would look into the save folder (on the Desktop, a privacy prompt) before
    /// anything is recorded. Blocking.
    @discardableResult
    public static func handleLeftovers(in folder: URL, writtenBefore before: Date, timeZone: TimeZone = .current) -> [Leftover] {
        handleLeftovers(in: folder, writtenBefore: before) { try moveIntoPlace($0, in: folder, date: $1, timeZone: timeZone) }
    }

    /// `handleLeftovers`, naming each with `rename(temp, its start)`.
    static func handleLeftovers(in folder: URL, writtenBefore before: Date,
                                rename: (URL, Date) throws -> URL) -> [Leftover] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter(isTempName).sorted().compactMap { name -> Leftover? in
            let url = folder.appendingPathComponent(name)
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified < before else { return nil }
            guard isPlayableMovie(at: url) else {
                return (try? FileManager.default.removeItem(at: url)) != nil ? .removed(url) : nil
            }
            guard let placed = try? rename(url, values.creationDate ?? modified) else { return .unnamed(url) }
            return .recovered(placed)
        }
    }

    /// Whether the MP4 at `url` has its index (`moov`), whole, among its top-level boxes, without which nothing in it
    /// plays. A finished movie has it at the end. One written in fragments (`ScreenRecorder`) has it from its first
    /// fragment on, a `moof` for each later one: cut off, or left by a writer that failed, it plays up to its last
    /// fragment; cut off in its first, it has its media (`mdat`, often sized to the end of the file) and no index.
    /// Reads box headers only.
    public static func isPlayableMovie(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let length = try? handle.seekToEnd() else { return false }
        var offset: UInt64 = 0
        while offset + 8 <= length {
            guard (try? handle.seek(toOffset: offset)) != nil, let header = try? handle.read(upToCount: 16), header.count >= 8
            else { return false }
            let bytes = [UInt8](header)
            var size = UInt64(bytes[0]) << 24 | UInt64(bytes[1]) << 16 | UInt64(bytes[2]) << 8 | UInt64(bytes[3])
            let type = String(decoding: bytes[4..<8], as: UTF8.self)
            if size == 0 { return type == "moov" }      // to the end of the file: nothing after it
            if size == 1 {                              // a 64-bit size follows the type
                guard bytes.count >= 16 else { return false }
                size = bytes[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
            }
            guard size >= 8 else { return false }
            if type == "moov" { return offset + size <= length } // an index cut off as it was written is none
            offset += size
        }
        return false
    }

    /// Bytes free for writing on the volume holding `folder` (nil if it can't be read). Cheap (`statfs`), but it's the
    /// file system: off the main thread.
    public static func freeBytes(at folder: URL) -> Int64? {
        var fs = statfs()
        guard statfs(folder.path, &fs) == 0 else { return nil }
        return Int64(fs.f_bavail) * Int64(fs.f_bsize)
    }

    /// Below this much free space a recording stops and keeps what it has: finishing the file needs room for its index,
    /// and a disk that fills up mid-write loses the whole recording.
    public static let minimumFreeBytes: Int64 = 400 * 1024 * 1024
}
