#!/usr/bin/env python3
"""Wire the CodexBar entry into Caelestia's packaged Bar.qml and Content.qml.

The packaged shell under /etc/xdg/quickshell/caelestia is never edited. The
user overlay at ~/.config/quickshell/caelestia mirrors it with symlinks; this
script replaces two of those symlinks with real, patched copies and records the
package files' checksums so `check` can tell you when an upgrade has moved the
ground under them.

Insertions are anchored on surrounding source rather than shipped as diffs, so
an unrelated upstream change nearby does not fail the install. Every step is
idempotent: running `install` twice is a no-op.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

STATE_NAME = "patch-state.json"

# --- The patches -----------------------------------------------------------
# Each entry: the file (relative to the shell root), a marker proving it is
# already applied, and a list of (anchor, insertion, position) edits where
# position is "before" or "after" the anchor.

BAR_DELEGATE = '''            DelegateChoice {
                roleValue: "codexUsage"
                delegate: EntryWrapper {
                    CodexUsage {
                        objectName: "taskbarCodexUsage"
                    }
                }
            }
'''

BAR_POPOUT_BRANCH = '''        } else if (id === "codexUsage") {
            const codex = ch.item as CodexUsage;
            const ring = codex.hoverAt(mapToItem(codex, 0, y).y);
            if (ring) {
                popouts.currentName = "codexusage";
                popouts.currentCenter = Qt.binding(() => ring.mapToItem(root, 0, ring.implicitHeight / 2).y);
                popouts.hasCurrent = true;
            } else {
                popouts.hasCurrent = false;
            }
'''

CONTENT_POPOUT = '''
        Popout {
            name: "codexusage"
            sourceComponent: CodexUsagePopout {}
        }
'''

PATCHES = {
    "modules/bar/Bar.qml": {
        "marker": "codexUsage",
        "edits": [
            ('            DelegateChoice {\n                roleValue: "power"\n', BAR_DELEGATE, "before"),
            ('        } else if (id === "activeWindow"', BAR_POPOUT_BRANCH, "before"),
        ],
    },
    "modules/bar/popouts/Content.qml": {
        "marker": "codexusage",
        "edits": [
            ('        Popout {\n            name: "lockstatus"\n            sourceComponent: LockStatus {}\n        }\n', CONTENT_POPOUT, "after"),
        ],
    },
}

# Files this project installs into the overlay, as (repo path, overlay path).
INSTALLED_QML = [
    ("qml/CodexUsageService.qml", "modules/bar/components/CodexUsageService.qml"),
    ("qml/CodexUsageRing.qml", "modules/bar/components/CodexUsageRing.qml"),
    ("qml/CodexUsage.qml", "modules/bar/components/CodexUsage.qml"),
    ("qml/CodexUsagePopout.qml", "modules/bar/popouts/CodexUsagePopout.qml"),
]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def explode(overlay: Path, package: Path, rel: str) -> None:
    """Turn an overlay directory symlink into a real directory of symlinks.

    Caelestia's overlay links whole directories (modules/bar -> /etc/xdg/...).
    To put a file inside one, the link has to become a directory whose entries
    each point back at the package. Existing real directories are left alone.
    """
    target = overlay / rel
    src = package / rel
    if target.is_symlink():
        target.unlink()
    elif target.is_dir():
        return
    target.mkdir(parents=True, exist_ok=True)
    for entry in sorted(src.iterdir()):
        link = target / entry.name
        if not link.exists() and not link.is_symlink():
            link.symlink_to(entry)


def patch_text(text: str, spec: dict, rel: str) -> str:
    for anchor, insertion, position in spec["edits"]:
        if anchor not in text:
            raise SystemExit(
                f"error: anchor not found in {rel}:\n  {anchor.splitlines()[0]!r}\n"
                "Upstream has changed this file. Re-check the patch against the "
                "packaged copy before installing."
            )
        if text.count(anchor) != 1:
            raise SystemExit(f"error: anchor is ambiguous in {rel} ({text.count(anchor)} matches)")
        text = (
            text.replace(anchor, insertion + anchor, 1)
            if position == "before"
            else text.replace(anchor, anchor + insertion, 1)
        )
    return text


def do_install(repo: Path, overlay: Path, package: Path, state_path: Path) -> int:
    for rel in ("modules", "modules/bar", "modules/bar/components", "modules/bar/popouts"):
        explode(overlay, package, rel)

    for repo_rel, overlay_rel in INSTALLED_QML:
        dest = overlay / overlay_rel
        source = repo / repo_rel
        if dest.is_symlink() or dest.exists():
            dest.unlink()
        dest.symlink_to(source)
        print(f"  link  {overlay_rel} -> {source}")

    state = {"package": str(package), "files": {}}
    for rel, spec in PATCHES.items():
        pkg_file = package / rel
        dest = overlay / rel
        original = pkg_file.read_text()
        if spec["marker"] in original:
            raise SystemExit(f"error: upstream {rel} already contains {spec['marker']!r}")

        if dest.is_symlink():
            dest.unlink()
        elif dest.exists() and spec["marker"] in dest.read_text():
            # Already patched: rebuild from the package so repeated installs
            # never stack insertions on top of each other.
            dest.unlink()

        dest.write_text(patch_text(original, spec, rel))
        state["files"][rel] = {"packageSha256": sha256(pkg_file)}
        print(f"  patch {rel}")

    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(json.dumps(state, indent=2) + "\n")
    print(f"  state {state_path}")
    return 0


def do_check(overlay: Path, package: Path, state_path: Path) -> int:
    if not state_path.exists():
        print("not installed (no patch state)")
        return 1

    state = json.loads(state_path.read_text())
    problems = 0

    for rel, spec in PATCHES.items():
        dest = overlay / rel
        recorded = state["files"].get(rel, {}).get("packageSha256")
        current = sha256(package / rel)
        if recorded != current:
            print(f"DRIFT  {rel}: upstream changed since the patch was applied")
            print(f"       recorded {recorded[:12]}… now {current[:12]}…")
            problems += 1
        elif not dest.exists() or spec["marker"] not in dest.read_text():
            print(f"LOST   {rel}: overlay copy is missing the patch")
            problems += 1
        else:
            print(f"ok     {rel}")

    for _, overlay_rel in INSTALLED_QML:
        dest = overlay / overlay_rel
        if not dest.exists():
            print(f"LOST   {overlay_rel}: missing")
            problems += 1
        else:
            print(f"ok     {overlay_rel}")

    # A dangling link is how a Caelestia upgrade that *removes* a file shows up.
    for dangling in sorted(p for p in overlay.rglob("*") if p.is_symlink() and not p.exists()):
        print(f"DANGLE {dangling.relative_to(overlay)}: points at a file the package no longer ships")
        problems += 1

    # A file the package ships that the overlay cannot resolve is how an
    # upgrade that *adds* a file shows up. Directory symlinks resolve through,
    # so only exploded directories can develop these holes.
    for pkg_file in sorted(package.rglob("*")):
        if not pkg_file.is_file():
            continue
        rel = pkg_file.relative_to(package)
        if not (overlay / rel).exists():
            print(f"HOLE   {rel}: shipped by the package, not reachable in the overlay")
            problems += 1

    return 1 if problems else 0


def collapse(overlay: Path, package: Path, rel: str) -> bool:
    """Undo `explode`: a directory of plain package symlinks becomes one symlink.

    Only collapses when every entry is a symlink pointing at the matching
    package entry, so a directory holding any customisation of the user's own
    (modules/dashboard, typically) is left exactly as it is.
    """
    target = overlay / rel
    src = package / rel
    if target.is_symlink() or not target.is_dir() or not src.is_dir():
        return False

    expected = {e.name for e in src.iterdir()}
    if {e.name for e in target.iterdir()} != expected:
        return False
    for entry in target.iterdir():
        if not entry.is_symlink() or entry.resolve() != (src / entry.name).resolve():
            return False

    for entry in list(target.iterdir()):
        entry.unlink()
    target.rmdir()
    target.symlink_to(src)
    return True


def do_uninstall(overlay: Path, package: Path, state_path: Path) -> int:
    for _, overlay_rel in INSTALLED_QML:
        dest = overlay / overlay_rel
        if dest.is_symlink() or dest.exists():
            dest.unlink()
            print(f"  remove {overlay_rel}")

    for rel in PATCHES:
        dest = overlay / rel
        if dest.exists() and not dest.is_symlink():
            dest.unlink()
        if not dest.exists():
            dest.symlink_to(package / rel)
            print(f"  restore {rel} -> package")

    # Deepest first, so an inner directory can collapse before its parent is
    # tested. Anything the user customised themselves blocks its own collapse.
    for rel in ("modules/bar/components", "modules/bar/popouts", "modules/bar", "modules"):
        if collapse(overlay, package, rel):
            print(f"  collapse {rel} -> package symlink")

    if state_path.exists():
        state_path.unlink()
        print(f"  remove {state_path}")
    return 0


def main() -> int:
    default_overlay = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "quickshell/caelestia"
    default_state = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "codexbar-caelestia" / STATE_NAME

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=("install", "check", "uninstall"))
    parser.add_argument("--overlay", type=Path, default=default_overlay)
    parser.add_argument("--package", type=Path, default=Path("/etc/xdg/quickshell/caelestia"))
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--state", type=Path, default=default_state)
    args = parser.parse_args()

    if not args.package.is_dir():
        raise SystemExit(f"error: packaged Caelestia not found at {args.package}")

    # A manual/CMake Caelestia install clones straight into
    # $XDG_CONFIG_HOME/quickshell/caelestia, so overlay and package are one
    # directory. Patching in place would edit the user's own checkout, could
    # never be re-run, and `uninstall` would leave a self-referential symlink.
    if args.overlay.resolve() == args.package.resolve():
        raise SystemExit(
            "error: the overlay and the package are the same directory:\n"
            f"  {args.overlay.resolve()}\n"
            "That is a manual (non-package) Caelestia install. This project needs the\n"
            "packaged layout, where /etc/xdg/quickshell/caelestia holds the shell and\n"
            "~/.config/quickshell/caelestia is a separate overlay. See the README\n"
            "section \"Supported installs\"."
        )
    args.overlay.mkdir(parents=True, exist_ok=True)

    if args.action == "install":
        return do_install(args.repo, args.overlay, args.package, args.state)
    if args.action == "check":
        return do_check(args.overlay, args.package, args.state)
    return do_uninstall(args.overlay, args.package, args.state)


if __name__ == "__main__":
    sys.exit(main())
