# Contributing

Thanks for looking. This is a small project with a narrow job, so the most
useful contributions are usually bug reports with enough detail to reproduce.

## Reporting a bug

Please include:

- Your `caelestia-shell`, `quickshell` and `qt6-base` versions
  (`pacman -Q caelestia-shell quickshell-git qt6-base`, or your distro's
  equivalent).
- How Caelestia is installed — distro package, or manual clone. Only the
  packaged layout is supported; see *Supported installs* in the README.
- The output of `./install.sh --check`.
- The backend's own output, which is where most problems show up:

  ```bash
  ~/.local/share/codexbar-caelestia/codexbar-usage.sh | jq
  ```

- Anything the shell logged: `caelestia shell -l | grep -i codex`. Note that
  this log is cumulative, so check timestamps before assuming a line is fresh.

**Redact before pasting.** The backend output contains your plan names and
usage figures. It does not contain tokens, but check anyway.

Problems with the `codexbar` CLI itself — a provider erroring, a payload
changing shape — belong upstream at
[steipete/CodexBar](https://github.com/steipete/CodexBar). If the CLI works but
this bar does not, it is ours.

## Development

The four QML files are symlinked from your clone into the Caelestia overlay, so
edits hot-reload — no restart needed. Editing `Bar.qml` or `Content.qml`
requires re-running `./install.sh`, since those are patched copies.

```bash
python3 -m unittest discover -s tests -v
shellcheck -x install.sh scripts/codexbar-usage.sh
qmllint qml/*.qml
```

Tests stub the `codexbar` CLI, so they run offline and never touch a real
credential. Please keep it that way.

### Working on the patches

`patches/apply.py` inserts into two upstream files using anchored text rather
than diffs, so an unrelated upstream change nearby does not break the install.
If you change an anchor, update the fixture in `tests/test_patcher.py` to
match — those fixtures deliberately carry only the anchor lines so they fail
loudly when the two drift apart.

Never write to the packaged shell. Everything goes into the user's overlay, and
`install.sh --uninstall` has to leave the overlay exactly as it found it.

### Working on the backend

`scripts/codexbar-usage.sh` owns everything between the CLI and the QML. Parts
of it — the source overrides, Claude's fallback, and the Antigravity credential
bridge and TLS shim — are shared verbatim with
[codexbar-waybar](https://github.com/Marouan-chak/codexbar-waybar), so a fix to
those, especially `cert_redirect.c`, probably belongs in both repos. The two
copies are kept byte-identical apart from a comment banner.

## Adding a provider

You usually do not need to. Providers come from the CLI, and unknown ids fall
back to a capitalised id and a generic Material icon. To add a nicer name, add
it to the `provider_name` map in `scripts/codexbar-usage.sh`. For a logo, drop
`ProviderIcon-<id>.svg` into `assets/providers/` — but only if upstream CodexBar
ships it, so the `NOTICE` attribution stays accurate.

## Style

Match what is there. Shell is bash with `set -u` and passes `shellcheck -x`.
QML follows Caelestia's own conventions — `pragma ComponentBehavior: Bound`,
`Tokens` for sizing, `Colours.palette` for colour, no hardcoded pixel values
where a token exists. Comments explain *why*, not what.

## License

Contributions are accepted under the [MIT License](LICENSE).
