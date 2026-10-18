# Changelog

All notable changes to Margin are listed here. Versions follow [Semantic Versioning](https://semver.org).

## Unreleased

### Changed

- Showing the frozen screen after ⇧⌘4 no longer holds Margin's main thread for about 4 ms per display: the frame is copied in the background, with the same pixels and the same files. Thumbnails reach the shelf about 1 ms sooner.

## 0.1.3 — 2026-10-18

### Added

- Close Shelf: a "✕ Close Shelf" button above the stack (it shows when the pointer is over the shelf), and Close Shelf in the menu bar menu and the pile's menu, take every card off at once. The files stay in your folder, and Restore Last Removed brings them all back. It replaces Clear shelf, and gives the keyboard back to your app.
- With Delete screenshots after pasting on, Close Shelf keeps the shots you haven't pasted: they move into your Save to folder as normal files.

### Changed

- Settings has General, Shortcuts and Recording panes, none taller than a small display, with a line under each option whose effect isn't obvious. The note about ⌃ now says what it means: each capture shortcut also works with ⌃ added, since every shot is already copied.
- The menu bar menu is grouped: captures, shelf, files, then Margin, with Quit on its own. Without Screen Recording permission, every capture item stays.
- The shelf thumbnail appears 2–5 ms sooner after a capture (it's made ahead of the PNG encode), and with Copy each capture on, the clipboard is written as soon as the file is in place.

## 0.1.2 — 2026-10-18

### Added

- Settings › Delete screenshots after pasting (off). While it's on, screenshots go to Margin's own folder instead of your save folder, and one you paste with ⌘V or ⌃V, or drag into an app, leaves the shelf. Restore Last Removed (or ⌘Z on the shelf) brings it back with its file. The file is deleted only once undo can't bring it back and the clipboard no longer holds it, and never sooner than 10 seconds after a paste (30 after a drag). A shot you dismiss, or clear from the shelf, goes the same way. Screen recordings are always saved.
- A paste is recognised from the keys you press. Edit › Paste from a menu, or an app that reads the clipboard only after you've let go of ⌘, doesn't count, and the card stays. With a clipboard manager that saves images, pastes may go unnoticed the same way. While the option is on, shots aren't offered to your other devices through Universal Clipboard.

## 0.1.1 — 2026-10-18

### Added

- Check for Updates… in the menu bar menu, and Settings › Check for updates automatically (on). Margin asks GitHub for the latest release at launch and once a day, never in the middle of a capture or a recording, and shows what's new with Install and Relaunch, Later and Skip This Version.
- Install and Relaunch replaces Margin only with the release's own zip, at the size and checksum GitHub lists and signed with the same certificate as your copy, so Screen Recording permission carries over. The old copy goes to the Trash.
- Margin's website, with Download Margin and Update Margin buttons. `margin://update` checks for updates; it never installs without a click in Margin's window.

## 0.1.0 — 2026-10-17

### Added

- Screen recording with ⇧⌘5. Drag an area, press Space and click a window, or click for the whole display; press ⇧⌘5 again, or choose Stop Recording in the menu bar, to stop. The recording is saved as `Screen Recording … .mp4` (hardware H.264 video, AAC sound) in the save folder, at the display's full Retina resolution and up to 60 frames a second.
- While recording, the menu bar shows a red stop button and the elapsed time. Screenshots keep working, and Margin's shelf, overlay and toasts stay out of the recording.
- Recordings land on the shelf with their first frame and their length. A click copies the file; dragging, Quick Look, renaming and undo work as for screenshots.
- A window recording carries on when the window is minimized or its app hidden, holding its last frame.
- Settings: Record system audio and Record microphone (both off), and a Record Screen shortcut.
- A recording stops by itself, keeping what was recorded and saying why, when its display goes or its window closes, the Mac sleeps, the disk is almost full (space macOS can free on its own counts as free), or it nears a FAT32 disk's 4 GB file limit.
- Recordings are written a second at a time, so one that can't be finished (a full disk, a crash, a power cut) still plays up to its last full second, and one left by a crash gets its name the next time you record.
- Rename or move the save folder while recording and the movie is saved in it; put it in the Trash or delete it and the movie goes to Unsaved.

### Changed

- Turn off for me, Turn off and Restore macOS screenshot shortcuts now include macOS's ⇧⌘5 toolbar shortcut. A shortcut that macOS still takes first is flagged under it in Settings.

## 0.0.19 — 2026-10-17

### Changed

- Screenshots are saved and copied 3–4× sooner. The PNG is now compressed on every core instead of one: a busy full-screen shot is in its file about 60 ms after you let go instead of about 205 ms, and an ordinary one in about 27 ms instead of about 100. The files are the same PNGs as before, with the same pixels, colour profile and metadata, and the same size to within a few KB.
- The shelf shows up to six cards instead of four (fewer when they don't fit the display).

## 0.0.18 — 2026-10-15

### Changed

- Window mode puts the clicked window on the shelf at once: its thumbnail is on screen about 27 ms after the click instead of about 145 ms (about 45–50 ms for a window that's partly covered, or with ⌥). It shows the window as it looked in the frozen screen, or as captured at the click, until its own shot, with the window's focused look, takes its place a moment later without a second fly-in. The saved file and the clipboard are exactly as before, and are ready about 10 ms sooner.
- In window mode the shutter sounds at the click, and the file is named for the moment you clicked.

### Fixed

- Quitting Margin right after a window-mode click lost that shot. Margin now waits for it to be saved.

## 0.0.17 — 2026-10-15

### Changed

- Shots reach the shelf faster. From letting go of the mouse to the thumbnail on screen takes about 19–33 ms instead of 38–50 ms, and files and the clipboard are ready 6–38% sooner. The crop, the thumbnail and the PNG encode now run in the background, start as soon as the image is captured, and the crop no longer copies pixels.
- Repeat Last Area (⇧⌘2) shows its thumbnail about 70 ms after the shortcut instead of about 96 ms: the outline flash reuses one window, drawn with layer borders, instead of building a new one each time.
- The fly-in that carries a shot to the shelf reuses its window, and much less work happens on the main thread during a capture (32–90% less).

### Fixed

- Pressing ⇧⌘4 again right as you let go of a selection could leave Margin in front with no window, so typing went nowhere until a click.

## 0.0.16 — 2026-10-15

### Changed

- A big shelf no longer slows launch or uses much memory. Only the cards in view, and the few that would come out of the pile next, are made and load their thumbnails, two at a time. With 200 shots on the shelf, Margin is ready in about 0.3 s instead of 1.1–5.6 s, and uses about 33 MB instead of 165–190 MB.
- The shelf's list (`shelf.json`) is written in the background instead of on the main thread, and moving your screenshots folder updates it in one write instead of one per shot (200 shots: 0.5 ms instead of about 0.4 s of a frozen shelf).
- PNGs are saved with the Up compression filter. Photo-like and gradient-heavy shots save about 45% faster and are about 30% smaller (a busy full screen: 165 ms instead of 298 ms to encode, 8.9 MB instead of 12.9 MB); ordinary UI shots save as fast as before and are 5–13% smaller.

## 0.0.15 — 2026-10-15

### Fixed

- Two copies of Margin could run at once (opened from two places, or with `open -n`): every shortcut saved each shot twice, and one of the two cards was gone after a restart. Opening Margin while it's running now shows Settings in the copy already running, and the new copy quits.
- One unreadable entry in the shelf's saved list (`shelf.json`), or a list written by a newer version, emptied the whole shelf, and the next capture saved over it. Unreadable entries are now skipped, and the original file is kept as `shelf.json.bad`.
- A shot whose save was cut off (a crash, a forced quit) was left as a hidden temporary file and lost. It's now recovered at the next launch, and its card stays on the shelf.
- A shortcut pressed while one of Margin's menus was open did nothing, then captured when the menu closed (while Settings was opening, say). It now does nothing at all; one pressed just after the menu closes works.
- Window mode skipped floating windows (tool palettes, Picture in Picture, always-on-top windows) and picked the window behind them. They're now picked; over the Dock or the menu bar nothing is.
- Closing the menu bar menu without choosing anything could leave the shelf holding the keyboard, so ⌫ removed a card instead of deleting text in your app. The keyboard now goes back to your app.
- The orange warning dot could stay after Screen Recording worked again. It now goes as soon as a capture or a check succeeds.
- With Screen Recording turned off while Margin ran, Margin kept asking ScreenCaptureKit for windows in the background, which could raise the system prompt at a random moment. It now waits for the next capture.
- About Margin could open behind the app in front. It now comes to the front.

## 0.0.14 — 2026-10-15

### Fixed

- Closing a card's or the pile's menu without choosing anything (Esc, or a click elsewhere) left the shelf holding the keyboard, so typing was lost. The keyboard now goes back to your app, unless the shelf already had it before the menu opened.
- After Spotlight opened and closed while the shelf had the keyboard, Esc left the keyboard nowhere until a click. It now goes back to your app.
- Quick Look's full-screen button left Margin the active app once Quick Look closed. Your app now gets its focus back.
- ⌥Space (and ⌥ or ⌃ with Esc, Space or ↩) during a capture went to the capture screen as well as to the app that owns that shortcut, such as a launcher. It now goes only to that app.
- The key that ended a capture (Esc, ↩) sent its release to your app.
- A second ⇧⌘4 cancelled before the screen froze could leave your app without keyboard focus.

### Changed

- Esc and Space are caught from the very start of ⇧⌘4, and the capture screen appears about 3 ms sooner.

## 0.0.13 — 2026-10-15

### Fixed

- Copy Path on a card didn't count as a copy from the shelf, so a shot still being saved replaced the copied path on the clipboard when it landed. The path now stays, and the "⌘V" mark leaves the previous card at once.
- While a shortcut was being recorded in Settings, opening Choose… kept the recorder listening: ⇧⌘G (Go to Folder) typed in the folder sheet became the shortcut. Recording now stops when the sheet opens.
- On keyboard layouts that change while ⌘ is held, such as "Dvorak – QWERTY ⌘", shortcuts with ⌘ were named, and refused, by what the key types without ⌘. They now follow what it types with ⌘, the way menus name them: ⇧⌘ on the QWERTY Z key reads ⇧⌘Z and is refused as Redo.

### Changed

- At launch, Margin removes the hint-bar counts that 0.0.5–0.0.7 stored and nothing reads any more.

## 0.0.12 — 2026-10-15

### Fixed

- Quick Look opened from the shelf couldn't be closed with Space or Esc: the keys went to the app you were in, and Quick Look stayed open. Space, Esc and its close button now close it and give the keyboard back to your app. With several shots selected, ← and → step through them.
- A rename that ended because a new shot pushed its card into the pile kept the keyboard on the shelf. The keyboard now goes back to your app.
- Dragging a brand-new card before its file was saved did nothing. The drag now starts as soon as the file is written, if you're still holding the mouse.
- When the save folder couldn't be written, shots went to a hidden "Unsaved" folder and the brief message didn't say how to find them. The message now says where they went and stays longer, and long messages wrap instead of being cut off.

### Added

- **Show Unsaved Shots** in the menu bar menu, shown while shots are waiting in the Unsaved folder. Open Screenshots Folder opens Unsaved when the save folder can't be opened.
- VoiceOver can read and use the shelf: each card says when it was taken and its size, with actions to copy, open, Quick Look, rename, remove or move to Trash; the pile and the tucked tab are buttons; messages like "Copied" are spoken.
- macOS's prompt for access to your Desktop, Documents, Downloads or an external disk now says why Margin asks: to save your screenshots there.

### Changed

- After you drag a shot out of the shelf, ⌘Z belongs to the app you dropped it into; use **Restore Last Removed** in the menu to bring the card back. The docs now say so.

## 0.0.11 — 2026-10-15

### Fixed

- Space, Esc and the other capture keys pressed right after ⇧⌘4, before the screen froze, went to the app in front: Space typed into your document, Esc took a full-screen app out of full screen. They now reach the capture screen.
- After Esc, the app you were in sometimes got its window back without focus, so typing went nowhere until you clicked. It now gets its focus and caret back every time, also after a quick second ⇧⌘4.
- The crosshair showed as an arrow until you moved the mouse. It now shows as soon as the screen freezes.
- Snapping and window mode used where windows were a moment ago, so a window moved or opened just before ⇧⌘4 snapped to its old position. They now follow it.
- Margin's own Settings, welcome and About windows were missing from your shots. They now appear and can be picked in window mode. The shelf still never shows in a shot.
- The capture screen stayed up, frozen on an old picture, after a Space switch, sleep or a user switch. It now cancels.
- Settings and the menu named shortcut keys after a US keyboard, so ⌃⌥⌘Z on a German keyboard read ⌃⌥⌘Y. Keys are now named the way your keyboard layout labels them, and the shortcuts Settings refuses (⇧⌘Z Redo and the like) follow your layout too.
- Margin could crash when an app went full screen during a capture.

## 0.0.10 — 2026-10-15

### Fixed

- Clicking a card to copy it took the keyboard away from the app you were in, so ⌘V straight after (in a terminal or a chat) beeped instead of pasting. ⌘Q, ⌘W and typing beeped too. A click now copies and leaves the keyboard where it was.
- A click copied only after the double-click delay (half a second, longer with a slow double-click setting), so a quick ⌘V pasted the old clipboard. It now copies at once.
- Cards for shots on an external disk or network share vanished for good when the disk was unplugged. They now stay, and work again when it's back.
- A card whose file was renamed or moved while Margin was quit stayed blank all session. It now shows the shot.
- Two quick ⌘Z presses could bring cards back in the wrong order when one step was a Move to Trash.
- ⌘Z on a card whose file had been deleted said "Restored" and then the card faded away. It now says "File not found", and the next ⌘Z moves on.
- ⌘Z after Finder's Put Back said "Couldn't restore". It now brings the card back.
- A rename in progress was hidden when its card folded into the pile or the shelf tucked, and typing went into the hidden field. The rename is now saved first.
- Tuck Shelf was enabled in the menu with an empty shelf, and did nothing.
- Settings accepted shortcuts that break other apps or never fire, such as ⌘Q, ⌘V, ⌃C, ⇧⌘Z, ⇧⌘5 and ⌘Space. They're now refused, with the reason. F-keys with one modifier are fine.

### Added

- Saved shots are tagged as screenshots, the way macOS tags its own, so Finder's and Spotlight's screenshot searches find them.

### Changed

- The shelf takes the keyboard only when you need its keys: after a ⌘-click (select), ✕, a click on the pile, Rename… or Move to Trash. Then Space (Quick Look), ⌫, ⌘Z, ⌘C and ⌘A work, and Esc gives the keyboard back. After a plain click, those keys go to your app.
- A double-click copies the shot as well as opening it.

## 0.0.9 — 2026-10-15

### Fixed

- ⇧⌘2 repeated the wrong part of the screen after your displays changed (closing the lid, plugging in a monitor, changing a display's arrangement or "More Space" scaling), and then kept repeating the wrong strip. The area is now remembered relative to its display. If that display now has a different resolution, ⇧⌘2 asks for a new area instead of guessing. An area saved by an older version carries over when you have one display.
- A capture that failed (a window closed just before the click, a display macOS won't capture, an empty area) did nothing at all. The shelf now says "Couldn't capture that window", "Couldn't capture this display", "Couldn't capture that area" or "Couldn't capture the screen".
- Starting a selection next to a window that hangs off the screen edge could start it off-screen, so a ⇧ square came out not quite square.
- Snap guides and "Snapped to window" no longer show for a window edge that's past the edge of the display.
- Letting go of Space after moving a selection now applies ⇧ (square) or ⌥ (from center) straight away, not on the next mouse move.
- After a display changed resolution, a capture could use the old size if Margin missed the change. It now notices and retries.
- ⌥ (keep shadow) shots of a window partly off-screen are never clipped.

## 0.0.8 — 2026-10-15

### Fixed

- The hint bar at the top of the capture screen (Space, ⇧, ⌥, Nudge, Z, ↩, Esc) disappeared after 5 captures. It now always shows; turn it off with the new Settings › **Show key hints while capturing**.

## 0.0.7 — 2026-10-14

### Changed

- The magnifier is off by default. Press Z during a capture to show or hide it (just for that capture); the hint bar lists "Z Magnifier".

## 0.0.6 — 2026-10-14

### Changed

- Card buttons are easier to find: a red ✕ at the top-right dismisses a shot, and the Options (•••) menu sits at the top-left with a tooltip.

## 0.0.5 — 2026-10-14

### Changed

- It's now clear what ⇧, ⌥ and Space do while you select: the hint bar uses words, highlights the key you're holding, and a pill next to the selection names the mode ("Square", "From center"). In window mode ⌥ shows "Keep shadow".
- Holding ⌥ while dragging a shot out shows "Keep on shelf" on the dragged thumbnail, updating as you press or release ⌥.
- The hint bar shows again for 5 captures whenever its hints change, so you see new keys after an update.

## 0.0.4 — 2026-10-14

### Fixed

- Arrow-key nudging is smoother and faster: each step repaints only the selection, and holding an arrow speeds up (a tap stays 1 px, ⇧ is 10 px).

## 0.0.3 — 2026-10-14

### Added

- Margin can turn off the four macOS screenshot shortcuts for you: **Turn off for me** in first run, and **Restore macOS screenshot shortcuts** in Settings to undo it. Changes apply at once, no logout needed.

## 0.0.2 — 2026-10-14

### Fixed

- ⌘V in a terminal now pastes your screenshot. Captures and shelf copies put the saved file next to the image on the clipboard, so Ghostty pastes its path and Claude Code attaches it as an image. Image apps still get the picture; Chrome-based apps (claude.ai, Slack) get the PNG file with its real name.

## 0.0.1 — 2026-10-14

The first public preview.

### Added

- Area capture on a frozen screen (⌘⇧4): release to capture, resize handles, arrow-key nudging, ⇧ square, ⌥ from centre, hold Space to move, pixel loupe with colour readout, snapping to window edges, HUD hints.
- Window capture (Space from area mode): just the window, transparent corners, no shadow (⌥ keeps it).
- Full-screen capture of the display under the pointer (⌘⇧3) and repeat last area (⌘⇧2), with ⌃ twins.
- Every shot saved as a PNG to `~/Desktop/Screenshots` (configurable), with 24-hour file names and atomic writes, and copied to the clipboard.
- The shelf: thumbnails on the right edge that stay until dragged into another app or dismissed; pile for older shots, tuck (⌘⇧1), ⌘V mark, toasts, Quick Look, rename, reveal, move to Trash, and ⌘Z undo. Survives relaunch.
- Menu bar icon with every action, and a warning state when Screen Recording permission is missing.
- First-run guide: permission, handing over the macOS screenshot shortcuts, first shot.
- Settings: save folder, copy each capture, shutter sound, launch at login, shortcuts.
