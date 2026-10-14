# Keyboard shortcuts

Every shortcut in Margin 0.0.7. Modifiers are written in the macOS order ⌃⌥⇧⌘ (Control, Option, Shift, Command), as in System Settings: ⇧⌘4 is Shift-Command-4.

## Global

These work from any app. The four marked *rebindable* can be changed in [Settings](user-guide.md#settings).

| Default | Action | |
|---|---|---|
| ⇧⌘4 | Capture an area on a frozen screen. Press Space for window mode | Rebindable |
| ⇧⌘3 | Capture the whole display under the pointer | Rebindable |
| ⇧⌘2 | Capture the last area again, with no overlay. Falls back to ⇧⌘4 if there's no last area, or its display is gone or at another resolution | Rebindable |
| ⇧⌘1 | Tuck or show the shelf | Rebindable |
| ⌃⇧⌘4 | Same as ⇧⌘4 | Follows ⇧⌘4 |
| ⌃⇧⌘3 | Same as ⇧⌘3 | Follows ⇧⌘3 |
| ⌃⇧⌘2 | Same as ⇧⌘2 | Follows ⇧⌘2 |

- **The ⌃ twins.** Each capture shortcut also answers with ⌃ added, because macOS uses ⌃ to mean "copy to the clipboard" and every Margin shot is already copied. If you set a capture shortcut that already includes ⌃, there's no twin.
- **Window capture** has no shortcut of its own: press Space after ⇧⌘4, or use **Capture Window** in the menu bar.
- **⇧⌘5** stays with macOS for screen recording.

The four macOS screenshot shortcuts (⇧⌘3, ⌃⇧⌘3, ⇧⌘4, ⌃⇧⌘4) must be off for Margin to receive those keys. First run's **Turn off for me** does that; see [Troubleshooting](troubleshooting.md#the-macos-screenshot-tool-opens-instead-of-margin).

## While selecting an area

| Keys | Action |
|---|---|
| Drag, then release | Select, and capture on release |
| ⇧ while dragging | Make the selection square |
| ⌥ while dragging | Grow the selection from its centre |
| Hold Space while dragging | Move the selection |
| ←↑→↓ while dragging | Keep the selection when you release, so you can adjust it |
| ←↑→↓ | Nudge the selection 1 px per tap; holding speeds up to 2 px, then 4 px |
| ⇧←↑→↓ | Nudge 10 px |
| Drag a handle | Resize (after the selection was kept) |
| Drag inside the selection | Move it (after it was kept) |
| ↩ or ⌤ | Capture the selection |
| Z | Show or hide the magnifier, for this capture |
| Space (not dragging) | Switch to window mode |
| Esc or right-click | Cancel: nothing saved, clipboard untouched |

⌘ shortcuts are ignored while the overlay is up. Switching apps with ⌘Tab cancels the capture.

## Window mode

| Keys | Action |
|---|---|
| Click | Capture the window under the pointer: transparent corners, no shadow |
| ⌥-click | Capture it with its shadow |
| Space | Back to area mode |
| Esc or right-click | Cancel |

## On the shelf

A plain click copies a card and leaves the keyboard with your app, so ⌘V right after it pastes there. The keys below reach the shelf only after you ⌘-click a card, click ✕ or the pile, or choose Rename…, Move to Trash or Clear shelf; Esc, a copy, closing Quick Look, tucking the shelf or a click elsewhere gives them back. Keys act on the selection if there is one, otherwise on the card under the pointer, otherwise on the last card you clicked.

| Keys | Action |
|---|---|
| Click | Copy the shot |
| Double-click | Open it in the default app |
| Drag | Send the file to another app; the card leaves when the drop lands |
| ⌥ held at the drop | Keep the card on the shelf |
| ⌘-click | Toggle the card in the selection |
| ⌘A | Select every card that isn't in the pile |
| ⌘C | Copy the selected cards |
| Space | Quick Look (← → step through the selected shots; Space or Esc closes it and gives the keys back to your app) |
| ⌫ or ⌦ | Dismiss (the file stays on disk) |
| Two-finger swipe right | Dismiss the card under the pointer |
| Esc | Close Quick Look; otherwise clear the selection and give the keys back to your app |
| ⌘Z | Bring back the card(s) last removed (up to 20 steps) |
| Right-click or ⌃-click | The card's menu: Copy Path, Reveal in Finder, Rename…, Move to Trash |
| Right-click the pile | Clear shelf |

**Renaming** (Rename… in the card's menu): ↩ saves, Esc cancels and clicking elsewhere keeps the new name (so does tucking the shelf, or a new shot pushing the card into the pile). ⌘X, ⌘C, ⌘V, ⌘A, ⌘Z and ⇧⌘Z edit the text; none of them reach the shelf.

**⌘Q and ⌘W** only act while one of Margin's windows (Settings, Welcome) is in front. While the shelf has the keys (after a ⌘-click or ✕, say), ⌘Q doesn't quit Margin and ⌘W doesn't close anything; press Esc or click back into your app to use them there. After a plain click on a card they go to your app as usual.

## In Settings

| Keys | Action |
|---|---|
| Click a shortcut, then press keys | Record a new shortcut. It needs ⌘ or ⌃ plus another modifier (or an F-key), and can't be one macOS or most apps use |
| Esc while recording | Cancel |
| Delete while recording | Reset to the default |
| ⌘W | Close Settings |

## In the menu bar menu

With the menu open, **⌘,** opens Settings and **⌘Q** quits. The capture items show their current shortcuts.
