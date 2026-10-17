import Foundation
import MarginKit
import Testing

@Suite struct RecordingStopTests {
    let domain = RecordingStop.streamErrorDomain

    @Test(arguments: [
        (-3817, RecordingStop.stoppedBySystem),  // userStopped: macOS's menu bar indicator
        (-3821, .stoppedBySystem),               // systemStoppedStream
        (-3801, .permission),                    // userDeclined
        (-3813, .windowClosed),                  // noWindowList
        (-3814, .displayGone),                   // noDisplayList
        (-3815, .displayGone),                   // noCaptureSource
        (-3822, .diskFull),                      // insufficientStorage (macOS 27)
    ])
    func streamErrorsSayWhy(code: Int, stop: RecordingStop) {
        #expect(RecordingStop.forStreamError(domain: domain, code: code, description: "x") == stop)
    }

    @Test func aWindowsSourceGoingIsTheWindowClosing() {
        for code in [-3813, -3814, -3815] {
            #expect(RecordingStop.forStreamError(domain: domain, code: code, description: "x", recordsWindow: true) == .windowClosed)
        }
        #expect(RecordingStop.forStreamError(domain: domain, code: -3817, description: "x", recordsWindow: true) == .stoppedBySystem)
    }

    @Test func otherErrorsKeepTheirDescription() {
        #expect(RecordingStop.forStreamError(domain: domain, code: -3811, description: "Internal error") == .error("Internal error"))
        // The same code from another domain (the encoder, the file system) isn't ScreenCaptureKit's.
        #expect(RecordingStop.forStreamError(domain: NSCocoaErrorDomain, code: -3813, description: "Disk") == .error("Disk"))
    }

    @Test func onlyStopsThatWerentAskedForHaveAToast() {
        #expect(RecordingStop.user.note == nil)
        #expect(RecordingStop.quit.note == nil)
        for stop: RecordingStop in [.displayGone, .windowClosed, .sleep, .sessionChanged, .diskFull, .stoppedBySystem,
                                    .permission, .error("the encoder stopped")] {
            let note = stop.note ?? ""
            #expect(note.hasPrefix("Recording stopped"), "\(stop)")
        }
        #expect(RecordingStop.windowClosed.note == "Recording stopped: the window closed")
        #expect(RecordingStop.error("the encoder stopped").note == "Recording stopped: the encoder stopped")
    }
}
