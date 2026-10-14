import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One encode feeds both the file and the clipboard.
public enum PNGWriter {
    public enum Failure: Error { case encode }

    /// PNG with compression filtering off (fast), the image's color profile, and DPI = 72 × scale (144 on Retina).
    public static func encode(_ image: CGImage, scale: CGFloat) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw Failure.encode }
        let dpi = 72 * scale
        let props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
            kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGCompressionFilter: IMAGEIO_PNG_FILTER_NONE],
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.encode }
        return data as Data
    }

    /// Writes to a hidden temp file in the same folder, then renames into place (never overwrites),
    /// so no app ever sees a half-written file. Creates the folder if needed.
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tmp = folder.appendingPathComponent(".margin-\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        if renamex_np(tmp.path, url.path, UInt32(RENAME_EXCL)) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
