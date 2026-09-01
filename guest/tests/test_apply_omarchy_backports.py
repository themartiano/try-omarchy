from __future__ import annotations

import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


GUEST = Path(__file__).resolve().parents[1]
SCRIPT = GUEST / "scripts/apply-omarchy-backports.py"


def digest(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


class ApplyOmarchyBackportsTests(unittest.TestCase):
    before = b"before\n"
    after = b"after\n"
    patch = b"""\
diff --git a/example.txt b/example.txt
--- a/example.txt
+++ b/example.txt
@@ -1 +1 @@
-before
+after
"""

    def fixture(self, temporary: str) -> tuple[Path, Path, Path]:
        base = Path(temporary)
        root = base / "root"
        target = root / "usr/share/omarchy/example.txt"
        target.parent.mkdir(parents=True)
        target.write_bytes(self.before)
        patch = base / "example.patch"
        patch.write_bytes(self.patch)
        spec = base / "spec.json"
        spec.write_text(
            json.dumps(
                {
                    "authenticity": {
                        "backports": [
                            {
                                "id": "fixture",
                                "patch": "example.patch",
                                "patchSha256": digest(self.patch),
                                "targets": [
                                    {
                                        "path": "example.txt",
                                        "beforeSha256": digest(self.before),
                                        "afterSha256": digest(self.after),
                                    }
                                ],
                            }
                        ]
                    }
                }
            ),
            encoding="utf-8",
        )
        return root, spec, target

    def run_script(self, root: Path, spec: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", str(SCRIPT), "--root", str(root), "--spec", str(spec)],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_applies_only_to_the_declared_preimage(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root, spec, target = self.fixture(temporary)
            first = self.run_script(root, spec)
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(target.read_bytes(), self.after)

            second = self.run_script(root, spec)
            self.assertNotEqual(second.returncode, 0)
            self.assertIn("beforeSha256 mismatch", second.stderr)

    def test_rejects_a_changed_patch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root, spec, target = self.fixture(temporary)
            (spec.parent / "example.patch").write_bytes(self.patch + b"\n")
            result = self.run_script(root, spec)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("patch digest mismatch", result.stderr)
            self.assertEqual(target.read_bytes(), self.before)

    def test_rejects_a_target_outside_the_omarchy_tree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root, spec, target = self.fixture(temporary)
            payload = json.loads(spec.read_text(encoding="utf-8"))
            payload["authenticity"]["backports"][0]["targets"][0]["path"] = "../example.txt"
            spec.write_text(json.dumps(payload), encoding="utf-8")
            result = self.run_script(root, spec)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unsafe target path", result.stderr)
            self.assertEqual(target.read_bytes(), self.before)

    def test_patches_a_staged_root_command_without_replacing_its_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root, spec, target = self.fixture(temporary)
            target.unlink()
            target = root / "usr/share/omarchy/bin/example"
            target.parent.mkdir()
            command = root / "usr/bin/example"
            command.parent.mkdir(parents=True)
            command.write_bytes(self.before)
            target.symlink_to("/usr/bin/example")

            payload = json.loads(spec.read_text(encoding="utf-8"))
            backport = payload["authenticity"]["backports"][0]
            backport["targets"][0]["path"] = "bin/example"
            patch_payload = self.patch.replace(b"example.txt", b"bin/example")
            (spec.parent / "example.patch").write_bytes(patch_payload)
            backport["patchSha256"] = digest(patch_payload)
            spec.write_text(json.dumps(payload), encoding="utf-8")

            result = self.run_script(root, spec)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(target.is_symlink())
            self.assertEqual(target.readlink(), Path("/usr/bin/example"))
            self.assertEqual(command.read_bytes(), self.after)

    def test_rejects_a_staged_command_symlink_outside_the_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root, spec, target = self.fixture(temporary)
            target.unlink()
            target.symlink_to("/tmp/example")
            result = self.run_script(root, spec)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("target is not a regular file", result.stderr)


if __name__ == "__main__":
    unittest.main()
