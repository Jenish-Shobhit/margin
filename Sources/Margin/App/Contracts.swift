// Contracts between the app's parts. Owned by the orchestrator: agents must not change this file.
// If a contract is missing something, add a private helper in your own files and report the gap.

import AppKit
import MarginKit

/// One finished capture. Produced by Capture/, consumed by AppCoordinator.
struct CaptureResult: @unchecked Sendable {
    enum Kind: Sendable { case area, window, screen }

    /// Full-resolution pixels in the display's color space (window shots have transparent corners).
    let image: CGImage
    /// Pixels per point, for the PNG's DPI.
    let scale: CGFloat
    /// Where the shot was on screen, in AppKit global points. The shelf's fly-in starts here.
    let sourceRect: CGRect
    let displayID: CGDirectDisplayID
    let kind: Kind
    let date: Date
}

/// Implemented by Capture/CaptureController.swift.
@MainActor
protocol CaptureControlling: AnyObject {
    /// At launch, once permission is granted: cache SCShareableContent and do one tiny capture.
    func prewarm() async
    /// ⌘⇧4: freeze every display and show the selection overlay. Space toggles window mode.
    func beginInteractiveCapture()
    /// ⌘⇧3: the display under the pointer, no overlay.
    func captureScreenUnderPointer()
    /// ⌘⇧2: `Preferences.lastArea` with no overlay; falls back to `beginInteractiveCapture()`.
    func repeatLastArea()
    /// Capture a rect (AppKit global points) directly, no overlay. Used by ⌘⇧2 and the DEBUG hook.
    func captureArea(_ rect: CGRect)
    /// True while the overlay is up.
    var isCapturing: Bool { get }
    /// Called on the main actor for every successful capture.
    var onCapture: ((CaptureResult) -> Void)? { get set }
    /// Called when a capture fails because Screen Recording permission is missing.
    var onPermissionMissing: (() -> Void)? { get set }
    /// Menu "Capture Window": the interactive capture, starting in window mode. (Contract v2)
    func beginWindowCapture()
}


/// Implemented by Shelf/ShelfController.swift.
@MainActor
protocol ShelfControlling: AnyObject {
    /// Load persisted items at launch (prunes missing files).
    func restore()
    /// Add a just-saved shot. Flies in from `sourceRect` (AppKit global points) unless Reduce Motion is on.
    /// Moves the shelf to `displayID`'s screen. If tucked, the shot flies into the tab instead.
    func add(_ item: ShelfItem, thumbnail: CGImage, flyInFrom sourceRect: CGRect, displayID: CGDirectDisplayID)
    /// ⌘⇧1.
    func toggleTucked()
    /// Move the ⌘V mark to this item (nil clears it).
    func setClipboardMark(_ itemID: UUID?)
    /// The shelf copied an item itself (click or ⌘C). Arguments: item id, new pasteboard changeCount.
    var onCopied: ((UUID, Int) -> Void)? { get set }
    /// An item left the shelf (drag-out, dismiss, trash, clear). Used to clear the mark.
    var onRemoved: (([UUID]) -> Void)? { get set }

    // State for the DEBUG hook.
    var itemIDs: [UUID] { get }
    var isTucked: Bool { get }
    var markedItemID: UUID? { get }

    // Contract v2 — save lifecycle and feedback.
    //
    // `add` happens before the PNG exists (thumbnail ≤ 100 ms, file ≤ 200 ms). Until `itemDidSave` arrives
    // the item is *pending*: never prune it, and drag/copy/Quick Look must wait or be disabled for it.
    // Always read path/bookmark from the shared `ShelfStore` by id rather than a cached copy.

    /// The PNG is on disk. `item` carries the final path (may differ from the predicted one) and its bookmark;
    /// the coordinator has already written it to the store.
    func itemDidSave(_ item: ShelfItem)
    /// Saving failed completely: drop the card (no undo) and show `message` as a toast.
    func itemSaveFailed(_ id: UUID, message: String)
    /// A short message inside the shelf (e.g. "Restored").
    func showToast(_ text: String)
    /// Remove every item (undoable with ⌘Z). Used by the pile's "Clear shelf" and the DEBUG `clear` command.
    func clear()
}

