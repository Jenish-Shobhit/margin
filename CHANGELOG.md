# Changelog

All notable changes to Margin are listed here. Versions follow [Semantic Versioning](https://semver.org).

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
