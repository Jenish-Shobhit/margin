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
- That capture waits for the window to look focused again (the app that had focus gets it back first), so it's in about 130 ms after the click. Until then the shelf shows a stand-in, the window cut from the frozen frame, which flies in at once; the capture's thumbnail replaces it in flight or on the card. The file and the clipboard are always the capture's. Where the frozen frame doesn't show that window alone (with ⌥, as the shadow makes the shot bigger; for a window not all on one display; with anything in front overlapping it: another window, the Dock, the menu bar), the stand-in is the window captured at the click instead, before its app has focus back: in after about 30 ms, it may look unfocused (with ⌥, with a smaller shadow) until the capture replaces it.

### Full screen (⌘⇧3) and repeat area (⌘⇧2)
- Both capture directly with no overlay. They use the same filter, so the shelf never appears in the shot.
- ⌘⇧2 briefly flashes the area outline (150 ms) *after* capturing.
- The last area is remembered relative to its display (plus the display's size in points), not in global points, so it stays on the same part of that display when displays are added, removed or rearranged. Repeating it doesn't change it. An area saved by 0.0.8 or earlier is converted on the first ⌘⇧2 when there's one display; otherwise ⌘⇧2 asks for a new area once.

### When a capture fails
- A missing Screen Recording permission opens First run (§7).
- Any other failure shows a shelf toast instead of doing nothing: "Couldn't capture that window" (it closed between hover and click; after a stand-in, its card goes with this toast), "Couldn't capture this display" (⌘⇧3 or ⌘⇧2 on a display ScreenCaptureKit can't capture), "Couldn't capture that area" (the crop came out empty) or "Couldn't capture the screen" (the freeze got no frame, including the 3 s timeout). An overlay closed by Esc gets no toast.
- ⌘⇧2 with nothing to crop falls back to ⌘⇧4.

## 3. Save, copy, sound — the moment of release

Release starts three things in parallel. The in-memory image feeds the shelf thumbnail right away, and **one** PNG encode feeds both the file and the clipboard. Both start off the main thread as soon as the image is ready (for an area, at mouse-up, while the overlay comes down); the main thread names the shot and puts the thumbnail on the shelf. After an area, focus goes back to the app you were in only once the thumbnail is committed to the screen.

- **Folder.** `~/Desktop/Screenshots` by default (Settings can change it). Create it if missing. With Delete screenshots after pasting on (since 0.1.2), Margin's own Pasteboard folder instead (§14.2).
  - If the folder can't be written, save to `~/Library/Application Support/Margin/Unsaved/` and show the shelf toast "Can't write to “Screenshots”. Saved to Unsaved: menu bar › Show Unsaved Shots" (with the save folder's name, shortened with “…” past 16 characters so the toast's three lines still reach the menu item; an error toast that wraps and stays 4 s). The menu bar offers **Show Unsaved Shots** while that folder holds shots (§6).
  - `Info.plist` gives the reason for the folder prompts: `NSDesktopFolderUsageDescription` (the default folder is on the Desktop), plus the Documents, Downloads, removable and network volume strings for a folder chosen in Settings.
- **Name.** `Screenshot yyyy-MM-dd 'at' HH.mm.ss.png`.
  - Use the `en_US_POSIX` locale and the local time zone, 24-hour time and plain ASCII spaces.
  - On a collision, add ` (2)`, ` (3)` and so on before `.png`.
- **PNG.**
  - The file is ImageIO's PNG with `kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGCompressionFilter: IMAGEIO_PNG_FILTER_UP]` (since 0.0.16; 0.0.15 and earlier used `IMAGEIO_PNG_FILTER_NONE`). Up is as fast as no filter on UI and about 45% faster on photo-like content, with smaller files.
  - ImageIO deflates on one core (zlib level 1), and that's nearly all of its time. So from two 256 KB bands of rows up (about 360 × 360 pixels), Margin writes that file itself (`ParallelPNG`), with the deflate spread over every core. A busy full-display shot (2940 × 1912) is in its file 61 ms after release instead of 207, and a flat UI one in 27 ms instead of 100:
    - The Up-filtered rows are cut into bands. Each band is deflated on a core of its own at level 1, as a raw stream primed with the previous band's last 32 KB and ended with a sync flush. The bands join into one zlib stream, whose Adler-32 is combined from theirs.
    - The chunks around the image data are the ones ImageIO writes for that image (from its PNG of a 1 × 1 crop, with the `eXIf`'s pixel size set): `iCCP` (or `sRGB` for sRGB), `cICP` where the space has one, `eXIf`, `pHYs`. The samples are ImageIO's too: vImage unpremultiplies with ImageIO's rounding.
    - So the file decodes to the same pixels with the same metadata, within a few KB of ImageIO's size (0.01% on a busy shot; a small flat one can be 4% larger or 8% smaller). With one band it would be ImageIO's file byte for byte, and the tests check that.
    - Smaller shots, and any format but 8-bit premultiplied RGB with alpha (16-bit, float, opaque or straight alpha), go to ImageIO, as does an image with a decode array (drawing it rounds differently) and any image whose ImageIO chunks it doesn't know.
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
  - Play only on a successful capture. Window mode's stand-in (§2) counts: the sound goes with it, at the click.
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
  - Up to 6 show (since 0.0.19; 4 before), newest at the bottom, fewer when they don't fit the display; older ones fold into the pile.
  - 176 pt wide. Height follows the shot's aspect ratio, clamped to 64–176 pt, with aspect-fill.
  - 10 pt gap, 14 pt from the screen edge and the bottom of the visible frame.
  - Corner radius 10, a subtle 1 px border and a soft shadow.
  - Thumbnails are downsampled to 2× the card size (`CGImageSourceCreateThumbnailAtIndex` for persisted items; the in-memory image for new ones, off the main thread right after the capture).
  - Since 0.0.16, only the cards that can be seen or soon could be are live (a view and a decoded thumbnail): the visible cards, the pile's fan (3) and as many again as there are visible cards (6) in the pile, plus any selected or last-clicked card. The rest of the pile becomes a card when it comes forward (a removal, ⌘Z), decoding at most 2 thumbnails at a time, newest first, and stops being one when it folds deeper again. Launch and memory then stay about the same however big the shelf is.
- **Order.** The newest is at the bottom, and older cards slide up with a spring.
- **Pile.** Show at most **4** cards, or fewer if they don't fit vertically. Older items fold into a pile above them labelled `+N older`.
  - Hovering the pile fans it out.
  - Dragging the pile sends all of its items.
  - Right-clicking the pile offers Close Shelf (undoable; "Clear shelf" until 0.1.3).
- **Close Shelf** (since 0.1.3). For a shelf of shots you're done with for now: every card leaves at once and the shelf goes away, its tab too while tucked; the files stay where they are. It's one ⌘Z step, so Restore Last Removed brings them all back, and the next capture shows the shelf as usual.
  - A small glass pill, "✕ Close Shelf", just above the top card or the pile at the stack's left edge (the toasts sit at its right on the same line). It fades in while the pointer is on a card or on it, and out 0.3 s after the pointer leaves (so crossing a gap between cards doesn't blink it); not while the pile fans out where it sits, a drag is on, a toast covers it, or the shelf is tucked away or empty. Quiet (secondary label colour) until the pointer is on it. Tooltip: "Take every card off the shelf. The files stay in their folder."
  - Also in the pile's right-click menu, and in the menu bar menu (§6). The DEBUG `clear` command is Close Shelf.
  - As for a tuck: a rename in progress keeps what was typed, Quick Look closes, and the keys go back to the app you're in (the shelf is gone, so nothing on it needs them). Shots in the air fade away; a recording's card just leaves, its file stays.
  - The toast: "Shelf closed · Restore Last Removed brings it back" (two lines, 2.4 s).
  - A shot in the Pasteboard folder (Delete screenshots after pasting, §14.2) is kept too: see §14.2.
- **Material.** The pile, tuck tab, toasts and the Close Shelf button use Liquid Glass (`NSGlassEffectView` or SwiftUI `.glassEffect()`). Cards are plain image cards.
- **Fly-in.** On release, a temporary transparent panel animates the image from the selection rect to its slot (about 0.45 s, spring), then hands off to the real card.
  - The new card gets a 2 pt accent ring for 1.5 s.
  - If the shelf is tucked, the shot flies into the tab and the count goes up. The shelf stays tucked.
- **Hover.** The card scales to 1.04 and shows:
  - ✕ (top-right, red; since 0.0.6) to dismiss.
  - ••• (top-left, tooltip "Options"; since 0.0.6) for the menu.
  - A meta line at the bottom: `HH:mm · W × H`.
- **Tuck.** ⌘⇧1 slides the shelf off the edge and leaves a 22 pt tab showing the count. Hovering the tab peeks the shelf; clicking it shows the shelf. Tucking (or the end of a peek) gives the keys back. Tucking keeps what a rename in progress has typed; a peek doesn't end while a rename is open.
- **Toasts.** Inside the shelf, above the top card, never as notifications: "Copied", "Path copied", "Restored", and error messages. They last 1.2 s. A message too long for one line wraps (up to three lines); the Unsaved warning (§3) stays 4 s.
- **VoiceOver.** The shelf window is "Margin Shelf". Its elements, top to bottom: the Close Shelf button (button "Close shelf", there whether or not the pointer is over the shelf), the pile (button "12 older screenshots"; press = a click, which gives the shelf the keys; action Close shelf), each visible card, and the tab while tucked (button "Show shelf, 5 screenshots"; only the tab while tucked and not peeking).
  - A card is a button labelled "Screenshot, 14:32, 3024 × 1964", plus "selected", "copied, ready to paste" (the ⌘V mark) and "saving" (pending) as they apply; its help is the file name. Press copies, as a click does; Show Menu opens the ••• menu.
  - Its actions: Copy, Open, Quick Look, Show in Finder, Copy Path, Rename, Remove from shelf, Move to Trash (only Copy and Remove from shelf while saving). Each does what its mouse twin does, keys included: only Quick Look, Rename, Remove from shelf and Move to Trash give the shelf the keys.
  - ✕ ("Remove from shelf") and ••• ("Options", a menu button) are buttons inside the card, there whether or not the pointer is over it.
  - Toasts are posted as announcements (`announcementRequested`, high priority). The panel stays non-activating, and VoiceOver's cursor never makes it key (focusing an element, or raising the window: `accessibilityPerformRaise` only orders it front).
- **Persistence.**
  - `~/Library/Application Support/Margin/shelf.json`.
  - Since 0.0.16 it's written off the main thread, on a serial queue that always ends with the newest list. A capture's card is in the file before its PNG is written (§3), and quitting waits for writes still on their way.
  - Store items in order with **bookmark data**, so moved files are followed, plus the date and pixel size.
  - Items survive quit and reboot.
  - Read item by item: an item that can't be read (a damaged file, or one written by a newer version) is skipped, not the whole shelf. A file with anything unreadable in it is kept as `shelf.json.bad` (never replacing an earlier one) before anything saves over it.
  - Drop any item whose file no longer resolves. Check at launch, whenever the shelf appears, and when a drag starts.
  - A file on a volume that isn't mounted (an unplugged disk, a disconnected share) hasn't gone: keep its card.

## 5. Shelf interactions

The shelf never steals focus. A click (copy) or double-click (open) leaves the keyboard with the app you're in, so ⌘V right after a click pastes there. The shelf takes the keys (the panel becomes key without activating Margin) only when they're needed next: ⌘-click, ✕ (so ⌘Z brings the card back), Rename…, Move to Trash, or a click on the pile. Esc, a copy (click, ⌘C, Copy Path), tucking, Close Shelf, a rename that ends because a new shot pushed its card into the pile, or a click elsewhere gives them back, and so does a card's or the pile's menu closed without a choice (Esc, a click elsewhere), unless the shelf had them when it opened. So does the menu bar menu, however it closes (none of its items needs the shelf's keys), unless the shelf had them when it opened.

| Input | Result |
|---|---|
| Drag a card | Drags a **plain file URL** (`NSURL` pasteboard writer, `.copy` only, never `.move`). The card stays faint in its slot during the drag. If `operation` is non-empty at the end, the card collapses out and the rest settle. On cancel, it springs back. A fresh card whose PNG is still being written starts its drag as soon as the file lands, if the button is still down (a release before that does nothing) |
| ⌥ held when the drop lands | The card stays on the shelf |
| ⌘-click | Toggle selection. Dragging a selected card drags all selected cards (stacked drag image with a count badge). ⌘C copies all selected cards as images |
| Click | Copies that shot at once (same clipboard write as §3), moves the ⌘V mark to it, shows the toast "Copied". The keyboard stays with the app you're in |
| Space | Quick Look (`QLPreviewPanel`) for the focused card or the selection. Like the shelf, it takes the keys without activating Margin (its panel is made non-activating): Space or Esc closes it and ← → step through the shots. Closing it (also with its close button, a copy or tucking) gives the keyboard back, as Esc does; after its full-screen button, which makes Margin the active app, activation goes back to the app you were in. Clicking another app closes it |
| ⌫ | Dismiss. The file stays on disk (a Pasteboard shot's, §14.2, until ⌘Z can't bring the card back) |
| Two-finger swipe right on a card | Dismiss |
| Double-click | Open with the default app (its first click has already copied the shot) |
| ••• / right-click | Copy path · Reveal in Finder · Rename… (inline; renames on disk) · Move to Trash |
| ⌘Z | Restore the last removed card(s). Keeps up to 20 steps, covering drag-out, dismiss, Close Shelf and trash (trash restores the file from the Trash; a file already back through Finder's Put Back counts as restored). Steps restore one at a time, newest first: a ⌘Z pressed while a file is still coming back from the Trash waits for it. Files are checked first: a card whose file was deleted meanwhile stays off the shelf ("File not found"), and that step is used up |

- **Drop success.** Never delete or move the file because of a drag. "Success" means only that the card leaves the shelf. (Since 0.1.2 a shot in the Pasteboard folder of Delete screenshots after pasting is deleted once its card is gone for good, at least 30 s after the drop, §14.2; it's never moved.)
  - If an app reports success wrongly, **Restore Last Removed** in the menu bar brings the card back. A drag never gives the shelf the keys (§5 intro), so ⌘Z right after a drop goes to the app it was dropped into; on the shelf, ⌘Z works after a ⌘-click or a click on the pile.
  - If an app reports failure wrongly, the card stays and ⌫ removes it.
- **⌘V mark.** A small accent pill reading "⌘V" sits at the bottom-right of the card whose image is on the clipboard.
  - Poll `NSPasteboard.general.changeCount` about once a second. If it differs from the count recorded after Margin's last write, clear the mark.
  - If the marked card is removed, the mark goes with it.
  - Copy Path clears it at once: the clipboard then holds the path, not the image.

## 6. Menu bar

- Template icon: SF Symbol `rectangle.righthalf.inset.filled`, with `sidebar.right` as a fallback.
- Menu items, in groups (since 0.1.3; Close Shelf is new, and Check for Updates… moved above About, Quit below a separator; since 1.0.0 the status line and Hide from Menu Bar):
  - The status line, then —: a coloured dot and Margin's state in secondary text, not a choice (since 1.0.0): "Recording" (red), "Screen Recording needed" or "A shortcut isn't working" (orange), else "Ready to capture" (green). The foot of Settings' sidebar says the same
  - Stop Recording ⇧⌘5, then —, while recording (since 0.1.0, §14.4)
  - The warnings, then —, while there are any (below)
  - Capture Area ⌘⇧4
  - Capture Window
  - Capture Screen ⌘⇧3
  - Repeat Last Area ⌘⇧2
  - Record Screen ⇧⌘5 (since 0.1.0; hidden while recording)
  - —
  - Tuck Shelf / Show Shelf ⌘⇧1 (disabled while the shelf is empty)
  - Close Shelf (since 0.1.3, §4; disabled while the shelf is empty)
  - Restore Last Removed (disabled when there's nothing to restore)
  - —
  - Open Screenshots Folder (creates it if missing; if it can't be opened, says so in a toast, and opens the Unsaved folder instead when that holds shots)
  - Show Unsaved Shots (only while `~/Library/Application Support/Margin/Unsaved/` holds shots; opens it in Finder. The menu is built synchronously, so it reads a flag that's checked off the main thread at launch and on each menu open, and set by a fallback save)
  - —
  - "macOS still uses ⇧⌘4 — Fix…" (only while a macOS shortcut takes one of Margin's keys)
  - Settings… ⌘,
  - Check for Updates… (since 0.1.1, §14.3)
  - About Margin (since 1.0.0 it opens Settings › About)
  - Hide from Menu Bar (since 1.0.0; not while something needs attention, below)
  - —
  - Quit Margin ⌘Q (no symbol)
- No section headers (`NSMenuItem.sectionHeader`): the separators group it, and headers would make a short menu taller.
- The warnings: a failed hotkey registration ("⇧⌘4 is used by another app — Change in Settings…", which opens Settings at Shortcuts), then, if Screen Recording permission is missing, "Allow Screen Recording…", which opens First run step 1 (the icon also gets a warning dot), and while permission is revoked, "Relaunch Margin". Until 0.1.2 "Allow Screen Recording…" took Capture Area's place; now every capture item stays, and each opens the permission step without permission.
- The shortcuts shown are for when the menu is closed. While any menu of Margin's is open, AppKit holds hotkeys back and delivers them when it closes; a press made while it was open (its event time between the menu opening and closing) is dropped, so it does nothing instead of capturing late. Not one in the last 0.5 s before AppKit reports the close: the menu is fading out then (about 0.25 s after Esc, 0.35 s after a choice), so a shortcut pressed right after dismissing the menu still works.
- Key order in all UI and docs follows macOS (⌃⌥⇧⌘, e.g. ⇧⌘4); older sections of this spec write ⌘⇧4, which means the same keys.
- **Hide from Menu Bar** (since 1.0.0, after Paneflo's): the menu item, or Settings › General › **Show menu bar icon**. Margin keeps running, with its shortcuts and the shelf. The first time it asks ("Hide Margin from the menu bar?", **Hide** / **Cancel**, and **Don't ask again**): a sheet on Settings when it's open, else an alert. Opening Margin again (Spotlight, Launchpad, Finder) brings the icon back and opens Settings at General with "Menu bar icon restored." under the switch. A hidden icon never strands the user: while Screen Recording is missing or a shortcut didn't register, the item isn't offered and the switch can't hide it (Settings says why), and an icon hidden earlier comes back by itself, with its dot. A recording shows it for as long as it runs (its time and Stop are there), without changing the choice. `MenuBarIconPolicy` (MarginKit) holds the rules; `menuBarIconHidden` and `menuBarIconHideSkipsConfirmation` are the defaults keys.
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
   - Show the note: ⌘⇧5 stays with macOS for screen recording. (Since 0.1.0 the list has 184, ⇧⌘5, too, and the note says Margin records the screen with it: §14.4.)
3. **Take your first shot:** "Press ⌘⇧4". It also notes that launch at login is on.

## 8. Settings

Since 1.0.0 Settings is laid out like Paneflo's, after System Settings: a 700 × 720 pt window (resizable, at least 640 × 440) with a sidebar of panes, each with a white symbol on a coloured tile, in two groups: **General**, **Shortcuts**, **Recording**, then **Updates**, **About**. Each pane starts with its tile, title and one sentence, then a grouped form that scrolls if the window is shorter. The foot of the sidebar is the menu's status line, with **Allow Screen Recording…** or **Change Shortcuts…** when that fixes it; Shortcuts gets an orange dot while a shortcut isn't working. **General** (Saving & Clipboard: Save to, Copy each capture, Delete screenshots after pasting; Capturing: Shutter sound, Show key hints while capturing; Startup: Launch at login; Menu Bar: Show menu bar icon, §6), **Shortcuts** (Margin's recorders in the menu's order, with Capture window shown as "Space after ⇧⌘4"; then the macOS screenshot shortcuts' status with **Turn Off** or **Restore**), **Recording** (Record system audio, Record microphone), **Updates** (the version and build, Check for updates automatically, the last check's time with **Check Now**) and **About** (the icon, version, Website, Source Code, Report an Issue, the licence and "No analytics"). From 0.1.3 to 0.1.4 the panes were toolbar tabs, the window as tall as each. Save to shows the folder by name, with its path as the tooltip. A toggle whose effect isn't obvious says it in a line under its title (Delete screenshots after pasting, Show key hints, Check for updates, the audio toggles). Section headers and buttons are title case, toggles sentence case. The Shortcuts footer: "Click a shortcut, then press the new keys. Each capture shortcut also works with ⌃ added (⌃⇧⌘4), since every shot is already copied." The window opens on the pane last used; the menu's shortcut warning opens it at Shortcuts, About Margin at About. Switching panes stops a shortcut recorder that's listening.

The settings, as first built (0.0.1 had six, in one small SwiftUI window):
- **Save to** (folder picker).
- **Copy each capture** (on).
- **Shutter sound** (on).
- **Show key hints while capturing** (on): the hint bar at the top of the capture overlay.
- **Launch at login** (on; `SMAppService.mainApp`).
- **Record system audio** and **Record microphone** (both off; since 0.1.0, §14.4).
- **Shortcuts:** recorders for Area, Screen, Repeat area and Tuck shelf (and Record screen since 0.1.0). A recorded combo needs ⌘ or ⌃, and is refused (with the reason, `ReservedShortcuts`) when it's ⌘ or ⌃ with one typing key, a combo macOS or most apps use (⇧⌘Z, ⌃⌘Q, ⌥⌘⎋…; ⇧⌘5 only while macOS's own ⇧⌘5 is on, §14.4), or an enabled system shortcut from `com.apple.symbolichotkeys`. Window mode is always Space from area mode, and the ⌃ twins follow automatically.
  - A recorder listens until it gets a combo (or Esc, or Delete), is clicked again, or the Settings window loses the keys: to another app, or to a sheet (Choose…'s folder panel, whose ⇧⌘G goes to a folder, never to the recorder).
  - Keys are named as the keyboard layout types them (`KeyboardLayout`), in Settings and the menu; a combo with ⌘ as its key types with ⌘ held, as menus name it. Menu shortcuts are refused by that name: Redo is ⇧⌘ on whichever key types Z with ⌘, which on "Dvorak – QWERTY ⌘" is where QWERTY has Z.
- **Check for updates automatically** (on; since 0.1.1, §14.3), between Show key hints and Launch at login.
- **Delete screenshots after pasting** (off; since 0.1.2, §14.2), under Copy each capture.

## 9. Not in 0.0.1

- Pin to screen, OCR/QR, timer, history.
- Annotate, blur, scrolling capture, GIF, file-name tokens. (Screen recording is in since 0.1.0, §14.)
- A general file shelf (dropping other files onto the shelf).
- Cloud/uploads, accounts, AI.
- Intel builds, notarization. (Updates from GitHub are in since 0.1.1, §14.)

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

## 14. Features after the passes (user request, 17 Oct 2026)

Shipped in this order: six cards (0.0.19), screen recording (**0.1.0**), updates and the website (0.1.1), delete after pasting (0.1.2). None of them may slow a screenshot: nothing new runs on the capture path, and recording code runs only while recording.

### 14.1 Six cards
The shelf shows up to 6 cards (was 4), fewer when they don't fit; see §4.

### 14.2 Delete screenshots after pasting (0.1.2)
- **Setting:** "Delete screenshots after pasting" (off by default), under Copy each capture.
- **While on**, a screenshot isn't saved to the Save to folder. Its PNG goes to `~/Library/Application Support/Margin/Pasteboard/` (same name, temp + rename, xattrs; Margin's own folder, so no privacy prompt), and it still goes on the shelf and, with Copy each capture, the clipboard. If that folder can't be written, the shot falls back to Unsaved as usual and is a normal file from then on.
- **Pasted = read by another app as ⌘V or ⌃V is pressed.** The clipboard item is written with a data provider (`NSPasteboardItem.setDataProvider`) for `public.png` and `public.file-url`, kept on this Mac (`prepareForNewContents(with: .currentHostOnly)`), so Margin learns when another app reads it. A read of either type counts as a paste when ⌘ or ⌃ is held and a key went down at most 0.3 s before it and after the write, and the read is at least 0.15 s after the write (`CGEventSource`, combined session state, which needs no permission; `PasteKeys`): the card leaves the shelf (as after a drag-out, one ⌘Z step, with Restore Last Removed). A read with no paste keys held is someone looking (a clipboard manager, Spotlight's clipboard history, another device), not a paste, and the card stays. A shelf copy (click, ⌘C) of a Pasteboard shot re-arms it. A drag out of the shelf also counts, as for any card. A paste from the Edit menu doesn't count, nor one whose read comes after the keys are up or more than 0.3 s after the key (a slow ⌃V in a terminal); the card stays. Nor does a read while Margin itself has the keys (in front, or with a key window: ⌘V in Rename…), since the keys went to Margin, nor one followed by another app coming to the front once ⌘ is up (⌘Tab: a clipboard manager polling as Tab went down); so the card leaves only once ⌘ and ⌃ are let go.
- **When a file goes.** A Pasteboard file is deleted only once nothing can reach it: its card has left the shelf, its ⌘Z step can no longer bring it back (pushed out by newer steps; quitting ends them all), at least 10 s have passed since a paste (30 s since a drop), so apps that read the file lazily still get it, and the clipboard no longer holds it (Margin's last write with it is no longer the pasteboard's, by change count). A dismissed card's file follows the same rule. A trashed card's file is in the Trash and is left there. Files of cards still on the shelf survive a relaunch; 30 s after a launch (so a paste or drop just before a quit still gets its 10 s or 30 s), files in that folder that no card holds (by path or bookmark), the clipboard doesn't offer and no set-aside `shelf.json.bad` names are deleted, and no others anywhere. Save to can't be the Pasteboard folder (it reads as the default).
- **Close Shelf** (§4, since 0.1.3) keeps what wasn't pasted: each Pasteboard file of the cards it takes off moves into the Save to folder (Unsaved if that can't take it, with the usual toast) under its own name, ` (2)` when that's taken, and is a normal file from then on, whether or not the option is still on. Its ⌘Z step (or its card, if ⌘Z brought it back meanwhile) points at it there. A clipboard item watched for a paste offers the new file URL while it's still promised, without a new change count (`PasteWatch.relocate`). Once an app has read the file URL (or the write wasn't watched), the pasteboard keeps the one it has, so that shot is copied instead: the clipboard keeps offering the Pasteboard file, deleted once the clipboard moves on. A shot still being saved moves when its save lands, and a rename the close saved lands first. Never a file that's gone, nothing while the Pasteboard folder is a link, and nothing is ever replaced (`PasteboardShots.keep`).
- **Turning it off** moves and deletes nothing: new shots go to Save to again, and copies are written as before (`setData`, no providers). Cards already holding Pasteboard files stay; a paste no longer takes them off the shelf, and their files go only once their cards are gone for good, by the rule above. Screen recordings are always saved.
- **Off costs nothing:** the clipboard write, the save path and the shelf are as before, with no provider, observer or timer; retention runs on the ⌘V mark's existing one-second tick and does nothing while no file waits.
- **Caveats (docs):** a clipboard manager that reads every copy (images included) gets the data first, after which a paste can't be told from it, so cards stay until dismissed. Pasteboard shots aren't offered to other devices through Universal Clipboard. Spotlight's clipboard history lists one only once it has been pasted, and keeps the entry after its file has gone.
- **As built** (why the first draft changed): the draft counted the first read by any other process as a paste, and deleted the file 10 s after. On macOS 27.0.1 (this Mac: Handoff off, Spotlight's clipboard history on, no third-party clipboard manager), with a test item written normally, `pboard` (its Universal Clipboard and content-type pipeline) read `public.file-url` 15–45 ms after every write, and Spotlight's history (process "Siri AI") read it about 60 ms after (from `pboard`'s copy); nothing read `public.png` until an app pasted. A provider is asked once per type (the pasteboard keeps the data), and one that gives nothing is never asked again. Written `currentHostOnly`, nothing read either type until a paste (Spotlight skips promised data, and indexes the item once a paste has resolved it). So the item is local-only, and the keys decide, which also covers third-party managers. Not "V down with ⌘ or ⌃", as first built: `CGEventSource.keyState` reports a letter only to the app in front (two test apps without Input Monitoring: the one in front saw V, the one behind never did), and Margin is behind when another app pastes; it does see the modifiers and how long ago a key went down. The key must come after the write, so ⇧⌘3's own keys, still down as its shot is copied, don't count; the 0.15 s keep out whatever reads every change at once. The file stays as long as ⌘Z can bring its card back, or the clipboard can still paste it, as "never lose a file the user can still reach" requires; the 10 s and 30 s are the least it waits.

### 14.3 Updates and the website
- **Menu:** "Check for Updates…" below About Margin. **Settings:** "Check for updates automatically" (on): at launch (after prewarm, never on the capture path) and every 24 h. It only calls GitHub's public API; nothing about the user is sent.
- **Check:** `GET https://api.github.com/repos/Jenish-Shobhit/margin/releases/latest`. The tag `vX.Y.Z` is compared with `CFBundleShortVersionString` as a semantic version. Newer: a small window "Margin X is available — you have Y", with the release notes, and **Install and Relaunch** / **Later** / **Skip This Version**. A manual check with nothing newer says "Margin Y is up to date." Errors say what failed and offer the releases page.
- **Install:** download the release asset `Margin-X.zip` (progress in the window) to a temp folder; unzip with `/usr/bin/ditto -x -k`; refuse unless the new bundle's ID is ours, its version is X, `codesign --verify --deep --strict` passes, and it satisfies the running app's designated requirement (same signing certificate, so Screen Recording permission carries over). Then a detached helper waits for Margin to quit (after the usual wait for saves), replaces the app where it is (the old one goes to the Trash), clears any quarantine attribute, and opens the new one. If the app's folder isn't writable, say so and open the release page instead.
- **URL scheme:** `margin://update` (`CFBundleURLTypes`) runs a check and shows its result. It never installs without a click in Margin's window: any page or app can open the link, so the offer it shows has no default button (a stray Return doesn't install).
- **Website:** `docs/index.html`, one self-contained page for GitHub Pages (served from `main` › `/docs`), with no external scripts, fonts or styles: icon and headline, **Download Margin X** (resolved from the GitHub API on load, falling back to the releases page; every download link on the page gets the zip), the one-line Terminal install (`curl -fsSL https://jenish-shobhit.github.io/margin/install.sh | bash`, with a Copy button), `demo.gif` in a MacBook frame (a Pause/Play button swaps it for `images/demo-poster.jpg`, which is also what Reduce Motion shows first), what Margin does, the overlay and the shelf (`capture.png`, `shelf-states.png`), the global shortcuts, install steps (Open Anyway), **Update Margin** (a `margin://update` link, with "or choose Check for Updates… in Margin's menu"), requirements, privacy and the permissions it asks for. Its Open Graph/Twitter card is `images/og.png`. It follows `prefers-color-scheme` and `prefers-reduced-motion`, and works at phone width.
- **Terminal install:** `docs/install.sh`, served next to the page. A file curl downloads isn't quarantined, so Margin opens with no Gatekeeper dialog while it isn't notarized; the script stands in for those checks. It asks the GitHub API for the latest release, downloads `Margin-X.zip` only once uploaded, refuses it unless its size and SHA-256 match what GitHub lists, it unzips (`ditto`) to Margin's bundle ID at version X, and `codesign --verify --deep --strict` passes against Margin's designated requirement (its certificate's leaf hash, pinned). It never sends Margin an Apple event (that raises an Automation prompt): if Margin is running, it asks the user to quit it and waits. The old copy goes to the Trash as "Margin <old>.app". Already at X, it only opens Margin. Requires macOS 26+ on Apple silicon.
- `scripts/release.sh` keeps naming the asset `Margin-<version>.zip`; the updater depends on that name.
- **As built** (decisions the bullets above leave open):
  - *Schedule.* The launch check runs 3 s after prewarm (or at once without permission, as there's no prewarm), unless a check got an answer less than an hour ago (a relaunch, an update); then one is due 24 h after the last answer, looked at hourly (so a Mac that slept catches up). A check that's due during a capture or a recording waits a minute (its window would be in the shot), and an offer that arrives during one waits until it's over. A failed automatic check is only logged, and tried again at the next hourly look.
  - *What's offered.* Only a release (not a draft or pre-release, and not a tag with a pre-release suffix) newer than the running version; a running copy newer than the latest release (a build of `main`) is up to date. Skip This Version holds for automatic checks of that exact version; a manual check (the menu, `margin://update`) still offers it. Later just closes the window, so the next automatic check offers it again. An automatic check's window comes to the front without taking the keyboard; a manual check's activates Margin.
  - *Requests.* Ephemeral `URLSession`s (no cookies, no cache), the user agent `Margin/<version>`, https only, redirects only to https. The download stops as soon as it's bigger than the size GitHub lists (512 MB if none is). A newer release without its zip is an error, not "up to date".
  - *Checks before installing.* The zip's size and, when GitHub lists one, its SHA-256 `digest`; `Margin.app` at the zip's top level (a folder, not a link); the bundle ID and version from its `Info.plist`; the Security framework's `codesign --verify --deep --strict` (`SecStaticCodeCheckValidity` with `kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate | kSecCSRestrictSymlinks`), then the same with the running copy's designated requirement (`SecCodeCopySelf` → `SecCodeCopyDesignatedRequirement`). A running copy signed ad hoc refuses at once ("can't be checked against it") and opens the releases page, as does one that's translocated or not a bundle.
  - *Staging and the swap.* The zip downloads into a temporary folder on the app's own volume (`FileManager`'s item replacement directory), so the helper's last step is a rename. The helper is `/bin/sh` (`UpdateInstall.helperScript`), started with `Process` before Margin quits (no sooner than 30 s after Margin's own launch, `UpdateInstall.relaunchDelay`: relaunched sooner, macOS asks whether Margin may bypass the private window picker): it waits up to 30 s for Margin's pid to exit (otherwise it changes nothing), moves the old app into the Trash folder with `mv` as `Margin <old version>.app` (` 2`, ` 3`… beside an earlier one; `NSWorkspace.recycle` can't run once Margin has quit, so Finder's Put Back doesn't know it), moves the new one into place, putting the old one back if that fails, clears `com.apple.quarantine`, `open -g`s the app at that path (the new one, or the old one after a failure), so the app the user is in keeps the keyboard, and deletes the staging folder. Each step goes to `~/Library/Logs/Margin/Update.log`. `LaunchGuard` covers the new copy starting while the old one is still going.
  - *Quitting* goes through `NSApp.terminate`, from the run loop rather than a main-queue block, so the usual wait for saves works. If Margin is still running 35 s later, the window says it didn't quit.
  - *After the relaunch.* Margin remembers the version it was installing (`pendingUpdate`). The next launch says "Updated to Margin X" in the shelf, or, when it's still the old version, shows the window with the helper's last `FAILED:` line.
  - *Not writable:* the app's folder or the bundle itself (`FileManager.isWritableFile`); the window says so and the releases page opens.
  - *Website:* `docs/.nojekyll` makes Pages serve the folder as it is. The API is asked once per page load; a failure leaves the button on the releases page.

### 14.4 Screen recording (0.1.0)
- **Shortcut:** ⇧⌘5 **Record Screen** (new `ShortcutAction`, rebindable; its ⌃ twin like the others). macOS's own ⇧⌘5 (symbolic hotkey **184**, "Screenshot and recording options") must be off for Margin to get it. "Turn off for me" (First run) and "Turn off macOS screenshot shortcuts" (Settings) now cover 184 with 28–31, still only on the user's click; "Restore" re-enables all five. Until then the Record row shows the usual "macOS uses ⇧⌘5" warning (any row whose keys an enabled macOS screenshot shortcut takes first shows it), and the menu's "macOS still uses ⇧⌘5 — Fix…". ⇧⌘5 leaves `ReservedShortcuts.common` (an enabled 184 is still caught as a system combo: `SystemShortcuts.otherEnabledCombos` counts it, with its default binding when the entry is missing, so ⇧⌘5 is refused for every action but Record Screen). First run's note about ⇧⌘5 now says Margin records with it.
- **Start:** ⇧⌘5 opens the capture overlay in record mode (the same frozen overlay and keys): drag an area, Space for a window, or click without dragging (or ↩ with no selection) for the whole display under the pointer; a click outside a kept selection only clears it, as for a screenshot. The hint bar says "Drag an area · Space Window · Click for the whole screen · Esc Cancel" until there's a selection, then the area hints with "↩ Record"; window mode has no ⌥ (a recorded window never has its shadow). Recording starts as soon as the overlay closes and focus is back with the app the user was in; the shutter sound doesn't play (macOS's short `begin_record` tick if Shutter sound is on, at the first frame).
- **While recording:** the status item shows a red stop glyph and the elapsed time (m:ss); its menu's first item is **Stop Recording ⇧⌘5** (and Record Screen is hidden). ⇧⌘5 again also stops. Margin's own windows (shelf, fly-ins, toasts, overlay) are excluded from the recording, its ordinary windows (Settings…) aren't, as in screenshots (the stream takes the cache's new filter when the ordinary windows of Margin's in it change: Settings opened or closed; other rebuilds of the cache leave the stream alone); screenshots still work during a recording. A display that disappears, a recorded window that closes, sleep (the Mac's or the displays'), another user taking over, a nearly full disk, a file as big as its disk allows (FAT32's 4 GB), macOS stopping it (its menu bar indicator) or a ScreenCaptureKit or encoder error stop the recording and keep what was recorded (with a toast saying why; after an encoder or disk error, up to its last fragment, below). "Nearly full" is under 400 MB free, checked every second on the temp file's own volume, so the file can still be finished; the free space is what macOS can make room for (`volumeAvailableCapacityForImportantUsageKey`: APFS's purgeable space counts), asked only once `statfs` says under 400 MB (it takes 7–130 ms); a folder already that full at the start counts as unwritable (the Unsaved fallback). On a volume with a file size limit (`volumeMaximumFileSizeKey`; FAT32: 4 GiB less a byte) the recording stops 128 MiB short of it. The display is kept from idle sleep while recording (a power assertion). Quitting stops and saves the recording first, waiting up to 15 s. **A stop never hangs:** ScreenCaptureKit gets 3 s to stop the stream (then the file is finished anyway, nothing after the stop in it), the whole stop 10 s (then the file is taken as it is, up to its last fragment: "The recording couldn't be finished: saved up to 0:42"), and putting the file in place 5 s more (then Margin is idle again, and the card comes if the file gets there).
- **Capture:** `SCStream` at the display's native pixel size (Retina), the display's refresh rate up to 60 fps, cursor shown, pixel format 420v (no colour conversion before the encoder; sRGB, BT.709), area via `sourceRect` and window via a desktop-independent window filter (opaque, no shadow, its size at the start; scaled down to fit, keeping its aspect ratio, if it grows). Sides are rounded down to even. A display beyond H.264 level 5.2 at its frame rate (more than 4K at 60 fps: 5K, 6K) is scaled down to fit, keeping its aspect ratio: H.264 can't take it whole. **Audio:** Settings "Record system audio" (off; Margin's own sounds excluded; no permission beyond Screen Recording) and "Record microphone" (off; turning it on asks for microphone permission, `NSMicrophoneUsageDescription`, and a recording that finds it still undetermined asks then; the hardened runtime needs the `com.apple.security.device.audio-input` entitlement). With both on, each is its own AAC track (system audio first) rather than a mix; QuickTime plays both, some players only the first.
- **Encode:** `AVAssetWriter`, hardware H.264 (High profile, a key frame every 2 s, no B-frames), MPEG-4 (`.mp4`, plays everywhere a pasted video is accepted; its index at the end, as written: moving it to the front would rewrite the whole movie at the stop, needing as much free space again), AAC audio. Written in **one-second movie fragments** (`movieFragmentInterval`): the index goes in with the first, a `moof` with each one after, so a file that's never finished (the writer failed, a full disk, a crash, a stop that gave up) plays up to its last fragment; finishing turns it into an ordinary MP4 with its index at the end (the same layout and brands as without fragments, about 500 bytes a second bigger, finished in a few ms). Real-time input, no frame copies, frames dropped rather than queued when the encoder falls behind. Bit rate scaled to pixels × fps so UI text stays sharp: 0.075 bit per pixel per frame, 2–100 Mbit/s (about 25 Mbit/s for 2940 × 1912 at 60 fps; ScreenCaptureKit sends a frame only when the screen changes, so a still screen costs far less). The last frame is held until the stop, so the file lasts as long as the recording.
- **File:** `Screen Recording yyyy-MM-dd 'at' HH.mm.ss.mp4` (start time) in the Save to folder, same rules as screenshots (Unsaved fallback, temp + rename); the temp file (`.margin-recording-<uuid>.mp4`) is finalised on stop. It's held open from its start, and named where it is at the stop: its folder renamed or moved meanwhile, in there ("Saved to “X”: the save folder was renamed or moved while recording"); in the Trash, deleted (copied out of the open file: a clone on APFS, instant and needing no free space) or no longer taking a rename, in Unsaved, with its toast ("“Screenshots” is in the Trash."). A writer that failed, or a finish that failed, leaves the file as it is, which is kept, with the length it has, if it has its index, and removed if not (cut off in its first second). A temp file left behind is dealt with by the next recording, in the folder it records into and in Unsaved, not at launch (which would look into the save folder): one that plays (a finished movie whose rename didn't happen, or one cut off by a crash, a forced quit, the quit's 15 s or a power loss, up to its last fragment) gets its `Screen Recording` name from its creation date, as a leftover screenshot does; one whose rename fails stays for the next time; only one with nothing that plays (no index) is removed.
- **Shelf:** a card like a screenshot's, with the poster frame (the first frame), a play glyph and the duration ("0:12") at the bottom-left, and the duration in the hover meta line. Drag, click to copy (`public.file-url` only; a mixed selection copies each card as its kind), double-click to open, Quick Look plays it, ✕, ⌘Z, the pile: all as for screenshots. `ShelfItem` gains a kind (screenshot or recording; missing means screenshot, so old shelf.json files load) and a recording's duration. Copy each capture puts the recording's file URL on the clipboard when it's saved, with the ⌘V mark.
- **Performance:** nothing of recording runs until ⇧⌘5. While recording, screenshot latency stays within 10% of not recording, and CPU stays low (hardware encoder; measure and document %CPU for a full-display 60 fps recording: `scripts/bench.sh record`, and `ab --record-b` for captures during a recording). Measured on a MacBook Air M2 at 2940 × 1912 pixels, 60 Hz: Margin at about 8% of one core (the system's encoder service about 6% more) for a full-display 60 fps recording of moving content, 60 frames a second with none dropped, memory flat over 5 minutes, 66–88 MB a minute; captures during it within ±6%; see architecture.md › Screen recording.
- **As built: failures** (after a review, 18 Oct 2026). Fragments were checked first: the finished file is the same plain MP4 as before (`ftyp`, `mdat`, `moov` at the end; brands `mp42`, `isom`, `mp41`), which `AVURLAsset` (its length), `AVAssetImageGenerator` (the shelf's poster frame), Quick Look and `avmediainfo` read as before. An A/B of bench builds recording a 2880 × 1800 window at 60 fps (eight 20 s rounds each, interleaved) measured Margin at 8.3% of a core against 8.1% (block by block 8.9/9.2, 8.1/7.4, 8.0/8.0: within the noise), the encoder service at 4.7% both, no frame dropped and the same file sizes. A writer that ran out of space on a FAT32 disk, or was cut off by `_exit`, kept all but its last second. `SCStream` lets go of its outputs once stopped (debug builds count the recorders alive: 0 after every recording), so the recorder doesn't leak and needs no `removeStreamOutput`.
