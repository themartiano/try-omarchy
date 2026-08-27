#!/usr/bin/env python3
"""Regression tests for restoring the cursor after the Omarchy screensaver."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


HELPER = (
    Path(__file__).resolve().parents[1]
    / "native-overlay/usr/local/bin/omarchy-native-cursor-restore"
)


class NativeCursorRestoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.commands = self.root / "commands"
        self.commands.mkdir()
        self.cmdline = self.root / "cmdline"
        self.log = self.root / "hyprctl.log"
        self.write_command(
            self.commands / "hyprctl",
            r"""
            printf '%s\n' "$*" >>"$CURSOR_TEST_LOG"
            if [[ ${CURSOR_TEST_FAIL_EVAL:-0} == 1 && $1 == eval ]]; then
              exit 1
            fi
            if [[ ${CURSOR_TEST_FAIL_ALL:-0} == 1 ]]; then
              exit 1
            fi
            """,
        )

    def run_helper(
        self,
        cmdline: str,
        *,
        fail_eval: bool = False,
        fail_all: bool = False,
    ) -> list[str]:
        self.cmdline.write_text(cmdline, encoding="utf-8")
        environment = os.environ.copy()
        environment["PATH"] = f"{self.commands}:{environment['PATH']}"
        environment["OMARCHY_NATIVE_CURSOR_CMDLINE"] = str(self.cmdline)
        environment["CURSOR_TEST_LOG"] = str(self.log)
        environment["CURSOR_TEST_FAIL_EVAL"] = "1" if fail_eval else "0"
        environment["CURSOR_TEST_FAIL_ALL"] = "1" if fail_all else "0"
        result = subprocess.run(
            [str(HELPER)],
            check=False,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")
        return self.log.read_text(encoding="utf-8").splitlines()

    def test_qemu_virgl_guest_cursor_stays_hidden(self) -> None:
        calls = self.run_helper("root=/dev/vda rw omarchy.qemu_virgl=1 quiet\n")
        self.assertEqual(
            calls,
            ["eval hl.config({ cursor = { invisible = true } })"],
        )

    def test_non_vm_cursor_is_restored_visible(self) -> None:
        calls = self.run_helper("root=/dev/nvme0n1 rw quiet\n")
        self.assertEqual(
            calls,
            ["eval hl.config({ cursor = { invisible = false } })"],
        )

    def test_kernel_option_must_match_exactly(self) -> None:
        calls = self.run_helper(
            "root=/dev/vda omarchy.qemu_virgl=10 xomarchy.qemu_virgl=1\n"
        )
        self.assertEqual(
            calls,
            ["eval hl.config({ cursor = { invisible = false } })"],
        )

    def test_legacy_hyprland_fallback_preserves_policy(self) -> None:
        calls = self.run_helper(
            "root=/dev/vda omarchy.qemu_virgl=1\n",
            fail_eval=True,
        )
        self.assertEqual(
            calls,
            [
                "eval hl.config({ cursor = { invisible = true } })",
                "keyword cursor:invisible true",
            ],
        )

    def test_cleanup_continues_when_hyprctl_is_unavailable(self) -> None:
        calls = self.run_helper(
            "root=/dev/vda omarchy.qemu_virgl=1\n",
            fail_all=True,
        )
        self.assertEqual(
            calls,
            [
                "eval hl.config({ cursor = { invisible = true } })",
                "keyword cursor:invisible true",
            ],
        )

    @staticmethod
    def write_command(path: Path, body: str) -> None:
        path.write_text("#!/bin/bash\n" + textwrap.dedent(body).lstrip())
        path.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
