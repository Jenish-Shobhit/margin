import CoreGraphics
import Foundation

/// A fresh folder under the temp directory. Call `remove()` when done.
struct TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarginKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String, contents: String = "x") throws -> URL {
        let f = url.appendingPathComponent(name)
        try Data(contents.utf8).write(to: f)
        return f
    }

    func contents() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.sorted() ?? []
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A solid-color image in `colorSpace`.
func makeImage(width: Int, height: Int, colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.35, green: 0.33, blue: 0.94, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
    return ctx.makeImage()!
}

/// PNG chunks by type (first occurrence), straight from the bytes.
func pngChunks(_ data: Data) -> [String: Data] {
    let bytes = [UInt8](data)
    var chunks: [String: Data] = [:]
    var i = 8 // signature
    while i + 8 <= bytes.count {
        let length = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
        let type = String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self)
        let start = i + 8
        guard start + length <= bytes.count else { break }
        if chunks[type] == nil { chunks[type] = Data(bytes[start..<(start + length)]) }
        i = start + length + 4 // + CRC
    }
    return chunks
}

func bigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
    let b = [UInt8](data)
    return UInt32(b[offset]) << 24 | UInt32(b[offset + 1]) << 16 | UInt32(b[offset + 2]) << 8 | UInt32(b[offset + 3])
}
