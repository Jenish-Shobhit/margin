# Margin

A better macOS screenshot app: capture → instant save to `~/Desktop/Screenshots` and copy to clipboard → thumbnail stacks on a right-edge shelf → stays until dragged into another app.

- **Build spec: `spec.md` (source of truth).** Visual reference: `dev_artifacts/ideation_v2.1.html` (local only).
- Stack: Swift 6, AppKit + SwiftUI, ScreenCaptureKit, SwiftPM, no third-party dependencies. Menu bar app. Command Line Tools only (no Xcode): use Swift Testing, not XCTest.
- Build and install with `scripts/build.sh --install --run`; always run from `/Applications/Margin.app` so Screen Recording permission persists.
- Build: `swift build --build-system native` (the default build system needs Xcode). Test: `scripts/test.sh` (adds the CLT Testing.framework paths).
- Commit often (Conventional Commits); every commit builds and passes `scripts/test.sh`.
- Ideation/design docs go in `dev_artifacts/` (gitignored), written as HTML.
- Keep project notes here in the repo, never in global `~/.claude`.
- Scope: keep it a focused screenshot tool; no agent/platform features unless asked.
