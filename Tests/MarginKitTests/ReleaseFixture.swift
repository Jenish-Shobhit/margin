import Foundation

/// GitHub's answer to `GET /repos/Jenish-Shobhit/margin/releases/latest` for v0.0.15 (17 Oct 2026), with every key
/// and its nesting as GitHub sent them; only the release notes are shortened.
let releaseFixtureJSON = #"""
{
  "url": "https://api.github.com/repos/Jenish-Shobhit/margin/releases/413404456",
  "assets_url": "https://api.github.com/repos/Jenish-Shobhit/margin/releases/413404456/assets",
  "upload_url": "https://uploads.github.com/repos/Jenish-Shobhit/margin/releases/413404456/assets{?name,label}",
  "html_url": "https://github.com/Jenish-Shobhit/margin/releases/tag/v0.0.15",
  "id": 413404456,
  "author": {
    "login": "Jenish-Shobhit",
    "id": 99080179,
    "node_id": "U_kgDOBefX8w",
    "avatar_url": "https://avatars.githubusercontent.com/u/99080179?v=4",
    "gravatar_id": "",
    "url": "https://api.github.com/users/Jenish-Shobhit",
    "html_url": "https://github.com/Jenish-Shobhit",
    "followers_url": "https://api.github.com/users/Jenish-Shobhit/followers",
    "following_url": "https://api.github.com/users/Jenish-Shobhit/following{/other_user}",
    "gists_url": "https://api.github.com/users/Jenish-Shobhit/gists{/gist_id}",
    "starred_url": "https://api.github.com/users/Jenish-Shobhit/starred{/owner}{/repo}",
    "subscriptions_url": "https://api.github.com/users/Jenish-Shobhit/subscriptions",
    "organizations_url": "https://api.github.com/users/Jenish-Shobhit/orgs",
    "repos_url": "https://api.github.com/users/Jenish-Shobhit/repos",
    "events_url": "https://api.github.com/users/Jenish-Shobhit/events{/privacy}",
    "received_events_url": "https://api.github.com/users/Jenish-Shobhit/received_events",
    "type": "User",
    "user_view_type": "public",
    "site_admin": false
  },
  "node_id": "RE_kwDOVJ03k84YpA0o",
  "tag_name": "v0.0.15",
  "target_commitish": "main",
  "name": "Margin 0.0.15",
  "draft": false,
  "immutable": false,
  "prerelease": false,
  "created_at": "2026-10-15T04:00:49Z",
  "updated_at": "2026-10-15T04:00:55Z",
  "published_at": "2026-10-15T04:00:55Z",
  "assets": [
    {
      "url": "https://api.github.com/repos/Jenish-Shobhit/margin/releases/assets/642603607",
      "id": 642603607,
      "node_id": "RA_kwDOVJ03k84mTVpX",
      "name": "Margin-0.0.15.zip",
      "label": "",
      "uploader": {
        "login": "Jenish-Shobhit",
        "id": 99080179,
        "node_id": "U_kgDOBefX8w",
        "avatar_url": "https://avatars.githubusercontent.com/u/99080179?v=4",
        "gravatar_id": "",
        "url": "https://api.github.com/users/Jenish-Shobhit",
        "html_url": "https://github.com/Jenish-Shobhit",
        "followers_url": "https://api.github.com/users/Jenish-Shobhit/followers",
        "following_url": "https://api.github.com/users/Jenish-Shobhit/following{/other_user}",
        "gists_url": "https://api.github.com/users/Jenish-Shobhit/gists{/gist_id}",
        "starred_url": "https://api.github.com/users/Jenish-Shobhit/starred{/owner}{/repo}",
        "subscriptions_url": "https://api.github.com/users/Jenish-Shobhit/subscriptions",
        "organizations_url": "https://api.github.com/users/Jenish-Shobhit/orgs",
        "repos_url": "https://api.github.com/users/Jenish-Shobhit/repos",
        "events_url": "https://api.github.com/users/Jenish-Shobhit/events{/privacy}",
        "received_events_url": "https://api.github.com/users/Jenish-Shobhit/received_events",
        "type": "User",
        "user_view_type": "public",
        "site_admin": false
      },
      "content_type": "application/zip",
      "state": "uploaded",
      "size": 1945999,
      "digest": "sha256:44b912c434e492dc22663146ae38838d47371f9b30b23d1f8ca591ad861bc226",
      "download_count": 0,
      "created_at": "2026-10-15T04:00:54Z",
      "updated_at": "2026-10-15T04:00:55Z",
      "browser_download_url": "https://github.com/Jenish-Shobhit/margin/releases/download/v0.0.15/Margin-0.0.15.zip"
    }
  ],
  "tarball_url": "https://api.github.com/repos/Jenish-Shobhit/margin/tarball/v0.0.15",
  "zipball_url": "https://api.github.com/repos/Jenish-Shobhit/margin/zipball/v0.0.15",
  "body": "## 0.0.15 — 2026-10-15\n\n### Fixed\n\n- Two copies of Margin could run at once (opened from two places, or with `open -n`): every shortcut saved each shot twice, and one of the two cards was gone after a restart. Opening Margin while it's running now shows Settings in the copy already running, and the new copy quits.\n- One unreadable entry in the shelf's saved list (`shelf.json`), or a list written by a newer version, emptied the whole shelf, and the next capture saved over it. Unreadable entries are now skipped, and the original file is kept as `shelf.json.bad`.\n\n## 0.0.14 — 2026-10-15\n\n### Changed\n\n- Esc and Space are caught from the very start of ⇧⌘4, and the capture screen appears about 3 ms sooner.\n\n### Install\n\nDownload `Margin-0.0.15.zip`, unzip, and move **Margin.app** to `/Applications`. Not notarized yet: on first open, go to **System Settings › Privacy & Security › Open Anyway**. Requires macOS 26+ on Apple silicon.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n"
}
"""#
