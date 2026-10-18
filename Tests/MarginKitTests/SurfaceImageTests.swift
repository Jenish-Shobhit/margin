import CoreGraphics
import Foundation
import IOSurface
@testable import MarginKit
import Testing

@Suite struct SurfaceImageTests {
    static let bgra = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// An image laid out as ScreenCaptureKit's are: a data provider over BGRA bytes, rows `stride` apart.
    func capturedImage(width: Int, height: Int, stride: Int? = nil,
                       space: CGColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!) -> CGImage {
        let stride = stride ?? width * 4
        var bytes = [UInt8](repeating: 0, count: stride * height)
        for y in 0..<height {
            for x in 0..<width {
                // Premultiplied: no channel above alpha.
                let o = y * stride + x * 4, a = 255 - (x * 3 + y) % 64
                bytes[o] = UInt8((x * 7 + y) % (a + 1))
                bytes[o + 1] = UInt8((y * 5 ^ x) % (a + 1))
                bytes[o + 2] = UInt8((x ^ y) % (a + 1))
                bytes[o + 3] = UInt8(a)
            }
            for p in (y * stride + width * 4)..<((y + 1) * stride) { bytes[p] = 0xAB } // row padding
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: Self.bgra), provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)!
    }

    /// The pixel bytes, row by row, without padding.
    func rows(_ image: CGImage) throws -> [UInt8] {
        let data = try #require(image.dataProvider?.data) as Data
        var out: [UInt8] = []
        for y in 0..<image.height {
            out += data[(y * image.bytesPerRow)..<(y * image.bytesPerRow + image.width * 4)]
        }
        return out
    }

    @Test(arguments: [(97, 61, nil), (640, 400, 640 * 4 + 64), (1, 1, nil), (300, 7, 300 * 4 + 4)] as [(Int, Int, Int?)])
    func copiesTheSameBytesLayoutAndColourSpace(width: Int, height: Int, stride: Int?) throws {
        let source = capturedImage(width: width, height: height, stride: stride)
        let copy = try #require(SurfaceImage.copy(of: source)?.image)
        #expect(copy.width == width && copy.height == height)
        #expect(copy.bitsPerComponent == 8 && copy.bitsPerPixel == 32)
        #expect(copy.bitmapInfo == source.bitmapInfo)
        #expect(copy.colorSpace == source.colorSpace)
        #expect(try rows(copy) == rows(source))
    }

    @Test func keepsAnICCProfileSpace() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData())
        let icc = try #require(CGColorSpace(iccData: p3))
        let source = capturedImage(width: 120, height: 80, space: icc)
        let copy = try #require(SurfaceImage.copy(of: source)?.image)
        #expect(copy.colorSpace?.copyICCData() as Data? == p3 as Data)
        #expect(try rows(copy) == rows(source))
    }

    @Test(arguments: [1, 3, 4, 16])
    func anyBandCountGivesTheSameCopy(bands: Int) throws {
        let source = capturedImage(width: 211, height: 157, stride: 211 * 4 + 12)
        let copy = try #require(SurfaceImage.copy(of: source, bands: bands)?.image)
        #expect(try rows(copy) == rows(source))
    }

    @Test func otherLayoutsAreLeftAlone() {
        // RGBA, premultiplied last: not ScreenCaptureKit's.
        #expect(SurfaceImage.copy(of: makeImage(width: 16, height: 16)) == nil)
        let gray = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!.makeImage()!
        #expect(SurfaceImage.copy(of: gray) == nil)
    }

    @Test func theCopyOutlivesItsSource() throws {
        var source: CGImage? = capturedImage(width: 64, height: 32)
        let original = try #require(source)
        let expected = try rows(original)
        let copy = try #require(SurfaceImage.copy(of: original)?.image)
        source = nil
        #expect(try rows(copy) == expected)
    }

    @Test func discardEmptiesTheSurfaceLater() async throws {
        let copy = try #require(SurfaceImage.copy(of: capturedImage(width: 64, height: 32)))
        var state: UInt32 = 0
        let keepCurrent: UInt32 = 3 // kIOSurfacePurgeableKeepCurrent: only reads the state
        IOSurfaceSetPurgeable(copy.surface, keepCurrent, &state)
        #expect(state == 0) // kIOSurfacePurgeableNonVolatile
        SurfaceImage.discard(copy.surface, after: 0.2)
        IOSurfaceSetPurgeable(copy.surface, keepCurrent, &state)
        #expect(state == 0) // not yet
        // Utility QoS: under a busy test run it can take a while.
        for _ in 0..<100 where state != SurfaceImage.purgeableEmpty {
            try await Task.sleep(for: .milliseconds(50))
            IOSurfaceSetPurgeable(copy.surface, keepCurrent, &state)
        }
        #expect(state == SurfaceImage.purgeableEmpty)
    }
}
