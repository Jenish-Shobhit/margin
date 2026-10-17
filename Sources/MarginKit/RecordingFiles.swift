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

    /// Removes the temp files of recordings cut off before they were finished (a crash, a forced quit) in `folder`: only
    /// those last written before `before` (this launch: no recording of this copy's can be older). Without its index an
    /// MP4 doesn't play, so there's nothing to put back. Runs when a recording starts in that folder, never at launch,
    /// which would look into the save folder (on the Desktop, a privacy prompt) before anything is recorded. Returns
    /// what was removed. Blocking.
    @discardableResult
    public static func removeLeftovers(in folder: URL, writtenBefore before: Date) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter(isTempName).compactMap { name -> URL? in
            let url = folder.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true, let modified = values.contentModificationDate, modified < before,
                  (try? FileManager.default.removeItem(at: url)) != nil else { return nil }
            return url
        }
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
