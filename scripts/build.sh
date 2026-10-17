#!/bin/bash
# Builds Margin.app (arm64), signs it, and optionally installs, runs and zips it.
#
#   scripts/build.sh [--debug | --bench] [--install] [--run] [--zip]
#
#   --debug    debug configuration (includes the DEBUG control hook, see scripts/debug.sh)
#   --bench    release optimisation plus the control hook (-DMARGIN_BENCH), for scripts/bench.sh
#   --install  quit any running Margin and replace /Applications/Margin.app (loud warning with --debug/--bench)
#   --run      open the app (the installed copy when --install is given)
#   --zip      write dist/Margin-<version>.zip (plain release builds only: refused with --debug or --bench)
#
# Signing uses the "Margin Dev" identity when the keychain has it. It is self-signed, so
# `security find-identity -v` hides it (CSSMERR_TP_NOT_TRUSTED), but codesign uses it fine, and
# its stable certificate keeps the Screen Recording permission across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.." >/dev/null
ROOT=$(pwd)

BUNDLE_ID="io.github.jenish-shobhit.margin"
IDENTITY_NAME="Margin Dev"
INSTALL_PATH="/Applications/Margin.app"

CONFIG=release
BENCH=0
INSTALL=0
RUN=0
ZIP=0
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --bench) BENCH=1 ;;
    --install) INSTALL=1 ;;
    --run) RUN=1 ;;
    --zip) ZIP=1 ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "build.sh: unknown option $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*" >&2; }

# Debug and bench builds listen for DistributedNotification commands (scripts/debug.sh, scripts/bench.sh),
# which any process of this user can post: never ship one, and say so loudly when one goes to /Applications.
if [[ "$CONFIG" == debug && "$BENCH" == 1 ]]; then
  echo "build.sh: --bench is a release build with the control hook; it can't be combined with --debug" >&2
  exit 2
fi
HOOK=0
if [[ "$CONFIG" == debug || "$BENCH" == 1 ]]; then HOOK=1; fi
KIND=$CONFIG
if [[ "$BENCH" == 1 ]]; then KIND=bench; fi
if [[ "$HOOK" == 1 && "$ZIP" == 1 ]]; then
  echo "build.sh: --zip makes the release artifact and can't be combined with --$KIND" \
    "(that build carries the control hook). Run scripts/build.sh --zip." >&2
  exit 2
fi
hook_install_warning() {
  warn "################################################################################"
  warn "#  Installing a $(echo "$KIND" | tr '[:lower:]' '[:upper:]') build to $INSTALL_PATH."
  warn "#  It carries the control hook: any process of this user can post the"
  warn "#  io.github.jenish-shobhit.margin.debug DistributedNotification and make it"
  warn "#  capture the screen, clear the shelf or dump its state to /tmp."
  warn "#  Reinstall a release build (scripts/build.sh --install) when you're done."
  warn "################################################################################"
}
if [[ "$HOOK" == 1 && "$INSTALL" == 1 ]]; then hook_install_warning; fi

PLIST_SRC="$ROOT/Resources/Info.plist"
ICON_SRC="$ROOT/Resources/AppIcon.icns"
# The hardened runtime's entitlements: audio input, for screen recordings with the microphone. Not part of the
# designated requirement, so the Screen Recording permission doesn't change with them.
ENTITLEMENTS="$ROOT/Resources/Margin.entitlements"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST_SRC")

# 1. Build ------------------------------------------------------------------------------------
say "Building Margin $VERSION ($KIND, arm64)"
SWIFT_FLAGS=(--build-system native -c "$CONFIG" --arch arm64)
# Its own build folder, so a bench build never shares objects with a release build.
if [[ "$BENCH" == 1 ]]; then SWIFT_FLAGS+=(--scratch-path "$ROOT/.build/bench" -Xswiftc -DMARGIN_BENCH); fi
set +e
swift build "${SWIFT_FLAGS[@]}" 2>&1 | grep -v "has been deprecated"
STATUS=${PIPESTATUS[0]}
set -e
if [[ "$STATUS" != 0 ]]; then
  echo "build.sh: swift build failed ($STATUS)" >&2
  exit "$STATUS"
fi
BIN_DIR=$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path 2>/dev/null | tail -1)
BINARY="$BIN_DIR/Margin"
if [[ ! -x "$BINARY" ]]; then
  echo "build.sh: no binary at $BINARY" >&2
  exit 1
fi

# 2. Assemble the bundle ----------------------------------------------------------------------
OUT_DIR="$ROOT/.build/app/$KIND"
APP="$OUT_DIR/Margin.app"
say "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Margin"
cp "$PLIST_SRC" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
else
  warn "No Resources/AppIcon.icns (run scripts/make-icon.swift). The app will have a generic icon."
fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# 3. Sign -------------------------------------------------------------------------------------
# No -v: the self-signed identity is "not trusted" and -v would hide it.
IDENTITY_HASH=$(security find-identity -p codesigning 2>/dev/null \
  | awk -v name="\"$IDENTITY_NAME\"" 'index($0, name) { print $2; exit }')
if [[ -n "$IDENTITY_HASH" ]]; then
  say "Signing with \"$IDENTITY_NAME\" ($IDENTITY_HASH)"
  codesign --force --options runtime --timestamp=none --entitlements "$ENTITLEMENTS" --sign "$IDENTITY_HASH" "$APP"
else
  warn "################################################################################"
  warn "#  No \"$IDENTITY_NAME\" code-signing identity in the keychain: signing ad-hoc."
  warn "#  macOS will ask for Screen Recording permission again after EVERY rebuild."
  warn "#  Fix: Keychain Access > Certificate Assistant > Create a Certificate…,"
  warn "#       name \"$IDENTITY_NAME\", type Code Signing, then rebuild."
  warn "################################################################################"
  codesign --force --options runtime --timestamp=none --entitlements "$ENTITLEMENTS" --sign - "$APP"
fi
codesign --verify --strict "$APP"

# 4. Install ----------------------------------------------------------------------------------
quit_running() {
  # Ask every running copy (matched by bundle id) to quit, then force it after 5 s.
  /usr/bin/osascript -l JavaScript - "$BUNDLE_ID" <<'JS' >/dev/null
ObjC.import('AppKit');
function run(argv) {
  const id = argv[0];
  const list = () => ObjC.unwrap($.NSRunningApplication.runningApplicationsWithBundleIdentifier(id)) || [];
  list().forEach(a => a.terminate);
  for (let i = 0; i < 50 && list().length > 0; i++) delay(0.1);
  list().forEach(a => a.forceTerminate);
  return list().length;
}
JS
}

if [[ "$INSTALL" == 1 ]]; then
  say "Installing to $INSTALL_PATH"
  quit_running
  rm -rf "$INSTALL_PATH"
  ditto "$APP" "$INSTALL_PATH"
  APP="$INSTALL_PATH"
fi

# 5. Zip --------------------------------------------------------------------------------------
if [[ "$ZIP" == 1 ]]; then
  # The release artifact must never carry the control hook (its notification name is in no other code).
  if strings "$APP/Contents/MacOS/Margin" | grep -q "margin\.debug"; then
    echo "build.sh: the binary contains the control hook; not zipping it" >&2
    exit 1
  fi
  mkdir -p "$ROOT/dist"
  ZIP_PATH="$ROOT/dist/Margin-$VERSION.zip"
  rm -f "$ZIP_PATH"
  # No extended attributes: they'd become ._ files inside the bundle (and break its seal) when
  # extracted with plain `unzip`. The code signature doesn't depend on them.
  ditto -c -k --keepParent --norsrc --noextattr --noacl "$APP" "$ZIP_PATH"
  say "Wrote $ZIP_PATH"
fi

# 6. Run --------------------------------------------------------------------------------------
if [[ "$RUN" == 1 ]]; then
  say "Opening $APP"
  open "$APP"
fi

say "Done: $APP"
# Repeated at the end so it isn't lost above the build output.
if [[ "$HOOK" == 1 && "$INSTALL" == 1 ]]; then hook_install_warning; fi
