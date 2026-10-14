import AppKit
import MarginKit

/// STUB — replaced by the Capture agent. Keep the class name and `init()`.
@MainActor
final class CaptureController: CaptureControlling {
    var onCapture: ((CaptureResult) -> Void)?
    var onPermissionMissing: (() -> Void)?
    private(set) var isCapturing = false

    init() {}

    func prewarm() async {}
    func beginInteractiveCapture() {}
    func captureScreenUnderPointer() {}
    func repeatLastArea() {}
    func captureArea(_ rect: CGRect) {}
}
