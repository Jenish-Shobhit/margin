## What and why

<!-- What does this change, and why? Link the issue (Fixes #123). -->

## User-visible changes

<!-- What someone using Margin will notice. "None" is fine. The maintainer turns this into the CHANGELOG entry. -->

## How it was tested

<!-- macOS version, displays, and the steps or QA items you ran. -->

## Checklist

- [ ] `swift build --build-system native` builds with no new warnings
- [ ] `scripts/test.sh` passes; `MarginKit` changes have tests
- [ ] The [QA](https://github.com/Jenish-Shobhit/margin/blob/main/docs/QA.md) items this touches pass on an installed build (`scripts/build.sh --install --run`):
  <!-- list them, e.g. "Shelf interactions: drag-out, ⌥ keeps the card" -->
- [ ] New behaviour has new QA items; `README.md` and `docs/` are updated if users will notice
- [ ] Commits follow [Conventional Commits](https://www.conventionalcommits.org), and each one builds and passes the tests
- [ ] Stays in scope: a focused screenshot tool, no new dependencies, no network access
