import AppKit

/// What Margin's state is right now, in one line: the menu's first line and the foot of Settings' sidebar (spec §6, §8).
/// The first that applies wins.
enum MarginStatus: Equatable {
    /// From the overlay closing until the recording is being saved.
    case recording
    /// Screen Recording permission is missing (or was revoked while running).
    case needsPermission
    /// A shortcut didn't register (another app has it, or it's set twice).
    case shortcutProblem
    case ready

    var title: String {
        switch self {
        case .recording: "Recording"
        case .needsPermission: "Screen Recording needed"
        case .shortcutProblem: "A shortcut isn’t working"
        case .ready: "Ready to capture"
        }
    }

    /// Whether only the menu bar icon (or Settings) can tell the user about it: the icon can't be hidden meanwhile.
    var needsAttention: Bool { self == .needsPermission || self == .shortcutProblem }

    var color: NSColor {
        switch self {
        case .recording: .systemRed
        case .needsPermission, .shortcutProblem: .systemOrange
        case .ready: .systemGreen
        }
    }

    /// A small coloured dot, for the menu's first line.
    var dot: NSImage {
        let color = color
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
