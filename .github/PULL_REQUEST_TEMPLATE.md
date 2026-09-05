## What this changes

<!-- One or two sentences. Link the issue if there is one. -->

## Why

<!-- The problem it solves. -->

## Checklist

- [ ] `python3 -m unittest discover -s tests` passes
- [ ] `shellcheck -x install.sh scripts/codexbar-usage.sh` is clean
- [ ] `qmllint qml/*.qml` reports no errors
- [ ] If an anchor in `patches/apply.py` changed, the fixture in `tests/test_patcher.py` was updated to match
- [ ] Nothing writes to the packaged shell under `/etc/xdg/quickshell/caelestia`
- [ ] `./install.sh --uninstall` still leaves the overlay as it found it
- [ ] CHANGELOG.md updated under `## [Unreleased]`

## Tested on

<!-- caelestia-shell / quickshell / qt6-base versions, and how Caelestia is installed. -->
