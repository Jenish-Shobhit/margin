# Troubleshooting

Answers to the problems people run into most. If yours isn't here, [open an issue](https://github.com/Jenish-Shobhit/margin/issues/new/choose).

- [Margin can't be opened](#margin-cant-be-opened)
- [Margin asks for Screen Recording, or lost it](#margin-asks-for-screen-recording-or-lost-it)
- [The macOS screenshot tool opens instead of Margin](#the-macos-screenshot-tool-opens-instead-of-margin)
- [A shortcut does nothing](#a-shortcut-does-nothing)
- [macOS asks to access the Desktop folder](#macos-asks-to-access-the-desktop-folder)
- [Nothing pastes after a capture](#nothing-pastes-after-a-capture)
- [A stray "v" appears in Ghostty](#a-stray-v-appears-in-ghostty)
- [Dragging into WhatsApp moved my screenshot](#dragging-into-whatsapp-moved-my-screenshot)
- [The shelf is gone](#the-shelf-is-gone)
- [Launch at login needs approval](#launch-at-login-needs-approval)
- [Where are my screenshots?](#where-are-my-screenshots)
- [The frozen screen won't go away](#the-frozen-screen-wont-go-away)
- [A display says "Can't capture this display"](#a-display-says-cant-capture-this-display)
- [Reporting a bug](#reporting-a-bug)

## Margin can't be opened

macOS says **"Margin" Not Opened** ("Apple could not verify…"), because Margin isn't notarized: notarization needs a paid Apple Developer ID. To open it:

1. Click **Done** in the dialog (not Move to Trash).
2. Open **System Settings › Privacy & Security** and scroll down to **Security**.
3. Next to "Margin" was blocked…, click **Open Anyway**, then confirm with your password or Touch ID.

You need to do this once per download.

If macOS says the app **is damaged**, the download or the unzip went wrong. Download the zip again from [Releases](https://github.com/Jenish-Shobhit/margin/releases/latest) and unzip it with Finder.

As an alternative to Open Anyway, you can clear the quarantine flag yourself. Do this only for a copy you downloaded from this repository's Releases:

```sh
xattr -dr com.apple.quarantine /Applications/Margin.app
```

**A new copy opens Margin's Settings and doesn't start.** Only one Margin runs at a time. Opening another copy (a newer download, say) while one is running opens the running one's Settings instead, and the new copy quits within a few seconds. Quit Margin first (menu bar › **Quit Margin**), then open the copy you want.

## Margin asks for Screen Recording, or lost it

Margin needs Screen Recording to see the screen. Without it, its menu bar icon shows an orange dot, the menu's first item reads **Allow Screen Recording…**, and pressing a capture shortcut opens the Welcome window at step 1 instead of capturing.

1. Open **System Settings › Privacy & Security › Screen & System Audio Recording** (**Open Privacy Settings** in the Welcome window goes there).
2. Turn **Margin** on.
3. If Margin still can't capture, click **Relaunch Margin** in the Welcome window or the menu. macOS often hands the permission only to a fresh copy of the app.

If you turn the permission off while Margin is running, the next capture fails. Margin then shows the warning, and keeps showing it until a capture works or you relaunch, even though macOS may still report the permission as granted until then.

If macOS keeps asking after you've allowed it:

- Make sure you're running `/Applications/Margin.app`, not a copy elsewhere (Downloads, a disk image). The permission belongs to the copy you granted it to.
- Remove Margin from the list with **−**, open it again and allow it once more. To start completely fresh, run `tccutil reset ScreenCapture io.github.jenish-shobhit.margin`, then relaunch Margin.
- Building from source? An ad-hoc-signed build counts as a new app after every build. See [Building](building.md#signing-the-margin-dev-certificate).

## The macOS screenshot tool opens instead of Margin

macOS's own screenshot shortcuts are still on, and macOS gets the keys before any app. The menu bar menu shows this as **macOS still uses ⇧⌘4 — Fix…**.

- Click that item, or open Settings, and choose **Turn off for me** (in the Welcome window) or **Turn off macOS screenshot shortcuts** (in Settings). Margin switches off the four macOS screenshot shortcuts (⇧⌘3, ⌃⇧⌘3, ⇧⌘4, ⌃⇧⌘4), and the change applies at once.
- To do it by hand: **System Settings › Keyboard › Keyboard Shortcuts… › Screenshots**, and untick those four.

If turning them off reports a problem:

- **"Something changed the shortcuts back"**: System Settings, open on its Keyboard pane, can write the old settings back. Quit System Settings and try again.
- **"Saved, but macOS hasn't applied it yet"**: log out and back in.

⇧⌘5 stays with macOS for screen recording; Margin doesn't use it.

## A shortcut does nothing

Check the menu bar icon first:

- **An orange dot, and a top item like "⇧⌘4 is used by another app — Change in Settings…"**. Another app registered that shortcut first. Choose a different one in Settings (the row says "Another app uses this shortcut"), or change it in the other app. "…is set for two actions" means two of Margin's own shortcuts are the same.
- **"Allow Screen Recording…"**. Captures are blocked until permission is granted; see [above](#margin-asks-for-screen-recording-or-lost-it).
- **"macOS still uses ⇧⌘4 — Fix…"**. macOS takes the key first; see [above](#the-macos-screenshot-tool-opens-instead-of-margin).

Other causes:

- Another app may take the same keys without Margin being told. macOS doesn't always report the clash, so there may be no warning. Quit apps that have their own capture shortcuts (other screenshot or clipboard tools), or give Margin a different shortcut in Settings.
- While a shortcut button in Settings is listening for keys, Margin's shortcuts are paused. Press Esc or click elsewhere.
- A capture is already on screen, or Margin is quitting.
- One of Margin's menus was open (the menu bar icon's, or a card's). A shortcut pressed then does nothing, rather than firing as the menu closes. Press it again once the menu is closed.

## macOS asks to access the Desktop folder

**"Margin" would like to access files in your Desktop folder** appears the first time Margin saves to `~/Desktop/Screenshots`, the default save folder, with Margin's reason: it saves your screenshots there. Click **Allow**.

If you clicked **Don't Allow**, captures go to `~/Library/Application Support/Margin/Unsaved/` instead, with the shelf toast "Can't write to “Screenshots”. Saved to Unsaved: menu bar › Show Unsaved Shots". To fix it, do one of these:

- Turn on **Desktop Folder** for Margin in **System Settings › Privacy & Security › Files & Folders**.
- Choose a different folder in **Settings › Save to**. A folder outside Desktop, Documents and Downloads, such as `~/Pictures/Screenshots`, doesn't ask.

To find those shots, choose **Show Unsaved Shots** in the menu bar (it's there while the Unsaved folder holds any) and move them where you want them. **Open Screenshots Folder** opens the Unsaved folder too when it can't open the save folder.

## Nothing pastes after a capture

- **Did you just ⌘-click a card, or click ✕?** Those give the shelf the keyboard, so ⌘Z, ⌫ and Space work there. Press Esc (or click into the app you want to paste into), then press ⌘V. A plain click on a card copies it and leaves the keyboard with your app.
- **In a terminal:** ⌘V pastes only text. Margin puts the saved file on the clipboard next to the image, so:
  - In **Ghostty**, ⌘V pastes the file's path, and in **Claude Code** that attaches the screenshot.
  - In **Claude Code in any terminal**, press **Ctrl+V** to attach the image from the clipboard.
  - In other terminals, drag the card into the window to type its path.
- **Is the ⌘V pill on a card?** If not, something else has been copied since. Click the card to copy it again.
- **Settings › Copy each capture is off?** Then captures leave the clipboard alone; click a card to copy it.
- **The shelf said "Couldn't save the screenshot"?** Without a file, the clipboard holds only the image. Image apps can paste it, terminals can't.
- **Pasted the instant you let go?** The clipboard is written once the file is on disk, a fraction of a second later.

## A stray "v" appears in Ghostty

Ghostty's ⌘V pastes text. When the clipboard holds nothing it can paste as text (for example an image copied from a browser), some Ghostty versions and configurations pass the keypress on to the program running in the terminal. That program sees a plain **v**. An example configuration is a `performable:` paste keybinding.

- Delete the **v**.
- Put a Margin copy on the clipboard: click the card (the ⌘V pill moves to it). A Margin copy carries the file, so ⌘V pastes its path.
- In Claude Code, use **Ctrl+V** for an image-only clipboard.

A shot that Margin couldn't save is copied as an image only, so it can cause the same thing.

## Dragging into WhatsApp moved my screenshot

It didn't. Margin offers every drag as a **copy** of the file and never moves or deletes it, whatever the receiving app does. The file stays in your save folder.

What you saw is the card leaving the shelf: a successful drop means "done with this one".

- **Hold ⌥ when you drop** to keep the card on the shelf. The dragged image shows "Keep on shelf".
- **Restore Last Removed** in the menu bar brings the card back. A drag leaves the keyboard with the app you dropped into, so ⌘Z right after the drop goes to that app; ⌘Z on the shelf works once you've ⌘-clicked a card or clicked the pile.

The same goes for any app that wrongly reports a drop as successful. If an app wrongly reports a *failed* drop, the card stays on the shelf, and ⌫ dismisses it.

## The shelf is gone

- **It's tucked.** Look for a narrow tab with a number at the right edge of the screen, near the bottom. Hover it to peek, click it, or press **⇧⌘1** (or choose **Show Shelf** in the menu bar).
- **It's on another display.** The shelf moves to the display of your most recent capture.
- **It's empty**, so it's hidden. **Restore Last Removed** in the menu bar brings back what last left it.
- **The files were deleted or moved to the Trash.** Cards drop off when their file is gone.
- **Its list was damaged.** The shelf is kept in `~/Library/Application Support/Margin/shelf.json`. If part of that file can't be read, the cards that can still be read come back, and the original file is kept beside it as `shelf.json.bad` (attach it to a bug report).
- **Margin isn't running.** If there's no menu bar icon, open Margin from Applications. If the icon is hidden by your menu bar settings, opening Margin again opens its Settings.

## Launch at login needs approval

The Welcome window says **Launch at login is waiting for your approval**, or Settings shows **Approve in System Settings › General › Login Items**. macOS has registered Margin but wants you to allow it.

Click **Open Login Items** and switch Margin on. Settings shows the real state again when you come back.

If Settings says **Couldn't turn on launch at login**, move Margin to `/Applications` and try again. Margin only registers itself at first launch when it's in `/Applications`.

## Where are my screenshots?

In `~/Desktop/Screenshots` unless you changed **Settings › Save to**. **Open Screenshots Folder** in the menu bar opens it. Shots that couldn't be written there are in `~/Library/Application Support/Margin/Unsaved/`: **Show Unsaved Shots** in the menu bar opens it.

To find one from the shelf, choose **Reveal in Finder** from its card's menu.

## The frozen screen won't go away

Press **Esc** or right-click. If the frozen picture never appeared, the overlay cancels itself after 3 seconds and the shelf shows "Couldn't capture the screen". Switching apps with ⌘Tab also cancels it.

## A display says "Can't capture this display"

macOS doesn't offer that display for capture. This happens with some Sidecar, AirPlay and DisplayLink setups. The display is dimmed and can't be selected on; capture on another display.

## Reporting a bug

[Open a bug report](https://github.com/Jenish-Shobhit/margin/issues/new?template=bug_report.yml) with your macOS version and Margin version (menu bar › About Margin). Recent logs help:

```sh
log show --last 10m --info --predicate 'subsystem == "io.github.jenish-shobhit.margin"'
```

Logs include file names and paths of your screenshots, so look them over before you paste them.
