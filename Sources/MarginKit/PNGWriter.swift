import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One encode feeds both the file and the clipboard.
public enum PNGWriter {
    public enum Failure: Error { case encode }

    /// PNG with compression filtering off (fast), the image's color profile, and DPI = 72 × scale (144 on Retina).
    /// ImageIO turns the DPI into the PNG's `pHYs` chunk and embeds the color space as `iCCP`.
    public static func encode(_ image: CGImage, scale: CGFloat) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw Failure.encode }
        let dpi = 72 * (scale > 0 ? scale : 1)
        let props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
            kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGCompressionFilter: IMAGEIO_PNG_FILTER_NONE],
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.encode }
        return data as Data
    }

    /// Writes to a hidden temp file in the same folder, then renames into place. Never overwrites: if `url`
    /// exists it throws `POSIXError(.EEXIST)`. No app ever sees a half-written file, and the temp file is
    /// removed on every failure. Creates the folder if needed. `metadata` is set before the file appears.
    public static func writeAtomically(_ data: Data, to url: URL, metadata: ScreenshotMetadata? = nil) throws {
        let tmp = try writeTemp(data, in: url.deletingLastPathComponent(), metadata: metadata)
        do {
            try moveExclusively(from: tmp, to: url)
        } catch {
            unlink(tmp.path)
            throw error
        }
    }

    /// Like `writeAtomically`, but picks the name: the first free `FileNamer` name in `folder`, moving on to
    /// ` (2)`, ` (3)`, … if another writer takes a name between the check and the rename. Returns the final URL.
    public static func writeUnique(
        _ data: Data, in folder: URL, date: Date, timeZone: TimeZone = .current, metadata: ScreenshotMetadata? = nil
    ) throws -> URL {
        let tmp = try writeTemp(data, in: folder, metadata: metadata)
        do {
            return try moveUnique(from: tmp, in: folder, date: date, timeZone: timeZone)
        } catch {
            unlink(tmp.path)
            throw error
        }
    }

    /// Renames `src` to the first free `FileNamer` name in `folder`, moving on to ` (2)`, ` (3)`, … if another writer
    /// takes a name between the check and the rename. Returns the final URL.
    static func moveUnique(from src: URL, in folder: URL, date: Date, timeZone: TimeZone = .current) throws -> URL {
        var taken = Set<URL>()
        for _ in 0..<1000 {
            let url = FileNamer.uniqueURL(in: folder, for: date, timeZone: timeZone) {
                taken.contains($0) || FileManager.default.fileExists(atPath: $0.path)
            }
            do {
                try moveExclusively(from: src, to: url)
                return url
            } catch let error as POSIXError where error.code == .EEXIST {
                taken.insert(url)
            }
        }
        throw POSIXError(.EEXIST)
    }

    /// Temp files are `.margin-<UUID>.tmp`: hidden, and recognisably Margin's (`LeftoverSaves`).
    static func tempName() -> String { ".margin-\(UUID().uuidString).tmp" }

    static func isTempName(_ name: String) -> Bool {
        guard name.hasPrefix(".margin-"), name.hasSuffix(".tmp") else { return false }
        return UUID(uuidString: String(name.dropFirst(".margin-".count).dropLast(".tmp".count))) != nil
    }

    /// Writes `data` to a new hidden temp file in `folder` (created if missing). On failure nothing is left behind.
    static func writeTemp(_ data: Data, in folder: URL, metadata: ScreenshotMetadata? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tmp = folder.appendingPathComponent(tempName())
        do {
            try data.write(to: tmp, options: .withoutOverwriting)
        } catch {
            unlink(tmp.path) // a partial write (e.g. disk full) can leave a file behind
            throw error
        }
        metadata?.apply(to: tmp)
        return tmp
    }

    /// `rename(2)` that fails with EEXIST instead of replacing an existing file.
    static func moveExclusively(from src: URL, to dst: URL) throws {
        if renamex_np(src.path, dst.path, UInt32(RENAME_EXCL)) == 0 { return }
        let renameError = errno
        // APFS and HFS+ support RENAME_EXCL; some network and FAT volumes don't.
        guard renameError == ENOTSUP || renameError == EINVAL else { throw posixError(renameError) }
        // link(2) also refuses to replace an existing file.
        if link(src.path, dst.path) == 0 {
            unlink(src.path)
            return
        }
        let linkError = errno
        guard linkError == ENOTSUP || linkError == EPERM || linkError == EXDEV else { throw posixError(linkError) }
        // No hard links either (FAT): check, then rename. The window is tiny and only affects other writers.
        if FileManager.default.fileExists(atPath: dst.path) { throw POSIXError(.EEXIST) }
        if rename(src.path, dst.path) != 0 { throw posixError(errno) }
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
