from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


GUEST = Path(__file__).resolve().parents[1]
UPDATER = GUEST / "scripts/update-upstream-pin.py"


class UpdateUpstreamPinTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        subprocess.run(["git", "init", "--quiet", str(self.source)], check=True)
        subprocess.run(
            ["git", "-C", str(self.source), "remote", "add", "origin", "https://github.com/basecamp/omarchy.git"],
            check=True,
        )
        subprocess.run(["git", "-C", str(self.source), "config", "user.name", "Test"], check=True)
        subprocess.run(["git", "-C", str(self.source), "config", "user.email", "test@example.com"], check=True)
        (self.source / "version").write_text("4.0.0.alpha\n", encoding="utf-8")
        (self.source / "bin").mkdir()
        command = self.source / "bin/omarchy"
        command.write_text("#!/bin/bash\n", encoding="utf-8")
        command.chmod(0o755)
        subprocess.run(["git", "-C", str(self.source), "add", "."], check=True)
        environment = os.environ.copy()
        environment.update(
            {
                "GIT_AUTHOR_DATE": "2026-08-25T10:12:38Z",
                "GIT_COMMITTER_DATE": "2026-08-25T10:12:38Z",
            }
        )
        subprocess.run(
            ["git", "-C", str(self.source), "commit", "--quiet", "-m", "release"],
            check=True,
            env=environment,
        )
        subprocess.run(["git", "-C", str(self.source), "tag", "v4.0.1"], check=True)
        self.spec = self.root / "spec.json"
        self.spec.write_text(
            json.dumps(
                {
                    "image": {"sourceDateEpoch": 1},
                    "upstream": {
                        "repository": "https://github.com/basecamp/omarchy",
                        "commit": "0" * 40,
                        "tree": "0" * 40,
                        "treeSha256": "0" * 64,
                        "version": "old",
                        "channel": "quattro",
                        "license": "MIT",
                    },
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_updater(self, *extra: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                str(UPDATER),
                "--release",
                "4.0.1",
                "--source",
                str(self.source),
                "--spec",
                str(self.spec),
                *extra,
            ],
            check=check,
            text=True,
            capture_output=True,
        )

    def test_updates_every_source_identity_field_atomically(self) -> None:
        result = self.run_updater()
        updated = json.loads(self.spec.read_text(encoding="utf-8"))
        commit = subprocess.check_output(
            ["git", "-C", str(self.source), "rev-parse", "HEAD"], text=True
        ).strip()
        tree = subprocess.check_output(
            ["git", "-C", str(self.source), "rev-parse", "HEAD^{tree}"], text=True
        ).strip()

        self.assertEqual(updated["upstream"]["commit"], commit)
        self.assertEqual(updated["upstream"]["tree"], tree)
        self.assertEqual(updated["upstream"]["release"], "4.0.1")
        self.assertEqual(updated["upstream"]["version"], "4.0.0.alpha")
        self.assertEqual(updated["image"]["sourceDateEpoch"], 1787652758)
        self.assertRegex(updated["upstream"]["treeSha256"], r"^[0-9a-f]{64}$")
        self.assertIn("Pinned Omarchy v4.0.1", result.stdout)
        self.run_updater("--check")

    def test_refuses_a_dirty_source_checkout(self) -> None:
        (self.source / "untracked").write_text("dirty\n", encoding="utf-8")
        result = self.run_updater(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source checkout is not clean", result.stderr)

    def test_refuses_head_that_does_not_match_the_release_tag(self) -> None:
        (self.source / "version").write_text("changed\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(self.source), "add", "version"], check=True)
        subprocess.run(["git", "-C", str(self.source), "commit", "--quiet", "-m", "later"], check=True)
        result = self.run_updater(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is not the v4.0.1 commit", result.stderr)

    def test_check_reports_a_stale_spec_without_rewriting_it(self) -> None:
        original = self.spec.read_bytes()
        result = self.run_updater("--check", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.spec.read_bytes(), original)
        self.assertIn("build spec does not match v4.0.1", result.stderr)


if __name__ == "__main__":
    unittest.main()
