# Architecture

How Margin 0.0.15 is put together, for anyone changing it. The product rules live in [`spec.md`](../spec.md); this page describes the code that implements them.

- [Targets and folders](#targets-and-folders)
- [The contracts](#the-contracts)
- [From hotkey to shelf](#from-hotkey-to-shelf)
- [Threading rules](#threading-rules)
- [Windows and focus](#windows-and-focus)
- [Persistence](#persistence)
- [Permissions](#permissions)
- [Hotkeys](#hotkeys)
- [The macOS screenshot shortcuts](#the-macos-screenshot-shortcuts)
- [Debug builds](#debug-builds)

## Targets and folders

`Package.swift` defines three targets. There are no external dependencies.

| Target | Kind | What's in it |
|---|---|---|
| `MarginKit` | Library | Pure logic with no windows. Everything here is unit-tested |
| `Margin` | Executable | The app: AppKit and SwiftUI. Depends on `MarginKit` |
| `MarginKitTests` | Tests | Swift Testing suites for `MarginKit` |

```mermaid
flowchart LR
    Hotkeys --> App
    MenuBar --> App
    App --> Capture
    Capture --> Overlay
    App --> Shelf
    App --> Onboarding
    App --> Settings
    App --> MarginKit
    Capture --> MarginKit
    Shelf --> MarginKit
    Settings --> MarginKit
```

**`Sources/MarginKit/`**

| File | Responsibility |
|---|---|
| `FileNamer.swift` | `Screenshot yyyy-MM-dd at HH.mm.ss.png` (en_US_POSIX, 24-hour, ASCII spaces) and ` (2)` collisions |
| `Geometry.swift` | AppKit ↔ CG coordinate flips, point → pixel rects, snapping to window edges |
| `WindowPicking.swift` | Which on-screen windows window mode picks, by layer and size: normal and floating windows, system UI that covers, overlays and menus it skips |
| `ShelfLayout.swift` | Card sizes, slots, how many cards fit and the `+N older` pile |
| `ShelfStore.swift` | `ShelfItem` (path, bookmark, date, pixel size; whether its volume is mounted) and the ordered, JSON-persisted list |
| `PNGWriter.swift` | One ImageIO encode (Up filter, colour profile, DPI) and the atomic write: temp file, then an exclusive rename |
| `LeftoverSaves.swift` | At launch, the temp files of saves cut off before their rename: a complete PNG back under its card's name, or a new one; the rest deleted |
| `ClipboardMark.swift` | The ⌘V mark's change-count bookkeeping, and `ClipboardWriter` (PNG + file URL per item; Copy Path's plain text) |
| `Preferences.swift` | `KeyCombo`, `ShortcutAction` (defaults, ⌃ twins, conflicts), `LastArea` and the `Preferences` store |
| `KeyCombo+Display.swift` | `⇧⌘4`-style strings in ⌃⌥⇧⌘ order, key names and Carbon ↔ AppKit modifiers |
| `KeyboardLayout.swift` | What the character keys type on the user's keyboard layout (`UCKeyTranslate`), so shortcuts read as the keys are labelled: with ⌘ held for a combo with ⌘, as menus name it ("Dvorak – QWERTY ⌘" types QWERTY then). A snapshot taken on the main thread at launch and on every input source change |
| `RuntimeStatus.swift` | Live state shared across the app: hotkey failures, revoked Screen Recording |
| `RunningCopies.swift` | Which of two running copies of Margin gives way: the one launched later |
| `SystemShortcuts.swift` | Reading the macOS screenshot shortcuts (IDs 28–31) |
| `SystemShortcuts+Write.swift` | Turning them off or on: the pure dictionary rewrite, `activateSettings -u`, and the check that it stuck |
| `LoginItem.swift` | `SMAppService.mainApp` state and registration |
| `ShelfUndo.swift` | `UndoSequencer`: the shelf's ⌘Z one step at a time, so a quick second ⌘Z waits for a slow first one. `TrashedFile.putBack`: a trashed shot back home (or already there, after Finder's Put Back) |
| `ShutterSound.swift` | The system Screen Capture sound, honouring "Play user interface sound effects" |
| `UnsavedShots.swift` | Whether the Unsaved folder holds shots (for the menu's Show Unsaved Shots), and the toast after a capture went there |

**`Sources/Margin/`**

| Folder | Responsibility |
|---|---|
| `App/` | `main.swift` (accessory app), `AppDelegate`, `LaunchGuard` (one copy at a time), `AppCoordinator` (wires everything, permission state, ⌘V mark), `AppCoordinator+Save` (the save pipeline), `Contracts.swift`, and `MainMenu` (a hidden main menu that gives text fields and windows their standard key equivalents) |
| `Capture/` | `CaptureController` (area, window, screen, repeat area), `ScreenGrabber` (ScreenCaptureKit calls and cropping), `ShareableContentCache`, `Displays`, logging and timings, and `CaptureSimulation` (DEBUG-only fakes) |
| `Overlay/` | The frozen-screen overlay: `OverlayPanel` and its pool, `OverlaySession` (selection state machine and keys), `OverlayView` (layers), `OverlayChrome` (hint bar, magnifier, pills), `SelectionMath` and `AreaFlash` |
| `Shelf/` | `ShelfController` (layout, tuck, peek, toasts) and its extensions: `+Actions` (every interaction, undo, drag-out) and `+Files` (disk checks). Also the views (`ShelfCardView`, `ShelfPileView`, `ShelfChrome`), `ShelfAccessibility` (what VoiceOver sees: the cards, pile and tab as buttons with actions, and toasts as announcements), `ShelfDrag`, `ShelfFlyIn`, `ShelfFiles` (all disk access), `ShelfThumbnails` and `ShelfStyle` |
| `Hotkeys/` | `HotkeyCenter`: Carbon registration. `OverlayHotkeys`: the overlay's keys as hotkeys while a capture is up, before the overlay can be key |
| `MenuBar/` | `StatusMenuController` (icon, warning dot, menu rebuilt on open) and `MenuKeyEquivalent` |
| `Onboarding/` | The first-run window: `FirstRunModel` (polled state), `FirstRunView` (SwiftUI) and its window controller |
| `Settings/` | `SettingsModel` (`@Observable`, shortcut recording), `SettingsView` (SwiftUI form) and its window controller |
| `Debug/` | `DebugCommandListener`, compiled only under `#if DEBUG || MARGIN_BENCH` (debug and bench builds) |

## The contracts

`Sources/Margin/App/Contracts.swift` holds the seams between the coordinator, capture and the shelf. The parts were built in parallel against these, so change them deliberately: both sides depend on them.

**`CaptureResult`** is one finished capture:

- `image`: full resolution, in the display's colour space, with transparent corners for windows. An area's shares the frozen display's pixels (`CGImage.cropping(to:)`, no copy), so nothing keeps it past the save: the shelf keeps only the thumbnail;
- `thumbnail`: `image` downsampled for the shelf card, made off the main thread right after the capture or crop;
- `scale`: pixels per point, used for the DPI;
- `sourceRect`: the on-screen rect in AppKit global points, where the fly-in starts;
- `displayID`, `kind` (`.area`, `.window` or `.screen`) and `date`.

**`CaptureControlling`** (implemented by `CaptureController`):

- `prewarm()`;
- `beginInteractiveCapture()` and `beginWindowCapture()`;
- `captureScreenUnderPointer()`, `repeatLastArea()` and `captureArea(_:)` (no overlay: used by ⇧⌘2 and the debug hook);
- `isCapturing`;
- the callbacks `onCapture` and `onPermissionMissing`.

`CaptureController` also has `onFailure`, outside the protocol: a short message for any failure but permission, which the coordinator shows as an error toast in the shelf.

**`ShelfControlling`** (implemented by `ShelfController`):

- `restore()` at launch, `add(_:thumbnail:flyInFrom:displayID:)` and `toggleTucked()`;
- `setClipboardMark(_:)`, and the callbacks `onCopied` and `onRemoved`;
- debug state: `itemIDs`, `isTucked` and `markedItemID`;
- **v2, the save lifecycle.** `add` happens before the PNG exists, so the item is *pending* until `itemDidSave(_:)` arrives with the final path and bookmark. A pending item is never pruned, and drag, copy and Quick Look wait for it. `itemSaveFailed(_:message:)` drops the card (with no undo) and shows a toast. `showToast(_:)` and `clear()` complete it.

## From hotkey to shelf

```mermaid
sequenceDiagram
    autonumber
    participant HK as HotkeyCenter
    participant AC as AppCoordinator
    participant CC as CaptureController
    participant OS as OverlaySession
    participant SC as ShelfController
    participant BG as Background task
    HK->>AC: perform(.captureArea)
    AC->>CC: beginInteractiveCapture()
    CC->>CC: capture every display in parallel
    CC->>OS: show overlays, draw each frozen frame
    OS->>CC: onArea (mouse up)
    CC->>AC: onCapture(CaptureResult)
    AC->>SC: add(pending item, thumbnail) and fly-in
    AC->>BG: encode PNG, write temp file, rename
    BG-->>AC: finishSave(outcome)
    AC->>AC: clipboard (PNG + file URL) and ⌘V mark
    AC->>SC: itemDidSave(item)
```

### Before the hotkey: prewarm

At launch, once Screen Recording is confirmed, `CaptureController.prewarm()` gets everything ready so the hotkey path doesn't have to:

- It creates one overlay panel per display and orders each in once, invisibly, so the window server already has their surfaces.
- It fetches `SCShareableContent` into `ShareableContentCache`. That builds a capture target per display, with a filter that excludes Margin's own windows.
- It runs one 16 × 16 capture to warm up ScreenCaptureKit.

After that, the cache refreshes on display, app and Space changes (debounced 150 ms), never on the hotkey path. A fetch that fails, or whose targets don't match the displays yet, is retried up to three times (0.5, 1 and 2 s apart). One that fails for lack of Screen Recording permission (revoked while running) isn't: the cache stops observing until a capture works again, since any further call could raise the system prompt at a random moment. The cache remembers each display's pixel size at the last fetch: a display that's new, or has changed size or scale since (a refresh still pending or failed), isn't trusted, and its capture fetches first (the cold path).

### The freeze (⇧⌘4)

1. The `AppCoordinator` checks permission without prompting and calls `beginInteractiveCapture()`.
2. If the cache is warm (and every display has the size it had at the last fetch), `SCScreenshotManager.captureImage` starts for every display at once (a task group, off the main thread). At the same time the transparent overlays go up, with a crosshair.
3. Each display's frame is drawn as it arrives. With the first one, the overlay becomes key (it's a non-activating panel, so keys reach it at once) and Margin activates, which the crosshair needs: only the frontmost app may set the cursor, and it's set again once the activation lands. Not before the first frame: taking key status from the frontmost window while ScreenCaptureKit is still grabbing would show that window unfocused in the frame (grey selection, no caret).
   - **Keys before that** (`OverlayHotkeys`): from the hotkey on, ⌤, Z and the arrows, alone or with ⇧ ⌥ ⌃, and Esc, Space and ↩, alone or with ⇧, are Carbon hotkeys (54 combos, 2–3 ms), handed to the session as key events, so they never reach the frontmost app. Plain Esc and Space are registered first, before anything else in `begin` (about 0.1 ms); the rest once the overlay is up. Registered after the captures have started, the first one can wait 5–7 ms on the window server, which is busy starting them. The Carbon handler is installed at prewarm. Esc, Space and ↩ with ⌥ or ⌃ aren't caught: those are other apps' global shortcuts (⌥Space opens launchers, ⌃Space switches input source), and a combo two apps register fires in both. A key pressed before Margin even gets ⇧⌘4 can't be caught: the window server hands the hotkey over 15–30 ms after the press, and a key it routes before that goes to the frontmost app. The first hotkey after launch is later still: 4–12 ms from its event's timestamp to Margin's handler (about 1 ms afterwards), and its first registration can take 2–7 ms, so on that capture an Esc 15 ms after ⇧⌘4 still reaches the app (20 ms is caught). Nothing Margin does at launch warms that (an unused plain hotkey registered at prewarm didn't), short of a real keystroke. The arrows go when the overlay is key (they need key repeat); the rest stay until the capture ends, because unregistering a hotkey drops a press of it still in the event queue. A key still down when it ends (the Esc or ↩ that ended it, a Space held to move the selection) keeps its hotkey until it's released, at most 0.5 s, and that release is swallowed: unregistered at once, the release alone would reach the app in front, which matters to apps that read releases (a terminal with the kitty keyboard protocol, games).
   - **Focus back**: when the capture ends, activation goes back to the app that had it (`yieldActivation`, then `activate`). If Margin's own activation hasn't landed yet, or landed under 60 ms ago (Esc pressed with the first frame), it waits for that first: handed back sooner, that app ends up active without its key window. A capture started during that wait takes the app over as the one to return to (Margin is frontmost by then), and gives focus back to it even if it ends before activating Margin itself (Esc before its first frame).
4. A display that fails is dimmed ("Can't capture this display"). If no frame arrives within 3 s the overlay cancels itself with a "Couldn't capture the screen" toast, so it can never be left eating clicks. It also cancels when the frozen frame stops matching the screen: a display change, a Space switch (focus then goes to the app with the frontmost window on the new Space, not back across Spaces), sleep of the Mac or its displays, or a switch to another user. Showing the overlay and activating Margin don't switch Spaces, even over a full-screen app.
5. As soon as the first display is frozen (not after the slowest one), the window list is refreshed for snapping and window mode: `SCShareableContent` with on-screen windows only, about 60 % of the full fetch, since Margin is listed through its overlay. Not earlier: a fetch started alongside the captures slows them by about 20 ms. When it lands, a selection being drawn re-snaps its start to it and window mode re-picks the window under the pointer; a window-mode click that came first is held until then. (The cold path's fetch already has fresh windows.)

The target is **≤ 80 ms from the hotkey to the first frozen frame**.

### Selecting

`OverlaySession` is a small state machine:

| Phase | Meaning |
|---|---|
| `idle` | Nothing selected yet |
| `dragging` | Releasing captures |
| `pinned` | An arrow key was pressed mid-drag, so releasing keeps the selection |
| `adjusting` | Handles, moving, nudging and ↩ |
| `moving`, `resizing` | Dragging the selection or one of its handles |

Selections are pixel-aligned and limited to the display where they started. Mouse-up in `dragging` calls `onArea` with the rect, the frozen image and the pixel rect. `CaptureController` starts the crop and the thumbnail off the main thread, closes the overlay meanwhile, and hands a `CaptureResult` to the coordinator. Only once that run-loop turn's Core Animation commit has put the thumbnail on screen does it save the last area and give focus back to the previous app: the preference write and AppKit's deactivation work (about 15 ms) would otherwise hold the commit back.

The other kinds:

- **Window mode** picks the first window under the pointer in `ShareableContentCache`'s front-to-back stack, which `WindowPicking` builds from `CGWindowList`: windows up to layer 19 (normal, floating panels, Picture in Picture) are picked if ScreenCaptureKit lists them, the Dock, banners and the menu bar (layers 20–100) cover what's behind them and pick nothing, and menus and up, and see-through overlays above layer 0 (bigger than their display, or covering it), are skipped. Clicking closes the overlay and waits for the previous app to be active again, so the window is shot with its own focused look. It then captures with `SCContentFilter(desktopIndependentWindow:)`: no shadow unless ⌥ was held.
- **⇧⌘3** captures the display under the pointer with the cached target.
- **⇧⌘2** captures the last area's display, crops it and flashes the outline once the thumbnail's commit is done. `LastArea` keeps the rect relative to its display, with the display's size in points, so it's rebuilt on the display's current frame; at another size it falls back to ⇧⌘4.

### The release (`AppCoordinator+Save`)

On the main actor, in this order:

1. Plays the shutter sound.
2. Predicts the file name with `FileNamer`. It's checked against an in-memory set of names already handed out, *not* the disk.
3. Calls `shelf.add` with a pending item and the result's thumbnail, which `CaptureController` downsampled off the main thread before handing the shot over. The fly-in starts here. The target is **≤ 100 ms from release to thumbnail**.

Then, in a detached task:

1. One `PNGWriter.encode` produces the bytes for both the file and the clipboard.
2. `writeAtomically` writes a hidden temp file (`.margin-<uuid>.tmp`) in the save folder, then `renamex_np(RENAME_EXCL)` moves it into place.
   - If the name is taken on disk, it moves on to the next free one.
   - If the folder can't be written, it falls back to `~/Library/Application Support/Margin/Unsaved/`.
3. It makes a Finder bookmark for the final file. The target is **≤ 200 ms from release to the PNG renamed into place**.

Back on the main actor, `finishSave`:

1. Writes the clipboard, if **Copy each capture** is on and this is still the newest capture (a copy from the shelf since then wins: a click, ⌘C or Copy Path). It writes one item per shot: `public.png`, plus `public.file-url` pointing at the *final* path. It records the pasteboard's `changeCount` and puts the ⌘V mark on the card.
2. Stores the final path and bookmark, and calls `shelf.itemDidSave`.
3. Shows the Unsaved toast if needed (and sets the flag behind the menu's **Show Unsaved Shots**), bumps the capture counter, and tells first run.

If saving fails completely, the card goes with "Couldn't save the screenshot". The clipboard gets the PNG alone, if it's still the newest capture.

Quitting while saves are in flight answers `.terminateLater`. Margin waits for them, at most 3 s, on a run-loop timer that also fires during the termination modal loop.

A save cut off between the temp file and the rename (a crash, a forced quit, that timeout) leaves its PNG hidden in the folder and its card in `shelf.json` without a bookmark. At the next launch, before the shelf's first file check and off the main thread, `LeftoverSaves` goes through the `.margin-<uuid>.tmp` files last written before the launch (only one copy of Margin runs, so nothing else is writing them) in the Unsaved folder and the folder of any card still waiting for its file. Not the save folder as such: on the Desktop, looking into it at launch would raise the Desktop folder's privacy prompt if it hasn't been answered; a cut-off save always leaves its card waiting, since the card is stored before the PNG is written. A complete PNG (it ends with its `IEND` chunk and ImageIO reads it whole) goes back under its card's name when a waiting card has its pixel size and was captured up to 2 minutes before it was written, so the card stays; otherwise it gets a `FileNamer` name from its own date. Anything else is deleted.

### On the shelf

- `ShelfFlight` animates the thumbnail from the selection to its slot in about 0.45 s, in a temporary click-through panel. It re-aims if the slot moves (another capture, a tuck, a peek), lands in the tab or the pile when that's where the card is, and then hands off to the real card. The card's accent ring lasts 1.5 s.
- A one-second timer compares the pasteboard's `changeCount` with the one recorded after Margin's last write. When they differ, the ⌘V mark clears. Copy Path clears it at once, since the clipboard then holds paths, not an image. Margin never reads the clipboard's contents.
- Drag-out writes a plain `NSURL` per item and offers `.copy` only. A non-empty drop operation without ⌥ removes the cards, as one undo step. The drag never makes the shelf key, so ⌘Z after a drop belongs to the app that took it; the menu's **Restore Last Removed** (`undo(fromMenu:)`) is the way back.

## Threading rules

- **UI and app state are `@MainActor`.** That covers AppKit and SwiftUI, `Preferences`, `ShelfStore` and `RuntimeStatus`. The package uses the Swift 6 language mode with strict concurrency.
- **The main thread never touches the save folder.** The first access to `~/Desktop` can block on the Desktop-folder privacy prompt, and the save folder could be on a slow volume. So these all run in detached tasks:
  - writing PNGs and checking whether shelf files exist (`ShelfFiles`);
  - putting back the leftovers of saves cut off, at launch (`LeftoverSaves`);
  - reading a file to copy it, renaming, trashing and untrashing;
  - loading thumbnails from disk;
  - creating the folder for **Open Screenshots Folder**, and checking whether the Unsaved folder holds shots (**Show Unsaved Shots**: the menu is built synchronously, so it reads a flag this check keeps current, at launch and on each menu open);
  - Settings' folder icon.

  Even the predicted file name is checked against memory, not the disk. Results come back to the main actor, and a background check is applied only to items that haven't changed since it started.
- **ScreenCaptureKit and pixel work run off the main thread:** captures, crops, encodes, a new shot's thumbnail and downsampling files. `SCShareableContent` is never fetched on the hotkey path.
- **Nothing touches ScreenCaptureKit before permission is confirmed.** An early call can raise the system prompt at a random moment, long before the user reaches **Allow…**. `CGPreflightScreenCaptureAccess` (6–10 ms) runs on the hotkey path only until access is confirmed.
- **Blocking system work stays off the main thread.** `SystemShortcuts.setEnabled` waits on `activateSettings` and asserts it isn't on the main thread; the UI calls `setEnabledInBackground`.
- **The one exception is `shelf.json`.** It lives in Application Support, which never prompts, and it's read and written on the main actor.

## Windows and focus

| Window | Level | Notes |
|---|---|---|
| Capture overlay (one per display) | `.screenSaver + 1` | Borderless, non-activating, made once and reused. Key from the first frozen frame; its keys are hotkeys until then. Swallows ⌘ shortcuts |
| ⇧⌘2 outline | `.screenSaver + 1` | Click-through, 150 ms. Made once and reused; the outline is two layer borders |
| Shelf | `.screenSaver` | Borderless, **non-activating** `NSPanel`; hidden when empty |
| Fly-in | `.screenSaver` | Click-through, one per shot in the air |

All of them join every Space and float over full-screen apps.

**Focus.** The shelf becomes key (`focusShelf`) only on a mouse-up whose next step is a shelf key: ⌘-click, ✕, the pile, Rename…, Move to Trash, Clear shelf. Never on a plain click (copy) or a double-click (open), so ⌘V right after a click reaches the user's app; never on a press that turns into a drag; and never by activating Margin. Its keys (⌘C, ⌘Z, ⌘A, Space, ⌫, Esc) then work while the menu bar still belongs to the other app. `releaseKeys` gives the keyboard back on Esc, after every copy (click, ⌘C, Copy Path), when the shelf goes out of sight (a tuck, which saves a rename in progress first, or the end of a peek, which waits while a rename is open), when a rename ends because a new shot folded its card into the pile (what was typed is saved), when a card's or the pile's menu closes without a choice, and when the menu bar menu closes at all (none of its items needs the shelf's keys; `StatusMenuController.menuDidClose`, after the chosen item's action), unless the shelf had the keys when the menu opened (`menuOpening`: once the shelf has had them, AppKit makes it key again whenever a menu of Margin's closes): `NSApp.deactivate()` makes the other app's window key again, unless Margin itself is frontmost. Not once another app has taken the keys from the shelf and handed them back (Spotlight opened and closed with ⌘Space): deactivating then leaves the keyboard with no window at all. So the shelf notes where its keys go (`shelfResignedKey`, `shelfBecameKey`), and after such a hand-back `releaseKeys` activates Margin and hands activation to the user's app instead (`handKeysBack`), as at the end of a capture.

**Quick Look** is made a non-activating panel too (`ShelfRootView.showQuickLook` adds `.nonactivatingPanel` to `QLPreviewPanel`'s style mask before it's shown). As a regular panel it became key in Margin while the keyboard went back to the user's app, so Space and Esc went there and it stayed open. Now it handles its own keys (Space, Esc, arrows). When it closes, the shelf is key again and `endPreviewPanelControl` calls `quickLookDidClose`, which calls `releaseKeys`. Its full-screen button activates Margin (macOS makes a full-screen window's app active), and an active Margin can't hand the keyboard back by deactivating, so then activation goes back to the app that was frontmost when Quick Look opened (`quickLookReturnApp`), unless one of Margin's own windows has the keys. `releaseKeys` with Quick Look open only closes it and lets that hand the keyboard back: deactivating while it animates away leaves the shelf key once it's gone, and a second `orderOut` during that animation cancels the close (`quickLookClosing` prevents one). If neither it nor the shelf has the keyboard any more (a click in another app), it closes (`keyWindowChanged`).

`MainMenu` installs a hidden main menu, so text fields get their standard edit keys. Its ⌘Q acts only while Margin is really frontmost (`NSRunningApplication.current.isActive`), and its Undo goes to the rename field's own undo manager while it's editing.

**Exclusion from captures.** Every capture filter excludes Margin's application, except its ordinary windows: everything of Margin's below the pop-up menu level, so Settings, First run, About, open panels and (where AppKit draws it in-process) the menu bar icon appear in shots and can be picked in window mode like any app's. The capture UI sits at the pop-up menu level or above (menus, the shelf and fly-in at `.screenSaver`, the overlay and ⇧⌘2 outline at `.screenSaver + 1`), and because the app itself is excluded, a window made after the last fetch (each fly-in) is never in a shot. The other way round, an ordinary window the cache doesn't know yet is cut out until the refresh it schedules when it becomes key or visible. `SCShareableContent` lists Margin, and so lets it be excluded, only while Margin owns at least one window. That's why the overlay panels exist from prewarm on, and why ⇧⌘3 makes sure of them even without a prewarm.

## Persistence

| Store | Where | Contents |
|---|---|---|
| `Preferences` | `UserDefaults`, domain `io.github.jenish-shobhit.margin` | `saveFolder`, `copyEachCapture`, `shutterSound`, `launchAtLogin`, `shortcut.<action>` (JSON `KeyCombo`), `lastArea` (JSON: rect relative to its display, display ID, display size), `firstRunDone`, `completedCaptures`, `showsCaptureHints`, `loginItemConfigured`. `hintCaptures.r<n>` (0.0.5–0.0.7) is removed at launch |
| `ShelfStore` | `~/Library/Application Support/Margin/shelf.json` | The shelf, oldest first: `id`, `path`, `bookmark`, `createdAt`, `pixelWidth`, `pixelHeight`. Rewritten atomically on every change. Read item by item: one that can't be read (damaged, or from a newer Margin) is skipped. A file with anything unreadable in it, or that isn't a list at all, is first moved to `shelf.json.bad` (`shelf.json.bad 2`… beside an earlier one), so no save overwrites it |
| Fallback saves | `~/Library/Application Support/Margin/Unsaved/` | PNGs that couldn't go to the save folder |
| Undo | Memory | Up to 20 steps. Thumbnails are kept for the newest 5. Steps restore one at a time (`UndoSequencer`), since each goes back to the indices it had, which holds only once newer steps are back |
| `RuntimeStatus` | Memory | Hotkey failures and revoked Screen Recording |

More on how these behave:

- **`Preferences.didChange`** is posted on every write. The hotkeys, Settings and the menu observe it, and `HotkeyCenter` re-registers only when the shortcuts actually changed.
- **The hint bar** shows while `Preferences.showsCaptureHints` is on (the default; a Settings toggle).
- **Bookmarks** let a card follow a file renamed or moved in Finder.
- **When a shelf file counts as gone:** `ShelfFiles.status` tells a file that's definitely gone (`ENOENT` on a mounted volume, or in a `.Trash` folder) from one Margin can't see right now (access denied, or its volume isn't mounted: `ShelfItem.isOnUnmountedVolume` checks the mount point the bookmark recorded, or `/Volumes/<name>`). Only the first drops the card, so a folder Margin may not read, or an unplugged disk, never empties the shelf.
- **When files are checked:** at launch, when the shelf appears, and on a mouse-down that may become a drag.

## Permissions

- **Screen Recording.**
  - **At launch:** `CGPreflightScreenCaptureAccess` only. `CGRequestScreenCaptureAccess` runs only when the user clicks **Allow…**.
  - **Without permission:** a capture shortcut opens first run at step 1 instead of touching ScreenCaptureKit.
  - **Revocation:** preflight is cached per process, so a revocation while running shows up as a capture error (`SCStreamError.userDeclined`). That sets `RuntimeStatus.screenRecordingRevoked`, which keeps the warning up until ScreenCaptureKit works again (a capture, or just its freeze, when Esc cancels it) or Margin relaunches. The menu bar's dot follows each change of it (`StatusMenuController` observes `RuntimeStatus.didChange`).
  - **Relaunch Margin** starts `/bin/sh`, which waits for this process to exit and then `open`s the bundle. It deliberately doesn't use `open -n`, so there's never a second copy.
- **One copy at a time.** Two copies would both register the shortcuts (one ⇧⌘3, two files) and each keep its own `shelf.json`. So `applicationDidFinishLaunching` asks `LaunchGuard` first: when an older copy with the same bundle ID runs (`RunningCopies`: launch date, then process ID, so two copies starting together agree), this one does nothing else. After 0.5 s it reopens the older one with `NSWorkspace.openApplication(at:)`, as Finder would (its `applicationShouldHandleReopen` shows Settings), and it quits if that copy still runs after `terminationTimeout` + 2 s; if it goes first (it was quitting for a relaunch), this one starts after all.
- **Files.** The default save folder is in `~/Desktop`, so macOS shows its Desktop-folder prompt on first write, with the reason from `NSDesktopFolderUsageDescription` (`Info.plist` also has the Documents, Downloads, removable and network volume strings, for a folder chosen in Settings). That's the reason for the off-main rule. A denied write falls back to Unsaved, and the menu offers **Show Unsaved Shots** while that folder holds shots.
- **Launch at login** uses `SMAppService.mainApp`. It's registered once, on the first launch from `/Applications` (never from a dev copy elsewhere). Settings shows `SMAppService`'s real status, including "requires approval".
- **No Accessibility or Input Monitoring.** Carbon hotkeys don't need them.

## Hotkeys

`HotkeyCenter` registers with Carbon's `RegisterEventHotKey` on the application event target, with the signature `'MRGN'`.

- **What it registers:** `Preferences.registeredCombos()`, which is each action's shortcut plus the ⌃ twin of each capture action.
- **When it re-registers:** whenever the shortcuts change.
- **While recording:** everything is unregistered while a Settings recorder is listening (`Preferences.isRecordingShortcut`), so pressing the current shortcut records it instead of firing it. The recorder is a local event monitor, so it sees every key Margin's windows get, a sheet's too: it stops when the Settings window resigns key, a sheet or alert included, and when **Choose…** opens the folder panel (⇧⌘G there is the panel's Go to Folder).
- **Failures:** two actions on one combo, Carbon's `eventHotKeyExistsErr`, or any other `OSStatus`. They go to `RuntimeStatus.hotkeyFailures`. The menu bar shows a warning dot and an item that opens Settings, and Settings shows a message under the shortcut.
- **With a menu open:** AppKit's menu tracking holds Carbon hotkey events back until the menu closes, so a shortcut pressed there would fire late (⇧⌘3 in the open menu, then a capture as Settings… opened). `HotkeyCenter` notes when any of Margin's menus begins and ends tracking (`NSMenu` notifications, `GetCurrentEventTime`), and drops a hotkey whose event time (`GetEventTime`) falls in that span (`MenuOpenTimes`), except its last 0.5 s: AppKit posts the end of tracking only once the menu has blinked the chosen item and faded out (about 0.25 s after Esc, 0.35 s after a choice), so a shortcut pressed right after the menu was dismissed still works, at most that late. One delivered while a menu is still open wasn't held back, and goes through.
- **macOS's own shortcuts:** while the macOS screenshot shortcuts are on, macOS takes ⇧⌘3 and ⇧⌘4 first, but registration still succeeds. That's why that clash is detected separately (below).

## The macOS screenshot shortcuts

**Reading** (`SystemShortcuts.current()`) costs little:

- It reads `AppleSymbolicHotKeys` from `com.apple.symbolichotkeys` with `CFPreferencesCopyAppValue`, after synchronizing.
- IDs 28–31 are the four screenshot shortcuts. A missing entry means enabled.
- `conflicts(_:with:)` lists the enabled ones whose binding is one of Margin's combos.
- It runs when the menu opens, every second while first run is open, and when Settings opens or becomes key.

**Writing** (`SystemShortcuts.setEnabled`) happens only when the user clicks **Turn off for me**, **Turn off macOS screenshot shortcuts** or **Restore macOS screenshot shortcuts**:

1. `applying(enabled:ids:to:)`, a pure function, sets `enabled` for 28–31 and keeps everything else: other IDs, each entry's `value` (so a binding the user changed survives), and any other keys. A missing entry gets the macOS default binding. If the stored value isn't a dictionary at all, nothing is written.
2. The result is written with `CFPreferencesSetAppValue` and synchronized.
3. `/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u` runs, with a 5 s timeout, so the change applies without logging out.
4. Margin waits until the saved preferences and the live state agree for 0.3 s. It reads the live state through SkyLight's private `CGSIsSymbolicHotKeyEnabled`, read-only, loaded with `dlsym`.
   - Something can write a half-applied snapshot back, such as System Settings open on its Keyboard pane. So it writes and activates again, up to three tries, before it reports "didn't stick".
   - If the setting is saved but activation fails, the UI says it will apply after the next login.

## Debug builds

`#if DEBUG` adds `DebugCommandListener`, which receives distributed notifications from `scripts/debug.sh`: `capture-area`, `capture-screen`, `toggle-shelf`, `clear` and `dump-state`. It also adds `CaptureSimulation`, which fakes extra displays and failing captures for testing.

Bench builds (`scripts/build.sh --bench`: release optimisation plus `-DMARGIN_BENCH`) have the listener too, but not `CaptureSimulation`. `scripts/bench.sh` drives them with its further commands (`hotkey`, `capture-window`, `select`, `click`, `cancel`, `mark`), which call the live overlay session's handlers in-process, and reads the `timing` log ([Building › Benchmarks](building.md#benchmarks)).

Release builds contain neither. [Building › The debug hook](building.md#the-debug-hook) has the commands and the safety rules.
