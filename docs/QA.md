# Margin QA checklist

Manual checks for every release (spec §12), kept in step with Margin 0.0.7. Run them on the installed build (`scripts/build.sh --install --run`) unless a step says otherwise.

Debug builds can drive captures without a mouse: `scripts/debug.sh capture-area x y w h`, `capture-screen`, `toggle-shelf`, `clear` and `dump-state`. See [building.md](building.md#the-debug-hook).

Before starting, hand the screenshot shortcuts to Margin (first run's **Turn off for me**, or Settings › **Turn off macOS screenshot shortcuts**) so it receives ⇧⌘3 and ⇧⌘4.

## Build and launch

- [ ] `scripts/build.sh --install --run` installs `/Applications/Margin.app` and launches it
- [ ] `codesign -dvv /Applications/Margin.app` shows `Authority=Margin Dev` (or the build printed the loud ad-hoc warning)
- [ ] No Dock icon; the menu bar icon appears
- [ ] `scripts/test.sh` passes
- [ ] `scripts/build.sh --zip` writes `dist/Margin-<version>.zip`, and the unzipped app launches
- [ ] `scripts/build.sh --debug --zip` refuses (exit 2) before building
- [ ] `--debug --install` prints the DEBUG-build warning banner before the build and again at the end
- [ ] A release binary has no debug hook: `strings /Applications/Margin.app/Contents/MacOS/Margin | grep -c margin.debug` prints 0

## Capture: shortcuts (§2)

- [ ] ⇧⌘4 starts area capture on a frozen screen; Space switches to window mode
- [ ] ⇧⌘3 captures the full display under the pointer, with no overlay
- [ ] ⇧⌘2 repeats the last area with no overlay and flashes the outline (150 ms) after capturing
- [ ] ⇧⌘2 falls back to ⇧⌘4 when there's no last area
- [ ] ⇧⌘2 falls back to ⇧⌘4 when the last area's display is gone, or at another resolution
- [ ] ⇧⌘2 captures the same part of the same display after the arrangement changes (another display added, removed or moved, or the lid closed)
- [ ] A window closed between hover and click shows the toast "Couldn't capture that window"; ⇧⌘3 on a display ScreenCaptureKit can't capture shows "Couldn't capture this display"
- [ ] ⌃⇧⌘4, ⌃⇧⌘3 and ⌃⇧⌘2 do the same as without ⌃
- [ ] ⇧⌘1 tucks and shows the shelf
- [ ] Shortcuts changed in Settings take effect immediately, ⌃ twins included; the old ones stop working

## Capture: freeze and selection (§2)

**Freeze**

- [ ] The overlay and crosshair appear immediately on every display
- [ ] The frozen frame doesn't visibly jump when it arrives

**Selecting**

- [ ] Dragging selects; releasing the mouse captures immediately
- [ ] A drag under 4×4 px is ignored and selection mode stays
- [ ] A selection can't leave the display where the drag started
- [ ] ⇧ while dragging makes a square
- [ ] ⌥ while dragging draws from the centre
- [ ] Holding Space while dragging moves the selection
- [ ] Holding ⇧ / ⌥ / Space while dragging highlights that hint, and a pill names the mode ("Square", "From center")

**Adjusting**

- [ ] Pressing an arrow key mid-drag keeps the selection on release
- [ ] Each of the 8 handles then resizes it (edge handles from 40 pt per side), and dragging inside moves it
- [ ] Arrow keys nudge 1 px per tap, ⇧+arrow 10 px
- [ ] Holding an arrow is smooth and speeds up (2 px, then 4 px)
- [ ] ↩ (and ⌤) captures the adjusted selection

**Pills and snapping**

- [ ] The size pill reads `W × H` in pixels
- [ ] Edges snap to window edges within 8 pt; the "Snapped to window" pill and guides show while snapped

**Magnifier and hint bar**

- [ ] No magnifier by default
- [ ] Z shows it, with an 11×11 pixel grid and `x, y · #RRGGBB` in display-local pixels; Z again hides it, for that capture only
- [ ] The hint bar shows at the top centre on every capture, and never after Settings › Show key hints while capturing is turned off
- [ ] Its items: Space Window (Move while dragging) · ⇧ Square · ⌥ From center · ←↑→↓ Nudge · Z Magnifier · ↩ Capture · Esc Cancel

**Cancelling**

- [ ] Esc cancels: no file, no sound, clipboard unchanged
- [ ] Right-click cancels the same way
- [ ] ⌘Tab to another app while selecting cancels it
- [ ] Changing displays during selection cancels it
- [ ] ⌘ shortcuts are swallowed while the overlay is up

## Capture: window mode (§2)

- [ ] Hovering highlights the window under the pointer with the pill `App · W × H`
- [ ] The hint bar reads Click to capture · ⌥ Keep shadow · Space Area · Esc Cancel
- [ ] Clicking captures just that window, even when partly covered
- [ ] Window shots have rounded, transparent corners and no shadow
- [ ] Holding ⌥ highlights "Keep shadow" and adds "· shadow" to the pill; ⌥-click keeps the shadow
- [ ] Space returns to area mode

## Save, copy, sound (§3)

**The file**

- [ ] The file lands in `~/Desktop/Screenshots` (created if missing) as `Screenshot yyyy-MM-dd at HH.mm.ss.png`, 24-hour, plain spaces
- [ ] Two captures in the same second get ` (2)`, ` (3)` names
- [ ] The PNG keeps the display's colour profile and has DPI 144 on Retina (`sips -g dpiWidth`)
- [ ] No app ever sees a half-written file (no `.margin-*.tmp` left behind)
- [ ] Quitting right after a capture waits for the save: ⇧⌘3, then Quit at once (or `osascript -e 'quit app "Margin"'`)
  - [ ] the PNG is in the folder and the card is back after relaunch
  - [ ] the quit never takes more than about 3 s
- [ ] An unwritable save folder saves to `~/Library/Application Support/Margin/Unsaved/` and shows the toast "Saved to Unsaved — folder not writable"

**The clipboard**

- [ ] Each capture leaves one pasteboard item: `public.png` (same bytes as the file, the same image type as `screencapture -c`) plus `public.file-url` of the saved file at its final name
- [ ] The clipboard is written after the file is renamed into place
- [ ] A capture whose save failed puts the PNG only
- [ ] "Copy each capture" off: the clipboard is untouched

**The sound**

- [ ] The shutter sound plays on success only, and follows the alert volume
- [ ] It's silent when UI sound effects or Settings › Shutter sound are off

## Timing targets (§3)

Check `log stream --level info --predicate 'subsystem == "io.github.jenish-shobhit.margin" && category == "timing"'` or `scripts/debug.sh dump-state`. Without `--level info` the per-step lines such as `hotkeyToFirstFrozen` don't show.

- [ ] Hotkey to first frozen frame on screen ≤ 80 ms
- [ ] Release to thumbnail visible ≤ 100 ms
- [ ] Release to PNG renamed into place ≤ 200 ms

## No Margin UI in any capture

- [ ] Shelf visible: not in area, window or full-screen shots
- [ ] Shelf tucked: the tab isn't in the shot
- [ ] During a fly-in: the flying thumbnail isn't in the next shot
- [ ] Toasts, the overlay, the hint bar and the magnifier never appear in shots
- [ ] `screencapture -x` *does* show the shelf (sanity check)

## The shelf (§4)

**Placement**

- [ ] Sits on the right edge of the visible frame of the most recent capture's display, clear of the Dock and menu bar
- [ ] Hidden when empty

**Cards and the pile**

- [ ] Cards are 176 pt wide, height follows the shot (64–176 pt), aspect-fill, newest at the bottom; older cards slide up
- [ ] At most 4 cards (fewer if they don't fit); older ones fold into `+N older`
- [ ] Hovering the pile fans it out; dragging the pile sends all its items; right-click › Clear shelf (undoable)

**Fly-in and hover**

- [ ] Fly-in from the selection to the slot (~0.45 s), then a 2 pt accent ring for 1.5 s
- [ ] Hovering a card scales it to 1.04 and shows the red ✕ (top-right), Options ••• (top-left) and `HH:mm · W × H`
- [ ] ✕ dismisses; ••• opens the menu and shows an "Options" tooltip

**Tucking and toasts**

- [ ] Tucking shows the tab with the count and the toast "Shelf tucked · ⇧⌘1"
- [ ] An empty shelf doesn't tuck
- [ ] Tucked: the shot flies into the tab, the count goes up, the shelf stays tucked
- [ ] The tuck tab peeks on hover and shows the shelf on click
- [ ] Toasts appear above the top card for 1.2 s, never as notifications
- [ ] Five captures give 4 cards plus `+1 older`, and survive quit and relaunch

## Shelf interactions (§5)

**Focus**

- [ ] The shelf never steals focus; keys work only after clicking it; clicking elsewhere gives focus back

**Dragging**

- [ ] Dragging a card drags a plain file URL (copy, never move); the card stays faint in its slot
- [ ] A successful drop collapses the card out and the rest settle; a cancelled drag springs back
- [ ] ⌥ held when the drop lands keeps the card
- [ ] ⌥-dragging shows "Keep on shelf" on the drag image, live as ⌥ changes
- [ ] A drag never deletes or moves the file

**Selection and copy**

- [ ] ⌘-click toggles selection; dragging a selected card drags all selected (stacked image with a count badge)
- [ ] ⌘A selects every card outside the pile; Esc clears the selection
- [ ] ⌘C copies all selected cards as images (each with its file URL)
- [ ] Click copies that shot, moves the ⌘V mark to it, and shows "Copied"; a double-click opens without copying

**Other actions**

- [ ] Space opens Quick Look for the focused card or the selection
- [ ] ⌫ (or ⌦) dismisses (the file stays on disk)
- [ ] Two-finger swipe right on a card dismisses it
- [ ] Double-click opens the file in the default app
- [ ] ••• and right-click (or ⌃-click) offer Copy Path · Reveal in Finder · Rename… (renames on disk) · Move to Trash; Copy Paths for a multi-selection
- [ ] ⌘Z restores the last removed card(s), up to 20 steps: drag-out, dismiss, clear and trash (the file comes back from the Trash)

**Rename field**

- [ ] ↩ saves, Esc cancels, and clicking elsewhere keeps the typed name
- [ ] ⌘X ⌘C ⌘V ⌘A edit the text, ⌘Z undoes typing and ⇧⌘Z redoes it
- [ ] None of those keys reach the shelf (⌘Z while renaming never brings back a card)

**⌘Q and ⌘W**

- [ ] After clicking a card (shelf key, another app frontmost), ⌘Q does not quit Margin and ⌘W does not close anything
- [ ] With Settings in front, ⌘Q quits and ⌘W closes the window

**The ⌘V mark**

- [ ] The ⌘V pill sits on the card whose image is on the clipboard
- [ ] Copying something else clears the ⌘V mark within about a second
- [ ] Removing the marked card removes the mark

## Files changed outside Margin

- [ ] A file deleted in Finder drops off the shelf (at launch, when the shelf appears, when a drag starts)
- [ ] A file renamed in Finder stays on the shelf and drags under its new name
- [ ] A file moved in Finder is followed (bookmark) and still drags
- [ ] A file moved to the Trash drops off the shelf

## Paste into apps (⌘V after a capture)

- [ ] WhatsApp
- [ ] Claude (web)
- [ ] Claude (desktop)
- [ ] Chrome (e.g. a Google Doc or a chat box): gets the PNG file with its real name
- [ ] Slack
- [ ] Notes
- [ ] Ghostty: ⌘V pastes the shell-escaped path; in Claude Code (also inside herdr) ⌘V attaches the image
- [ ] Terminal (Claude Code: Ctrl+V attaches the image)

## Drag into apps (from the shelf)

- [ ] Finder
- [ ] WhatsApp
- [ ] Claude (web)
- [ ] Claude (desktop)
- [ ] Chrome
- [ ] Slack
- [ ] Notes
- [ ] Terminal (inserts the path)

## Displays, Spaces, system states

**Displays and Spaces**

- [ ] Two displays with different scales (Retina + non-Retina): freeze, selection, magnifier pixels, file pixel size and DPI are right on both
- [ ] A display ScreenCaptureKit can't capture is dimmed with "Can't capture this display"; the others still work
- [ ] The shelf moves to the display of the latest capture; it repositions when a display is added or removed
- [ ] A full-screen app in front: overlay and shelf appear above it
- [ ] Switching Spaces: the shelf stays on every Space
- [ ] Sleep/wake: hotkeys, shelf and capture still work afterwards
- [ ] A 50-item shelf stays responsive

**Revoking Screen Recording while running**

- [ ] The next capture shows First run step 1 and the menu bar warning dot, and nothing crashes
- [ ] The warning stays afterwards, even though preflight is cached as granted; it doesn't clear itself a second later
- [ ] The menu shows "Allow Screen Recording…" and "Relaunch Margin" until a capture succeeds or Margin relaunches
- [ ] `dump-state` shows `permission.revoked: true`
- [ ] Relaunch Margin quits and reopens it, with only one copy running afterwards

## Appearance and accessibility

- [ ] Light mode
- [ ] Dark mode
- [ ] Reduce motion: no fly-in; cards appear in place
- [ ] Reduce transparency: glass (pile, tab, toasts) falls back to solid

## Menu bar (§6)

**The icon and its items**

- [ ] The template icon follows the menu bar's appearance
- [ ] Items: Capture Area, Capture Window, Capture Screen, Repeat Last Area, Tuck Shelf (Show Shelf while tucked), Restore Last Removed, Open Screenshots Folder, Settings… (⌘,), About Margin <version>, Quit Margin (⌘Q)
- [ ] The shortcuts shown match Settings
- [ ] About shows the icon, the current version and build (e.g. 0.0.7 (7)) and "© 2026 Jenish Shobhit · MIT License"
- [ ] Opening Margin again while it runs (Finder, Spotlight) opens Settings, or First run step 1 without permission

**Actions**

- [ ] Restore Last Removed brings back the last removed card(s) like ⌘Z on the shelf, without clicking the shelf first (dismiss, drag-out, clear, trash)
- [ ] Capture Window starts the capture in window mode (Space switches to area)
- [ ] The menu itself never appears in a shot started from it
- [ ] Open Screenshots Folder creates the folder if missing and opens it in Finder

**Warnings**

- [ ] Without Screen Recording permission: a warning dot on the icon, and the first item reads "Allow Screen Recording…" and opens First run step 1
- [ ] A shortcut that fails to register:
  - [ ] shows a warning dot, and the menu's top item names it and opens Settings, e.g. "⇧⌘4 and ⌃⇧⌘4 are set for two actions — Change in Settings…" (other failures read "… is used by another app" or "… isn't available")
  - [ ] to force one: quit Margin, run `defaults write io.github.jenish-shobhit.margin shortcut.repeatArea -data 7b226b6579436f6465223a32312c226d6f64696669657273223a3736387d` (Repeat area = ⇧⌘4), and relaunch
  - [ ] fixing it in Settings removes the warning at once
  - [ ] `dump-state` lists each OSStatus under `hotkeys`
- [ ] A macOS screenshot shortcut still on that Margin also uses (e.g. only "Save picture of selected area as a file"):
  - [ ] the menu shows a quiet "macOS still uses ⇧⌘4 — Fix…" above Settings (no dot), which opens First run at step 2
  - [ ] with three or more it reads "macOS still uses N of Margin's shortcuts — Fix…"
  - [ ] after turning the shortcut off in System Settings and reopening the menu, the item is gone (it's checked each time the menu opens)

## First run (§7)

**When it shows**

- [ ] Shows on first launch and whenever permission is missing
- [ ] A later launch with first run done and permission granted shows no window, even if macOS still owns a shortcut (the menu's "Fix…" item covers that)

**The steps**

- [ ] Step 1 requests access, deep-links to Screen & System Audio Recording, polls, and offers "Relaunch Margin" when needed; relaunch works
- [ ] Step 2's checklist of the four macOS shortcuts updates live (missing entry = enabled); the ⇧⌘5 note shows
- [ ] Step 2: **Turn off for me** turns all four off at once with no logout, and the boxes tick
- [ ] Step 2: "Open Keyboard Shortcuts" opens Keyboard settings
- [ ] Step 2: a failure shows the reason under the buttons
- [ ] Step 3 says "Press ⇧⌘4" and the real launch-at-login state (on, off, or waiting for approval with "Open Login Items")
- [ ] The window closes after the first successful capture (later if it mentions shortcuts macOS still uses)
- [ ] A fresh account (or reset prefs) gets through First run in under a minute

**Touching `com.apple.symbolichotkeys`**

- [ ] Margin writes to it only on an explicit click (Turn off for me, Turn off / Restore in Settings)
- [ ] Each write keeps the other shortcuts and any custom binding

## Settings (§8)

**The settings**

- [ ] Six settings (Save to, Copy each capture, Shutter sound, Show key hints while capturing, Launch at login, Shortcuts), plus the macOS screenshot shortcuts row
- [ ] Save to: the folder picker changes where the next capture lands

**Launch at login**

- [ ] On by default; toggling registers/unregisters (System Settings › General › Login Items)
- [ ] The toggle shows what macOS has, not just the preference: remove Margin in System Settings › General › Login Items, reopen Settings, and the toggle (and `dump-state`'s `launchAtLogin.on`) reads off

**Shortcut recorders**

- [ ] Recorders for Area, Screen, Repeat area and Tuck shelf; recording the current shortcut works
- [ ] A combo without ⌘ or ⌃ is refused with a message
- [ ] A combo another action uses is refused, naming that action
- [ ] Esc cancels recording; Delete resets to the default

**macOS screenshot shortcuts row**

- [ ] The status line is right ("All four are on, so macOS takes them before Margin.", "All four are off.")
- [ ] The button turns them off when any are on, and reads **Restore macOS screenshot shortcuts** once all four are off
- [ ] Restore re-enables them at once
