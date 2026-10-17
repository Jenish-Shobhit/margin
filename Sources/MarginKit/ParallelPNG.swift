import Accelerate
import CoreGraphics
import Foundation
import Synchronization
import zlib

/// The PNG `PNGWriter` writes, deflated on several cores at once.
///
/// ImageIO's PNG encoder is zlib at level 1 on one thread, and deflate is nearly all of its time (156 of 159 ms for a
/// busy 2940 × 1912 shot). This writes the same file the way pigz does: the Up-filtered rows are cut into bands, each
/// band is deflated on a core of its own as a raw stream primed with the previous band's last 32 KB and ended on a byte
/// boundary (a sync flush), and the bands join into one zlib stream whose Adler-32 is combined from theirs.
///
/// Everything else is ImageIO's, so a decoder sees the same pixels and the same metadata:
/// - the chunks before the image data (iCCP or sRGB, cICP, eXIf, pHYs) are the ones ImageIO writes for a 1 × 1 crop
///   of the image with the same options, with the eXIf's pixel size set to the image's;
/// - samples are unpremultiplied by vImage, which rounds as ImageIO does (all 65 536 colour and alpha pairs agree);
/// - every row uses the Up filter, the zlib level is 1 and the image data is cut into 16 KB IDAT chunks.
///
/// Each band boundary costs a few bytes, so files are within a fraction of a percent of ImageIO's; with one band the
/// file is ImageIO's, byte for byte.
enum ParallelPNG {
    /// Filtered bytes per band (a full 2940 × 1912 display makes 86): enough bands that the slower efficiency cores
    /// take fewer of them (bands go to whichever core is free), few enough that their fixed costs don't show.
    static let bandBytes = 256 * 1024
    static let maxBands = 128
    /// Cores to deflate on.
    static let workers = ProcessInfo.processInfo.activeProcessorCount

    /// Worth it from two bands' worth of rows (about 360 × 360 pixels); ImageIO alone is as fast below that.
    static func isWorthIt(_ image: CGImage) -> Bool {
        image.height * (1 + 4 * image.width) >= 2 * bandBytes
    }

    /// The PNG, or nil when this image isn't one it writes as ImageIO would: anything but 8-bit premultiplied RGB with
    /// alpha (16-bit, float, opaque or straight-alpha layouts, other colour models), or if ImageIO's chunks for it
    /// aren't the ones it knows. `bands` overrides the band count (tests).
    static func encode(_ image: CGImage, scale: CGFloat, bands: Int? = nil, workers: Int = workers) -> Data? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              image.alphaInfo == .premultipliedFirst || image.alphaInfo == .premultipliedLast,
              let space = image.colorSpace, space.model == .rgb, space.supportsOutput,
              let metadata = Metadata(of: image, scale: scale)
        else { return nil }
        let layout = Layout(width: width, height: height, bands: bands)
        guard layout.rowsPerBand * layout.stride < Int(UInt32.max / 2) else { return nil }

        let results = Bands(count: layout.count)
        defer { results.deallocate() }
        let next = Atomic<Int>(0)
        DispatchQueue.concurrentPerform(iterations: max(1, min(workers, layout.count))) { _ in
            guard let worker = Worker(layout) else { return }
            while true {
                let k = next.wrappingAdd(1, ordering: .relaxed).oldValue
                guard k < layout.count else { return }
                results.buffer[k] = worker.compress(band: k, of: image, space: space)
            }
        }
        // A worker that couldn't start leaves its bands to the others; one that failed a band leaves it empty.
        guard next.load(ordering: .relaxed) >= layout.count, results.buffer.allSatisfy(\.ok) else { return nil }
        return assemble(metadata, layout, results.buffer)
    }

    // MARK: Layout

    struct Layout {
        let width, height, stride, rowsPerBand, count, dictionaryRows: Int

        init(width: Int, height: Int, bands: Int? = nil) {
            self.width = width
            self.height = height
            stride = 1 + 4 * width
            var rows = max(1, ParallelPNG.bandBytes / stride)
            if let bands { rows = (height + max(1, min(bands, height)) - 1) / max(1, min(bands, height)) }
            if (height + rows - 1) / rows > ParallelPNG.maxBands { rows = (height + ParallelPNG.maxBands - 1) / ParallelPNG.maxBands }
            rowsPerBand = rows
            count = (height + rows - 1) / rows
            // deflate looks back at most 32 KB: the rows that cover it.
            dictionaryRows = (32768 + stride - 1) / stride
        }

        func rows(of band: Int) -> Range<Int> { (band * rowsPerBand)..<min(height, (band + 1) * rowsPerBand) }
    }

    /// Each band's result, written by whichever worker took it (one writer per slot) and read once they're all done.
    struct Bands: @unchecked Sendable {
        let buffer: UnsafeMutableBufferPointer<Band>

        init(count: Int) {
            buffer = .allocate(capacity: count)
            buffer.initialize(repeating: Band())
        }

        func deallocate() {
            for band in buffer { band.bytes?.deallocate() }
            buffer.deallocate()
        }
    }

    /// One band's deflated bytes and the Adler-32 of what went in.
    struct Band {
        var bytes: UnsafeMutablePointer<UInt8>?
        var count = 0
        var adler: UInt = 1
        var inputLength = 0
        var ok = false
    }

    // MARK: A worker

    /// One core's buffers and deflate stream, reused for every band it takes.
    final class Worker {
        let layout: Layout
        let bytesPerRow: Int
        let pixels: UnsafeMutableRawPointer
        let filtered: UnsafeMutablePointer<UInt8>
        let zeroRow: UnsafeMutablePointer<UInt8>
        /// zlib's state points back at its stream, so the stream must not move.
        let stream: UnsafeMutablePointer<z_stream>

        init?(_ layout: Layout) {
            self.layout = layout
            bytesPerRow = 4 * layout.width
            stream = .allocate(capacity: 1)
            stream.initialize(to: z_stream())
            guard deflateInit2_(stream, 1, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                                Int32(MemoryLayout<z_stream>.size)) == Z_OK
            else {
                stream.deallocate()
                return nil
            }
            pixels = .allocate(byteCount: (layout.rowsPerBand + layout.dictionaryRows + 1) * bytesPerRow, alignment: 64)
            filtered = .allocate(capacity: max(layout.rowsPerBand, layout.dictionaryRows) * layout.stride)
            zeroRow = .allocate(capacity: bytesPerRow)
            zeroRow.initialize(repeating: 0, count: bytesPerRow)
        }

        deinit {
            deflateEnd(stream)
            stream.deallocate()
            pixels.deallocate()
            filtered.deallocate()
            zeroRow.deallocate()
        }

        func compress(band k: Int, of image: CGImage, space: CGColorSpace) -> Band {
            let rows = layout.rows(of: k)
            let last = rows.upperBound == layout.height
            let dictionaryRows = k == 0 ? 0 : layout.dictionaryRows
            // Straight RGBA for the band's rows, the row above them and the rows the dictionary is made of.
            let first = max(0, rows.lowerBound - dictionaryRows - 1)
            guard fill(first..<rows.upperBound, from: image, space: space), deflateReset(stream) == Z_OK else { return Band() }

            if dictionaryRows > 0 {
                let from = max(0, rows.lowerBound - dictionaryRows)
                for row in from..<rows.lowerBound { filter(row, firstFilled: first, into: filtered + (row - from) * layout.stride) }
                let length = min(32768, (rows.lowerBound - from) * layout.stride)
                let end = filtered + (rows.lowerBound - from) * layout.stride
                guard deflateSetDictionary(stream, end - length, uInt(length)) == Z_OK else { return Band() }
            }
            for row in rows { filter(row, firstFilled: first, into: filtered + (row - rows.lowerBound) * layout.stride) }
            let length = rows.count * layout.stride
            var band = Band()
            band.inputLength = length
            band.adler = adler32(1, filtered, uInt(length))

            var capacity = Int(deflateBound(stream, uLong(length))) + 64
            var out = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            stream.pointee.next_in = filtered
            stream.pointee.avail_in = uInt(length)
            let flush = last ? Z_FINISH : Z_SYNC_FLUSH
            var produced = 0
            while true {
                stream.pointee.next_out = out + produced
                stream.pointee.avail_out = uInt(capacity - produced)
                let status = deflate(stream, flush)
                produced = capacity - Int(stream.pointee.avail_out)
                if status == Z_STREAM_END || (!last && status == Z_OK && stream.pointee.avail_out > 0) { break }
                guard status == Z_OK || status == Z_BUF_ERROR else {
                    out.deallocate()
                    return Band()
                }
                // Out of room (incompressible rows): grow and go on.
                let bigger = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity * 2)
                bigger.update(from: out, count: produced)
                out.deallocate()
                out = bigger
                capacity *= 2
            }
            band.bytes = out
            band.count = produced
            band.ok = true
            return band
        }

        /// Draws `rows` of the image into `pixels` (copying, in its own colour space: no colour matching), then
        /// unpremultiplies and reorders BGRA to RGBA.
        private func fill(_ rows: Range<Int>, from image: CGImage, space: CGColorSpace) -> Bool {
            let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            guard let ctx = CGContext(data: pixels, width: layout.width, height: rows.count, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: space, bitmapInfo: info)
            else { return false }
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .none
            // The context's bottom row is image row rows.upperBound - 1.
            ctx.draw(image, in: CGRect(x: 0, y: rows.upperBound - layout.height, width: layout.width, height: layout.height))
            var buffer = vImage_Buffer(data: pixels, height: vImagePixelCount(rows.count), width: vImagePixelCount(layout.width),
                                       rowBytes: bytesPerRow)
            let flags = vImage_Flags(kvImageDoNotTile)
            return vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, flags) == kvImageNoError
                && vImagePermuteChannels_ARGB8888(&buffer, &buffer, [2, 1, 0, 3], flags) == kvImageNoError
        }

        /// Row `row` with the Up filter: a filter byte of 2, then each byte minus the one above it (zeros above row 0).
        private func filter(_ row: Int, firstFilled: Int, into out: UnsafeMutablePointer<UInt8>) {
            let base = pixels.assumingMemoryBound(to: UInt8.self)
            let current = base + (row - firstFilled) * bytesPerRow
            let above = row == 0 ? UnsafePointer(zeroRow) : UnsafePointer(base + (row - 1 - firstFilled) * bytesPerRow)
            out[0] = 2
            let dst = UnsafeMutableRawPointer(out + 1)
            var i = 0
            while i + 16 <= bytesPerRow {
                let a = UnsafeRawPointer(current + i).loadUnaligned(as: SIMD16<UInt8>.self)
                let b = UnsafeRawPointer(above + i).loadUnaligned(as: SIMD16<UInt8>.self)
                dst.storeBytes(of: a &- b, toByteOffset: i, as: SIMD16<UInt8>.self)
                i += 16
            }
            while i < bytesPerRow {
                out[1 + i] = current[i] &- above[i]
                i += 1
            }
        }
    }

    // MARK: The file

    /// Signature, IHDR, ImageIO's chunks, the zlib stream in 16 KB IDAT chunks, IEND.
    private static func assemble(_ metadata: Metadata, _ layout: Layout, _ bands: UnsafeMutableBufferPointer<Band>) -> Data {
        var adler = adler32(0, nil, 0)
        for band in bands { adler = adler32_combine(adler, band.adler, band.inputLength) }
        let header: [UInt8] = [0x78, 0x01] // deflate, 32 KB window, level 1: what ImageIO writes
        let trailer: [UInt8] = [UInt8(truncatingIfNeeded: adler >> 24), UInt8(truncatingIfNeeded: adler >> 16),
                                UInt8(truncatingIfNeeded: adler >> 8), UInt8(truncatingIfNeeded: adler)]
        let streamLength = header.count + bands.reduce(0) { $0 + $1.count } + trailer.count
        let idatSize = 16384
        let idatCount = (streamLength + idatSize - 1) / idatSize
        let size = 8 + (12 + 13) + metadata.chunks.reduce(0) { $0 + 12 + $1.data.count } + idatCount * 12 + streamLength + 12
        let w = layout.width, h = layout.height
        let ihdr: [UInt8] = [UInt8(truncatingIfNeeded: w >> 24), UInt8(truncatingIfNeeded: w >> 16), UInt8(truncatingIfNeeded: w >> 8),
                             UInt8(truncatingIfNeeded: w), UInt8(truncatingIfNeeded: h >> 24), UInt8(truncatingIfNeeded: h >> 16),
                             UInt8(truncatingIfNeeded: h >> 8), UInt8(truncatingIfNeeded: h)] + metadata.ihdrTail

        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            var out = Writer(base: raw.bindMemory(to: UInt8.self).baseAddress!)
            out.put([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            out.chunk("IHDR", ihdr)
            for chunk in metadata.chunks { out.chunk(chunk.type, chunk.data) }
            header.withUnsafeBufferPointer { head in
                trailer.withUnsafeBufferPointer { tail in
                    var pieces: [UnsafeBufferPointer<UInt8>] = [head]
                    for band in bands where band.count > 0 { pieces.append(UnsafeBufferPointer(start: UnsafePointer(band.bytes), count: band.count)) }
                    pieces.append(tail)
                    var piece = 0, offset = 0, left = streamLength
                    while left > 0 {
                        let length = min(idatSize, left)
                        out.put32(length)
                        let start = out.at
                        out.put(Array("IDAT".utf8))
                        var need = length
                        while need > 0 {
                            let take = min(need, pieces[piece].count - offset)
                            (out.base + out.at).update(from: pieces[piece].baseAddress! + offset, count: take)
                            out.at += take
                            offset += take
                            need -= take
                            if offset == pieces[piece].count { piece += 1; offset = 0 }
                        }
                        out.crc(from: start)
                        left -= length
                    }
                }
            }
            out.chunk("IEND", [])
            precondition(out.at == size)
        }
        return data
    }

    private struct Writer {
        let base: UnsafeMutablePointer<UInt8>
        var at = 0

        mutating func put(_ bytes: [UInt8]) {
            for b in bytes { base[at] = b; at += 1 }
        }

        mutating func put32(_ v: Int) {
            put([UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)])
        }

        /// The CRC-32 of everything since `start` (the chunk's type and data).
        mutating func crc(from start: Int) {
            put32(Int(crc32(0, base + start, uInt(at - start))))
        }

        mutating func chunk(_ type: String, _ data: [UInt8]) { chunk(Array(type.utf8), data) }

        mutating func chunk(_ type: [UInt8], _ data: [UInt8]) {
            put32(data.count)
            let start = at
            put(type)
            put(data)
            crc(from: start)
        }
    }

    // MARK: ImageIO's chunks

    /// What ImageIO writes for this image besides the pixels, taken from its PNG of the image's top-left pixel.
    struct Metadata {
        /// IHDR after the size: bit depth, colour type, compression, filter and interlace methods.
        let ihdrTail: [UInt8]
        /// The chunks between IHDR and the image data, in order.
        let chunks: [(type: [UInt8], data: [UInt8])]

        /// Chunks that don't depend on the pixels or (but for eXIf's, set here) on the size.
        static let known: Set<String> = ["iCCP", "sRGB", "cICP", "pHYs", "gAMA", "cHRM", "eXIf"]

        init?(of image: CGImage, scale: CGFloat) {
            guard let pixel = image.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)),
                  let png = PNGWriter.encodeWithImageIO(pixel, scale: scale)
            else { return nil }
            let b = [UInt8](png)
            guard b.count > 8, b[0..<8].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { return nil }
            var i = 8
            var tail: [UInt8]?
            var chunks: [(type: [UInt8], data: [UInt8])] = []
            var sawData = false, sawEnd = false
            while i + 12 <= b.count, !sawEnd {
                let n = b[i..<(i + 4)].reduce(0) { $0 << 8 | Int($1) }
                guard n <= b.count - i - 12 else { return nil }
                let type = Array(b[(i + 4)..<(i + 8)])
                var data = Array(b[(i + 8)..<(i + 8 + n)])
                switch String(decoding: type, as: UTF8.self) {
                case "IHDR":
                    guard tail == nil, n == 13, data[0..<8].elementsEqual([0, 0, 0, 1, 0, 0, 0, 1]) else { return nil }
                    tail = Array(data[8..<13])
                case "IDAT":
                    sawData = true
                case "IEND":
                    sawEnd = true
                case let name:
                    // Anything else, or anything after the image data, might depend on what this doesn't copy.
                    guard tail != nil, !sawData, Self.known.contains(name) else { return nil }
                    if name == "eXIf" {
                        guard Self.setPixelSize(in: &data, width: image.width, height: image.height) else { return nil }
                    }
                    chunks.append((type, data))
                }
                i += 12 + n
            }
            // 8-bit RGBA, deflate, filter method 0, not interlaced: what the encoder writes.
            guard let tail, tail == [8, 6, 0, 0, 0], sawData, sawEnd else { return nil }
            ihdrTail = tail
            self.chunks = chunks
        }

        /// Sets the Exif IFD's PixelXDimension and PixelYDimension, 1 in the 1 × 1 crop's, to the image's size.
        /// Fails on any other layout than ImageIO's: a TIFF header, IFD0 without a size of its own, and the two as
        /// LONGs in the Exif IFD.
        static func setPixelSize(in d: inout [UInt8], width: Int, height: Int) -> Bool {
            guard d.count >= 8 else { return false }
            let big: Bool
            switch (d[0], d[1]) {
            case (0x4D, 0x4D): big = true
            case (0x49, 0x49): big = false
            default: return false
            }
            func u16(_ o: Int) -> Int? {
                guard o >= 0, o + 2 <= d.count else { return nil }
                return big ? Int(d[o]) << 8 | Int(d[o + 1]) : Int(d[o + 1]) << 8 | Int(d[o])
            }
            func u32(_ o: Int) -> Int? {
                guard o >= 0, o + 4 <= d.count else { return nil }
                let bytes = big ? [d[o], d[o + 1], d[o + 2], d[o + 3]] : [d[o + 3], d[o + 2], d[o + 1], d[o]]
                return bytes.reduce(0) { $0 << 8 | Int($1) }
            }
            /// (tag, type, count, offset of the value) for each entry of the IFD at `offset`.
            func entries(_ offset: Int) -> [(tag: Int, type: Int, count: Int, value: Int)]? {
                guard let n = u16(offset), offset + 2 + 12 * n <= d.count else { return nil }
                return (0..<n).compactMap { k in
                    let e = offset + 2 + 12 * k
                    guard let tag = u16(e), let type = u16(e + 2), let count = u32(e + 4) else { return nil }
                    return (tag, type, count, e + 8)
                }
            }
            guard u16(2) == 42, let ifd0 = u32(4), let main = entries(ifd0),
                  !main.contains(where: { $0.tag == 0x0100 || $0.tag == 0x0101 }), // ImageWidth, ImageLength
                  let pointer = main.first(where: { $0.tag == 0x8769 }), let exifOffset = u32(pointer.value),
                  let exif = entries(exifOffset)
            else { return false }
            let sizes = exif.filter { $0.tag == 0xA002 || $0.tag == 0xA003 }
            guard sizes.count == 2, sizes.allSatisfy({ $0.type == 4 && $0.count == 1 && u32($0.value) == 1 }) else { return false }
            for entry in sizes {
                let v = UInt32(entry.tag == 0xA002 ? width : height)
                let bytes = [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
                for k in 0..<4 { d[entry.value + k] = big ? bytes[k] : bytes[3 - k] }
            }
            return true
        }
    }
}
