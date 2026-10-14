# Changelog

All notable changes to Margin are listed here. Versions follow [Semantic Versioning](https://semver.org).

## 0.0.1 — unreleased

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
