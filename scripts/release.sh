#!/bin/bash
# Publishes a Margin release from a clean main.
#
#   scripts/release.sh <version> [--no-install]      e.g. scripts/release.sh 0.0.2
#
# --no-install publishes without replacing /Applications/Margin.app, so the copy there can be updated to the
# new release the way users get it (Check for Updates…).
#
# Expects a `## <version> — <date>` section at the top of CHANGELOG.md (written by hand). Then it:
# bumps CFBundleShortVersionString and CFBundleVersion, builds, installs and zips the signed release app,
# commits, tags v<version>, pushes main and the tag, and creates the GitHub release with the zip. The release
# notes are every CHANGELOG section since the last tagged release, so versions never published get listed too.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [--no-install]}"
INSTALL_ARGS=(--install --run)
case "${2:-}" in
  "") ;;
  --no-install) INSTALL_ARGS=() ;;
  *) echo "usage: scripts/release.sh <version> [--no-install]" >&2; exit 1 ;;
esac
PLIST=Resources/Info.plist

[[ "$(git branch --show-current)" == main ]] || { echo "error: not on main" >&2; exit 1; }
git diff --quiet -- . ':!CHANGELOG.md' && git diff --cached --quiet || { echo "error: uncommitted changes besides CHANGELOG.md" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && { echo "error: tag v$VERSION exists" >&2; exit 1; }
grep -q "^## $VERSION " CHANGELOG.md || { echo "error: no '## $VERSION — <date>' section in CHANGELOG.md" >&2; exit 1; }
# Without it build.sh signs ad hoc, and every installed copy would refuse the release as an update (spec §14.3).
security find-identity -p codesigning 2>/dev/null | grep -q '"Margin Dev"' \
  || { echo "error: no \"Margin Dev\" signing identity in the keychain" >&2; exit 1; }
LAST=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
# From this version's section down to the last released one (or to the end with no earlier tag).
NOTES=$(awk -v v="$VERSION" -v last="${LAST#v}" '
  $0 ~ "^## "v" " {on=1}
  on && last != "" && $0 ~ "^## "last" " {exit}
  on' CHANGELOG.md)
# With only this version unreleased, its own heading is left out, as before.
if [[ "$(grep -c '^## ' <<<"$NOTES")" == 1 ]]; then NOTES=$(sed '1d' <<<"$NOTES"); fi
[[ -n "${NOTES//[[:space:]]/}" ]] || { echo "error: the $VERSION section in CHANGELOG.md is empty" >&2; exit 1; }

BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"

scripts/test.sh >/dev/null
scripts/build.sh ${INSTALL_ARGS[@]+"${INSTALL_ARGS[@]}"} --zip
ZIP="dist/Margin-$VERSION.zip"
[[ -f "$ZIP" ]] || { echo "error: $ZIP missing" >&2; exit 1; }

git add "$PLIST" CHANGELOG.md
git commit -q -m "chore(release): $VERSION

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
git tag -a "v$VERSION" -m "Margin $VERSION"
git push -q origin main "v$VERSION"

NOTES_FILE=$(mktemp)
{
  printf '%s\n\n' "$NOTES"
  printf '### Install\n\nDownload `Margin-%s.zip`, unzip, and move **Margin.app** to `/Applications`. Not notarized yet: on first open, go to **System Settings › Privacy & Security › Open Anyway**. Requires macOS 26+ on Apple silicon.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n' "$VERSION"
} > "$NOTES_FILE"
gh release create "v$VERSION" "$ZIP" --title "Margin $VERSION" --notes-file "$NOTES_FILE"
rm -f "$NOTES_FILE"
echo "==> Released $VERSION (build $BUILD)"
