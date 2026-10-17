#if DEBUG
import AppKit
import MarginKit

/// Faults for the recording under way (spec §14.4), for the control hook (`DebugCommandListener`, `scripts/debug.sh`),
/// to see what each failure leaves behind without a broken disk or encoder:
///   recording-fault fail      the writer fails now, as on a full disk: the recording stops, keeping what it wrote
///   recording-fault crash     Margin ends at once, mid-recording, as in a crash (`_exit`: no crash report, no dialog);
///                             the next recording into that folder finds the temp file
///   recording-fault hang-stream   the next stop's `stopCapture` never answers: the file is finished after 3 s anyway
///   recording-fault hang-finish   the next stop's `finishWriting` never answers: after 10 s the stop gives up, keeping
///                             the file up to its last fragment
/// Debug builds only: bench builds don't carry them.
@MainActor
enum RecordingDebugCommands {
    static let usage = "usage: recording-fault fail|crash|hang-stream|hang-finish"

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
        case "hang-stream":
            recorder?.faults.withLock { _ = $0.insert(.hangStream) }
        case "hang-finish":
            recorder?.faults.withLock { _ = $0.insert(.hangFinish) }
        default:
            RecordingLog.log.error("\(usage, privacy: .public)")
        }
        return true
    }
}
#endif
