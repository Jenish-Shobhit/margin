# Margin QA checklist

Manual checks for every release (spec §12). Run them on the installed build (`scripts/build.sh --install --run`) unless a step says otherwise. Debug builds can drive captures without a mouse: `scripts/debug.sh capture-area x y w h`, `capture-screen`, `toggle-shelf`, `clear`, `dump-state`.

Before starting: turn off the four macOS screenshot shortcuts (System Settings › Keyboard › Keyboard Shortcuts › Screenshots) so Margin receives ⌘⇧3/⌘⇧4.

## Build and launch

- [ ] `scripts/build.sh --install --run` installs `/Applications/Margin.app` and launches it
- [ ] `codesign -dv /Applications/Margin.app` shows `Authority=Margin Dev` (or the build printed the loud ad-hoc warning)
- [ ] No Dock icon; the menu bar icon appears
- [ ] `scripts/test.sh` passes
- [ ] `scripts/build.sh --zip` writes `dist/Margin-0.0.1.zip`, and the unzipped app launches

## Capture: shortcuts (§2)

- [ ] ⌘⇧4 starts area capture on a frozen screen; Space switches to window mode
- [ ] ⌘⇧3 captures the full display under the pointer, with no overlay
- [ ] ⌘⇧2 repeats the last area with no overlay and flashes the outline (150 ms) after capturing
- [ ] ⌘⇧2 falls back to ⌘⇧4 when there's no last area
- [ ] ⌘⇧2 falls back to ⌘⇧4 when the last area's display is gone
- [ ] ⌃⌘⇧4, ⌃⌘⇧3 and ⌃⌘⇧2 do the same as without ⌃
- [ ] ⌘⇧1 tucks and shows the shelf
- [ ] Shortcuts changed in Settings take effect immediately, ⌃ twins included; the old ones stop working

## Capture: freeze and selection (§2)

- [ ] The overlay and crosshair appear immediately on every display
- [ ] The frozen frame doesn't visibly jump when it arrives
- [ ] Dragging selects; releasing the mouse captures immediately
- [ ] A drag under 4×4 px is ignored and selection mode stays
- [ ] A selection can't leave the display where the drag started
- [ ] ⇧ while dragging makes a square
- [ ] ⌥ while dragging draws from the centre
- [ ] Holding Space while dragging moves the selection
- [ ] Each of the 8 handles resizes the selection
- [ ] Arrow keys nudge by 1 px, ⇧+arrow by 10 px
- [ ] ↩ captures the adjusted selection
- [ ] The size pill reads `W × H` in pixels
- [ ] Edges snap to window edges within 8 pt; the "Snapped to window" pill and guides show while snapped
- [ ] The loupe shows an 11×11 pixel grid and `x, y · #RRGGBB` with display-local pixel coordinates
- [ ] The HUD hint bar shows at the top centre, and is gone after the 5th successful capture
- [ ] Esc cancels: no file, no sound, clipboard unchanged
- [ ] Changing displays during selection cancels it

## Capture: window mode (§2)

- [ ] Hovering highlights the window under the pointer with the pill `App · W × H`
- [ ] Clicking captures just that window, even when partly covered
- [ ] Window shots have rounded, transparent corners and no shadow
- [ ] Holding ⌥ while clicking keeps the shadow

## Save, copy, sound (§3)

- [ ] The file lands in `~/Desktop/Screenshots` (created if missing) as `Screenshot yyyy-MM-dd at HH.mm.ss.png`, 24-hour, plain spaces
- [ ] Two captures in the same second get ` (2)`, ` (3)` names
- [ ] The PNG keeps the display's colour profile and has DPI 144 on Retina (`sips -g dpiWidth`)
- [ ] No app ever sees a half-written file (no `.margin-*.tmp` left behind)
- [ ] An unwritable save folder saves to `~/Library/Application Support/Margin/Unsaved/` and shows the toast "Saved to Unsaved — folder not writable"
- [ ] The clipboard holds the image (same bytes as the file) with the same image types as `screencapture -c`, and no file URL
- [ ] "Copy each capture" off: the clipboard is untouched
- [ ] The shutter sound plays on success only, follows the alert volume, and is silent when UI sound effects or Settings › Shutter sound are off

## Timing targets (§3)

Check `log stream --predicate 'subsystem == "io.github.jenish-shobhit.margin" AND category == "timing"'` or `scripts/debug.sh dump-state`.

- [ ] Hotkey to first frozen frame on screen ≤ 80 ms
- [ ] Release to thumbnail visible ≤ 100 ms
- [ ] Release to PNG renamed into place ≤ 200 ms

## No Margin UI in any capture

- [ ] Shelf visible: not in area, window or full-screen shots
- [ ] Shelf tucked: the tab isn't in the shot
- [ ] During a fly-in: the flying thumbnail isn't in the next shot
- [ ] Toasts, the overlay, HUD and loupe never appear in shots
- [ ] `screencapture -x` *does* show the shelf (sanity check)

## The shelf (§4)

- [ ] Sits on the right edge of the visible frame of the most recent capture's display, clear of the Dock and menu bar
- [ ] Hidden when empty
- [ ] Cards are 176 pt wide, height follows the shot (64–176 pt), aspect-fill, newest at the bottom; older cards slide up
- [ ] At most 4 cards (fewer if they don't fit); older ones fold into `+N older`
- [ ] Hovering the pile fans it out; dragging the pile sends all its items; right-click › Clear shelf (undoable)
- [ ] Fly-in from the selection to the slot (~0.45 s), then a 2 pt accent ring for 1.5 s
- [ ] Tucked: the shot flies into the tab, the count goes up, the shelf stays tucked
- [ ] Hovering a card scales it to 1.04 and shows ✕, ••• and `HH:mm · W × H`
- [ ] The tuck tab peeks on hover and shows the shelf on click
- [ ] Toasts appear above the top card for 1.2 s, never as notifications
- [ ] Five captures give 4 cards plus `+1 older`, and survive quit and relaunch

## Shelf interactions (§5)

- [ ] The shelf never steals focus; keys work only after clicking it; clicking elsewhere gives focus back
- [ ] Dragging a card drags a plain file URL (copy, never move); the card stays faint in its slot
- [ ] A successful drop collapses the card out and the rest settle; a cancelled drag springs back
- [ ] ⌥ held when the drop lands keeps the card
- [ ] ⌘-click toggles selection; dragging a selected card drags all selected (stacked image with a count badge)
- [ ] ⌘C copies all selected cards as images
- [ ] Click copies that shot, moves the ⌘V mark to it, and shows "Copied"
- [ ] Space opens Quick Look for the focused card or the selection
- [ ] ⌫ dismisses (the file stays on disk)
- [ ] Two-finger swipe right on a card dismisses it
- [ ] Double-click opens the file in the default app
- [ ] ••• and right-click offer Copy path · Reveal in Finder · Rename… (renames on disk) · Move to Trash
- [ ] ⌘Z restores the last removed card(s), up to 20 steps: drag-out, dismiss, clear and trash (the file comes back from the Trash)
- [ ] Rename field: ⌘X ⌘C ⌘V ⌘A edit the text, ⌘Z undoes typing and ⇧⌘Z redoes it; none of them reach the shelf (⌘Z while renaming never brings back a card)
- [ ] After clicking a card (shelf key, another app frontmost), ⌘Q does not quit Margin and ⌘W does not close anything; with Settings in front, ⌘Q quits and ⌘W closes the window
- [ ] A drag never deletes or moves the file
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
- [ ] Chrome (e.g. a Google Doc or a chat box)
- [ ] Slack
- [ ] Notes
- [ ] Terminal (Claude Code: Ctrl+V)

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

- [ ] Two displays with different scales (Retina + non-Retina): freeze, selection, loupe pixels, file pixel size and DPI are right on both
- [ ] The shelf moves to the display of the latest capture; it repositions when a display is added or removed
- [ ] A full-screen app in front: overlay and shelf appear above it
- [ ] Switching Spaces: the shelf stays on every Space
- [ ] Sleep/wake: hotkeys, shelf and capture still work afterwards
- [ ] Revoking Screen Recording while running: the next capture shows First run step 1 and the menu bar warning dot, and nothing crashes
- [ ] A 50-item shelf stays responsive

## Appearance and accessibility

- [ ] Light mode
- [ ] Dark mode
- [ ] Reduce motion: no fly-in; cards appear in place
- [ ] Reduce transparency: glass (pile, tab, toasts) falls back to solid

## Menu bar (§6)

- [ ] The template icon follows the menu bar's appearance
- [ ] Items: Capture Area, Capture Window, Capture Screen, Repeat Last Area, Show/Tuck Shelf, Restore Last Removed, Open Screenshots Folder, Settings…, About Margin 0.0.1, Quit
- [ ] Restore Last Removed brings back the last removed card(s) like ⌘Z on the shelf, without clicking the shelf first (dismiss, drag-out, clear, trash)
- [ ] The shortcuts shown match Settings
- [ ] Capture Window starts area capture (Space switches to window mode)
- [ ] The menu itself never appears in a shot started from it
- [ ] Open Screenshots Folder creates the folder if missing and opens it in Finder
- [ ] About shows the icon, version 0.0.1 (1) and "© 2026 Jenish Shobhit · MIT License"
- [ ] Without Screen Recording permission: a warning dot on the icon, and the first item reads "Allow Screen Recording…" and opens First run step 1
- [ ] A shortcut that fails to register shows a warning dot, and the menu's top item names it and opens Settings, e.g. "⇧⌘4 and ⌃⇧⌘4 are set for two actions — Change in Settings…" (other failures read "… is used by another app" or "… isn't available"). To force one, quit Margin, run `defaults write io.github.jenish-shobhit.margin shortcut.repeatArea -data 7b226b6579436f6465223a32312c226d6f64696669657273223a3736387d` (Repeat area = ⇧⌘4), relaunch, then fix it in Settings: the warning goes away at once. `dump-state` lists each OSStatus under `hotkeys`
- [ ] With a macOS screenshot shortcut still on that Margin also uses (e.g. only "Save picture of selected area as a file"): the menu shows a quiet "macOS still uses ⇧⌘4 — Fix…" above Settings (no dot), which opens First run at step 2. With three or more it reads "macOS still uses N of Margin's shortcuts — Fix…". Turn the shortcut off in System Settings, reopen the menu: the item is gone (checked each time the menu opens)

## First run (§7)

- [ ] Shows on first launch and whenever permission is missing; a later launch with first run done and permission granted shows no window, even if macOS still owns a shortcut (the menu's "Fix…" item covers that)
- [ ] Step 1 requests access, deep-links to Screen & System Audio Recording, polls, and offers "Relaunch Margin" when needed; relaunch works
- [ ] Step 2's checklist of the four macOS shortcuts updates live (missing entry = enabled); the button opens Keyboard Shortcuts; the ⌘⇧5 note shows
- [ ] Step 3 says "Press ⌘⇧4" and mentions launch at login
- [ ] The window closes after the first successful capture
- [ ] A fresh account (or reset prefs) gets through First run in under a minute
- [ ] Margin never writes to `com.apple.symbolichotkeys`

## Settings (§8)

- [ ] Exactly five settings: Save to, Copy each capture, Shutter sound, Launch at login, Shortcuts
- [ ] Save to: the folder picker changes where the next capture lands
- [ ] Launch at login: on by default, toggling registers/unregisters (System Settings › General › Login Items)
- [ ] Shortcut recorders for Area, Screen, Repeat area and Tuck shelf; recording the current shortcut works
