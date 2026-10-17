import AppKit
import MarginKit

/// ⇧⌘5 (spec §14.4): choosing what to record, the recording's state in the menu bar, and the finished file onto the shelf
/// and the clipboard, as a screenshot's would go.
extension AppCoordinator {
    func wireRecording() {
        capture.onRecord = { [weak self] target in self?.recording.start(target) }
        capture.shareableContent.onTargetsRebuilt = { [weak self] in self?.recording.targetsChanged() }
        recording.onChange = { [weak self] in self?.recordingChanged() }
        recording.onFinished = { [weak self] finished in self?.handleRecording(finished) }
        recording.onFailure = { [weak self] message in self?.shelf.showToast(message, isError: true) }
        recording.onPermissionMissing = { [weak self] in self?.captureLostPermission() }
    }

    /// ⇧⌘5 and the menu's Record Screen: choose what to record in the overlay, or stop the recording under way.
    func toggleRecording() {
        if recording.isActive {
            recording.stop()
            return
        }
        guard canStartCapture() else { return }
        capture.beginRecordingChoice()
    }

    /// The menu's Stop Recording.
    func stopRecording() { recording.stop() }

    /// DEBUG hook: records `target` straight away, with no overlay.
    func startRecording(_ target: RecordingTarget) {
        guard !recording.isActive, canStartCapture() else { return }
        recording.start(target)
    }

    var isRecording: Bool { recording.isActive }

    /// The menu bar's stop glyph and clock, from the moment the overlay closes until the recording is being saved.
    private func recordingChanged() {
        let running = recording.state == .starting || recording.state == .recording
        menuBar?.setRecording(running ? recording.elapsed : nil)
        // A quit waiting for this recording goes ahead once it's saved (or couldn't be).
        if recordingHoldsQuit, !recording.isActive {
            recordingHoldsQuit = false
            saveFinished()
        }
    }

    /// The recording is in place: its card flies in from what was recorded, ready at once (the file exists), and with
    /// Copy each capture its file goes on the clipboard, as the newest capture.
    func handleRecording(_ finished: FinishedRecording) {
        screenRecordingWorked()
        let item = finished.item
        shelf.add(item, thumbnail: finished.thumbnail ?? Self.recordingPlaceholder, flyInFrom: finished.sourceRect,
                  displayID: finished.displayID)
        shelf.itemDidSave(item)
        lastSavedPath = item.path

        captureSequence += 1
        if prefs.copyEachCapture, captureSequence > lastClipboardSequence {
            lastClipboardSequence = captureSequence
            let changeCount = ClipboardWriter.write([ClipboardWriter.Entry(fileURL: item.url)])
            mark.didWrite(itemID: item.id, changeCount: changeCount)
            shelf.setClipboardMark(item.id)
        }
        if finished.usedFallback {
            didSaveToUnsaved()
            shelf.showToast(UnsavedShots.fallbackToast(saveFolder: prefs.saveFolder), isError: true,
                            duration: Self.fallbackToastDuration)
        } else if let note = finished.note {
            shelf.showToast(note, isError: true, duration: Self.fallbackToastDuration)
        }
        prefs.completedCaptures += 1
        FirstRunWindowController.shared.captureSucceeded()
    }

    /// A card for a recording whose first frame couldn't be read back: plain dark, as an empty card is.
    static let recordingPlaceholder: CGImage = {
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.13, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return ctx.makeImage()!
    }()
}
