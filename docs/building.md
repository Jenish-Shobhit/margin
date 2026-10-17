# Building Margin

Margin builds with SwiftPM and the Xcode Command Line Tools alone. There's no Xcode project and there are no third-party dependencies.

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Building by hand](#building-by-hand)
- [Tests](#tests)
- [scripts/build.sh](#scriptsbuildsh)
- [Signing: the Margin Dev certificate](#signing-the-margin-dev-certificate)
- [The debug hook](#the-debug-hook)
- [Timings and logs](#timings-and-logs)
- [Benchmarks](#benchmarks)
- [The app icon](#the-app-icon)
- [Releasing](#releasing)
- [The website](#the-website)
- [Testing updates](#testing-updates)

## Requirements

- macOS 26 (Tahoe) or later on Apple silicon. Margin builds for arm64 only.
- The Xcode Command Line Tools with Swift 6.2 or later (`Package.swift` uses tools version 6.2). Install them with `xcode-select --install`, and check with `swift --version`.
- Xcode isn't needed, and the scripts don't use `xcodebuild`, `actool` or XCTest.

## Quick start

```sh
git clone https://github.com/Jenish-Shobhit/margin.git
cd margin
scripts/build.sh --install --run
```

Do the [Margin Dev certificate](#signing-the-margin-dev-certificate) first, once, or macOS asks for Screen Recording permission again after every build.

Always run the installed copy, `/Applications/Margin.app`:

- Screen Recording permission belongs to the app at that path, signed by that certificate.
- Launch at login only registers from `/Applications`.
- **Relaunch Margin** needs an app bundle.

`swift run` starts a bare binary with none of that, so it's only useful for a quick look.

## Building by hand

```sh
swift build --build-system native              # debug
swift build --build-system native -c release --arch arm64
```

**Why `--build-system native`:** the default build system in recent SwiftPM releases needs Xcode. With only the Command Line Tools it fails with "Unknown error parsing property list". SwiftPM's native build system works with the Command Line Tools, and the scripts always pass it.

This gives you a binary in `.build/`, not an app. `scripts/build.sh` assembles the bundle.

## Tests

```sh
scripts/test.sh
scripts/test.sh --filter FileNamer   # extra arguments go to `swift test`
```

The tests use **Swift Testing** (`import Testing`), not XCTest. The Command Line Tools ship `Testing.framework` outside the compiler's default search paths, so plain `swift test` can't find it. `scripts/test.sh` runs `swift test --build-system native` and adds the framework and runtime search paths (`-F` and `-rpath` for `/Library/Developer/CommandLineTools/Library/Developer/Frameworks` and `…/usr/lib`). It also filters out deprecation noise.

The tests cover `MarginKit`, the app's pure logic:

- file names and collisions;
- coordinate maths and snapping;
- shelf layout and the pile;
- the order ⌘Z restores steps in;
- `shelf.json` round trips, bookmarks, pruning and unmounted volumes, and damaged or newer files;
- PNG encoding, DPI and atomic writes, and putting back the temp files of saves cut off;
- the clipboard items, including emulated Ghostty pastes;
- updates: version order, GitHub's release JSON (a fixture of a real answer), choosing the zip, what a check offers and Skip This Version, when checks are due, `margin://update`, the downloaded bundle's checks, and the swap helper run against fake bundles in a temporary folder;
- key-combo display and conflicts;
- preferences and the hint counter;
- the login item state;
- parsing and rewriting the macOS screenshot shortcuts, ⇧⌘5's 184 among them;
- recording names, temp files and leftovers, the frame rate, encoded size and bit rate rules, and durations; `shelf.json` with recordings, and from before them.

They never touch real system state: they use temporary folders, throwaway `UserDefaults` suites, and fake executables in place of `activateSettings`. One test is off by default because it mounts a volume: `MARGIN_DISK_IMAGE_TESTS=1 scripts/test.sh` also attaches and detaches a small disk image in a temporary folder, to check that a shot on an unplugged disk keeps its card.

The app target (windows, capture, the shelf) is checked by hand with [docs/QA.md](QA.md) and the [debug hook](#the-debug-hook).

## scripts/build.sh

```text
scripts/build.sh [--debug | --bench] [--install] [--run] [--zip]
```

The script runs these steps:

1. **Build** with `swift build --build-system native -c <config> --arch arm64` (release unless `--debug`).
2. **Assemble** `.build/app/<config>/Margin.app`: the binary, `Resources/Info.plist`, `PkgInfo` and `Resources/AppIcon.icns`.
3. **Sign** with the hardened runtime and `Resources/Margin.entitlements` (audio input, for recordings with the microphone): the **Margin Dev** identity if the keychain has it, otherwise ad-hoc with a loud warning (see below). It then checks the result with `codesign --verify --strict`.
4. `--install`: quit every running Margin (matched by bundle ID, forced after 5 s), then replace `/Applications/Margin.app`.
5. `--zip`: write `dist/Margin-<version>.zip` with `ditto`, without extended attributes, so a plain `unzip` doesn't leave `._` files that break the signature.
6. `--run`: open the app (the installed copy with `--install`).

| Option | Effect |
|---|---|
| `--debug` | Debug configuration. Includes the [debug hook](#the-debug-hook) |
| `--bench` | Release optimisation plus the debug hook (`-DMARGIN_BENCH`), in its own build folder (`.build/bench`), for [benchmarks](#benchmarks) |
| `--install` | Replace `/Applications/Margin.app`. With `--debug` or `--bench`, prints a warning banner before and after the build |
| `--run` | Open the built (or installed) app |
| `--zip` | Write the release zip. **Refused with `--debug` or `--bench`** (exit 2), before anything builds, and refused if the binary contains the hook anyway |
| `-h`, `--help` | Show usage |

The version comes from `CFBundleShortVersionString` in `Resources/Info.plist`.

## Signing: the Margin Dev certificate

macOS ties Screen Recording permission to the app's *designated requirement*, part of its code signature.

- **Signed with a certificate:** the requirement names the bundle ID and that certificate, so every rebuild matches and the permission stays.

  ```text
  identifier "io.github.jenish-shobhit.margin" and certificate leaf = H"…"
  ```

- **Signed ad-hoc:** the requirement is the hash of the binary itself, which changes with every build. macOS then sees each build as a new app and asks again.

So create a self-signed code-signing certificate named exactly **Margin Dev**, once. You don't need an Apple Developer account.

### With Keychain Access

1. Open **Keychain Access › Certificate Assistant › Create a Certificate…**.
2. Name: `Margin Dev`. Identity Type: **Self Signed Root**. Certificate Type: **Code Signing**.
3. Click **Create**, then rebuild.

### From the command line

This uses macOS's own `/usr/bin/openssl` (LibreSSL), in a scratch folder outside the repository:

```sh
cd "$(mktemp -d)"
cat > margin-dev.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Margin Dev
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config margin-dev.cnf -keyout margin-dev.key -out margin-dev.crt
/usr/bin/openssl pkcs12 -export -inkey margin-dev.key -in margin-dev.crt \
  -name "Margin Dev" -out margin-dev.p12 -passout pass:margin
security import margin-dev.p12 -k ~/Library/Keychains/login.keychain-db \
  -P margin -T /usr/bin/codesign
rm margin-dev.key margin-dev.p12
```

- `-T /usr/bin/codesign` lets `codesign` use the key without asking each time.
- If you use OpenSSL 3 (for example from Homebrew) instead, add `-legacy` to the `pkcs12` command, or `security import` may reject the file.
- Never commit the key or the `.p12`; `.gitignore` already excludes `*.p12` and `*.pem`.

### Checking it

```sh
security find-identity -p codesigning | grep "Margin Dev"
codesign -dvv /Applications/Margin.app 2>&1 | grep Authority   # Authority=Margin Dev
codesign -d -r- /Applications/Margin.app                         # the designated requirement
```

Leave out `-v` in `security find-identity`. A self-signed certificate isn't trusted (`CSSMERR_TP_NOT_TRUSTED`), so `-v`, which lists only valid identities, hides it. `codesign` signs with it all the same, and `build.sh` looks for it the same way.

### Without it

`build.sh` signs ad-hoc (`codesign --sign -`) and prints a warning that Screen Recording permission will be asked for again after every rebuild. If permission gets into a muddle, reset it and relaunch:

```sh
tccutil reset ScreenCapture io.github.jenish-shobhit.margin
```

## The debug hook

Debug builds (`scripts/build.sh --debug`) include a control hook for driving Margin without a mouse.

- It's compiled only under `#if DEBUG || MARGIN_BENCH`. Release builds don't contain it; bench builds (`--bench`) do.
- It listens for the distributed notification `io.github.jenish-shobhit.margin.debug`, whose object is the command.

`scripts/debug.sh` posts the commands:

```sh
scripts/build.sh --debug --install --run
scripts/debug.sh capture-area 100 100 400 300   # x y w h in AppKit global points, no overlay
scripts/debug.sh capture-screen                 # the display under the pointer
scripts/debug.sh toggle-shelf                   # tuck / show
scripts/debug.sh clear                          # empty the shelf (undoable)
scripts/debug.sh dismiss 4                      # the 4 newest cards off the shelf (undoable)
scripts/debug.sh restore-last                   # Restore Last Removed
scripts/debug.sh record-area 100 100 800 500    # record a rect (AppKit global points), no overlay
scripts/debug.sh record-screen                  # record the display under the pointer
scripts/debug.sh record-window 1234             # record that window (its window number)
scripts/debug.sh stop-recording                 # stop and save, as ⇧⌘5 does
scripts/debug.sh dump-state                     # print the state as JSON
```

- AppKit global points have their origin at the bottom-left of the main display, with y going up.
- `dump-state` makes the app write `/tmp/margin-state.json`, which the script prints. It includes:
  - the shelf's items and paths, which have a live card (`cards`: in the pile or not, with a decoded thumbnail or not), the tuck state, the ⌘V mark and the pasteboard change count;
  - the permission state and the login item;
  - each hotkey registration and its `OSStatus`;
  - the overlay's mode and purpose while a capture is up (`overlay.mode`, `overlay.purpose`: `capture` or `record`), and who has focus (`focus`: Margin's key window, whether it's active, the frontmost app);
  - the last capture's timings;
  - the recording (`recording`: its state, target, encoded size, fps, bit rate, temp file, frames written and dropped, and the last one's duration), each item's kind (`itemKinds`) and the status item (`statusItem`: its title, whether it shows the recording glyph, the menu's items).
- To check visuals, take a `screencapture -x`: it sees the shelf, while Margin's own captures never do.
- `scripts/bench.sh` also uses `hotkey <action>`, `capture-window`, `select x y w h`, `click x y [window=<id>]`, `key space|return|escape`, `cancel` and `mark <text>`, which drive a live overlay in-process (see `DebugCommandListener.swift`); `click … window=<id>` clicks only if that window is the one window mode would pick there, so a test never captures or records another app's window. `copy [n]` copies the n-th newest card as a click does, and `show settings|first-run|shortcuts|none` opens or closes Margin's windows.

**Any process running as your user can post that notification.** A debug build can therefore be made to capture the screen, clear the shelf or write its state to `/tmp`. That's why:

- `build.sh --zip` refuses `--debug`;
- `build.sh --debug --install` prints a warning banner before and after the build.

When you're done, put a release build back with `scripts/build.sh --install`.

## Timings and logs

Margin logs to the unified log under the subsystem `io.github.jenish-shobhit.margin`. The `timing` category has each step of a capture:

```sh
log stream --level info --predicate 'subsystem == "io.github.jenish-shobhit.margin" && category == "timing"'
```

Without `--level info` you'll miss the per-step lines (`hotkeyToFirstFrozen`, `releaseToResult`, …). The `release→thumbnail`, `release→clipboard` and `release→file` lines show either way.

The intervals are also signposts (`freeze`, `captureDisplay`, `crop`, `thumbnail`, `save`, …), so Instruments' os_signpost instrument shows them as intervals.

The info lines read `name: 12.3 ms` (sizes: `name: 45.6 KB`). The ones that say what a user feels:

| Line | From | To |
|---|---|---|
| `hotkeyEventToHandler` | The Carbon hotkey event's time stamp | Margin's handler (in-process dispatch only: the event is stamped as it reaches Margin; `scripts/bench.sh run --real-hotkey` measures the press itself as `keyPressToHandler`) |
| `hotkeyToFirstFrozen`, `…Frame` | The handler | The first frozen frame handed to the render server, and the display's next refresh after that |
| `releaseToThumbnailCommit`, `…Frame` | Mouse-up (or the capture, for ⇧⌘3, ⇧⌘2 and window mode; the click, for window mode's stand-in) | The main thread's Core Animation commit after the thumbnail went to the shelf, and the next refresh after that |
| `releaseToFile` | The same | The PNG renamed into place |
| `screenCapture`, `areaCapture`, `windowCapture` | The shortcut or click | The image, before the release clock starts (in window mode, the stand-in made at the click, when there is one) |
| `windowShot`, `releaseToShotThumbnailCommit`, `…Frame` | The click; the release | Window mode's own capture, after a stand-in; its thumbnail in place of the stand-in's (the bench adds the two up as `e2e.toShotThumbnailFrame`). `windowStandIn.*` is the window's capture at the click, before focus goes back |
| `release.*`, `finishSave.*` | | Main-thread steps of the release (`release.main` is all of `handleCapture`) and of the save's return |
| `launchToStarted`, `launchToPrewarmed` | The process start | Everything wired up; the first capture ready |
| `shelfRestore`, `shelfRestoreThumbnails` | | The shelf at launch, and the thumbnails of the cards in view (or nearly) loaded |
| `shelfSave`, `shelfWrite` | | What each change to the shelf costs the main thread for `shelf.json` (handing the list over), and the write itself, in the background |
| `shelfFileCheck`, `shelfFileCheck.apply` | | A background check of the shelf's files, and applying its result on the main thread |

The targets are:

| From | To | Target |
|---|---|---|
| Hotkey | First frozen frame on screen | ≤ 80 ms |
| Release | Thumbnail on the shelf | ≤ 100 ms |
| Release | PNG renamed into place | ≤ 200 ms |

## Benchmarks

`scripts/bench.sh` measures those lines in a **bench build**: release optimisation (debug builds distort timing) plus the debug hook, which a shipped release never has.

```sh
scripts/bench.sh build                    # a bench app of this tree; prints .build/bench-apps/<sha>/Margin.app
scripts/bench.sh build main               # or of any ref (built in a temporary worktree)
scripts/bench.sh run --app <app> --n 30   # 30 of each: ⇧⌘4 small / medium / full display, ⇧⌘3, ⇧⌘2, window mode
scripts/bench.sh ab <A.app> <B.app>       # two builds interleaved in blocks of 5, with the change and a p-value
scripts/bench.sh launch --shelf empty     # launch → ready, and memory (--shelf <file> for a full shelf)
scripts/bench.sh make-shelf <dir> 200 [<png>]  # a shelf.json of 200 cards for that (clones of <png>)
scripts/bench.sh ab <app> <app> --animate --record-b   # captures with and without a recording under way
scripts/bench.sh record --app <app> --seconds 30       # a full-display recording: CPU, energy, drops, file size
scripts/bench.sh encode <png>…            # PNG filter options on real captures: time, size, thumbnail decode
scripts/bench.sh micro                    # small main-thread steps in isolation
scripts/bench.sh report <results.jsonl>   # the table again; two files side by side
scripts/bench.sh help                     # every option
```

- It prints median, p90, min and max per metric and suite, against the [targets](#timings-and-logs), and keeps every value in a results file (`.build/bench-scratch/`).
- It drives the same calls a shortcut and a drag make (`hotkey captureArea`, then `select`), so everything but the window server's hand-over of the key is measured; `--real-hotkey` posts a real ⇧⌘4 instead (it needs Accessibility, and macOS's own ⇧⌘4 off).
- Captures see the bench's own window, a flat app UI or, with `--content photo`, a busy photo-like image, so PNG times don't depend on what's on screen.
- It backs up the installed app, Margin's preferences, `shelf.json` and the clipboard, and restores them at the end (or on Ctrl-C). Meanwhile shots go to its scratch folder, with **Copy each capture** and the sound off (`--sound` keeps it).
- It acts only while its window or Margin is in front and nobody is using the keyboard or mouse: it takes the screen after 20 s without input (`--idle`) and pauses on any input or when another app comes forward. With `--retake`, an app left in front by someone who has since been away for `--idle` seconds goes behind the bench window again, as at the start, instead of waiting for a click on it.
- It launches Margin at most every 30 s (`--relaunch-gap`), counting from the launch of the copy it quits: relaunched more often, Margin makes macOS ask the user whether it may bypass the system's private window picker. An `ab` of a single suite waits between blocks for that.
- Profile the same runs with `sample Margin 10 -file out.txt` while it captures.
- **Recording.** `--animate` adds a bar and a block that move every frame (Core Animation), so a recording encodes a frame per refresh. `ab A B --record-b` records the bench window during build B's blocks; give the same app twice to compare captures with and without a recording. `record` covers the whole main display (menu bar and Dock included, below Margin's shelf) with the animated window and, for each of `--n` rounds, measures Margin's CPU (from its CPU time) and energy impact (`top`'s POWER) for `--seconds` idle, then for as long recording the whole display, then the file: frames written and dropped, MB per minute. The movies go to the scratch folder and are deleted with it.

## The app icon

```sh
swift scripts/make-icon.swift                         # writes Resources/AppIcon.icns
swift scripts/make-icon.swift out.icns --png icon.png # elsewhere, plus a PNG preview
```

The icon is drawn from vectors at every size and packed with `iconutil`.

## Releasing

Releases are cut by the maintainer from a clean `main`:

1. Add a section to the top of `CHANGELOG.md`, headed `## <version> — <YYYY-MM-DD>`, with Added / Changed / Fixed.
2. Run `scripts/release.sh <version>`, for example `scripts/release.sh 0.0.8`.

The script checks that:

- you're on `main`;
- nothing but `CHANGELOG.md` has changed;
- the tag doesn't exist yet;
- the changelog section is there.

Then it does the release:

1. Sets `CFBundleShortVersionString` to the new version and increments `CFBundleVersion` in `Resources/Info.plist`.
2. Runs `scripts/test.sh`.
3. Runs `scripts/build.sh --install --run --zip`: a signed release build, installed locally and zipped to `dist/Margin-<version>.zip`.
4. Commits `chore(release): <version>`, tags `v<version>` and pushes `main` and the tag.
5. Creates the GitHub release with `gh`, attaching the zip. The notes are the changelog section plus install instructions.

You need `gh` signed in with push access, and the Margin Dev certificate, so release builds keep a stable signature. Releases aren't notarized; users open them with Open Anyway, as the README explains.

**Keep the zip's name and the certificate.** The updater (spec §14.3) installs only the asset named exactly `Margin-<version>.zip` from the latest release, containing a `Margin.app` whose version is that release's and whose signature satisfies the running copy's designated requirement. So a release signed with another certificate (or ad hoc) is refused by every installed copy, and they'd all have to be reinstalled by hand. Publish it as a full release, not a draft or pre-release: GitHub's `releases/latest` skips those, and so does the updater.

## The website

`docs/index.html` is Margin's download page: one self-contained file (inline CSS and JS, no external scripts or fonts) that asks GitHub's API for the latest release when it loads, and links its zip. `docs/.nojekyll` makes GitHub Pages serve the folder as it is, without Jekyll.

To publish it, once: on GitHub, open the repository's **Settings › Pages**, choose **Deploy from a branch**, then branch **main** and folder **/docs**, and save. It appears at <https://jenish-shobhit.github.io/margin/> a minute later, and updates with every push to `main`. Nothing in the release script touches it: the page always shows whatever release is latest.

To look at it locally, open `docs/index.html` in a browser (the download button falls back to the releases page if the API can't be reached).

## Testing updates

The updater can be tested end to end without GitHub, against a release you make yourself. Do it with a debug build installed, and put a release build back afterwards.

1. **The "new" version.** In a scratch worktree (`git worktree add --detach <scratch>/new HEAD`), set `CFBundleShortVersionString` in `Resources/Info.plist` to something higher (`9.9.9`), run `scripts/build.sh` (not `--install`), and zip the app as a release is zipped:

   ```sh
   ditto -c -k --keepParent --norsrc --noextattr --noacl .build/app/release/Margin.app <scratch>/www/ok/Margin-9.9.9.zip
   ```

2. **A feed.** Write `<scratch>/www/latest.json` in the shape of GitHub's answer (see `Tests/MarginKitTests/ReleaseFixture.swift`): `tag_name` `v9.9.9`, `html_url`, `body`, `published_at`, and one asset with `name` `Margin-9.9.9.zip`, `browser_download_url`, `size` and `digest` (`sha256:` and the zip's `shasum -a 256`).
3. **Serve it** with `python3 -m http.server 8765 --bind 127.0.0.1 --directory <scratch>/www`, or use `file://` URLs throughout. Release builds only accept https; DEBUG and bench builds also take `file://` and `http://127.0.0.1`.
4. **Check and install** with the debug build running from `/Applications`:

   ```sh
   scripts/debug.sh update-check http://127.0.0.1:8765/latest.json   # the window offers 9.9.9
   scripts/debug.sh update-state; cat /tmp/margin-update-state.json  # what it shows
   scripts/debug.sh update-install                                   # download, check, quit, swap, relaunch
   ```

   With a local feed the window never takes the keyboard and Open Releases Page only logs. After the relaunch, `/Applications/Margin.app` is the 9.9.9 build, the shelf says "Updated to Margin 9.9.9", the old app is in the Trash as "Margin <old version>.app" and `~/Library/Logs/Margin/Update.log` has each step.
5. **Refusals.** Each of these must leave the app alone and say why: a zip of a copy with another `CFBundleIdentifier` (re-signed with Margin Dev), a feed whose tag doesn't match the app's version, a copy re-signed ad hoc (`codesign --force --sign - …`), a copy changed after signing (append a byte to its icon or executable), a zip without `Margin.app`, a wrong `size` or `digest`, a feed with no asset, an unreachable feed. `update-readonly on` stands in for an `/Applications` you can't write, and `update-trash /var/empty` makes the helper fail and put the old app back (the next launch says so).
6. **Clean up:** delete the old copy from the Trash, `defaults delete io.github.jenish-shobhit.margin debugUpdateFeedURL` if you set it, and reinstall a release build (`scripts/build.sh --install --run`).
