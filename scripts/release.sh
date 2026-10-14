#!/bin/bash
# Publishes a Margin release from a clean main.
#
#   scripts/release.sh <version>      e.g. scripts/release.sh 0.0.2
#
# Expects a `## <version> — <date>` section at the top of CHANGELOG.md (written by hand). Then it:
# bumps CFBundleShortVersionString and CFBundleVersion, builds, installs and zips the signed release app,
# commits, tags v<version>, pushes main and the tag, and creates the GitHub release with the zip.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
PLIST=Resources/Info.plist

[[ "$(git branch --show-current)" == main ]] || { echo "error: not on main" >&2; exit 1; }
git diff --quiet -- . ':!CHANGELOG.md' && git diff --cached --quiet || { echo "error: uncommitted changes besides CHANGELOG.md" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && { echo "error: tag v$VERSION exists" >&2; exit 1; }
NOTES=$(awk -v v="$VERSION" '$0 ~ "^## "v" " {on=1; next} /^## / && on {exit} on' CHANGELOG.md)
[[ -n "${NOTES//[[:space:]]/}" ]] || { echo "error: no '## $VERSION — <date>' section in CHANGELOG.md" >&2; exit 1; }

BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"

scripts/test.sh >/dev/null
scripts/build.sh --install --run --zip
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
