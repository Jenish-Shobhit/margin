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
                                    .permission, .fileSizeLimit(4_294_967_295), .error("the encoder stopped")] {
            let note = stop.note ?? ""
            #expect(note.hasPrefix("Recording stopped"), "\(stop)")
        }
        #expect(RecordingStop.windowClosed.note == "Recording stopped: the window closed")
        #expect(RecordingStop.stoppedBySystem.note == "Recording stopped by macOS")
        #expect(RecordingStop.error("the encoder stopped").note == "Recording stopped: the encoder stopped")
    }

    @Test func aFileSizeLimitIsSaidAsPeopleKnowIt() {
        #expect(RecordingStop.fileSizeLimit(4_294_967_295).note == "Recording stopped: the disk can't hold files over 4 GB")
        #expect(RecordingStop.fileSizeLimit(500 * 1024 * 1024).note == "Recording stopped: the disk can't hold files over 500 MB")
    }

    @Test func theToastSaysWhatWasKept() {
        // A finished file: the stop's own note, or nothing for one that was asked for.
        #expect(RecordingStop.user.toast(saved: 12, complete: true) == nil)
        #expect(RecordingStop.windowClosed.toast(saved: 12, complete: true) == "Recording stopped: the window closed")
        // A writer that failed stopped the recording: what it wrote is what was recorded, and the note says why.
        #expect(RecordingStop.error("Disk Full").toast(saved: 41.6, complete: false) == "Recording stopped: Disk Full")
        // Not finished after a stop that was asked for, or one for another reason: how much is there.
        #expect(RecordingStop.user.toast(saved: 41.6, complete: false) == "The recording couldn't be finished: saved up to 0:42")
        #expect(RecordingStop.quit.toast(saved: 0.2, complete: false) == "The recording couldn't be finished: saved up to 0:01")
        #expect(RecordingStop.sleep.toast(saved: 75, complete: false) == "The recording couldn't be finished: saved up to 1:15")
        // Nothing kept.
        #expect(RecordingStop.user.toast(saved: nil, complete: false) == "Couldn't save the recording")
        #expect(RecordingStop.windowClosed.toast(saved: nil, complete: true) == "Couldn't save the recording")
        #expect(RecordingStop.error("Disk Full").toast(saved: nil, complete: false) == "Couldn't save the recording: Disk Full")
    }
}
