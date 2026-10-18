# README images

Every image here except `settings.png` is rendered from Margin's real views, offscreen. `settings.png` is Margin's own Settings window (General pane, default settings), captured with `screencapture -l` of that window alone. None of them is a screenshot of anyone's screen.

- **Views.** A scratch harness compiles the app's own sources and uses its real views: `ShelfCardView`, `ShelfPileView` (Liquid Glass), `ShelfTabView`, `ShelfToastView`, `ShelfDragImage`, `OverlayView` with its pills, hint bar and magnifier and `FirstRunView`.
  - The views live in windows that are never ordered on screen.
  - Core Animation's `CARenderer` draws them at 2×. The first-run window uses `cacheDisplay`.
- **Content.** Everything behind the views is synthetic and drawn with CoreGraphics: the wallpaper, the menu bar, the "Design review" chat, the editor, and the sample shots on the cards.
- **State.** First run uses a throwaway `UserDefaults` suite and fake sources. No system settings are read or written.
- **Motion.** `demo.gif` runs the app's own springs (card moves, hover, ⌘V mark, collapse) on a paused layer clock, and steps through it at 25 fps.
  - The fly-in copies `ShelfFlight`'s layers and spring values. That class opens an on-screen panel, so the harness can't use it directly.
  - The "⇧⌘4" keycap is a demo annotation, not part of Margin.
- **Encoding.** PNGs are recompressed losslessly with ImageMagick. The GIF is encoded with ffmpeg `palettegen`/`paletteuse`.
