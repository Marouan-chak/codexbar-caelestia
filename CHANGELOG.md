# Changelog

All notable changes to this project will be documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **A failing provider no longer destroys its own cached snapshot.** The
  payload was cached wholesale, so the first refresh where a provider errored
  overwrote its last good data and the fallback had nothing to serve. The cache
  is now written per provider, keeping the last good entry for any that failed.
- **The popout no longer stretches off screen.** Its root is loaded by a
  `Loader`, not placed in a layout, so `Layout.preferredWidth` was ignored and
  a long unwrapped provider error set the width. The width is now pinned and
  error text wraps.
- The provider error was printed twice in the popout, as subtitle and body.

### Added
- Initial release. A `codexUsage` Caelestia bar entry drawing one
  `CircularProgress` ring per enabled CodexBar provider, with the provider's
  brand mark inside and its most-constrained window's percentage underneath.
- Hover popout listing every usage window a provider reports, with a live reset
  countdown derived from `resetsAt`, plus pace and credit lines when the CLI
  supplies them.
- `scripts/codexbar-usage.sh`, which talks to the `codexbar` CLI directly and
  normalises the result into the shape the QML consumes. Window labels follow
  window length rather than the field the window arrived in, so providers that
  report weekly in `primary` (Antigravity) label correctly.
- Provider handling the `codexbar` CLI does not do: `--source oauth` for Codex
  and Claude, Claude's OAuth -> CLI fallback on 429, the fetch stagger, and
  Antigravity's credential bridge and `cert_redirect.c` TLS shim. The shim
  builds lazily and degrades to a provider error when there is no C compiler,
  so only Antigravity users need one.
- `install.sh` refuses manual/CMake Caelestia installs, where the checkout and
  the overlay are one directory, instead of patching the user's clone in place.
- `patches/apply.py`, an idempotent anchored patcher for the two upstream files
  that have to be modified, recording package checksums so `./install.sh
  --check` can report `DRIFT`, `LOST`, `HOLE` and `DANGLE` after a Caelestia
  upgrade.
- `scripts/probe-entries.qml`, which re-derives Caelestia's default bar order
  from the installed config plugin without starting the shell.
- Live-reloaded settings at `~/.config/codexbar-caelestia/config.json`.
- `hideUnavailable` (default `true`): providers that error with no cached data
  are dropped from the bar instead of showing a permanently dashed ring.
