import Foundation

/// Captures the save folder couldn't take (spec §3) wait in `Preferences.fallbackSaveFolder`, "Unsaved".
/// The menu bar offers Show Unsaved Shots while that folder holds any.
public enum UnsavedShots {
    /// Whether `folder` holds anything to show: a visible file. Hidden ones (`.DS_Store`, a write's
    /// `.margin-<uuid>.tmp`) don't count, and neither does a missing folder. Blocking: call off the main thread.
    public static func exist(in folder: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        return names.contains { !$0.hasPrefix(".") }
    }

    /// Why a capture went to Unsaved.
    public enum Reason: Equatable, Sendable {
        /// The save folder couldn't be written (or, for a recording, its disk was nearly full).
        case notWritable
        /// A recording's folder went to the Trash while it was recorded.
        case trashed
        /// A recording's folder was deleted while it was recorded.
        case deleted
    }

    /// The shelf toast after a capture went to Unsaved: which folder refused it (or what became of it), where the shot
    /// is, and how to find it. The menu item's name has no-break spaces, so the wrapped toast keeps it on one line. A
    /// long folder name is shortened: in full it could push the way back past the toast's three lines.
    public static func fallbackToast(saveFolder: URL, reason: Reason = .notWritable) -> String {
        let name = "“\(shortened(saveFolder.lastPathComponent))”"
        let why = switch reason {
        case .notWritable: "Can't write to \(name)."
        case .trashed: "\(name) is in the Trash."
        case .deleted: "\(name) was deleted."
        }
        return "\(why) Saved to Unsaved: menu bar › \(menuItemTitle.replacingOccurrences(of: " ", with: "\u{00A0}"))"
    }

    /// The longest folder name the toast shows in full (a Dutch "Schermafbeeldingen" already takes a fourth line).
    static let maxFolderNameLength = 16

    static func shortened(_ name: String) -> String {
        guard name.count > maxFolderNameLength else { return name }
        return name.prefix(maxFolderNameLength - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The menu bar item that opens the Unsaved folder.
    public static let menuItemTitle = "Show Unsaved Shots"
}
