#!/usr/bin/env python3
"""Tests for deferred, content-matched per-user migrations."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


GUEST = Path(__file__).resolve().parents[1]
USER_MIGRATE = GUEST / "native-overlay/usr/local/lib/try-omarchy/user-migrate"


class UserMigrationTests(unittest.TestCase):
    @staticmethod
    def digest(payload: bytes) -> str:
        return hashlib.sha256(payload).hexdigest()

    def fixture(self, root: Path, records: dict[str, bytes]) -> tuple[Path, Path, dict[str, str]]:
        home = root / "home"
        toggles = home / ".local/state/omarchy/toggles/hypr"
        toggles.mkdir(parents=True)
        manifest = root / "migration.tsv"
        manifest.write_text(
            "".join(
                f"{self.digest(payload)}\t{name}\n"
                for name, payload in records.items()
            ),
            encoding="ascii",
        )
        environment = os.environ.copy()
        environment["HOME"] = str(home)
        environment["TRY_OMARCHY_USER_MIGRATION_MANIFEST"] = str(manifest)
        return home, toggles, environment

    def test_exact_defaults_are_preserved_then_disabled(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            records = {
                "window-no-gaps.lua": b"stock no gaps\n",
                "single-window-aspect-ratio.lua": b"stock aspect ratio\n",
            }
            home, toggles, environment = self.fixture(Path(temporary), records)
            for name, payload in records.items():
                (toggles / name).write_bytes(payload)
            flags = toggles / "flags.lua"
            flags.write_text("sentinel\n", encoding="ascii")
            unknown = toggles / "future-toggle.lua"
            unknown.write_text("user choice\n", encoding="ascii")

            subprocess.run([str(USER_MIGRATE)], check=True, env=environment)

            preserved = (
                home
                / ".local/state/try-omarchy/preserved/0003-hypr-toggle-defaults"
            )
            for name, payload in records.items():
                self.assertFalse((toggles / name).exists())
                self.assertEqual((preserved / name).read_bytes(), payload)
            self.assertEqual(flags.read_text(encoding="ascii"), "sentinel\n")
            self.assertEqual(unknown.read_text(encoding="ascii"), "user choice\n")
            marker = (
                home
                / ".local/state/try-omarchy/migrations/0003-hypr-toggle-defaults"
            )
            self.assertIn("moved=2\n", marker.read_text(encoding="ascii"))

            # Once complete, deliberately re-enabling the stock toggle is a
            # user choice and must survive later logins.
            (toggles / "window-no-gaps.lua").write_bytes(records["window-no-gaps.lua"])
            subprocess.run([str(USER_MIGRATE)], check=True, env=environment)
            self.assertTrue((toggles / "window-no-gaps.lua").is_file())

    def test_modified_and_unsafe_entries_are_left_in_place(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            records = {
                "window-no-gaps.lua": b"stock no gaps\n",
                "single-window-aspect-ratio.lua": b"stock aspect ratio\n",
            }
            home, toggles, environment = self.fixture(Path(temporary), records)
            modified = toggles / "window-no-gaps.lua"
            modified.write_text("locally modified\n", encoding="ascii")
            symlink = toggles / "single-window-aspect-ratio.lua"
            symlink.symlink_to("flags.lua")

            subprocess.run([str(USER_MIGRATE)], check=True, env=environment)

            self.assertEqual(modified.read_text(encoding="ascii"), "locally modified\n")
            self.assertTrue(symlink.is_symlink())
            marker = (
                home
                / ".local/state/try-omarchy/migrations/0003-hypr-toggle-defaults"
            )
            self.assertIn("preserved=2\n", marker.read_text(encoding="ascii"))

    def test_missing_toggle_directory_completes_without_creating_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            home = root / "home"
            home.mkdir()
            manifest = root / "migration.tsv"
            stock_digest = self.digest(b"stock\n")
            manifest.write_text(
                f"{stock_digest}\twindow-no-gaps.lua\n",
                encoding="ascii",
            )
            environment = os.environ.copy()
            environment["HOME"] = str(home)
            environment["TRY_OMARCHY_USER_MIGRATION_MANIFEST"] = str(manifest)

            subprocess.run([str(USER_MIGRATE)], check=True, env=environment)

            self.assertFalse(
                (home / ".local/state/omarchy/toggles/hypr").exists()
            )
            self.assertTrue(
                (
                    home
                    / ".local/state/try-omarchy/migrations/0003-hypr-toggle-defaults"
                ).is_file()
            )


if __name__ == "__main__":
    unittest.main()
