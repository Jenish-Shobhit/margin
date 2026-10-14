import Foundation
import MarginKit
import Testing

@Suite struct ScreenshotMetadataTests {
    /// Reads one `com.apple.metadata:` attribute back as a property list value.
    private func read(_ name: String, at url: URL) -> Any? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let n = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
        guard n == size else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    @Test func writtenFileCarriesTheScreenshotAttributes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("margin-meta-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let meta = ScreenshotMetadata(kind: .selection, globalRect: CGRect(x: 10, y: 20, width: 50, height: 60))
        let url = folder.appendingPathComponent("shot.png")
        try PNGWriter.writeAtomically(Data([0x89, 0x50]), to: url, metadata: meta)

        #expect(read("com.apple.metadata:kMDItemIsScreenCapture", at: url) as? Bool == true)
        #expect(read("com.apple.metadata:kMDItemScreenCaptureType", at: url) as? String == "selection")
        #expect(read("com.apple.metadata:kMDItemScreenCaptureGlobalRect", at: url) as? [Double] == [10, 20, 50, 60])

        let unique = try PNGWriter.writeUnique(Data([0x89]), in: folder, date: Date(), metadata: ScreenshotMetadata(kind: .display, globalRect: .zero))
        #expect(read("com.apple.metadata:kMDItemScreenCaptureType", at: unique) as? String == "display")
    }

    @Test func noMetadataLeavesAPlainFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("margin-meta-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("plain.png")
        try PNGWriter.writeAtomically(Data([0x89]), to: url)
        #expect(read("com.apple.metadata:kMDItemIsScreenCapture", at: url) == nil)
    }
}
