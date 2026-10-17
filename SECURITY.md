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

Margin is a local app. It has no networking code, no analytics, no telemetry and no update checks. It isn't sandboxed: it runs with the hardened runtime and one entitlement, `com.apple.security.device.audio-input`, which lets a screen recording include the microphone once you allow it. Release builds are signed with a self-signed certificate and aren't notarized.

| What | When and why |
|---|---|
| **Screen Recording** (ScreenCaptureKit) | Captures only when you press a capture shortcut or choose a capture from the menu. It also makes one 16 × 16 warm-up capture at launch, which is discarded. It reads the on-screen window list (frames and app names, not contents) for edge snapping and window mode. It asks for permission only when you click **Allow…**. A screen recording (⇧⌘5) streams only what you chose, from when you choose it until you stop it, while the menu bar shows a red stop button and the time; with **Record system audio** on it includes what the Mac plays |
| **Microphone** | Only with **Record microphone** on in Settings, during a recording. macOS asks for permission when you turn it on |
| **The save folder** (default `~/Desktop/Screenshots`) | Writes each PNG, and each screen recording (a hidden temp file while recording, renamed when it's done; one left by a crash is removed the next time you record there). Reads files back for thumbnails, copying and Quick Look. Renames or moves files to the Trash only when you choose **Rename…** or **Move to Trash**. A drag never moves or deletes a file. macOS asks before the first write to the Desktop folder |
| **`~/Library/Application Support/Margin/`** | `shelf.json` (the shelf's paths, Finder bookmarks, dates and sizes), and `Unsaved/` for shots the save folder couldn't take |
| **Preferences** (`io.github.jenish-shobhit.margin`) | Its own settings and shortcuts, the last area, a few counters |
| **The pasteboard** | Writes the PNG and the saved file's URL when a capture completes (if **Copy each capture** is on), and when you copy from the shelf; a recording's file URL alone. **Copy Path** writes plain text. Once a second it reads only the pasteboard's change count, never its contents, to keep the ⌘V mark right |
| **`com.apple.symbolichotkeys`** | Reads the five macOS screenshot shortcuts (IDs 28–31, and 184 for ⇧⌘5) to show whether they're on. **Writes them only when you click** **Turn off for me**, **Turn off macOS screenshot shortcuts** or **Restore macOS screenshot shortcuts**, keeping every other shortcut and custom binding. Then runs `/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u` so the change applies, and checks it with SkyLight's private `CGSIsSymbolicHotKeyEnabled` (read-only) |
| **Global hotkeys** | Carbon `RegisterEventHotKey` for its own shortcuts only. It doesn't watch other keys, and needs neither Accessibility nor Input Monitoring |
| **Launch at login** | `SMAppService.mainApp`, registered on first launch from `/Applications` and toggled in Settings |
| **Other system settings** | Reads "Play user interface sound effects" (`com.apple.sound.uiaudio.enabled`) to decide whether to play the shutter sound. While recording, holds a power assertion that keeps the display from idle sleep |
| **Helper processes** | `activateSettings -u` (above). For **Relaunch Margin**, `/bin/sh` waits for Margin to exit, then runs `/usr/bin/open` on the app |
| **Logs** | The macOS unified log, subsystem `io.github.jenish-shobhit.margin`: timings, errors, and saved file names and paths |

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
