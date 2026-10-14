# Contributing to Margin

Thanks for helping. Margin is small on purpose. This page explains what fits, how to build and test it, and what a good pull request looks like.

## Scope: a focused screenshot tool

Margin does one thing: capture the screen, save and copy the shot, and keep it on the shelf until you drag it somewhere. Changes that make that faster, more reliable, clearer or more accessible are welcome.

These are out of scope unless the maintainer asks for them:

- annotation, blur, OCR or QR, pinning shots to the screen, timers, a capture history;
- scrolling capture, screen recording or GIFs, file-name templates;
- a general-purpose file shelf (dropping other files onto it);
- cloud uploads, accounts, AI or agent features, anything that talks to the network;
- Intel builds, auto-update.

Margin also has no third-party dependencies, and none should be added.

**For anything bigger than a bug fix, open an issue first,** so we can agree it fits before you spend time on it. [`spec.md`](spec.md) is the product's source of truth. If your change alters behaviour it describes, say so in the PR.

## Setting up

You need macOS 26 or later on Apple silicon, and the Xcode Command Line Tools (Swift 6.2 or later). Xcode isn't needed.

```sh
git clone https://github.com/Jenish-Shobhit/margin.git
cd margin
scripts/build.sh --install --run
```

[docs/building.md](docs/building.md) has the details:

- the self-signed **Margin Dev** certificate, so Screen Recording permission survives rebuilds;
- why every build uses `--build-system native`;
- the debug hook.

[docs/architecture.md](docs/architecture.md) explains how the code fits together.

Run the copy in `/Applications`, as `build.sh --install` does. Screen Recording permission and launch at login depend on it.

## Code style

- **Match the surrounding code:** its naming, structure and the way its doc comments explain *why*. When in doubt, read the neighbouring file.
- **Swift 6 language mode with strict concurrency:**
  - UI code is `@MainActor`.
  - Capture, encoding and disk access run off the main thread.
  - The main thread never touches the save folder, because the Desktop privacy prompt can block it ([threading rules](docs/architecture.md#threading-rules)).
- **Pure logic goes in `MarginKit`, with tests.** The app target (`Sources/Margin/`) holds windows, views and system integration.
- **`Sources/Margin/App/Contracts.swift`** defines the seams between capture, the shelf and the coordinator. Change it deliberately, and update both sides.
- **No network code, no analytics.** Never write system settings except on an explicit user action, as **Turn off for me** does.
- Keep the UI text short and plain. Write shortcuts in the macOS order ⌃⌥⇧⌘, as in "⇧⌘4".

## Tests

```sh
scripts/test.sh
```

- Tests use **Swift Testing** (`import Testing`), not XCTest, and live in `Tests/MarginKitTests/`.
- Use `scripts/test.sh` rather than plain `swift test`: it adds the Command Line Tools path for `Testing.framework`. Extra arguments are passed through, for example `scripts/test.sh --filter ShelfLayout`.
- Tests must not touch real system state. Use temporary folders (`TempDir`), a throwaway `UserDefaults(suiteName:)`, and fake executables in place of system tools.

Behaviour in the app target is checked by hand with [docs/QA.md](docs/QA.md). Run the items your change touches, and add items for new behaviour. A debug build with `scripts/debug.sh` lets you capture and inspect state without a mouse.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org):

```text
feat(shelf): red dismiss button top-right, options button top-left
fix(clipboard): ⌘V in terminals pastes the screenshot's path
docs: …
```

- **Types:** `feat`, `fix`, `perf`, `refactor`, `test`, `docs` and `chore`.
- **Scopes** name the area, for example `overlay`, `shelf`, `capture`, `clipboard`, `settings`, `onboarding`, `menubar`, `hotkeys`, `app`.
- Keep each commit to one logical change, and make sure every commit builds and passes `scripts/test.sh`.
- Use the body to explain why, when that isn't obvious.
- Never commit `.build/`, `dist/`, `dev_artifacts/`, `*.app`, `*.zip`, certificates or keys.

## Pull requests

Keep PRs small and focused. The [PR template](.github/pull_request_template.md) asks for this checklist:

- [ ] `swift build --build-system native` builds with no new warnings
- [ ] `scripts/test.sh` passes, with tests added or updated for `MarginKit` changes
- [ ] The [QA](docs/QA.md) items this touches pass on an installed build (list them), and new behaviour has new items
- [ ] User-visible changes are reflected in `README.md` and `docs/`
- [ ] It stays within scope: no new dependencies, no network access

Describe user-visible changes in the PR. The maintainer writes the `CHANGELOG.md` entry when releasing, so don't bump versions.

## Releases

Releases are cut by the maintainer from `main`. Each user-visible change usually ships as its own patch release (0.0.x):

1. Add a `## <version> — <date>` section to `CHANGELOG.md`, with Added, Changed and Fixed.
2. Run `scripts/release.sh <version>`.

The script bumps the version in `Resources/Info.plist` and runs the tests. It then builds, signs, installs and zips the app, commits `chore(release): <version>`, tags `v<version>`, pushes, and publishes a GitHub release with the zip. See [docs/building.md](docs/building.md#releasing).

## Reporting bugs and security issues

- **Bugs:** use the [bug report form](https://github.com/Jenish-Shobhit/margin/issues/new?template=bug_report.yml). Check [Troubleshooting](docs/troubleshooting.md) first.
- **Security vulnerabilities:** don't open a public issue. Report privately as described in [SECURITY.md](SECURITY.md).

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).

By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
