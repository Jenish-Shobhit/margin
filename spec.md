# Margin — build spec for v0.0.1

Margin is a native macOS screenshot app. Every capture is saved to disk, copied to the clipboard, and put on a shelf of thumbnails at the right edge of the screen. A thumbnail stays there until you drag it into another app or dismiss it.

This file is the source of truth for building it. For visuals, see `dev_artifacts/ideation_v2.1.html` (local and gitignored, so it may be missing in a fresh clone). If the two disagree, this file wins.

## 0. Ground rules

- **Version.** The first release is `0.0.1` (`CFBundleShortVersionString` 0.0.1, `CFBundleVersion` 1, git tag `v0.0.1`).
- **License.** MIT. The copyright holder is `git config user.name`.
- **Bundle ID.** `io.github.jenish-shobhit.margin`. Never change it, because Screen Recording permission (TCC) is keyed to it.
- **Platform.** Minimum macOS 26 (Tahoe), Apple silicon (arm64) only. Dev machine: macOS 27, Swift 6.4, Command Line Tools only.
  - There is no Xcode, no `xcodebuild`, no `actool` and no XCTest.
  - Use SwiftPM and **Swift Testing** (`import Testing`).
- **No third-party dependencies.**
  - Hotkeys use Carbon `RegisterEventHotKey`. It needs no permission. The shortcut recorder is a small SwiftUI view.
  - Reading sindresorhus/KeyboardShortcuts (MIT) for reference is fine.
  - Never copy from Mio (GPL).
- **Swift 6 language mode.** UI code is `@MainActor`. Capture and encoding run off the main thread.
- **Scope.** Ship exactly §2–§9. Anything under "Not in 0.0.1" stays out, even if it's easy.
- **Commits.**
  - Use Conventional Commits (`feat:`, `fix:`, `chore:`, `docs:`, `test:`, `perf:`).
  - Commit at the end of every milestone in §11, and at every working sub-step in between (aim for one or more commits per hour of work).
  - Every commit builds and passes `scripts/test.sh`.
  - Never commit `.build/`, `dev_artifacts/`, `*.app`, `*.zip`, or certificates.

## 1. Repository layout

```
Package.swift                 swift-tools-version 6.2+, platforms [.macOS(.v26)]
Sources/MarginKit/            pure logic, no AppKit windows, fully unit-tested
  FileNamer.swift             names, collisions
  Geometry.swift              point↔pixel, coordinate flips, rounding, snapping math
  ShelfLayout.swift           card sizes, slot positions, visible vs pile
  ShelfStore.swift            Codable model + JSON persistence (bookmarks)
  PNGWriter.swift             ImageIO encode, DPI, atomic write
  ScreenshotMetadata.swift    the screenshot tags screencapture sets
  SystemShortcuts.swift       parse com.apple.symbolichotkeys (IDs 28–31)
  ClipboardMark.swift         change-count bookkeeping
Sources/Margin/               the app (AppKit + SwiftUI)
  App/  Capture/  Overlay/  Shelf/  Hotkeys/  MenuBar/  Onboarding/  Settings/  Debug/
Tests/MarginKitTests/
Resources/Info.plist
scripts/build.sh              build → assemble Margin.app → sign → (--install) → (--run)
scripts/make-icon.swift       draws the app icon → AppIcon.icns via iconutil
scripts/debug.sh              drives DEBUG builds (see §10)
docs/QA.md                    manual test checklist (§12)
README.md  LICENSE  CHANGELOG.md  spec.md  CLAUDE.md
```

## 2. Capture

### Shortcuts (defaults; rebindable in Settings)

| Keys | Action |
|---|---|
| ⌘⇧4 | Area capture on a frozen screen. Press Space for window mode |
| ⌘⇧3 | Full screen: the display under the pointer |
| ⌘⇧2 | Repeat the last area, with no overlay. Falls back to ⌘⇧4 if there's no last area, or its display is gone or at another resolution |
| ⌃⌘⇧4 · ⌃⌘⇧3 · ⌃⌘⇧2 | Same as without ⌃ (every shot is already copied) |
| ⌘⇧1 | Tuck or show the shelf |

### Freeze (area mode)
1. On the hotkey, **immediately** show a transparent full-screen overlay on every display and switch the cursor to a crosshair. The overlay is one borderless `NSPanel` per display at level `.screenSaver + 1`, on all Spaces, `.fullScreenAuxiliary`.
   - The overlay's keys work from the hotkey on, never reaching the app in front: until the first frame is frozen they're caught as Carbon hotkeys (⌤, Z and the arrows with any of ⇧ ⌥ ⌃; Esc, Space and ↩ alone or with ⇧, since with ⌥ or ⌃ they're other apps' shortcuts, such as a launcher's ⌥Space), plain Esc and Space before anything else on the hotkey path. A key pressed before macOS hands Margin the hotkey (15–30 ms after it) can't be caught. Only then does the overlay become key and Margin activate (the crosshair needs it): sooner, the frontmost window would lose its focused look in the frozen frame. When the capture ends, that app gets its focus back as it was.
2. In parallel (a `TaskGroup`), capture every display with `SCScreenshotManager.captureImage(contentFilter:configuration:)`.
   - Filter: `SCContentFilter(display:excludingApplications:[Margin]…)`.
   - Configuration: full pixel size via `SCShareableContent.info(for:).pointPixelScale`, `showsCursor = false`, best resolution.
   - When each image arrives, draw it into that display's overlay. Margin's capture UI (overlay, shelf, fly-in, toasts, outline, menus) is excluded from the capture, so overlay order doesn't matter and nothing visibly jumps.
   - Margin's ordinary windows (Settings, First run, About, open panels) are `exceptingWindows`, so they appear in shots and window mode like any app's: everything of Margin's below the pop-up menu level. A window opened since the last cache refresh is left out until the refresh it triggers (≈ 0.2 s).
3. Keep `SCShareableContent` cached and **prewarm** at launch with one tiny capture. Refresh the cache on display or app changes, never on the hotkey path (unless a display is new, or changed size or scale, since the last refresh: its cached target would capture at the old size).
   - The window list (snapping, window mode) is refreshed for every ⌘⇧4, with on-screen windows only, as soon as the first display is frozen (fetching while the captures start slows them by about 20 ms). A selection being drawn re-snaps to it when it lands, and a window-mode click that comes first waits for it, so it never picks from the old list.

### Selecting
- Drag to select. **Releasing the mouse captures immediately.**
- A drag under 4×4 px is ignored, and you stay in selection mode.
- A selection is limited to the display where the drag started.
- While dragging:
  - ⇧ makes a square.
  - ⌥ draws from the center.
  - Holding Space moves the selection.
- To fine-tune instead of releasing: drag a handle (8 handles) or nudge with the arrow keys (⇧ = 10 px), then press ↩ to capture.
- The size pill reads `W × H` in **pixels**.
- **Snapping.** Selection edges snap to window edges within 8 pt (window frames come from the cached `SCShareableContent`). Show the "Snapped to window" pill and thin guides while snapped.
- **Loupe** (since 0.0.7: off by default, Z toggles it for the current capture). An 11×11 pixel grid that follows the cursor, with a label `x, y · #RRGGBB`. Pixel coordinates are display-local.
- **HUD hint bar** at the top center: Space Window · ⇧ Square · ⌥ From center · ←↑→↓ Nudge · ↩ Capture · Esc Cancel. It always shows, unless **Show key hints while capturing** is off in Settings.
- **Esc cancels.** Nothing is saved, no sound plays, and the clipboard is unchanged.
- A display change during selection cancels, and so do a Space switch, the Mac or its displays going to sleep, and a switch to another user: the frozen frame no longer matches the screen. After a Space switch, focus goes to the app in front on the new Space rather than back to the old one.

### Window mode
- Space (from area mode) toggles it.
- Hovering highlights the window under the pointer and shows the pill `App · W × H`.
  - Windows are taken front to back from `CGWindowList`. Normal windows and the ones floating above them below the Dock's level (floating panels, Picture in Picture, always-on-top windows: layers 1–19) can be picked, so a floating window is picked over the one behind it. System UI from the Dock's level to below menus (the Dock, banners, the menu bar) isn't picked but hides what's behind it. Menus and up (Margin's capture UI among them) are ignored, and so is a window above layer 0 that's bigger than its display or covers all of it: an overlay, usually see-through. Snapping uses the windows that can be picked.
- Clicking captures that window with `SCContentFilter(desktopIndependentWindow:)`. That gives just the window, even if it's partly covered, with rounded corners and a transparent background.
- There is **no shadow** (`ignoreShadowsSingleWindow = true`). Holding ⌥ while clicking keeps the shadow.

### Full screen (⌘⇧3) and repeat area (⌘⇧2)
- Both capture directly with no overlay. They use the same filter, so the shelf never appears in the shot.
- ⌘⇧2 briefly flashes the area outline (150 ms) *after* capturing.
- The last area is remembered relative to its display (plus the display's size in points), not in global points, so it stays on the same part of that display when displays are added, removed or rearranged. Repeating it doesn't change it. An area saved by 0.0.8 or earlier is converted on the first ⌘⇧2 when there's one display; otherwise ⌘⇧2 asks for a new area once.

### When a capture fails
- A missing Screen Recording permission opens First run (§7).
- Any other failure shows a shelf toast instead of doing nothing: "Couldn't capture that window" (it closed between hover and click), "Couldn't capture this display" (⌘⇧3 or ⌘⇧2 on a display ScreenCaptureKit can't capture), "Couldn't capture that area" (the crop came out empty) or "Couldn't capture the screen" (the freeze got no frame, including the 3 s timeout). An overlay closed by Esc gets no toast.
- ⌘⇧2 with nothing to crop falls back to ⌘⇧4.

## 3. Save, copy, sound — the moment of release

Release starts three things in parallel. The in-memory image feeds the shelf thumbnail right away, and **one** PNG encode feeds both the file and the clipboard.

- **Folder.** `~/Desktop/Screenshots` by default (Settings can change it). Create it if missing.
  - If the folder can't be written, save to `~/Library/Application Support/Margin/Unsaved/` and show the shelf toast "Can't write to “Screenshots”. Saved to Unsaved: menu bar › Show Unsaved Shots" (with the save folder's name, shortened with “…” past 16 characters so the toast's three lines still reach the menu item; an error toast that wraps and stays 4 s). The menu bar offers **Show Unsaved Shots** while that folder holds shots (§6).
  - `Info.plist` gives the reason for the folder prompts: `NSDesktopFolderUsageDescription` (the default folder is on the Desktop), plus the Documents, Downloads, removable and network volume strings for a folder chosen in Settings.
- **Name.** `Screenshot yyyy-MM-dd 'at' HH.mm.ss.png`.
  - Use the `en_US_POSIX` locale and the local time zone, 24-hour time and plain ASCII spaces.
  - On a collision, add ` (2)`, ` (3)` and so on before `.png`.
- **PNG.**
  - Use ImageIO with `kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGCompressionFilter: IMAGEIO_PNG_FILTER_UP]` (since 0.0.16; 0.0.15 and earlier used `IMAGEIO_PNG_FILTER_NONE`). Up is as fast as no filter on UI and about 45% faster on photo-like content, with smaller files.
  - Keep the display's color profile.
  - Set DPI to 72 × scale (144 on Retina), as macOS does.
  - Tag the file the way `screencapture` does: the `kMDItemIsScreenCapture`, `kMDItemScreenCaptureType` (selection, window, display) and `kMDItemScreenCaptureGlobalRect` extended attributes, set on the temp file before it's renamed into place.
  - Write to a hidden temp file in the same folder, then `rename(2)`, so no app sees a half-written file.
  - A temp file left by a save that was cut off (a crash, a forced quit) is dealt with at the next launch, off the main thread, in the folder its card is waiting in (the card is stored before the PNG is written) and in Unsaved: a complete PNG gets its screenshot name back (its card's, so the card stays on the shelf) and anything else is deleted. Margin doesn't look into the save folder at launch otherwise: on the Desktop that could raise the privacy prompt before anything is captured.
- **Clipboard** (on by default; Settings › Copy each capture). `clearContents()`, then write the PNG data (the same bytes as the file).
  - Before finalising, run `screencapture -c` once on the dev machine, list `NSPasteboard.general.types`, and write the same *image* types macOS writes. **Since 0.0.2** each item also carries `public.file-url` of the saved file (see "Changes after 0.0.1"), so ⌘V in a terminal pastes the path.
  - Record `changeCount` for the ⌘V mark (§5).
  - Only the newest capture writes the clipboard, and only if nothing was copied from the shelf (a click, ⌘C or Copy Path) since it was taken: that copy wins.
- **Sound.** Play the system "Screen Capture" sound via `AudioServicesPlaySystemSound`, so it follows the alert volume.
  - Skip it when `com.apple.sound.uiaudio.enabled` is 0 or Settings › Sound is off.
  - Play only on a successful capture.
- **Timing targets** (measure on the dev machine; log with `os.Logger` and signposts):
  - Hotkey to first frozen frame on screen: ≤ 80 ms.
  - Release to thumbnail visible: ≤ 100 ms.
  - Release to PNG renamed into place: ≤ 200 ms.

## 4. The shelf

- **Panel.**
  - A borderless, **non-activating** `NSPanel` on the right edge of the `visibleFrame` of the display of the most recent capture (the main display at launch).
  - Level `.screenSaver`, below the capture overlay.
  - Collection behavior: `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.stationary`.
  - Hidden when empty. No Dock icon (`LSUIElement`).
  - Rebuild the panel position on every display change.
- **Never in a shot.** Every capture uses the exclusion filter. The overlay level is above the shelf.
- **Cards.**
  - 176 pt wide. Height follows the shot's aspect ratio, clamped to 64–176 pt, with aspect-fill.
  - 10 pt gap, 14 pt from the screen edge and the bottom of the visible frame.
  - Corner radius 10, a subtle 1 px border and a soft shadow.
  - Thumbnails are downsampled to 2× the card size (`CGImageSourceCreateThumbnailAtIndex` for persisted items; the in-memory image for new ones).
- **Order.** The newest is at the bottom, and older cards slide up with a spring.
- **Pile.** Show at most **4** cards, or fewer if they don't fit vertically. Older items fold into a pile above them labelled `+N older`.
  - Hovering the pile fans it out.
  - Dragging the pile sends all of its items.
  - Right-clicking the pile offers "Clear shelf" (undoable).
- **Material.** The pile, tuck tab and toasts use Liquid Glass (`NSGlassEffectView` or SwiftUI `.glassEffect()`). Cards are plain image cards.
- **Fly-in.** On release, a temporary transparent panel animates the image from the selection rect to its slot (about 0.45 s, spring), then hands off to the real card.
  - The new card gets a 2 pt accent ring for 1.5 s.
  - If the shelf is tucked, the shot flies into the tab and the count goes up. The shelf stays tucked.
- **Hover.** The card scales to 1.04 and shows:
  - ✕ (top-right, red; since 0.0.6) to dismiss.
  - ••• (top-left, tooltip "Options"; since 0.0.6) for the menu.
  - A meta line at the bottom: `HH:mm · W × H`.
- **Tuck.** ⌘⇧1 slides the shelf off the edge and leaves a 22 pt tab showing the count. Hovering the tab peeks the shelf; clicking it shows the shelf. Tucking (or the end of a peek) gives the keys back. Tucking keeps what a rename in progress has typed; a peek doesn't end while a rename is open.
- **Toasts.** Inside the shelf, above the top card, never as notifications: "Copied", "Path copied", "Restored", and error messages. They last 1.2 s. A message too long for one line wraps (up to three lines); the Unsaved warning (§3) stays 4 s.
- **VoiceOver.** The shelf window is "Margin Shelf". Its elements, top to bottom: the pile (button "12 older screenshots"; press = a click, which gives the shelf the keys; action Clear shelf), each visible card, and the tab while tucked (button "Show shelf, 5 screenshots"; only the tab while tucked and not peeking).
  - A card is a button labelled "Screenshot, 14:32, 3024 × 1964", plus "selected", "copied, ready to paste" (the ⌘V mark) and "saving" (pending) as they apply; its help is the file name. Press copies, as a click does; Show Menu opens the ••• menu.
  - Its actions: Copy, Open, Quick Look, Show in Finder, Copy Path, Rename, Remove from shelf, Move to Trash (only Copy and Remove from shelf while saving). Each does what its mouse twin does, keys included: only Quick Look, Rename, Remove from shelf and Move to Trash give the shelf the keys.
  - ✕ ("Remove from shelf") and ••• ("Options", a menu button) are buttons inside the card, there whether or not the pointer is over it.
  - Toasts are posted as announcements (`announcementRequested`, high priority). The panel stays non-activating, and VoiceOver's cursor never makes it key (focusing an element, or raising the window: `accessibilityPerformRaise` only orders it front).
- **Persistence.**
  - `~/Library/Application Support/Margin/shelf.json`.
  - Store items in order with **bookmark data**, so moved files are followed, plus the date and pixel size.
  - Items survive quit and reboot.
  - Read item by item: an item that can't be read (a damaged file, or one written by a newer version) is skipped, not the whole shelf. A file with anything unreadable in it is kept as `shelf.json.bad` (never replacing an earlier one) before anything saves over it.
  - Drop any item whose file no longer resolves. Check at launch, whenever the shelf appears, and when a drag starts.
  - A file on a volume that isn't mounted (an unplugged disk, a disconnected share) hasn't gone: keep its card.

## 5. Shelf interactions

The shelf never steals focus. A click (copy) or double-click (open) leaves the keyboard with the app you're in, so ⌘V right after a click pastes there. The shelf takes the keys (the panel becomes key without activating Margin) only when they're needed next: ⌘-click, ✕ (so ⌘Z brings the card back), Rename…, Move to Trash, Clear shelf, or a click on the pile. Esc, a copy (click, ⌘C, Copy Path), tucking, a rename that ends because a new shot pushed its card into the pile, or a click elsewhere gives them back, and so does a card's or the pile's menu closed without a choice (Esc, a click elsewhere), unless the shelf had them when it opened. So does the menu bar menu, however it closes (none of its items needs the shelf's keys), unless the shelf had them when it opened.

| Input | Result |
|---|---|
| Drag a card | Drags a **plain file URL** (`NSURL` pasteboard writer, `.copy` only, never `.move`). The card stays faint in its slot during the drag. If `operation` is non-empty at the end, the card collapses out and the rest settle. On cancel, it springs back. A fresh card whose PNG is still being written starts its drag as soon as the file lands, if the button is still down (a release before that does nothing) |
| ⌥ held when the drop lands | The card stays on the shelf |
| ⌘-click | Toggle selection. Dragging a selected card drags all selected cards (stacked drag image with a count badge). ⌘C copies all selected cards as images |
| Click | Copies that shot at once (same clipboard write as §3), moves the ⌘V mark to it, shows the toast "Copied". The keyboard stays with the app you're in |
| Space | Quick Look (`QLPreviewPanel`) for the focused card or the selection. Like the shelf, it takes the keys without activating Margin (its panel is made non-activating): Space or Esc closes it and ← → step through the shots. Closing it (also with its close button, a copy or tucking) gives the keyboard back, as Esc does; after its full-screen button, which makes Margin the active app, activation goes back to the app you were in. Clicking another app closes it |
| ⌫ | Dismiss. The file stays on disk |
| Two-finger swipe right on a card | Dismiss |
| Double-click | Open with the default app (its first click has already copied the shot) |
| ••• / right-click | Copy path · Reveal in Finder · Rename… (inline; renames on disk) · Move to Trash |
| ⌘Z | Restore the last removed card(s). Keeps up to 20 steps, covering drag-out, dismiss, clear and trash (trash restores the file from the Trash; a file already back through Finder's Put Back counts as restored). Steps restore one at a time, newest first: a ⌘Z pressed while a file is still coming back from the Trash waits for it. Files are checked first: a card whose file was deleted meanwhile stays off the shelf ("File not found"), and that step is used up |

- **Drop success.** Never delete or move the file because of a drag. "Success" means only that the card leaves the shelf.
  - If an app reports success wrongly, **Restore Last Removed** in the menu bar brings the card back. A drag never gives the shelf the keys (§5 intro), so ⌘Z right after a drop goes to the app it was dropped into; on the shelf, ⌘Z works after a ⌘-click or a click on the pile.
  - If an app reports failure wrongly, the card stays and ⌫ removes it.
- **⌘V mark.** A small accent pill reading "⌘V" sits at the bottom-right of the card whose image is on the clipboard.
  - Poll `NSPasteboard.general.changeCount` about once a second. If it differs from the count recorded after Margin's last write, clear the mark.
  - If the marked card is removed, the mark goes with it.
  - Copy Path clears it at once: the clipboard then holds the path, not the image.

## 6. Menu bar

- Template icon: SF Symbol `rectangle.righthalf.inset.filled`, with `sidebar.right` as a fallback.
- Menu items:
  - Capture Area ⌘⇧4
  - Capture Window
  - Capture Screen ⌘⇧3
  - Repeat Last Area ⌘⇧2
  - —
  - Tuck Shelf / Show Shelf ⌘⇧1 (disabled while the shelf is empty)
  - Restore Last Removed (disabled when there's nothing to restore)
  - Open Screenshots Folder (creates it if missing; if it can't be opened, says so in a toast, and opens the Unsaved folder instead when that holds shots)
  - Show Unsaved Shots (only while `~/Library/Application Support/Margin/Unsaved/` holds shots; opens it in Finder. The menu is built synchronously, so it reads a flag that's checked off the main thread at launch and on each menu open, and set by a fallback save)
  - —
  - "macOS still uses ⇧⌘4 — Fix…" (only while a macOS shortcut takes one of Margin's keys)
  - Settings…
  - About Margin (current version)
  - Quit Margin
- If Screen Recording permission is missing, the icon gets a warning dot and the first item becomes "Allow Screen Recording…", which opens First run step 1. While permission is revoked, "Relaunch Margin" is offered; a failed hotkey registration adds a warning item that opens Settings.
- The shortcuts shown are for when the menu is closed. While any menu of Margin's is open, AppKit holds hotkeys back and delivers them when it closes; a press made while it was open (its event time between the menu opening and closing) is dropped, so it does nothing instead of capturing late. Not one in the last 0.5 s before AppKit reports the close: the menu is fading out then (about 0.25 s after Esc, 0.35 s after a choice), so a shortcut pressed right after dismissing the menu still works.
- Key order in all UI and docs follows macOS (⌃⌥⇧⌘, e.g. ⇧⌘4); older sections of this spec write ⌘⇧4, which means the same keys.
- Opening Margin again while it runs opens Settings (or First run step 1 without permission). One copy runs at a time: a second copy (another path, `open -n`) asks the running one to do that and quits before registering a shortcut, restoring the shelf or touching ScreenCaptureKit. A copy that's still quitting (a relaunch, at most the 3 s quit wait) is waited for instead.

## 7. First run

One window with three steps. It shows on first launch or whenever permission is missing, and closes itself after the first successful capture.

1. **Allow Screen Recording.**
   - Check with `CGPreflightScreenCaptureAccess()`; request with `CGRequestScreenCaptureAccess()`.
   - Afterwards, deep-link to Privacy & Security › Screen & System Audio Recording.
   - Poll once a second. If access is granted but needs a relaunch, show "Relaunch Margin".
2. **Hand over the shortcuts.** A live checklist of the four macOS screenshot shortcuts.
   - Read `AppleSymbolicHotKeys` from `com.apple.symbolichotkeys` with `CFPreferencesCopyAppValue` (call `CFPreferencesAppSynchronize` before each poll, once a second).
   - The IDs are:
     - **28** Save picture of screen as a file, ⌘⇧3.
     - **29** Copy picture of screen to the clipboard, ⌃⌘⇧3.
     - **30** Save picture of selected area as a file, ⌘⇧4.
     - **31** Copy picture of selected area to the clipboard, ⌃⌘⇧4.
   - A **missing entry means enabled.**
   - **Since 0.0.3:** the primary button **Turn off for me** writes `enabled = 0` for 28–31 and applies it (see "Changes after 0.0.1"); a secondary link opens Keyboard › Keyboard Shortcuts.
   - Show the note: ⌘⇧5 stays with macOS for screen recording.
3. **Take your first shot:** "Press ⌘⇧4". It also notes that launch at login is on.

## 8. Settings

There are six settings, in one small SwiftUI window:
- **Save to** (folder picker).
- **Copy each capture** (on).
- **Shutter sound** (on).
- **Show key hints while capturing** (on): the hint bar at the top of the capture overlay.
- **Launch at login** (on; `SMAppService.mainApp`).
- **Shortcuts:** recorders for Area, Screen, Repeat area and Tuck shelf. A recorded combo needs ⌘ or ⌃, and is refused (with the reason, `ReservedShortcuts`) when it's ⌘ or ⌃ with one typing key, a combo macOS or most apps use (⇧⌘Z, ⇧⌘5, ⌃⌘Q, ⌥⌘⎋…), or an enabled system shortcut from `com.apple.symbolichotkeys`. Window mode is always Space from area mode, and the ⌃ twins follow automatically.
  - A recorder listens until it gets a combo (or Esc, or Delete), is clicked again, or the Settings window loses the keys: to another app, or to a sheet (Choose…'s folder panel, whose ⇧⌘G goes to a folder, never to the recorder).
  - Keys are named as the keyboard layout types them (`KeyboardLayout`), in Settings and the menu; a combo with ⌘ as its key types with ⌘ held, as menus name it. Menu shortcuts are refused by that name: Redo is ⇧⌘ on whichever key types Z with ⌘, which on "Dvorak – QWERTY ⌘" is where QWERTY has Z.

## 9. Not in 0.0.1

- Pin to screen, OCR/QR, timer, history.
- Annotate, blur, scrolling capture, recording/GIF, file-name tokens.
- A general file shelf (dropping other files onto the shelf).
- Cloud/uploads, accounts, AI.
- Intel builds, auto-update, notarization.

## 10. Build, sign, debug

- **`scripts/build.sh [--debug] [--install] [--run]`**
  1. `swift build -c release --arch arm64`.
  2. Assemble `Margin.app`:
     - `Contents/MacOS/Margin`
     - `Contents/Info.plist`: `LSUIElement` true, `LSMinimumSystemVersion` 26.0, the version strings, `NSHumanReadableCopyright`
     - `Contents/Resources/AppIcon.icns`
  3. Sign: `codesign --force --options runtime --sign "Margin Dev"`.
     - Detect the identity with `security find-identity -p codesigning` **without `-v`**. "Margin Dev" is self-signed and untrusted (`CSSMERR_TP_NOT_TRUSTED`), so `-v` hides it, but codesign uses it fine. The designated requirement pins the certificate leaf hash, which is what keeps the TCC permission across rebuilds.
     - If that identity is missing, fall back to ad-hoc (`-`) with a loud warning that Screen Recording permission will be asked again after every rebuild.
  4. `--install`: quit the running copy, replace `/Applications/Margin.app`, and keep that path stable for TCC.
  5. `--run`: launch it.
- **Release artifact:** `ditto -c -k --keepParent Margin.app dist/Margin-0.0.1.zip`.
- **DEBUG-only control hook** (`#if DEBUG`, absent from release builds). It's a `DistributedNotificationCenter` observer, driven by `scripts/debug.sh`:
  - `capture-area x y w h` — global points, no overlay.
  - `capture-screen`
  - `dump-state` — writes shelf items, mark and tuck state, and the last timings to `/tmp/margin-state.json`.
  - `clear`
  - Use it to verify the pipeline, files, clipboard and timings without a mouse.
  - Add `screencapture -x` of the screen to check visuals. Margin must never appear in Margin's own captures, but it *does* appear in `screencapture`, which is how you verify the shelf.

## 11. Milestones (commit at the end of each, plus in between)

| # | Deliverable | Done when |
|---|---|---|
| M0 | Scaffold: package, both targets, Info.plist, build script, signing check, menu bar icon, LICENSE, README stub, `docs/QA.md` | The app launches from `/Applications`, shows the menu bar icon, and `swift test` runs |
| M1 | MarginKit: FileNamer, Geometry, ShelfLayout, ShelfStore, PNGWriter, SystemShortcuts, ClipboardMark, with tests | Tests cover names, collisions, flips, scale rounding, layout or pile counts, JSON round-trip, symbolic hotkey parsing (including missing-means-on), and PNG DPI |
| M2 | Capture core: permission, prewarm, freeze, basic area selection, Esc, save, copy, sound, timing logs | ⌘⇧4 → drag → file in the folder plus image on the clipboard; Margin is not in the image; timings logged |
| M3 | Overlay polish: handles, nudge, ↩, ⇧/⌥/Space, loupe, snapping, guides, HUD | Every key in §2 works on one display and on two |
| M4 | Window mode, full screen, repeat area, ⌃ twins | Window shots have transparent corners and no shadow (⌥ keeps it); ⌘⇧2 needs no overlay |
| M5 | Shelf: panel, cards, layout, fly-in, ring, ⌘V mark, pile, persistence, placement, excluded from capture | Five captures give 4 cards plus `+1 older`; it survives a relaunch; it never appears in a shot |
| M6 | Shelf interactions: all of §5, tuck, tab, peek, toasts | Drag to Finder, Chrome, Slack, WhatsApp and Terminal works or degrades as §5 describes; ⌘Z restores |
| M7 | First run, Settings, launch at login, menu-bar warning state | A fresh account (or reset prefs) goes through First run in under a minute |
| M8 | Hardening: display add/remove, Spaces, full-screen apps, sleep/wake, permission revoked, unwritable folder, 50-item shelf, timing targets met | Everything in `docs/QA.md` passes |
| M9 | Release: icon, README, CHANGELOG, version 0.0.1, zip, tag, public GitHub repo, GitHub release | §13 done |

## 12. QA checklist (`docs/QA.md`)

Write it at M0 and grow it with each milestone. It must cover at least these:
- Every row of §2 and §5.
- The three timing targets.
- No Margin UI in any capture (shelf visible, tucked, during fly-in).
- Two displays with different scales.
- A full-screen app in front.
- Switching Spaces.
- Sleep/wake.
- Revoking permission while running.
- A file deleted, renamed or moved in Finder while it's on the shelf.
- Pasting into WhatsApp, Claude (web and desktop), Chrome, Slack, Notes and Terminal (Claude Code: Ctrl+V).
- Dragging into all of the same apps.
- Light and dark mode.
- Reduce motion: no fly-in, so cards appear in place.
- Reduce transparency: glass falls back to solid.

## 13. Open-source release

- **README.md** covers:
  - One-line pitch, a GIF or screenshot placeholder, the features list, and the shortcuts table.
  - **Install:**
    1. Download the zip from Releases.
    2. Move Margin.app to /Applications.
    3. On first open, macOS blocks it because 0.0.1 isn't notarized. Go to System Settings › Privacy & Security › Open Anyway.
  - **Build from source:**
    1. `git clone`.
    2. Optionally create a self-signed "Code Signing" certificate named "Margin Dev" in Keychain Access, so permission persists across builds.
    3. `scripts/build.sh --install --run`.
  - First-run steps, a privacy note (no network, no analytics; files stay local), and the license.
- **CHANGELOG.md**: `## 0.0.1 — first public preview`.
- **Publish:**
  1. `gh repo create Jenish-Shobhit/margin --public --source . --push --description "Screenshots that wait in the margin of your screen until you drag them where they belong. Native macOS."`.
  2. Add topics: macos, screenshot, swift, menubar-app, screencapturekit.
  3. Create an annotated tag `v0.0.1`.
  4. `gh release create v0.0.1 dist/Margin-0.0.1.zip --title "Margin 0.0.1" --notes-file <CHANGELOG section>`.

## Deviations

- **Build system.** Swift 6.4's default SwiftPM build system needs Xcode ("Unknown error parsing property list"). Always build with `swift build --build-system native` (scripts already do this).
- **Tests.** Run `scripts/test.sh`, not plain `swift test`: it adds the Command Line Tools path for `Testing.framework`.

## Changes after 0.0.1 (user feedback, 14 Oct 2026)

Each item ships as its own patch release (version bump, CHANGELOG entry, tag, GitHub release with the zip), numbered in the order it lands. The version column was the plan; shipped versions: ⌘V in terminals → 0.0.2, turn off macOS shortcuts → 0.0.3, nudge → 0.0.4, ⌥ discoverability (+ hint bar re-shows after hint changes) → 0.0.5, card buttons → 0.0.6, magnifier on demand → 0.0.7. A bug pass followed in 0.0.8–0.0.15 (see CHANGELOG.md).

| Version | Change |
|---|---|
| 0.0.2 | **⌘V in terminals.** Captures and shelf copies put one pasteboard item with `public.png` **and** `public.file-url` (the saved file). Ghostty pastes a file URL as its path, so ⌘V in Claude Code (CLI, inside herdr) gets the screenshot; image-taking apps still get the PNG. Write the clipboard only after the file is renamed into place, using the final URL. Verify WhatsApp, Claude desktop, Chrome, Slack, Notes still paste an image. |
| 0.0.3 | **Nudge is slow.** Arrow-key nudging must follow key repeat smoothly (no full-frame redraws per step; only invalidate the selection's dirty rects). ⇧ = 10 px. |
| 0.0.4 | **Card buttons.** Dismiss ✕ moves to the **top-right** and is **red**. The options button moves to the **top-left**, with a clear menu glyph and a tooltip ("Options"). |
| 0.0.5 | **⌥ is unclear.** When a modifier is held during selection, its HUD item highlights and a small pill next to the selection names the active mode ("From center", "Square"). Window mode: holding ⌥ shows "Keep shadow". Shelf: an ⌥-drag shows "Keep on shelf" on the drag image. HUD labels use words, not just symbols. |
| 0.0.6 | **Turn off macOS shortcuts automatically.** Supersedes "never write system settings": First run step 2 gets a primary button **Turn off for me**. It sets `enabled = 0` for `AppleSymbolicHotKeys` 28–31 in `com.apple.symbolichotkeys` (keeping each entry's `value`) and runs `/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u` so it applies at once. Settings gets **Restore macOS screenshot shortcuts** (re-enables 28–31 the same way). Only ever on an explicit click. |
| 0.0.7 | **Magnifier on demand.** The loupe is off by default; press **Z** during a capture to show or hide it (remembered for the rest of that capture only). The HUD lists "Z Magnifier". |
