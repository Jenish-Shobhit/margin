# Security policy

## Supported versions

Only the [latest release](https://github.com/Jenish-Shobhit/margin/releases/latest) gets fixes. Margin is pre-1.0, so please update before reporting.

## Reporting a vulnerability

**Please don't open a public issue.** Report it privately through GitHub:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**, or go straight to [the advisory form](https://github.com/Jenish-Shobhit/margin/security/advisories/new).
3. Describe the problem, the Margin and macOS versions, and how to reproduce it.

You'll get a reply on the advisory. Please allow time for a fix and a release before you disclose anything publicly.

## What Margin accesses

Margin is a local app. It has no analytics, no telemetry and no accounts; its only network requests are [update checks](#updates). It isn't sandboxed: it runs with the hardened runtime and one entitlement, `com.apple.security.device.audio-input`, which lets a screen recording include the microphone once you allow it. Release builds are signed with a self-signed certificate and aren't notarized.

| What | When and why |
|---|---|
| **Screen Recording** (ScreenCaptureKit) | Captures only when you press a capture shortcut or choose a capture from the menu. It also makes one 16 × 16 warm-up capture at launch, which is discarded. It reads the on-screen window list (frames and app names, not contents) for edge snapping and window mode. It asks for permission only when you click **Allow…**. A screen recording (⇧⌘5) streams only what you chose, from when you choose it until you stop it, while the menu bar shows a red stop button and the time; with **Record system audio** on it includes what the Mac plays |
| **Microphone** | Only with **Record microphone** on in Settings, during a recording. macOS asks for permission when you turn it on |
| **The save folder** (default `~/Desktop/Screenshots`) | Writes each PNG, and each screen recording (a hidden temp file while recording, renamed when it's done, in the folder it's in by then; one left by a crash is named the next time you record, or removed if nothing in it plays; one whose folder went to the Trash or was deleted while recording is moved or copied to Unsaved). Reads files back for thumbnails, copying and Quick Look. Renames or moves files to the Trash only when you choose **Rename…** or **Move to Trash**. A drag never moves or deletes a file. macOS asks before the first write to the Desktop folder |
| **`~/Library/Application Support/Margin/`** | `shelf.json` (the shelf's paths, Finder bookmarks, dates and sizes), `Unsaved/` for shots the save folder couldn't take, and, with **Delete screenshots after pasting** on, `Pasteboard/` for screenshots until they're pasted. Margin deletes files in `Pasteboard/` itself: one whose card has left the shelf, once ⌘Z can't bring it back and the clipboard no longer holds it, and at launch any there that no card holds. It deletes nothing anywhere else |
| **Preferences** (`io.github.jenish-shobhit.margin`) | Its own settings and shortcuts, the last area, a few counters |
| **The pasteboard** | Writes the PNG and the saved file's URL when a capture completes (if **Copy each capture** is on), and when you copy from the shelf; a recording's file URL alone. **Copy Path** writes plain text. Once a second it reads only the pasteboard's change count, never its contents, to keep the ⌘V mark right. With **Delete screenshots after pasting** on, a Pasteboard screenshot's item is promised rather than written, and kept to this Mac (not offered to other devices): macOS asks Margin for it when an app reads it, and at that moment Margin checks whether ⌘ or ⌃ is held and how long ago a key was pressed (`CGEventSource`, no Input Monitoring; not which key), to tell a paste from a clipboard manager's read. It learns nothing about the reading app or what's typed |
| **`com.apple.symbolichotkeys`** | Reads the five macOS screenshot shortcuts (IDs 28–31, and 184 for ⇧⌘5) to show whether they're on. **Writes them only when you click** **Turn off for me** (First run), or **Turn Off** or **Restore** (Settings › Shortcuts, under macOS Screenshot Shortcuts), keeping every other shortcut and custom binding. Then runs `/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u` so the change applies, and checks it with SkyLight's private `CGSIsSymbolicHotKeyEnabled` (read-only) |
| **Global hotkeys** | Carbon `RegisterEventHotKey` for its own shortcuts only. It doesn't watch other keys, and needs neither Accessibility nor Input Monitoring (the paste check above reads the modifiers and the time since the last key press once, when its own clipboard item is read) |
| **Launch at login** | `SMAppService.mainApp`, registered on first launch from `/Applications` and toggled in Settings |
| **Other system settings** | Reads "Play user interface sound effects" (`com.apple.sound.uiaudio.enabled`) to decide whether to play the shutter sound. While recording, holds a power assertion that keeps the display from idle sleep |
| **Helper processes** | `activateSettings -u` (above). For **Relaunch Margin**, `/bin/sh` waits for Margin to exit, then runs `/usr/bin/open` on the app |
| **Logs** | The macOS unified log, subsystem `io.github.jenish-shobhit.margin`: timings, errors, and saved file names and paths |
| **Network** | Only for updates: `GET https://api.github.com/repos/Jenish-Shobhit/margin/releases/latest` at launch and once a day while **Check for updates automatically** is on, and when you choose **Check for Updates…** or open `margin://update`; and the release's `Margin-<version>.zip` when you click **Install and Relaunch**. No cookies, no cache, no account; the user agent is `Margin/<version>`. Nothing about you, your Mac or your files is sent. With the setting off, no request is made unless you ask |
| **Updates** | `/usr/bin/ditto` unzips the download, and `/bin/sh` (the script in `UpdateInstall.helperScript`) waits for Margin to exit, moves the old app into the Trash, moves the new one into its place, clears its quarantine attribute and opens it, logging each step to `~/Library/Logs/Margin/Update.log`. See [Updates](#updates) |

## Updates

Margin replaces itself only after you click **Install and Relaunch**, and only with a release it has checked. `margin://update` (from the website) only runs a check: it can't install anything, and it ignores everything in the link after `update`.

Before anything is replaced, the download must pass all of these (`UpdateVerifier`):

1. It's the release's asset named exactly `Margin-<version>.zip`, fetched over https (redirects included), with the size GitHub lists and, when GitHub records one, the same SHA-256 `digest`.
2. `/usr/bin/ditto -x -k` unzips it into a private temporary folder, and `Margin.app` is a folder at its top level, not a link.
3. Its `Info.plist` has the bundle ID `io.github.jenish-shobhit.margin` and exactly the release's version as `CFBundleShortVersionString`.
4. Its code signature is valid as `codesign --verify --deep --strict` checks it: the Security framework's `SecStaticCodeCheckValidity` with every architecture, nested code, strict validation and no links out of the bundle.
5. It satisfies the **running** copy's designated requirement (`SecCodeCopySelf`, `SecCodeCopyDesignatedRequirement`): the same bundle ID signed by the same certificate leaf. So only whoever holds the private key that signed your copy can make an update it accepts, and macOS's Screen Recording permission, which is tied to that requirement, carries over. A copy signed ad hoc (a build from source without the certificate) refuses every update.

If any check fails, nothing changes and the window says which one. The checks rely on the code signature, not on GitHub alone: a release whose zip someone else signed is refused even if it's served from the right place. The certificate is self-signed and releases aren't notarized, so this pins *continuity* with the copy you installed, not Apple's judgement of it; the first download is trusted the way any download from the releases page is.

The swap happens after Margin quits. A helper waits for Margin's process to end (at most 30 s, then it gives up and changes nothing), moves the old app into your Trash as `Margin <old version>.app`, moves the checked app into its place (a rename on the same volume), puts the old one back if that fails, removes `com.apple.quarantine` and opens the app. The new app comes from the folder Margin verified it in, which only your user can write; Margin never asks for an administrator password, and an app folder it can't write ends with the releases page instead.

## Debug builds

Debug builds (`scripts/build.sh --debug`) include a local control hook for testing. It listens for the distributed notification `io.github.jenish-shobhit.margin.debug`, which **any process running as the same user can post**. That process can then make Margin:

- capture or record the screen;
- tuck or clear the shelf, or copy from it;
- write its state, including file paths, to `/tmp/margin-state.json`.

The hook is compiled only under `#if DEBUG` and **is never part of a release**:

- `scripts/build.sh` refuses `--zip` with `--debug`, and release zips come from release builds;
- installing a debug build prints a warning banner.

To check an installed copy, this prints `0` for a release build:

```sh
strings /Applications/Margin.app/Contents/MacOS/Margin | grep -c margin.debug
```

If you find a debug build distributed as a Margin release, report it as a vulnerability.

Debug builds can also point the updater at a local release and install it (`update-check`, `update-install`); what they install still has to pass every check under [Updates](#updates).
