#if DEBUG
import CoreGraphics

/// Fakes for exercising the multi-display freeze (partial success, a stalled display) on a machine with one
/// display. DEBUG builds only, set by a temporary test harness; empty, and so inert, otherwise.
@MainActor
enum CaptureSimulation {
    /// Extra displays appended to `Displays.all` (AppKit global points, e.g. right of the real one). Their
    /// overlay panels sit off-screen, and ScreenCaptureKit doesn't list them.
    static var extraDisplays: [DisplayInfo] = []
    /// Replaces a display's freeze capture.
    static var faults: [CGDirectDisplayID: CaptureFault] = [:]
}

/// What a display's freeze capture does instead of calling ScreenCaptureKit.
enum CaptureFault: Sendable {
    /// Throws `error` after `delay`.
    case fail(any Error, after: Duration)
    /// Doesn't answer for a minute.
    case stall
    /// Returns `image` after `delay`.
    case frame(SendableImage, after: Duration)

    func perform() async throws -> SendableImage {
        switch self {
        case let .fail(error, delay):
            try await Task.sleep(for: delay)
            throw error
        case .stall:
            try await Task.sleep(for: .seconds(60))
            throw CaptureError.noImage
        case let .frame(image, delay):
            try await Task.sleep(for: delay)
            return image
        }
    }
}
#endif
