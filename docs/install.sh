#!/bin/bash
# Installs Margin, or updates it, from its latest GitHub release. Paste into Terminal:
#
#   curl -fsSL https://jenish-shobhit.github.io/margin/install.sh | bash
#
# A file curl downloads isn't quarantined, so Margin opens without the "Not Opened" dialog and Open Anyway
# that a browser download gets while Margin isn't notarized. This script stands in for those checks: the zip
# must match the size and SHA-256 GitHub lists for it, and the app must be signed with Margin's own
# certificate (the one every release and the in-app updater use), or nothing is installed.
#
# MARGIN_APP (default /Applications/Margin.app) and MARGIN_NO_OPEN=1 are for testing.
set -euo pipefail

REPO="Jenish-Shobhit/margin"
APP="${MARGIN_APP:-/Applications/Margin.app}"
BUNDLE_ID="io.github.jenish-shobhit.margin"
REQUIREMENT='identifier "io.github.jenish-shobhit.margin" and certificate leaf = H"8b3cfb0bd2b9891795d4793f0e62c0de361efe26"'

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || die "Margin is a macOS app."
[[ "$(uname -m)" == arm64 ]] || die "Margin needs a Mac with Apple silicon."
macos=$(sw_vers -productVersion)
(( ${macos%%.*} >= 26 )) || die "Margin needs macOS 26 or later; this Mac has $macos."

say "Finding the latest release"
json=$(curl -fsSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$REPO/releases/latest") \
  || die "couldn't reach GitHub. Check your connection and try again."
field() { plutil -extract "$1" raw -o - - <<<"$json" 2>/dev/null; }

version=$(field tag_name) || die "GitHub's answer has no release in it."
version=${version#v}
[[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "the latest release's tag ($version) isn't a version."
zip_name="Margin-$version.zip"

url="" size="" digest=""
i=0
while name=$(field "assets.$i.name"); do
  if [[ "$name" == "$zip_name" ]]; then
    [[ "$(field "assets.$i.state")" == uploaded ]] || die "Margin $version is still being uploaded. Try again in a minute."
    url=$(field "assets.$i.browser_download_url")
    size=$(field "assets.$i.size")
    digest=$(field "assets.$i.digest" || true)
    break
  fi
  i=$((i + 1))
done
[[ "$url" == https://github.com/* ]] || die "the latest release has no $zip_name."

installed=""
[[ -d "$APP" ]] && installed=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)
if [[ "$installed" == "$version" ]] && codesign --verify -R="$REQUIREMENT" "$APP" 2>/dev/null; then
  say "Margin $version is already installed and up to date"
  [[ "${MARGIN_NO_OPEN:-}" == 1 ]] || open "$APP"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "Downloading Margin $version"
curl -fL --progress-bar -o "$tmp/$zip_name" "$url" || die "the download failed. Try again."
[[ "$(stat -f %z "$tmp/$zip_name")" == "$size" ]] || die "the download isn't the size GitHub lists. Nothing was installed."
if [[ "$digest" == sha256:* ]]; then
  sum=$(shasum -a 256 "$tmp/$zip_name" | cut -d ' ' -f 1)
  [[ "sha256:$sum" == "$digest" ]] || die "the download's checksum doesn't match GitHub's. Nothing was installed."
fi

say "Checking it"
ditto -x -k "$tmp/$zip_name" "$tmp/unzipped" || die "the zip couldn't be opened. Nothing was installed."
new="$tmp/unzipped/Margin.app"
[[ -d "$new" ]] || die "the zip has no Margin.app. Nothing was installed."
[[ "$(defaults read "$new/Contents/Info.plist" CFBundleIdentifier 2>/dev/null)" == "$BUNDLE_ID" ]] \
  || die "the zip's app isn't Margin. Nothing was installed."
[[ "$(defaults read "$new/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)" == "$version" ]] \
  || die "the zip's app isn't version $version. Nothing was installed."
codesign --verify --deep --strict -R="$REQUIREMENT" "$new" 2>/dev/null \
  || die "the app isn't signed with Margin's certificate. Nothing was installed."

# Margin is asked to quit by the user rather than by an Apple event, which would raise an Automation prompt.
if pgrep -xq Margin; then
  say "Quit Margin from its menu bar icon (Quit Margin). Waiting…"
  for _ in $(seq 1 240); do pgrep -xq Margin || break; sleep 0.5; done
  pgrep -xq Margin && die "Margin is still running. Quit it, then run this again."
fi

if [[ -d "$APP" ]]; then
  old="$HOME/.Trash/Margin ${installed:-old}.app"
  [[ -e "$old" ]] && old="$HOME/.Trash/Margin ${installed:-old} $(date +%H.%M.%S).app"
  mv "$APP" "$old" || die "couldn't move the old Margin to the Trash. Nothing was installed."
fi
ditto "$new" "$APP" || die "couldn't copy Margin into $(dirname "$APP")."
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

if [[ -n "$installed" ]]; then
  say "Updated Margin $installed to $version"
else
  say "Installed Margin $version in $(dirname "$APP")"
fi
[[ "${MARGIN_NO_OPEN:-}" == 1 ]] || open "$APP"
