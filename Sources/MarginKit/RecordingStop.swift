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
    /// The writer failed (the encoder, the disk), or ScreenCaptureKit stopped with an error: its description.
    case error(String)

    /// Why, as the end of a toast; nil for a stop that was asked for.
    var cause: String? {
        switch self {
        case .user, .quit: nil
        case .displayGone: "the display was disconnected"
        case .windowClosed: "the window closed"
        case .sleep: "the Mac went to sleep"
        case .sessionChanged: "another user took over the Mac"
        case .diskFull: "the disk is almost full"
        case .stoppedBySystem: "macOS stopped it"
        case .permission: "Margin lost Screen Recording permission"
        case .error(let why): why
        }
    }

    /// The toast, or nil for a stop that was asked for.
    public var note: String? {
        switch self {
        case .stoppedBySystem: "Recording stopped by macOS"
        default: cause.map { "Recording stopped: \($0)" }
        }
    }

    /// The toast for a recording that ended this way. `saved` is the length of what was kept (nil: nothing could be
    /// saved); `complete`, whether its file was finished. One that wasn't plays up to its last fragment: for a writer
    /// that failed, that's what was recorded (the stop's own note says why); after a stop that was asked for, or one
    /// for another reason, it's less than the recording, and the toast says how much is there.
    public func toast(saved: TimeInterval?, complete: Bool) -> String? {
        guard let saved else {
            if case .error(let why) = self { return "Couldn't save the recording: \(why)" }
            return "Couldn't save the recording"
        }
        if complete { return note }
        if case .error = self { return note }
        return "The recording couldn't be finished: saved up to \(RecordingFormat.cardDurationText(saved))"
    }

    /// ScreenCaptureKit's error domain (`SCStreamErrorDomain`).
    public static let streamErrorDomain = "com.apple.ScreenCaptureKit.SCStreamErrorDomain"

    /// What ScreenCaptureKit stopping the stream means, from its error: `SCStreamError.Code`'s raw values, so this needs
    /// no ScreenCaptureKit (and covers `insufficientStorage`, which only macOS 27's SDK names). Anything else, or an error
    /// from elsewhere (the encoder), is an error with its description. `recordsWindow`: the stream records a window, whose
    /// capture source going away (the window closed, or its app quit) isn't a display going.
    public static func forStreamError(domain: String, code: Int, description: String,
                                      recordsWindow: Bool = false) -> RecordingStop {
        guard domain == streamErrorDomain else { return .error(description) }
        switch code {
        case -3817, -3821: return .stoppedBySystem   // userStopped, systemStoppedStream
        case -3801: return .permission               // userDeclined
        case -3813: return .windowClosed             // noWindowList
        case -3814, -3815: return recordsWindow ? .windowClosed : .displayGone // noDisplayList, noCaptureSource
        case -3822: return .diskFull                 // insufficientStorage
        default: return .error(description)
        }
    }
}
