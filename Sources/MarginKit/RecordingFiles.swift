import Foundation

/// A screen recording's file (spec §14.4): written to a hidden temp file in the save folder while recording, and renamed
/// into place, under its start time's name, when it's finished.
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

    /// What became of a leftover temp file.
    public enum Leftover: Hashable, Sendable {
        /// A finished movie whose rename never happened: renamed to this.
        case recovered(URL)
        /// Cut off mid-recording (a crash, a forced quit): without its index an MP4 doesn't play, so it's removed.
        case removed(URL)
    }

    /// Deals with the temp files of recordings in `folder` last written before `before` (this launch: no recording of this
    /// copy's can be older). A complete movie (finished, but its rename never happened) gets a `Screen Recording` name
    /// from when it was started; one cut off mid-recording is removed. Runs when a recording starts in that folder,
    /// never at launch, which would look into the save folder (on the Desktop, a privacy prompt) before anything is
    /// recorded. Blocking.
    @discardableResult
    public static func handleLeftovers(in folder: URL, writtenBefore before: Date, timeZone: TimeZone = .current) -> [Leftover] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter(isTempName).sorted().compactMap { name -> Leftover? in
            let url = folder.appendingPathComponent(name)
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified < before else { return nil }
            if isPlayableMovie(at: url),
               let placed = try? moveIntoPlace(url, in: folder, date: values.creationDate ?? modified, timeZone: timeZone) {
                return .recovered(placed)
            }
            return (try? FileManager.default.removeItem(at: url)) != nil ? .removed(url) : nil
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
