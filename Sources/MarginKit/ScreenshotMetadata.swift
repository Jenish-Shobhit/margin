import CoreGraphics
import Foundation

/// The Spotlight attributes macOS's own screenshots carry. `screencapture` writes them as extended attributes
/// (`com.apple.metadata:<name>`, each a binary plist), and Finder's and Spotlight's screenshot searches use them.
public struct ScreenshotMetadata: Sendable, Equatable {
    /// `kMDItemScreenCaptureType`.
    public enum Kind: String, Sendable { case selection, window, display }

    public var kind: Kind
    /// Where the shot was, in global points with a top-left origin, like `screencapture -R`.
    public var globalRect: CGRect

    public init(kind: Kind, globalRect: CGRect) {
        self.kind = kind
        self.globalRect = globalRect
    }

    /// Attribute name → binary plist value.
    public var attributes: [String: Data] {
        func plist(_ value: Any) -> Data {
            (try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)) ?? Data()
        }
        let r = globalRect.standardized
        return [
            "com.apple.metadata:kMDItemIsScreenCapture": plist(true),
            "com.apple.metadata:kMDItemScreenCaptureType": plist(kind.rawValue),
            "com.apple.metadata:kMDItemScreenCaptureGlobalRect": plist([r.minX, r.minY, r.width, r.height].map(Double.init)),
        ]
    }

    /// Best effort: a volume without extended attributes just gets a plain PNG.
    public func apply(to url: URL) {
        for (name, value) in attributes {
            _ = value.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, $0.count, 0, 0) }
        }
    }
}
