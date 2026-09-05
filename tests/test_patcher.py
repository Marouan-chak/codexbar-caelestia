"""Tests for patches/apply.py against a synthetic Caelestia tree.

The fixtures below carry only the anchor lines the patcher targets, so these
tests fail loudly if an anchor is changed without the fixture following it.
"""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
APPLY = REPO / "patches" / "apply.py"

BAR_QML = '''ColumnLayout {
    function checkPopout(y: real): void {
        if (id === "statusIcons") {
            popouts.hasCurrent = true;
        } else if (id === "activeWindow" && Config.bar.popouts.activeWindow && Config.bar.activeWindow.showOnHover) {
            popouts.hasCurrent = true;
        }
    }

    Repeater {
        DelegateChooser {
            DelegateChoice {
                roleValue: "statusIcons"
                delegate: EntryWrapper {
                    StatusIcons {
                        objectName: "taskbarStatusIcons"
                    }
                }
            }
            DelegateChoice {
                roleValue: "power"
                delegate: EntryWrapper {
                    Power {
                        objectName: "taskbarPowerButton"
                    }
                }
            }
        }
    }
}
'''

CONTENT_QML = '''Item {
    Item {
        Popout {
            name: "battery"
            sourceComponent: Battery {}
        }

        Popout {
            name: "lockstatus"
            sourceComponent: LockStatus {}
        }

        Repeater {}
    }
}
'''


def build_tree(tmp: Path):
    """A package tree plus an overlay of whole-directory symlinks, as shipped."""
    package = tmp / "package"
    (package / "modules/bar/components").mkdir(parents=True)
    (package / "modules/bar/popouts").mkdir(parents=True)
    (package / "services").mkdir(parents=True)
    (package / "modules/bar/Bar.qml").write_text(BAR_QML)
    (package / "modules/bar/popouts/Content.qml").write_text(CONTENT_QML)
    (package / "modules/bar/components/Clock.qml").write_text("Item {}\n")
    (package / "services/Audio.qml").write_text("Item {}\n")

    overlay = tmp / "overlay"
    overlay.mkdir()
    for entry in package.iterdir():
        (overlay / entry.name).symlink_to(entry)
    return package, overlay


def apply(action, package, overlay, state):
    return subprocess.run(
        [sys.executable, str(APPLY), action, "--overlay", str(overlay),
         "--package", str(package), "--repo", str(REPO), "--state", str(state)],
        capture_output=True, text=True, timeout=60,
    )


class PatcherTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        tmp = Path(self._tmp.name)
        self.package, self.overlay = build_tree(tmp)
        self.state = tmp / "state.json"

    def tearDown(self):
        self._tmp.cleanup()

    def test_install_patches_both_files_and_links_the_qml(self):
        proc = apply("install", self.package, self.overlay, self.state)
        self.assertEqual(proc.returncode, 0, proc.stderr)

        bar = (self.overlay / "modules/bar/Bar.qml").read_text()
        self.assertIn('roleValue: "codexUsage"', bar)
        self.assertIn('} else if (id === "codexUsage") {', bar)
        # Inserted before the power delegate, so the entry can sit mid-bar.
        self.assertLess(bar.index('roleValue: "codexUsage"'), bar.index('roleValue: "power"'))

        content = (self.overlay / "modules/bar/popouts/Content.qml").read_text()
        self.assertIn('name: "codexusage"', content)

        for name in ("CodexUsage.qml", "CodexUsageRing.qml", "CodexUsageService.qml"):
            link = self.overlay / "modules/bar/components" / name
            self.assertTrue(link.is_symlink(), name)
            self.assertTrue(link.exists(), f"{name} dangles")

    def test_package_is_never_written_to(self):
        before = (self.package / "modules/bar/Bar.qml").read_text()
        apply("install", self.package, self.overlay, self.state)
        self.assertEqual((self.package / "modules/bar/Bar.qml").read_text(), before)

    def test_exploded_dirs_still_expose_untouched_package_files(self):
        apply("install", self.package, self.overlay, self.state)
        # modules/bar became a real directory; its other entries must still
        # resolve back into the package.
        self.assertTrue((self.overlay / "modules/bar/components/Clock.qml").exists())
        # Whole directories we never touched stay plain symlinks.
        self.assertTrue((self.overlay / "services").is_symlink())

    def test_install_is_idempotent(self):
        apply("install", self.package, self.overlay, self.state)
        first = (self.overlay / "modules/bar/Bar.qml").read_text()
        proc = apply("install", self.package, self.overlay, self.state)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual((self.overlay / "modules/bar/Bar.qml").read_text(), first)
        self.assertEqual(first.count('roleValue: "codexUsage"'), 1)

    def test_check_passes_after_install(self):
        apply("install", self.package, self.overlay, self.state)
        proc = apply("check", self.package, self.overlay, self.state)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_check_reports_an_upstream_change(self):
        apply("install", self.package, self.overlay, self.state)
        (self.package / "modules/bar/Bar.qml").write_text(BAR_QML + "// upstream moved on\n")
        proc = apply("check", self.package, self.overlay, self.state)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("DRIFT", proc.stdout)

    def test_check_reports_a_file_the_upgrade_added(self):
        apply("install", self.package, self.overlay, self.state)
        (self.package / "modules/bar/components/New.qml").write_text("Item {}\n")
        proc = apply("check", self.package, self.overlay, self.state)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("HOLE", proc.stdout)

    def test_check_reports_a_file_the_upgrade_removed(self):
        apply("install", self.package, self.overlay, self.state)
        (self.package / "modules/bar/components/Clock.qml").unlink()
        proc = apply("check", self.package, self.overlay, self.state)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("DANGLE", proc.stdout)

    def test_refuses_a_manual_clone_layout_without_touching_it(self):
        # Manual/CMake Caelestia installs clone straight into the config dir,
        # so overlay and package are one directory and there is no pristine
        # copy to rebuild patched files from.
        before = (self.package / "modules/bar/Bar.qml").read_text()
        proc = apply("install", self.package, self.package, self.state)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("same directory", proc.stderr)
        self.assertEqual((self.package / "modules/bar/Bar.qml").read_text(), before)
        self.assertFalse(self.state.exists())

    def test_missing_anchor_fails_loudly_instead_of_silently(self):
        (self.package / "modules/bar/Bar.qml").write_text("ColumnLayout {}\n")
        proc = apply("install", self.package, self.overlay, self.state)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("anchor not found", proc.stderr)

    def test_uninstall_restores_plain_symlinks(self):
        apply("install", self.package, self.overlay, self.state)
        proc = apply("uninstall", self.package, self.overlay, self.state)
        self.assertEqual(proc.returncode, 0, proc.stderr)

        bar = self.overlay / "modules/bar/Bar.qml"
        # Resolves back into the package (directly, or through a collapsed
        # parent link) and carries none of our insertions.
        self.assertEqual(bar.resolve(), (self.package / "modules/bar/Bar.qml").resolve())
        self.assertNotIn("codexUsage", bar.read_text())
        self.assertFalse((self.overlay / "modules/bar/components/CodexUsage.qml").exists())
        self.assertFalse(self.state.exists())

    def test_uninstall_collapses_exploded_dirs_back_to_symlinks(self):
        apply("install", self.package, self.overlay, self.state)
        self.assertFalse((self.overlay / "modules/bar").is_symlink())
        apply("uninstall", self.package, self.overlay, self.state)
        # Back to the shipped shape, so a later upgrade that adds a file under
        # modules/bar is visible through the link rather than becoming a HOLE.
        self.assertTrue((self.overlay / "modules").is_symlink())
        self.assertTrue((self.overlay / "modules/bar/Bar.qml").exists())
        self.assertNotIn("codexUsage", (self.overlay / "modules/bar/Bar.qml").read_text())

    def test_uninstall_leaves_user_customised_dirs_exploded(self):
        # A file of the user's own in an exploded dir must block its collapse.
        apply("install", self.package, self.overlay, self.state)
        (self.overlay / "modules/bar/components/MyThing.qml").write_text("Item {}\n")
        apply("uninstall", self.package, self.overlay, self.state)
        self.assertFalse((self.overlay / "modules/bar/components").is_symlink())
        self.assertTrue((self.overlay / "modules/bar/components/MyThing.qml").exists())

    def test_state_records_the_package_checksums(self):
        apply("install", self.package, self.overlay, self.state)
        state = json.loads(self.state.read_text())
        self.assertIn("modules/bar/Bar.qml", state["files"])
        self.assertEqual(len(state["files"]["modules/bar/Bar.qml"]["packageSha256"]), 64)


if __name__ == "__main__":
    unittest.main()
