#!/usr/bin/env python3

from __future__ import annotations

from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "try_omarchy_build_cache", REPOSITORY / "scripts/build-cache.py"
)
assert SPEC is not None and SPEC.loader is not None
build_cache = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build_cache)


FAKE_GUEST_BUILDER = textwrap.dedent(
    r"""
    import hashlib
    import json
    from pathlib import Path
    import sys
    import time

    root = Path(sys.argv[1])
    mode = sys.argv[2]
    count_path = root / "build-count"
    count = int(count_path.read_text()) + 1 if count_path.exists() else 1
    count_path.write_text(f"{count}\n")
    if mode == "fail":
        raise SystemExit(23)
    if mode == "slow":
        time.sleep(0.2)
    if mode == "mutate":
        (root / "guest/build.input").write_text("changed during build\n")

    output = root / "dist/guest"
    output.mkdir(parents=True, exist_ok=True)
    artifacts = {
        "LICENSE.omarchy",
        "build-spec.json",
        "initramfs-linux.img",
        "packages.lock.txt",
        "provenance.json",
        "rootfs.ext4",
        "rootfs.ext4.zst",
        "vmlinuz-linux",
    }
    spec = (root / "guest/spec.json").read_bytes()
    records = []
    checksums = {}
    for name in sorted(artifacts):
        contents = spec if name == "build-spec.json" else f"{name} build {count}\n".encode()
        (output / name).write_bytes(contents)
        digest = hashlib.sha256(contents).hexdigest()
        checksums[name] = digest
        records.append({"path": name, "bytes": len(contents), "sha256": digest})
    manifest = {
        "schemaVersion": 1,
        "kind": "try-omarchy-guest-artifacts",
        "artifacts": records,
    }
    manifest_bytes = (json.dumps(manifest, sort_keys=True) + "\n").encode()
    (output / "guest-manifest.json").write_bytes(manifest_bytes)
    checksums["guest-manifest.json"] = hashlib.sha256(manifest_bytes).hexdigest()
    (output / "SHA256SUMS").write_text(
        "".join(f"{digest}  {name}\n" for name, digest in sorted(checksums.items()))
    )
    """
)


class BuildCacheTests(unittest.TestCase):
    @staticmethod
    def prepare_fake_guest(root: Path) -> None:
        (root / "guest").mkdir()
        (root / "guest/spec.json").write_text('{"schemaVersion": 1}\n')
        (root / "guest/build.input").write_text("initial\n")

    def test_make_orders_components_and_propagates_force(self) -> None:
        dry_run = subprocess.run(
            ["make", "-n", "build"],
            cwd=REPOSITORY,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        ).stdout
        guest = dry_run.index(" guest --")
        runtime = dry_run.index(" runtime --")
        app = dry_run.index(" app --")
        self.assertLess(guest, runtime)
        self.assertLess(runtime, app)

        forced = subprocess.run(
            ["make", "-n", "build", "FORCE=1"],
            cwd=REPOSITORY,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        ).stdout
        self.assertEqual(3, forced.count('OMARCHY_FORCE_BUILD="1"'))

        invalid_release = subprocess.run(
            ["make", "release", "RELEASE_SIGN_IDENTITY=invalid"],
            cwd=REPOSITORY,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        self.assertNotEqual(0, invalid_release.returncode)
        self.assertNotIn("build-cache.py", invalid_release.stdout)

    def test_guest_fingerprint_tracks_build_inputs_but_not_documentation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "guest/tests").mkdir(parents=True)
            (root / "guest/scripts/__pycache__").mkdir(parents=True)
            (root / "guest/build.sh").write_text("one\n")
            (root / "guest/README.md").write_text("first docs\n")
            (root / "guest/tests/example.py").write_text("first test\n")
            bytecode = root / "guest/scripts/__pycache__/helper.pyc"
            bytecode.write_bytes(b"first transient bytecode\n")
            command = [
                str(root / "guest/build.sh"),
                "--output",
                str(root / "dist/guest"),
            ]

            original = build_cache.fingerprint(root, "guest", command)
            (root / "guest/README.md").write_text("second docs\n")
            (root / "guest/tests/example.py").write_text("second test\n")
            bytecode.write_bytes(b"second transient bytecode\n")
            self.assertEqual(original, build_cache.fingerprint(root, "guest", command))

            (root / "guest/build.sh").write_text("two\n")
            self.assertNotEqual(
                original, build_cache.fingerprint(root, "guest", command)
            )

    def test_guest_validation_checks_manifest_and_successful_output_snapshot(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "dist/guest"
            output.mkdir(parents=True)
            (root / "guest").mkdir()
            spec_contents = b'{"schemaVersion": 1}\n'
            (root / "guest/spec.json").write_bytes(spec_contents)

            records = []
            checksums: dict[str, str] = {}
            for name in sorted(build_cache.GUEST_ARTIFACTS):
                contents = (
                    spec_contents if name == "build-spec.json" else f"{name}\n".encode()
                )
                (output / name).write_bytes(contents)
                digest = hashlib.sha256(contents).hexdigest()
                checksums[name] = digest
                records.append({"path": name, "bytes": len(contents), "sha256": digest})
            manifest = {
                "schemaVersion": 1,
                "kind": "try-omarchy-guest-artifacts",
                "artifacts": records,
            }
            manifest_bytes = (json.dumps(manifest, sort_keys=True) + "\n").encode()
            (output / "guest-manifest.json").write_bytes(manifest_bytes)
            checksums["guest-manifest.json"] = hashlib.sha256(
                manifest_bytes
            ).hexdigest()
            (output / "SHA256SUMS").write_text(
                "".join(
                    f"{digest}  {name}\n" for name, digest in sorted(checksums.items())
                )
            )

            snapshot = build_cache.validate_guest(root, None)
            self.assertEqual(
                snapshot, build_cache.validate_guest(root, {"outputs": snapshot})
            )

            artifact = output / "rootfs.ext4.zst"
            metadata = artifact.stat()
            os.utime(artifact, ns=(metadata.st_atime_ns, metadata.st_mtime_ns + 1))
            with self.assertRaisesRegex(build_cache.CacheError, "metadata changed"):
                build_cache.validate_guest(root, {"outputs": snapshot})

    def test_state_write_is_readable_and_replaces_old_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / "state/component.json"
            first = {"schemaVersion": build_cache.SCHEMA_VERSION, "fingerprint": "one"}
            second = {"schemaVersion": build_cache.SCHEMA_VERSION, "fingerprint": "two"}
            build_cache.write_state(state, first)
            self.assertEqual(first, build_cache.read_state(state))
            build_cache.write_state(state, second)
            self.assertEqual(second, build_cache.read_state(state))

    def test_cached_runner_skips_rebuilds_and_never_stamps_bad_builds(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.prepare_fake_guest(root)
            build_input = root / "guest/build.input"
            state_dir = root / ".build/state"

            def invoke(mode: str = "good", *, force: bool = False) -> None:
                command = [sys.executable, "-c", FAKE_GUEST_BUILDER, str(root), mode]
                with redirect_stdout(io.StringIO()):
                    build_cache.run(root, state_dir, "guest", command, force)

            invoke()
            self.assertEqual("1", (root / "build-count").read_text().strip())
            self.assertTrue((state_dir / "guest.json").is_file())

            invoke()
            self.assertEqual("1", (root / "build-count").read_text().strip())

            build_input.write_text("edited\n")
            invoke()
            self.assertEqual("2", (root / "build-count").read_text().strip())

            invoke(force=True)
            self.assertEqual("3", (root / "build-count").read_text().strip())

            with (root / "dist/guest/rootfs.ext4.zst").open("ab") as stream:
                stream.write(b"tampered")
            invoke()
            self.assertEqual("4", (root / "build-count").read_text().strip())

            with self.assertRaisesRegex(build_cache.CacheError, "exit status 23"):
                invoke("fail")
            self.assertFalse((state_dir / "guest.json").exists())

            invoke()
            self.assertTrue((state_dir / "guest.json").is_file())
            with self.assertRaisesRegex(build_cache.CacheError, "inputs changed"):
                invoke("mutate")
            self.assertFalse((state_dir / "guest.json").exists())

    def test_concurrent_builds_share_the_component_lock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.prepare_fake_guest(root)
            build_command = [
                sys.executable,
                "-c",
                FAKE_GUEST_BUILDER,
                str(root),
                "slow",
            ]
            wrapper = [
                sys.executable,
                str(REPOSITORY / "scripts/build-cache.py"),
                "--root",
                str(root),
                "--state-dir",
                str(root / ".build/state"),
                "guest",
                "--",
                *build_command,
            ]
            first = subprocess.Popen(
                wrapper, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
            )
            second = subprocess.Popen(
                wrapper, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
            )
            first_output, _ = first.communicate(timeout=10)
            second_output, _ = second.communicate(timeout=10)
            self.assertEqual(0, first.returncode, first_output)
            self.assertEqual(0, second.returncode, second_output)
            self.assertEqual("1", (root / "build-count").read_text().strip())
            combined = first_output + second_output
            self.assertEqual(1, combined.count("recorded successful guest build"))
            self.assertEqual(1, combined.count("guest is up to date"))


if __name__ == "__main__":
    unittest.main()
