"""End-to-end tests for scripts/codexbar-usage.sh.

The `codexbar` CLI is replaced with a stub that dispatches on `--provider`, so
these run offline and never touch a real credential.
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "codexbar-usage.sh"

# Trimmed from real CLI responses: one provider whose primary window is the
# weekly one (Antigravity does this), one conventional provider, and one that
# fails outright.
RESPONSES = {
    "antigravity": [
        {
            "provider": "antigravity",
            "source": "app",
            "usage": {
                "plan": "Google AI Pro",
                "primary": {"usedPercent": 1.1, "windowMinutes": 10080, "resetsAt": "2026-09-10T19:30:55Z"},
                "secondary": {"usedPercent": 0, "windowMinutes": 300},
                "extraRateWindows": [
                    {"id": "x", "title": "Gemini 5-hour", "window": {"usedPercent": 2, "windowMinutes": 300}}
                ],
            },
        }
    ],
    "claude": [
        {
            "provider": "claude",
            "source": "oauth",
            "usage": {
                "plan": "Claude Enterprise",
                "primary": {"usedPercent": 73, "windowMinutes": 300, "resetDescription": "Sep 6 at 12:39AM"},
                "secondary": {"usedPercent": 7, "windowMinutes": 10080},
            },
            "pace": {"secondary": {"summary": "On track"}},
            "credits": {"remaining": 12},
        }
    ],
    "codex": [{"provider": "codex", "error": {"message": "HTTP 429"}}],
}

# What the CLI returns once every live Antigravity source has failed: no error,
# just a non-quota row. Trimmed from a real 0.70.0 response.
ANTIGRAVITY_OFFLINE = [
    {
        "provider": "antigravity",
        "source": "offline",
        "diagnostic": "Live Antigravity usage is unavailable; showing offline data.",
        "usage": {
            "loginMethod": "offline",
            "extraRateWindows": [
                {
                    "id": "antigravity-offline-conversations",
                    "title": "Offline · 11 conversations",
                    "usageKnown": False,
                    "window": {"usedPercent": 0},
                }
            ],
        },
    }
]

STUB = r"""#!/usr/bin/env bash
# Stand-in for the codexbar CLI: answers `usage --provider <p>` from a fixture.
provider=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --provider) provider="$2"; shift 2 ;;
        *) shift ;;
    esac
done
f="$FIXTURE_DIR/$provider.json"
if [[ -f "$f" ]]; then
    cat "$f"
else
    printf '%s' "$FALLBACK_OUTPUT"
fi
"""


def run(responses=None, *, fallback="", providers="antigravity claude codex", env_extra=None):
    """Run the normaliser against a stubbed CLI."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        fixtures = tmp / "fixtures"
        fixtures.mkdir()
        for provider, body in (responses or {}).items():
            (fixtures / f"{provider}.json").write_text(json.dumps(body))

        stub = tmp / "codexbar"
        stub.write_text(STUB)
        stub.chmod(0o755)

        env = dict(os.environ)
        env.update(
            {
                "CODEXBAR_BIN": str(stub),
                "CODEXBAR_PROVIDERS": providers,
                "CODEXBAR_STAGGER": "0",
                "FIXTURE_DIR": str(fixtures),
                "FALLBACK_OUTPUT": fallback,
                "XDG_CACHE_HOME": str(tmp / "cache"),
                "XDG_CONFIG_HOME": str(tmp / "config"),
            }
        )
        env.update(env_extra or {})
        proc = subprocess.run(
            ["bash", str(SCRIPT)], capture_output=True, text=True, env=env, timeout=60
        )
        return proc, json.loads(proc.stdout)


@unittest.skipUnless(shutil.which("jq"), "jq is required")
class NormaliseTest(unittest.TestCase):
    def setUp(self):
        _, self.out = run(RESPONSES)
        self.by_id = {p["id"]: p for p in self.out["providers"]}

    def test_reports_available_and_all_providers(self):
        self.assertTrue(self.out["available"])
        self.assertEqual(set(self.by_id), {"antigravity", "claude", "codex"})

    def test_window_labels_come_from_length_not_slot(self):
        # Antigravity puts its weekly window in `primary`; the label has to
        # follow windowMinutes, not the field it arrived in.
        labels = [w["label"] for w in self.by_id["antigravity"]["windows"]]
        self.assertEqual(labels[:2], ["Weekly", "Current session"])

    def test_claude_weekly_uses_upstream_wording(self):
        labels = [w["label"] for w in self.by_id["claude"]["windows"]]
        self.assertEqual(labels, ["Current session", "All models"])

    def test_extra_windows_keep_their_titles(self):
        labels = [w["label"] for w in self.by_id["antigravity"]["windows"]]
        self.assertIn("Gemini 5-hour", labels)

    def test_max_percent_ignores_extra_windows(self):
        self.assertAlmostEqual(self.by_id["antigravity"]["maxPercent"], 1.1)
        self.assertEqual(self.by_id["claude"]["maxPercent"], 73)

    def test_pace_and_credits_are_carried_through(self):
        self.assertEqual(self.by_id["claude"]["pace"], "On track")
        self.assertEqual(self.by_id["claude"]["credits"], 12)

    def test_errored_provider_survives_with_its_message(self):
        codex = self.by_id["codex"]
        self.assertEqual(codex["error"], "HTTP 429")
        self.assertEqual(codex["windows"], [])
        self.assertIsNone(codex["maxPercent"])


@unittest.skipUnless(shutil.which("jq"), "jq is required")
class SourceSelectionTest(unittest.TestCase):
    """The CLI's `auto` source picks a macOS-only path for codex and claude."""

    ECHO_ARGS = "#!/usr/bin/env bash\necho \"$@\" >> \"$FIXTURE_DIR/calls.log\"\necho '[]'\n"

    def _calls(self, providers):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            fixtures = tmp / "fixtures"
            fixtures.mkdir()
            stub = tmp / "codexbar"
            stub.write_text(self.ECHO_ARGS)
            stub.chmod(0o755)
            env = dict(os.environ)
            env.update(
                {
                    "CODEXBAR_BIN": str(stub),
                    "CODEXBAR_PROVIDERS": providers,
                    "CODEXBAR_STAGGER": "0",
                    "FIXTURE_DIR": str(fixtures),
                    "XDG_CACHE_HOME": str(tmp / "cache"),
                    "XDG_CONFIG_HOME": str(tmp / "config"),
                }
            )
            subprocess.run(["bash", str(SCRIPT)], capture_output=True, text=True, env=env, timeout=60)
            return (fixtures / "calls.log").read_text().splitlines()

    def test_codex_and_claude_are_forced_to_oauth(self):
        for line in self._calls("codex"):
            self.assertIn("--source oauth", line)

    def test_other_providers_get_no_source_override(self):
        for line in self._calls("gemini"):
            self.assertNotIn("--source", line)

    def test_claude_falls_back_to_the_cli_source_on_error(self):
        # An empty array is not a provider-level error, so no retry. An error
        # entry is, so claude should be asked twice: oauth, then cli.
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            fixtures = tmp / "fixtures"
            fixtures.mkdir()
            stub = tmp / "codexbar"
            stub.write_text(
                "#!/usr/bin/env bash\n"
                'echo "$@" >> "$FIXTURE_DIR/calls.log"\n'
                "echo '[{\"provider\":\"claude\",\"error\":{\"message\":\"HTTP 429\"}}]'\n"
            )
            stub.chmod(0o755)
            env = dict(os.environ)
            env.update(
                {
                    "CODEXBAR_BIN": str(stub),
                    "CODEXBAR_PROVIDERS": "claude",
                    "CODEXBAR_STAGGER": "0",
                    "FIXTURE_DIR": str(fixtures),
                    "XDG_CACHE_HOME": str(tmp / "cache"),
                    "XDG_CONFIG_HOME": str(tmp / "config"),
                }
            )
            subprocess.run(["bash", str(SCRIPT)], capture_output=True, text=True, env=env, timeout=60)
            calls = (fixtures / "calls.log").read_text().splitlines()
            self.assertEqual(len(calls), 2, calls)
            self.assertIn("--source oauth", calls[0])
            self.assertIn("--source cli", calls[1])


@unittest.skipUnless(shutil.which("jq"), "jq is required")
class AntigravityCredentialsTest(unittest.TestCase):
    """Injected OAuth creds make the CLI skip `agy -p /usage`, its only working
    Linux source, so they must never be picked up implicitly."""

    RECORD_ENV = (
        "#!/usr/bin/env bash\n"
        'printf "%s\\n" "${ANTIGRAVITY_OAUTH_CREDENTIALS_JSON:-<unset>}" > "$FIXTURE_DIR/creds.log"\n'
        "echo '[]'\n"
    )

    def _injected(self, env_extra=None):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            fixtures = tmp / "fixtures"
            fixtures.mkdir()
            # A stale Gemini CLI login, where the script used to look by default.
            (tmp / ".gemini").mkdir()
            (tmp / ".gemini" / "oauth_creds.json").write_text('{"refresh_token": "gemini"}')
            stub = tmp / "codexbar"
            stub.write_text(self.RECORD_ENV)
            stub.chmod(0o755)
            env = dict(os.environ)
            env.pop("ANTIGRAVITY_OAUTH_CREDENTIALS_JSON", None)
            env.update(
                {
                    "HOME": str(tmp),
                    "CODEXBAR_BIN": str(stub),
                    "CODEXBAR_PROVIDERS": "antigravity",
                    "CODEXBAR_STAGGER": "0",
                    "FIXTURE_DIR": str(fixtures),
                    "XDG_CACHE_HOME": str(tmp / "cache"),
                    "XDG_CONFIG_HOME": str(tmp / "config"),
                }
            )
            env.update({k: v.format(tmp=tmp) for k, v in (env_extra or {}).items()})
            subprocess.run(["bash", str(SCRIPT)], capture_output=True, text=True, env=env, timeout=60)
            return (fixtures / "creds.log").read_text().strip()

    def test_gemini_creds_are_not_injected_by_default(self):
        self.assertEqual(self._injected(), "<unset>")

    def test_an_explicit_creds_path_is_still_injected(self):
        injected = self._injected({"CODEXBAR_ANTIGRAVITY_CREDS": "{tmp}/.gemini/oauth_creds.json"})
        self.assertEqual(injected, '{"refresh_token": "gemini"}')


@unittest.skipUnless(shutil.which("jq"), "jq is required")
class FailureTest(unittest.TestCase):
    def test_invalid_json_yields_an_error_entry_not_a_crash(self):
        proc, out = run({}, fallback="not json at all", providers="codex")
        self.assertEqual(proc.returncode, 0)
        self.assertFalse(out["available"])
        self.assertEqual(out["providers"][0]["id"], "codex")
        self.assertIn("no usable response", out["providers"][0]["error"])

    def test_empty_output_is_reported_per_provider(self):
        _, out = run({}, fallback="", providers="codex")
        self.assertFalse(out["available"])
        self.assertIsNotNone(out["providers"][0]["error"])

    def test_missing_cli_is_reported(self):
        proc, out = run(RESPONSES, env_extra={"CODEXBAR_BIN": "/nonexistent/codexbar"})
        self.assertEqual(proc.returncode, 0)
        self.assertFalse(out["available"])
        self.assertIn("codexbar CLI not found", out["error"])

    def test_an_error_never_overwrites_a_cached_good_snapshot(self):
        # Regression: the payload used to be cached wholesale, so the first
        # time a provider broke it clobbered its own last good data and the
        # fallback had nothing left to serve.
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            fixtures = tmp / "fixtures"
            fixtures.mkdir()
            stub = tmp / "codexbar"
            stub.write_text(STUB)
            stub.chmod(0o755)
            env = dict(os.environ)
            env.update({
                "CODEXBAR_BIN": str(stub), "CODEXBAR_PROVIDERS": "codex claude",
                "CODEXBAR_STAGGER": "0", "FIXTURE_DIR": str(fixtures),
                "FALLBACK_OUTPUT": "", "XDG_CACHE_HOME": str(tmp / "cache"),
                "XDG_CONFIG_HOME": str(tmp / "config"),
            })

            def run_once():
                return json.loads(subprocess.run(
                    ["bash", str(SCRIPT)], capture_output=True, text=True,
                    env=env, timeout=60).stdout)

            good = [{"provider": "codex", "usage": {"primary": {"usedPercent": 42, "windowMinutes": 300}}}]
            claude = [{"provider": "claude", "usage": {"primary": {"usedPercent": 5, "windowMinutes": 300}}}]
            (fixtures / "codex.json").write_text(json.dumps(good))
            (fixtures / "claude.json").write_text(json.dumps(claude))
            run_once()

            # codex now fails, twice. Claude keeps working throughout, so the
            # payload stays "available" and the cache keeps being written.
            (fixtures / "codex.json").write_text(json.dumps(
                [{"provider": "codex", "error": {"message": "HTTP 429"}}]))
            run_once()
            second = run_once()

            codex = next(p for p in second["providers"] if p["id"] == "codex")
            self.assertEqual(codex["maxPercent"], 42, "cached snapshot was lost")
            self.assertTrue(codex["stale"])
            self.assertIsNone(codex["error"])

    def test_a_provider_that_never_worked_keeps_its_error(self):
        # Nothing to fall back on, so the error must survive for the UI to act
        # on — that is what lets the bar drop the ring entirely.
        _, out = run({"codex": [{"provider": "codex", "error": {"message": "not configured"}}]},
                     providers="codex")
        self.assertEqual(out["providers"][0]["error"], "not configured")
        self.assertEqual(out["providers"][0]["windows"], [])

    def test_usage_known_false_windows_are_dropped(self):
        responses = {
            "codex": [
                {
                    "provider": "codex",
                    "usage": {
                        "primary": {"usedPercent": 0, "windowMinutes": 300, "usageKnown": False},
                        "secondary": {"usedPercent": 5, "windowMinutes": 10080},
                    },
                }
            ]
        }
        _, out = run(responses, providers="codex")
        labels = [w["label"] for w in out["providers"][0]["windows"]]
        self.assertEqual(labels, ["Weekly"])

    def test_an_offline_snapshot_is_a_failure_not_zero_usage(self):
        _, out = run({"antigravity": ANTIGRAVITY_OFFLINE}, providers="antigravity")
        provider = out["providers"][0]
        self.assertFalse(out["available"])
        self.assertIn("Live Antigravity usage is unavailable", provider["error"])
        self.assertEqual(provider["windows"], [])

    def test_an_offline_snapshot_falls_back_to_the_cached_one(self):
        # Regression: "offline" carried no error, so it replaced the last good
        # snapshot in the cache and the ring showed 0%.
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            fixtures = tmp / "fixtures"
            fixtures.mkdir()
            stub = tmp / "codexbar"
            stub.write_text(STUB)
            stub.chmod(0o755)
            env = dict(os.environ)
            env.update({
                "CODEXBAR_BIN": str(stub), "CODEXBAR_PROVIDERS": "antigravity",
                "CODEXBAR_STAGGER": "0", "FIXTURE_DIR": str(fixtures),
                "FALLBACK_OUTPUT": "", "XDG_CACHE_HOME": str(tmp / "cache"),
                "XDG_CONFIG_HOME": str(tmp / "config"),
            })

            def run_once():
                return json.loads(subprocess.run(
                    ["bash", str(SCRIPT)], capture_output=True, text=True,
                    env=env, timeout=60).stdout)

            (fixtures / "antigravity.json").write_text(json.dumps(RESPONSES["antigravity"]))
            run_once()
            (fixtures / "antigravity.json").write_text(json.dumps(ANTIGRAVITY_OFFLINE))
            run_once()
            second = run_once()

            provider = second["providers"][0]
            self.assertAlmostEqual(provider["maxPercent"], 1.1, msg="cached snapshot was lost")
            self.assertTrue(provider["stale"])
            self.assertIsNone(provider["error"])

    def test_a_failed_provider_falls_back_to_its_cached_snapshot(self):
        # Two runs sharing one cache dir: the second has codex failing, and
        # should serve the first run's codex data marked stale.
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            fixtures = tmp / "fixtures"
            fixtures.mkdir()
            stub = tmp / "codexbar"
            stub.write_text(STUB)
            stub.chmod(0o755)
            env = dict(os.environ)
            env.update(
                {
                    "CODEXBAR_BIN": str(stub),
                    "CODEXBAR_PROVIDERS": "codex",
                    "CODEXBAR_STAGGER": "0",
                    "FIXTURE_DIR": str(fixtures),
                    "FALLBACK_OUTPUT": "",
                    "XDG_CACHE_HOME": str(tmp / "cache"),
                    "XDG_CONFIG_HOME": str(tmp / "config"),
                }
            )

            good = [{"provider": "codex", "usage": {"primary": {"usedPercent": 42, "windowMinutes": 300}}}]
            (fixtures / "codex.json").write_text(json.dumps(good))
            first = json.loads(subprocess.run(["bash", str(SCRIPT)], capture_output=True,
                                              text=True, env=env, timeout=60).stdout)
            self.assertEqual(first["providers"][0]["maxPercent"], 42)
            self.assertFalse(first["providers"][0]["stale"])

            (fixtures / "codex.json").unlink()
            second = json.loads(subprocess.run(["bash", str(SCRIPT)], capture_output=True,
                                               text=True, env=env, timeout=60).stdout)
            self.assertEqual(second["providers"][0]["maxPercent"], 42)
            self.assertTrue(second["providers"][0]["stale"])
            self.assertTrue(second["stale"])


if __name__ == "__main__":
    unittest.main()
