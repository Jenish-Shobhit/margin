#if DEBUG
import AppKit
import MarginKit

/// Faults for the recording under way (spec §14.4), for the control hook (`DebugCommandListener`, `scripts/debug.sh`),
/// to see what each failure leaves behind without a broken disk or encoder:
///   recording-fault fail      the writer fails now, as on a full disk: the recording stops, keeping what it wrote
/// Debug builds only: bench builds don't carry them.
@MainActor
enum RecordingDebugCommands {
    /// Runs `parts` if it's one of these commands; false otherwise.
    static func run(_ parts: [String], coordinator: AppCoordinator) -> Bool {
        guard parts.first == "recording-fault" else { return false }
        let recorder = coordinator.recording.recorder
        switch parts.dropFirst().first {
        case "fail":
            recorder?.simulateFailure()
        default:
            RecordingLog.log.error("usage: recording-fault fail")
        }
        return true
    }
}
#endif
