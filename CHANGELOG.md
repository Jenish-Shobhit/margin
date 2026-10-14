# Changelog

All notable changes to Margin are listed here. Versions follow [Semantic Versioning](https://semver.org).

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
