#if DEBUG || MARGIN_BENCH
import AppKit
import MarginKit

/// The updater's commands for the control hook (`DebugCommandListener`, `scripts/debug.sh`), to test spec §14.3 against
/// a local release instead of GitHub's:
///   update-check [feed]       Check for Updates…, against `feed` (a URL: `file://…` or `http://127.0.0.1…`) when given
///   update-check-auto [feed]  an automatic check now, whatever the schedule (it respects Skip This Version)
///   update-open <url>         what opening that URL does (`margin://update`, or anything else)
///   update-install            Install and Relaunch
///   update-later | update-skip | update-cancel   the window's other buttons
///   update-trash <folder>     the helper's Trash folder (one it can't write tests its failure path); `-` resets it
///   update-readonly on|off    Install and Relaunch acts as if the app's folder couldn't be written
///   update-state              write the updater's state as JSON to /tmp/margin-update-state.json
/// None of them reaches the network unless the feed (or GitHub's, with no feed) is asked.
@MainActor
enum UpdateDebugCommands {
    static let stateFileURL = URL(fileURLWithPath: "/tmp/margin-update-state.json")

    /// Runs `parts` if it's one of these commands; false otherwise.
    static func run(_ parts: [String]) -> Bool {
        let updates = UpdateController.shared
        let argument = parts.count > 1 ? URL(string: parts[1]) : nil
        switch parts.first {
        case "update-check":
            if let argument { updates.debugFeed = argument }
            updates.checkForUpdates()
        case "update-check-auto":
            if let argument { updates.debugFeed = argument }
            updates.debugAutomaticCheck()
        case "update-open":
            if let argument { updates.open(argument) }
        case "update-install": updates.install()
        case "update-later": updates.later()
        case "update-skip": updates.skip()
        case "update-cancel": updates.cancel()
        case "update-trash":
            updates.debugTrash = parts.count > 1 && parts[1] != "-" ? URL(fileURLWithPath: parts[1], isDirectory: true) : nil
        case "update-readonly":
            updates.debugReadOnly = parts.count > 1 && parts[1] == "on"
        case "update-state":
            do {
                let data = try JSONSerialization.data(withJSONObject: updates.debugState, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: stateFileURL, options: .atomic)
            } catch {
                UpdateController.log.error("update-state failed: \(error.localizedDescription, privacy: .public)")
            }
        default:
            return false
        }
        return true
    }
}
#endif
