from __future__ import annotations

import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


GUEST = Path(__file__).resolve().parents[1]
SCRIPT = GUEST / "scripts/write-provenance.py"


def digest(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


class WriteProvenanceTests(unittest.TestCase):
    def fixture(self, temporary: str) -> tuple[Path, Path, Path, Path]:
        base = Path(temporary)
        root = base / "root"
        omarchy = root / "usr/share/omarchy"
        (omarchy / "bin").mkdir(parents=True)
        (omarchy / "bin/example").write_bytes(b"verbatim\n")
        target = omarchy / "shell/example.qml"
        target.parent.mkdir()
        target.write_bytes(b"patched\n")
        (omarchy / "themes").mkdir()
        (omarchy / "themes/example").write_bytes(b"theme\n")

        patch = base / "example.patch"
        patch.write_bytes(b"reviewed patch\n")
        backport = {
            "id": "fixture",
            "description": "Fixture backport",
            "reference": "https://example.test/backport",
            "patch": "example.patch",
            "patchSha256": digest(patch.read_bytes()),
            "targets": [
                {
                    "path": "shell/example.qml",
                    "beforeSha256": digest(b"upstream\n"),
                    "afterSha256": digest(target.read_bytes()),
                }
            ],
        }
        spec = base / "spec.json"
        spec.write_text(
            json.dumps(
                {
                    "upstream": {"commit": "fixture"},
                    "themes": ["example"],
                    "authenticity": {
                        "verbatimRuntimeTrees": ["bin"],
                        "backportedRuntimeTrees": ["shell"],
                        "backports": [backport],
                    },
                }
            ),
            encoding="utf-8",
        )
        return root, spec, target, base / "provenance.json"

    def run_writer(self, root: Path, spec: Path, output: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "python3",
                str(SCRIPT),
                "--root",
                str(root),
                "--spec",
                str(spec),
                "--output",
                str(output),
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_records_verbatim_trees_and_reviewed_backports_separately(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root, spec, _, output = self.fixture(temporary)
            result = self.run_writer(root, spec, output)
            self.assertEqual(result.returncode, 0, result.stderr)
            provenance = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(provenance["verbatimRuntimeTrees"], ["bin"])
            self.assertEqual(provenance["backportedRuntimeTrees"], ["shell"])
            self.assertEqual(provenance["backports"][0]["id"], "fixture")
            self.assertIn("enumerated reviewed backports", provenance["claim"])
            self.assertEqual(set(provenance["sha256Trees"]), {"bin", "shell", "themes"})

    def test_rejects_an_installed_target_that_differs_from_the_postimage(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root, spec, target, output = self.fixture(temporary)
            target.write_bytes(b"unexpected\n")
            result = self.run_writer(root, spec, output)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("backport target digest mismatch", result.stderr)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
