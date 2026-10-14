import CoreGraphics
import Foundation
import ImageIO
import MarginKit
import Testing

@Suite struct PNGWriterEncodeTests {
    func properties(_ data: Data) throws -> [CFString: Any] {
        let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(src) as String? == "public.png")
        return try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
    }

    @Test func retinaIs144DPI() throws {
        let data = try PNGWriter.encode(makeImage(width: 80, height: 60), scale: 2)
        let props = try properties(data)
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 80)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 60)
        let dpiX = try #require(props[kCGImagePropertyDPIWidth] as? Double)
        let dpiY = try #require(props[kCGImagePropertyDPIHeight] as? Double)
        #expect(abs(dpiX - 144) < 0.5 && abs(dpiY - 144) < 0.5)
    }

    @Test func dpiIsInThePHYsChunk() throws {
        let data = try PNGWriter.encode(makeImage(width: 8, height: 8), scale: 2)
        let pHYs = try #require(pngChunks(data)["pHYs"])
        #expect(pHYs.count == 9)
        // 144 dpi = 5669.29 pixels per metre; unit byte 1 = metre.
        #expect(abs(Int(bigEndianUInt32(pHYs, at: 0)) - 5669) <= 1)
        #expect(abs(Int(bigEndianUInt32(pHYs, at: 4)) - 5669) <= 1)
        #expect(pHYs.last == 1)
    }

    @Test func scaleOneIs72DPI() throws {
        let data = try PNGWriter.encode(makeImage(width: 8, height: 8), scale: 1)
        let dpi = try #require(try properties(data)[kCGImagePropertyDPIWidth] as? Double)
        #expect(abs(dpi - 72) < 0.5)
        let pHYs = try #require(pngChunks(data)["pHYs"])
        #expect(abs(Int(bigEndianUInt32(pHYs, at: 0)) - 2835) <= 1) // 72 dpi = 2834.6 px/m
    }

    @Test func displayP3IsPreserved() throws {
        let data = try PNGWriter.encode(makeImage(width: 16, height: 16), scale: 2)
        #expect(pngChunks(data)["iCCP"] != nil)
        let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(decoded.colorSpace?.name == CGColorSpace.displayP3)
        let profile = try properties(data)[kCGImagePropertyProfileName] as? String
        #expect(profile?.contains("P3") == true)
    }

    @Test func otherColorSpacesArePreservedToo() throws {
        let adobe = try #require(CGColorSpace(name: CGColorSpace.adobeRGB1998))
        let data = try PNGWriter.encode(makeImage(width: 4, height: 4, colorSpace: adobe), scale: 1)
        #expect(pngChunks(data)["iCCP"] != nil)
        let profile = try properties(data)[kCGImagePropertyProfileName] as? String
        #expect(profile?.contains("Adobe RGB") == true)
    }

    @Test func pixelsSurviveTheRoundTrip() throws {
        let image = makeImage(width: 10, height: 10, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let data = try PNGWriter.encode(image, scale: 2)
        let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(decoded.width == 10 && decoded.height == 10)
        #expect(rgba(image) == rgba(decoded))
    }

    /// Redraws into a fixed RGBA8 sRGB layout so row padding and alpha layout don't matter.
    func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    @Test func largeRetinaShot() throws {
        let data = try PNGWriter.encode(makeImage(width: 3024, height: 1964), scale: 2)
        let props = try properties(data)
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 3024)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 1964)
    }
}

@Suite struct PNGWriterFileTests {
    func tempFiles(_ dir: TempDir) -> [String] { dir.contents().filter { $0.hasPrefix(".margin-") } }

    @Test func writesBytesAndLeavesNoTempFile() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let data = try PNGWriter.encode(makeImage(width: 4, height: 4), scale: 2)
        let url = dir.url.appendingPathComponent("Screenshot.png")
        try PNGWriter.writeAtomically(data, to: url)
        #expect(try Data(contentsOf: url) == data)
        #expect(dir.contents() == ["Screenshot.png"])
    }

    @Test func createsMissingFolders() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let url = dir.url.appendingPathComponent("Desktop/Screenshots/shot.png")
        try PNGWriter.writeAtomically(Data("png".utf8), to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func neverOverwrites() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let url = try dir.file("shot.png", contents: "original")
        #expect {
            try PNGWriter.writeAtomically(Data("new".utf8), to: url)
        } throws: { error in
            (error as? POSIXError)?.code == .EEXIST
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "original")
        #expect(tempFiles(dir).isEmpty)
        #expect(dir.contents() == ["shot.png"])
    }

    @Test func failureInMissingParentLeavesNothing() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        // The parent is a file, so the folder can't be created.
        let blocker = try dir.file("blocker")
        #expect(throws: (any Error).self) {
            try PNGWriter.writeAtomically(Data("x".utf8), to: blocker.appendingPathComponent("shot.png"))
        }
        #expect(dir.contents() == ["blocker"])
    }

    @Test func readOnlyFolderThrowsAndLeavesNothing() throws {
        let dir = try TempDir()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.url.path)
            dir.remove()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.url.path)
        #expect(throws: (any Error).self) {
            try PNGWriter.writeAtomically(Data("x".utf8), to: dir.url.appendingPathComponent("shot.png"))
        }
        #expect(dir.contents().isEmpty)
    }

    @Test func writeUniqueCountsUp() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_791_999_737)
        let a = try PNGWriter.writeUnique(Data("1".utf8), in: dir.url, date: date, timeZone: utc)
        let b = try PNGWriter.writeUnique(Data("2".utf8), in: dir.url, date: date, timeZone: utc)
        let c = try PNGWriter.writeUnique(Data("3".utf8), in: dir.url, date: date, timeZone: utc)
        #expect(a.lastPathComponent == "Screenshot 2026-10-14 at 17.42.17.png")
        #expect(b.lastPathComponent == "Screenshot 2026-10-14 at 17.42.17 (2).png")
        #expect(c.lastPathComponent == "Screenshot 2026-10-14 at 17.42.17 (3).png")
        #expect(try String(contentsOf: b, encoding: .utf8) == "2")
        #expect(tempFiles(dir).isEmpty)
        #expect(dir.contents().count == 3)
    }

    @Test func manyWritesToTheSameNameNeverClobber() async throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let date = Date(timeIntervalSince1970: 1_791_999_737)
        let folder = dir.url
        let urls = try await withThrowingTaskGroup(of: URL.self) { group in
            for i in 0..<20 {
                group.addTask { try PNGWriter.writeUnique(Data("\(i)".utf8), in: folder, date: date) }
            }
            return try await group.reduce(into: [URL]()) { $0.append($1) }
        }
        #expect(Set(urls).count == 20)
        #expect(tempFiles(dir).isEmpty)
        let contents = Set(try urls.map { try String(contentsOf: $0, encoding: .utf8) })
        #expect(contents == Set((0..<20).map(String.init)))
    }
}
