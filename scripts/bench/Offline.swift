import AppKit
import ImageIO
import UniformTypeIdentifiers

// Offline measurements: no Margin process, no screen. They call MarginKit's own code (compiled in by bench.sh).

enum Offline {
    static func ms(_ start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    static func timed(_ runs: Int, _ body: () -> Void) -> (median: Double, p90: Double) {
        var times: [Double] = []
        for _ in 0..<runs {
            let t = ContinuousClock.now
            body()
            times.append(ms(t))
        }
        times.sort()
        return (Stats.quantile(times, 0.5), Stats.quantile(times, 0.9))
    }

    /// The image as ScreenCaptureKit hands it over: 8-bit BGRA, premultiplied first, little-endian, decoded.
    static func capturedImage(_ path: String) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    static func encode(_ image: CGImage, filter: Int32?) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144]
        if let filter { props[kCGImagePropertyPNGDictionary] = [kCGImagePropertyPNGCompressionFilter: filter] }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    /// The shelf card's thumbnail from a PNG file's bytes, as `ShelfThumbnails.load` makes it at launch.
    static func thumbnail(_ data: Data) {
        let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)!
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: 352,
        ]
        _ = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Every PNG filter choice on each image: encode time, size, and the launch thumbnail's decode time.
    static func encode(_ paths: [String]) {
        guard !paths.isEmpty else { fail("encode <png>…") }
        let filters: [(String, Int32?)] = [
            ("none (Margin today)", IMAGEIO_PNG_FILTER_NONE), ("ImageIO default", nil), ("sub", IMAGEIO_PNG_FILTER_SUB),
            ("up", IMAGEIO_PNG_FILTER_UP), ("paeth", IMAGEIO_PNG_FILTER_PAETH), ("sub+up (fast adaptive)", IMAGEIO_PNG_FILTER_SUB | IMAGEIO_PNG_FILTER_UP),
            ("all five (adaptive)", 0xF8), ("no filters key 0", IMAGEIO_PNG_NO_FILTERS),
        ]
        print("image                          filter               encode med   p90     size KB   thumb decode med")
        for path in paths {
            guard let image = capturedImage(path) else { say("can't read \(path)"); continue }
            let name = "\(URL(fileURLWithPath: path).lastPathComponent.prefix(22)) \(image.width)×\(image.height)"
            for (label, filter) in filters {
                var data = Data()
                let t = timed(5) { data = encode(image, filter: filter) }
                let d = timed(5) { thumbnail(data) }
                print(String(format: "%-30@ %-20@ %8.1f %8.1f %9.0f %12.1f", name as NSString, label as NSString,
                             t.median, t.p90, Double(data.count) / 1024, d.median))
            }
            // PNGWriter itself (what the app runs), and the clipboard write of its bytes on a private pasteboard.
            var png = Data()
            let w = timed(5) { png = (try? PNGWriter.encode(image, scale: 2)) ?? Data() }
            let pb = NSPasteboard(name: NSPasteboard.Name("margin-bench-\(UUID().uuidString)"))
            let c = MainActor.assumeIsolated { timed(5) { ClipboardWriter.write(pngs: [png], fileURLs: [URL(fileURLWithPath: "/tmp/x.png")], to: pb) } }
            pb.releaseGlobally()
            print(String(format: "%-30@ %-20@ %8.1f %8.1f %9.0f   clipboard write %.1f ms (p90 %.1f)", name as NSString,
                         "PNGWriter.encode" as NSString, w.median, w.p90, Double(png.count) / 1024, c.median, c.p90))
        }
    }

    /// Small steps the main thread takes per capture or at launch, run here in isolation.
    @MainActor
    static func micro() {
        func row(_ label: String, _ r: (median: Double, p90: Double)) {
            print(String(format: "%-58@ median %8.3f ms   p90 %8.3f ms", label as NSString, r.median, r.p90))
        }
        row("ShutterSound.uiSoundsEnabled (CFPreferencesAppSynchronize)", timed(200) { _ = ShutterSound.uiSoundsEnabled })
        // As a capture sees it: once, after a while of nothing (the cache may have gone cold).
        var cold: [Double] = []
        for _ in 0..<10 {
            usleep(500_000)
            let t = ContinuousClock.now
            _ = ShutterSound.uiSoundsEnabled
            cold.append(ms(t))
        }
        cold.sort()
        row("  … once after 0.5 s idle (10×)", (Stats.quantile(cold, 0.5), Stats.quantile(cold, 0.9)))
        row("FileNamer.fileName (a DateFormatter per call)", timed(500) { _ = FileNamer.fileName(for: Date()) })
        let reserved: Set<String> = []
        row("FileNamer.uniqueURL against the in-memory set", timed(500) {
            _ = FileNamer.uniqueURL(in: URL(fileURLWithPath: "/tmp"), for: Date()) { reserved.contains($0.path) }
        })
        row("CGPreflightScreenCaptureAccess", timed(50) { _ = CGPreflightScreenCaptureAccess() })

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margin-bench-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shot = dir.appendingPathComponent("shot.png")
        FileManager.default.createFile(atPath: shot.path, contents: Data([0]))
        for count in [10, 50, 200] {
            let store = ShelfStore(fileURL: dir.appendingPathComponent("shelf-\(count).json"))
            for i in 0..<count {
                store.append(ShelfItem(url: shot, createdAt: Date().addingTimeInterval(Double(i)), pixelSize: CGSize(width: 2940, height: 1912)))
            }
            var bytes = 0
            store.didSave = { _, b in bytes = b }
            let r = timed(50) { store.save() }
            row("ShelfStore.save, \(count) cards (\(bytes / 1024) KB)", r)
            row("ShelfStore.load, \(count) cards", timed(20) { store.load() })
        }
        let pb = NSPasteboard(name: NSPasteboard.Name("margin-bench-\(UUID().uuidString)"))
        for mb in [1, 4, 12] {
            let data = Data(count: mb * 1_048_576)
            row("ClipboardWriter.write, \(mb) MB PNG + file URL (private pasteboard)", timed(10) {
                ClipboardWriter.write(pngs: [data], fileURLs: [shot], to: pb)
            })
        }
        pb.releaseGlobally()
    }

    /// `count` cards on one busy 2940×1912 PNG (APFS clones), with real bookmarks, in `dir`/shelf.json.
    @MainActor
    static func makeShelf(dir: URL, count: Int) {
        let shots = dir.appendingPathComponent("shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let master = shots.appendingPathComponent("master.png")
        if !FileManager.default.fileExists(atPath: master.path) {
            let image = makePhoto(width: 2940, height: 1912)
            guard let data = try? PNGWriter.encode(image, scale: 2) else { fail("encode failed") }
            try? data.write(to: master)
        }
        let store = ShelfStore(fileURL: dir.appendingPathComponent("shelf.json"))
        try? FileManager.default.removeItem(at: store.fileURL)
        let base = Date().addingTimeInterval(-Double(count) * 60)
        for i in 0..<count {
            let url = shots.appendingPathComponent(String(format: "Screenshot %03d.png", i))
            if !FileManager.default.fileExists(atPath: url.path), clonefile(master.path, url.path, 0) != 0 {
                try? FileManager.default.copyItem(at: master, to: url)
            }
            store.append(ShelfItem(url: url, createdAt: base.addingTimeInterval(Double(i) * 60), pixelSize: CGSize(width: 2940, height: 1912)))
        }
        print("\(store.fileURL.path): \(count) cards")
    }
}
