#if DEBUG
import AppKit
import MarginKit

/// Faults for the recording under way (spec §14.4), for the control hook (`DebugCommandListener`, `scripts/debug.sh`),
/// to see what each failure leaves behind without a broken disk or encoder:
///   recording-fault fail      the writer fails now, as on a full disk: the recording stops, keeping what it wrote
///   recording-fault crash     Margin ends at once, mid-recording, as in a crash (`_exit`: no crash report, no dialog);
///                             the next recording into that folder finds the temp file
/// Debug builds only: bench builds don't carry them.
@MainActor
enum RecordingDebugCommands {
    static let usage = "usage: recording-fault fail|crash"

    /// Runs `parts` if it's one of these commands; false otherwise.
    static func run(_ parts: [String], coordinator: AppCoordinator) -> Bool {
        guard parts.first == "recording-fault" else { return false }
        let recorder = coordinator.recording.recorder
        switch parts.dropFirst().first {
        case "fail":
            recorder?.simulateFailure()
        case "crash":
            guard recorder != nil else {
                RecordingLog.log.error("recording-fault crash: nothing is being recorded")
                return true
            }
            RecordingLog.log.notice("recording-fault crash: exiting mid-recording")
            _exit(70)
        default:
            RecordingLog.log.error("\(usage, privacy: .public)")
        }
        return true
    }
}
#endif
