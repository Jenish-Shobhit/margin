# README images

Every image here except `settings.png` is rendered from Margin's real views, offscreen. `settings.png` is Margin's own Settings window (General pane, default settings, 1.0.0), captured with `screencapture -l` of that window alone. None of them is a screenshot of anyone's screen.

- **Views.** A scratch harness compiles the app's own sources and uses its real views: `ShelfCardView`, `ShelfPileView` (Liquid Glass), `ShelfTabView`, `ShelfToastView`, `ShelfDragImage`, `OverlayView` with its pills, hint bar and magnifier and `FirstRunView`.
  - The views live in windows that are never ordered on screen.
  - Core Animation's `CARenderer` draws them at 2×. The first-run window uses `cacheDisplay`.
- **Content.** Everything behind the views is synthetic and drawn with CoreGraphics: the wallpaper, the menu bar, the "Design review" chat, the editor, and the sample shots on the cards.
- **State.** First run uses a throwaway `UserDefaults` suite and fake sources. No system settings are read or written.
- **Motion.** `demo.gif` runs the app's own springs (card moves, hover, ⌘V mark, collapse) on a paused layer clock, and steps through it at 25 fps.
  - The fly-in copies `ShelfFlight`'s layers and spring values. That class opens an on-screen panel, so the harness can't use it directly.
  - The "⇧⌘4" keycap is a demo annotation, not part of Margin.
- **Encoding.** PNGs are recompressed losslessly with ImageMagick. The GIF is encoded with ffmpeg `palettegen`/`paletteuse`.

## Website images

- `demo-poster.jpg` is the first frame of `demo.gif`, extracted with ffmpeg. The website shows it when the demo is paused, and first under Reduce Motion.
- `og.png` is the website's Open Graph/Twitter card (1200 × 630): the app icon, the headline and `demo-poster.jpg` in the page's MacBook frame, laid out in HTML and rendered offscreen with `WKWebView`'s `takeSnapshot`.
- `shelf/*.webp` are the cards on the website hero's shelf, cropped from `settings.png`, `shelf-states.png` and `capture.png` with ImageMagick (`-crop … -strip`, WebP at quality 86–90; the Settings crop is scaled to 504 px wide), so the hero doesn't load the full images.
