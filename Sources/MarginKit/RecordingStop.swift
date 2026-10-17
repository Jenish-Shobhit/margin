import Foundation

/// Why a screen recording stopped (spec §14.4), and what the shelf's toast says when it wasn't asked to. A recording
/// that stops by itself keeps what was recorded.
public enum RecordingStop: Equatable, Sendable {
    /// ⇧⌘5 again, or Stop Recording.
    case user
    /// Margin is quitting.
    case quit
    case displayGone, windowClosed, sleep, sessionChanged, diskFull
    /// Stopped from macOS's screen-recording indicator in the menu bar, or by macOS itself.
    case stoppedBySystem
    case permission
    case error(String)

    /// The toast, or nil for a stop that was asked for.
    public var note: String? {
        switch self {
        case .user, .quit: nil
        case .displayGone: "Recording stopped: the display was disconnected"
        case .windowClosed: "Recording stopped: the window closed"
        case .sleep: "Recording stopped: the Mac went to sleep"
        case .sessionChanged: "Recording stopped: another user took over the Mac"
        case .diskFull: "Recording stopped: the disk is almost full"
        case .stoppedBySystem: "Recording stopped by macOS"
        case .permission: "Recording stopped: Margin lost Screen Recording permission"
        case .error(let why): "Recording stopped: \(why)"
        }
    }

    /// ScreenCaptureKit's error domain (`SCStreamErrorDomain`).
    public static let streamErrorDomain = "com.apple.ScreenCaptureKit.SCStreamErrorDomain"

    /// What ScreenCaptureKit stopping the stream means, from its error: `SCStreamError.Code`'s raw values, so this needs
    /// no ScreenCaptureKit (and covers `insufficientStorage`, which only macOS 27's SDK names). Anything else, or an error
    /// from elsewhere (the encoder), is an error with its description.
    public static func forStreamError(domain: String, code: Int, description: String) -> RecordingStop {
        guard domain == streamErrorDomain else { return .error(description) }
        switch code {
        case -3817, -3821: return .stoppedBySystem   // userStopped, systemStoppedStream
        case -3801: return .permission               // userDeclined
        case -3813: return .windowClosed             // noWindowList
        case -3814, -3815: return .displayGone       // noDisplayList, noCaptureSource
        case -3822: return .diskFull                 // insufficientStorage
        default: return .error(description)
        }
    }
}
