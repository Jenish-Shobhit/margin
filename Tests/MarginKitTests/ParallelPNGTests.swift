import CoreGraphics
import Foundation
import ImageIO
@testable import MarginKit
import Testing
import zlib

/// ParallelPNG must write what ImageIO writes: the same samples, the same chunks around them, valid CRCs and Adler-32.
@Suite struct ParallelPNGTests {
    // MARK: Images

    enum Content: Sendable { case noise, alphaNoise, gradient, flat, window }
    /// SCK's BGRA (premultiplied first, little-endian) or CGContext's default RGBA (premultiplied last).
    enum Layout: Sendable { case bgra, rgba }

    struct Case: Sendable, CustomTestStringConvertible {
        let width: Int, height: Int, content: Content, layout: Layout, bands: Int?
        var testDescription: String { "\(width)×\(height) \(content) \(layout) bands \(bands.map(String.init) ?? "auto")" }
    }

    static func image(_ c: Case, space: CGColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!) -> CGImage {
        image(width: c.width, height: c.height, content: c.content, layout: c.layout, space: space)
    }

    static func image(width: Int, height: Int, content: Content, layout: Layout = .bgra,
                      space: CGColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!) -> CGImage {
        let info = layout == .bgra
            ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        if content == .window {
            // Transparent around a rounded card with a soft shadow, as a window shot is.
            let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
            let card = CGRect(x: 0, y: 0, width: width, height: height).insetBy(dx: CGFloat(width) / 8, dy: CGFloat(height) / 8)
            ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: CGColor(gray: 0, alpha: 0.5))
            ctx.setFillColor(CGColor(red: 0.95, green: 0.6, blue: 0.2, alpha: 1))
            ctx.addPath(CGPath(roundedRect: card, cornerWidth: 20, cornerHeight: 20, transform: nil))
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.9, alpha: 0.6))
            ctx.fill(card.insetBy(dx: 30, dy: 30))
            return ctx.makeImage()!
        }
        var rng = SplitMix(seed: UInt64(width * 7919 + height))
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                var c: (UInt8, UInt8, UInt8)
                var a: UInt8 = 255
                switch content {
                case .noise: c = (rng.byte(), rng.byte(), rng.byte())
                case .alphaNoise:
                    a = rng.byte()
                    c = (rng.byte(below: a), rng.byte(below: a), rng.byte(below: a))
                case .gradient: c = (UInt8(x * 255 / max(1, width - 1)), UInt8(y * 255 / max(1, height - 1)), UInt8((x + y) & 0xFF))
                case .flat, .window: c = (40, 120, 220)
                }
                // Colour channels in memory order: B G R A, or R G B A.
                if layout == .bgra { px[i] = c.2; px[i + 1] = c.1; px[i + 2] = c.0; px[i + 3] = a }
                else { px[i] = c.0; px[i + 1] = c.1; px[i + 2] = c.2; px[i + 3] = a }
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: info), provider: CGDataProvider(data: Data(px) as CFData)!,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
        mutating func byte(below limit: UInt8) -> UInt8 { UInt8(truncatingIfNeeded: next() % (UInt64(limit) + 1)) }
    }

    // MARK: Reading PNGs back

    struct Chunk: Equatable { let type: String, data: [UInt8] }

    /// Every chunk, after checking the signature and each CRC.
    static func chunks(_ data: Data) throws -> [Chunk] {
        let b = [UInt8](data)
        try #require(b.count > 8 && b[0..<8].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        var i = 8, out: [Chunk] = []
        while i < b.count {
            try #require(i + 12 <= b.count)
            let n = b[i..<(i + 4)].reduce(0) { $0 << 8 | Int($1) }
            try #require(i + 12 + n <= b.count)
            let crc = b[(i + 8 + n)..<(i + 12 + n)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let computed = b.withUnsafeBufferPointer { UInt32(crc32(0, $0.baseAddress! + i + 4, uInt(4 + n))) }
            try #require(crc == computed, "CRC of chunk at \(i)")
            out.append(Chunk(type: String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self), data: Array(b[(i + 8)..<(i + 8 + n)])))
            i += 12 + n
        }
        try #require(out.first?.type == "IHDR" && out.last?.type == "IEND")
        return out
    }

    /// The chunks that aren't image data.
    static func metadata(_ data: Data) throws -> [Chunk] { try chunks(data).filter { $0.type != "IDAT" } }

    /// The 8-bit RGBA samples: IDAT inflated (zlib checks the Adler-32) and the Up filter undone (filter 0, none, on
    /// an image one row high, as libpng writes it).
    static func samples(_ data: Data) throws -> [UInt8] {
        let all = try chunks(data)
        let ihdr = all[0].data
        let width = ihdr[0..<4].reduce(0) { $0 << 8 | Int($1) }, height = ihdr[4..<8].reduce(0) { $0 << 8 | Int($1) }
        #expect(Array(ihdr[8..<13]) == [8, 6, 0, 0, 0])
        let stream = all.filter { $0.type == "IDAT" }.flatMap(\.data)
        let stride = 1 + 4 * width
        var raw = [UInt8](repeating: 0, count: stride * height)
        var z = z_stream()
        try #require(inflateInit_(&z, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
        defer { inflateEnd(&z) }
        var status: Int32 = 0
        stream.withUnsafeBufferPointer { src in
            raw.withUnsafeMutableBufferPointer { dst in
                z.next_in = UnsafeMutablePointer(mutating: src.baseAddress!)
                z.avail_in = uInt(src.count)
                z.next_out = dst.baseAddress!
                z.avail_out = uInt(dst.count)
                status = inflate(&z, Z_FINISH)
            }
        }
        try #require(status == Z_STREAM_END, "inflate: \(status)") // Z_DATA_ERROR on a wrong Adler-32
        #expect(z.avail_in == 0 && z.avail_out == 0)
        var out = [UInt8](repeating: 0, count: 4 * width * height)
        for y in 0..<height {
            try #require(raw[y * stride] == (height == 1 ? 0 : 2), "row \(y) has filter \(raw[y * stride])")
            for x in 0..<(4 * width) {
                out[y * 4 * width + x] = raw[y * stride + 1 + x] &+ (y > 0 ? out[(y - 1) * 4 * width + x] : 0)
            }
        }
        return out
    }

    /// ImageIO's decode of the PNG, row by row, after checking it reads the whole file.
    static func decoded(_ data: Data) throws -> [UInt8] {
        let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetStatus(src) == .statusComplete)
        #expect(CGImageSourceGetStatusAtIndex(src, 0) == .statusComplete)
        let image = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let bytes = [UInt8](try #require(image.dataProvider?.data) as Data)
        let row = image.width * image.bitsPerPixel / 8
        return (0..<image.height).flatMap { bytes[($0 * image.bytesPerRow)..<($0 * image.bytesPerRow + row)] }
    }

    /// ParallelPNG's PNG of `image` against ImageIO's: same samples, same decode, same chunks besides the image data.
    func expectMatchesImageIO(_ image: CGImage, scale: CGFloat = 2, bands: Int? = nil) throws {
        let ours = try #require(ParallelPNG.encode(image, scale: scale, bands: bands))
        let theirs = try #require(PNGWriter.encodeWithImageIO(image, scale: scale))
        #expect(try Self.samples(ours) == Self.samples(theirs))
        #expect(try Self.decoded(ours) == Self.decoded(theirs))
        #expect(try Self.metadata(ours) == Self.metadata(theirs))
    }

    // MARK: Tests

    static let cases: [Case] = [
        Case(width: 1, height: 1, content: .noise, layout: .bgra, bands: nil),
        Case(width: 1, height: 1, content: .alphaNoise, layout: .bgra, bands: 3),
        Case(width: 1, height: 333, content: .noise, layout: .bgra, bands: 7),
        Case(width: 333, height: 1, content: .alphaNoise, layout: .rgba, bands: 4),
        Case(width: 17, height: 13, content: .alphaNoise, layout: .bgra, bands: 5),
        Case(width: 257, height: 191, content: .alphaNoise, layout: .bgra, bands: 16),
        Case(width: 640, height: 480, content: .gradient, layout: .bgra, bands: nil),
        Case(width: 640, height: 480, content: .flat, layout: .rgba, bands: 9),
        Case(width: 1000, height: 700, content: .noise, layout: .bgra, bands: nil),
        Case(width: 1000, height: 700, content: .window, layout: .bgra, bands: nil),
        Case(width: 900, height: 600, content: .window, layout: .rgba, bands: 13),
        // Rows wider than the 32 KB the next band looks back at; rows so narrow that it spans several bands.
        Case(width: 4000, height: 64, content: .noise, layout: .bgra, bands: 8),
        Case(width: 8, height: 4000, content: .noise, layout: .bgra, bands: 12),
    ]

    @Test(arguments: cases)
    func matchesImageIO(_ c: Case) throws {
        try expectMatchesImageIO(Self.image(c), bands: c.bands)
    }

    @Test func everyPremultipliedPairUnpremultipliesAsImageIODoes() throws {
        // Row = alpha, column = colour value, including colour > alpha (not valid premultiplied, but possible).
        var px = [UInt8](repeating: 0, count: 256 * 256 * 4)
        for a in 0..<256 {
            for c in 0..<256 {
                let i = (a * 256 + c) * 4
                px[i] = UInt8(c); px[i + 1] = UInt8(255 - c); px[i + 2] = UInt8(c / 2); px[i + 3] = UInt8(a)
            }
        }
        let image = CGImage(width: 256, height: 256, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 1024,
                            space: CGColorSpace(name: CGColorSpace.displayP3)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                            provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        try expectMatchesImageIO(image, bands: 8)
    }

    @Test func oneBandIsImageIOsFileByteForByte() throws {
        for image in [Self.image(width: 300, height: 200, content: .alphaNoise),
                      Self.image(width: 640, height: 480, content: .gradient, space: CGColorSpace(name: CGColorSpace.sRGB)!),
                      Self.image(width: 500, height: 400, content: .window, layout: .rgba),
                      Self.image(width: 333, height: 1, content: .alphaNoise), Self.image(width: 1, height: 1, content: .noise)] {
            #expect(ParallelPNG.encode(image, scale: 2, bands: 1, workers: 1) == PNGWriter.encodeWithImageIO(image, scale: 2))
        }
    }

    @Test func sameBytesWhicheverCoresTakeTheBands() async throws {
        let image = Self.image(width: 700, height: 500, content: .alphaNoise)
        let one = try #require(ParallelPNG.encode(image, scale: 2, bands: 11, workers: 1))
        #expect(ParallelPNG.encode(image, scale: 2, bands: 11, workers: 2) == one)
        #expect(ParallelPNG.encode(image, scale: 2, bands: 11, workers: 16) == one)
        // Several at once, as captures in quick succession are.
        let shared = SendableImage(image: image)
        let all = await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<6 { group.addTask { ParallelPNG.encode(shared.image, scale: 2, bands: 11) } }
            return await group.reduce(into: [Data?]()) { $0.append($1) }
        }
        #expect(all.count == 6 && all.allSatisfy { $0 == one })
    }

    struct SendableImage: @unchecked Sendable { let image: CGImage }

    @Test func colourSpacesAndScales() throws {
        var spaces: [(String, CGColorSpace)] = [
            ("sRGB", CGColorSpace(name: CGColorSpace.sRGB)!),
            ("Display P3", CGColorSpace(name: CGColorSpace.displayP3)!),
            ("Adobe RGB", CGColorSpace(name: CGColorSpace.adobeRGB1998)!),
            ("main display", CGDisplayCopyColorSpace(CGMainDisplayID())),
        ]
        // A profile only known by its bytes, as an external display's can be.
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData())
        spaces.append(("ICC data", try #require(CGColorSpace(iccData: p3))))
        for (name, space) in spaces {
            for scale in [1.0, 2.0, 3.0] {
                let image = Self.image(width: 300, height: 220, content: .alphaNoise, space: space)
                #expect(ParallelPNG.encode(image, scale: scale) != nil, "\(name) at \(scale)×")
                try expectMatchesImageIO(image, scale: scale, bands: 6)
            }
        }
    }

    @Test func leavesOtherFormatsToImageIO() throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        func context(_ bits: Int, _ info: UInt32, _ space: CGColorSpace = p3) throws -> CGImage {
            let ctx = try #require(CGContext(data: nil, width: 600, height: 400, bitsPerComponent: bits, bytesPerRow: 0, space: space, bitmapInfo: info))
            ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 0.7))
            ctx.fill(CGRect(x: 10, y: 10, width: 300, height: 200))
            return try #require(ctx.makeImage())
        }
        let straight = Self.image(width: 600, height: 400, content: .noise)
        let unpremultiplied = try #require(CGImage(
            width: 600, height: 400, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 2400, space: p3,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: straight.dataProvider!,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let others: [CGImage] = [
            try context(16, CGImageAlphaInfo.premultipliedLast.rawValue),
            try context(32, CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue,
                        CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!),
            try context(8, CGImageAlphaInfo.noneSkipLast.rawValue),
            try context(8, CGImageAlphaInfo.none.rawValue, CGColorSpaceCreateDeviceGray()),
            unpremultiplied,
        ]
        for image in others {
            #expect(ParallelPNG.encode(image, scale: 2) == nil)
            // PNGWriter still writes them, with ImageIO.
            #expect(try PNGWriter.encode(image, scale: 2) == PNGWriter.encodeWithImageIO(image, scale: 2))
        }
    }

    @Test func bandsCoverEveryRowOnce() {
        for (w, h, bands) in [(2940, 1912, nil), (7680, 4320, nil), (1, 1, nil), (8, 4000, 12), (100, 7, 50), (16000, 16000, nil)] as [(Int, Int, Int?)] {
            let layout = ParallelPNG.Layout(width: w, height: h, bands: bands)
            #expect(layout.count >= 1 && layout.count <= ParallelPNG.maxBands)
            let rows = (0..<layout.count).map { layout.rows(of: $0) }
            #expect(rows.first?.lowerBound == 0 && rows.last?.upperBound == h)
            #expect(zip(rows, rows.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound && !$1.isEmpty })
        }
        // A full Retina display of a 13" MacBook: bands of 22 rows, about 256 KB each.
        #expect(ParallelPNG.Layout(width: 2940, height: 1912).count == 87)
    }

    @Test func exifPixelSizeIsSetAsImageIOWouldWriteIt() throws {
        func exif(_ w: Int, _ h: Int) throws -> [UInt8] {
            let png = try #require(PNGWriter.encodeWithImageIO(makeImage(width: w, height: h), scale: 2))
            return try #require(try Self.chunks(png).first { $0.type == "eXIf" }).data
        }
        var one = try exif(1, 1)
        #expect(ParallelPNG.Metadata.setPixelSize(in: &one, width: 2940, height: 1912))
        #expect(one == (try exif(2940, 1912)))
        // Anything but a 1 × 1 crop's, as ImageIO lays it out, is refused.
        var again = one
        #expect(!ParallelPNG.Metadata.setPixelSize(in: &again, width: 10, height: 10))
        var empty: [UInt8] = []
        #expect(!ParallelPNG.Metadata.setPixelSize(in: &empty, width: 10, height: 10))
        var notTIFF = [UInt8](repeating: 0, count: 64)
        #expect(!ParallelPNG.Metadata.setPixelSize(in: &notTIFF, width: 10, height: 10))
    }
}
