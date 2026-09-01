#!/usr/bin/env python3
"""Isolated contracts for the boot-scoped SSH systemd generator."""

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest


GUEST = Path(__file__).resolve().parents[1]
GENERATOR = (
    GUEST
    / "native-overlay/usr/lib/systemd/system-generators/try-omarchy-ssh-access"
)


class SSHAccessGeneratorTests(unittest.TestCase):
    def run_generator(
        self, command_line: str, *, vendor_unit_exists: bool = True
    ) -> tuple[
        subprocess.CompletedProcess[str], Path, tempfile.TemporaryDirectory[str]
    ]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        output = root / "normal"
        output.mkdir()
        cmdline = root / "cmdline"
        cmdline.write_text(command_line + "\n", encoding="ascii")
        vendor = root / "sshd.service"
        if vendor_unit_exists:
            vendor.write_text(
                "[Service]\nExecStart=/usr/bin/sshd -D\n", encoding="ascii"
            )
        test_generator = root / "generator"
        source = GENERATOR.read_text(encoding="utf-8")
        source = source.replace("/proc/cmdline", str(cmdline)).replace(
            "/usr/lib/systemd/system/sshd.service", str(vendor)
        )
        test_generator.write_text(source, encoding="utf-8")
        test_generator.chmod(0o755)
        result = subprocess.run(
            [str(test_generator), str(output), str(root / "early"), str(root / "late")],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return result, output, temporary

    def test_absent_and_lookalike_tokens_do_nothing(self) -> None:
        for command_line in (
            "root=/dev/vda rw",
            "root=/dev/vda tryomarchy.ssh_access=0",
            "root=/dev/vda xtryomarchy.ssh_access=1",
            "root=/dev/vda tryomarchy.ssh_access=1x",
        ):
            result, output, temporary = self.run_generator(command_line)
            with temporary:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse((output / "multi-user.target.wants").exists())

    def test_absent_token_does_not_require_vendor_unit(self) -> None:
        result, output, temporary = self.run_generator(
            "root=/dev/vda rw", vendor_unit_exists=False
        )
        with temporary:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((output / "multi-user.target.wants").exists())

    def test_exact_token_creates_only_runtime_wants_link(self) -> None:
        result, output, temporary = self.run_generator(
            "root=/dev/vda rw tryomarchy.ssh_access=1"
        )
        with temporary:
            link = output / "multi-user.target.wants/sshd.service"
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(link.is_symlink())
            self.assertEqual(link.resolve().name, "sshd.service")
            self.assertEqual(
                [path.relative_to(output).as_posix() for path in output.rglob("*")],
                ["multi-user.target.wants", "multi-user.target.wants/sshd.service"],
            )

    def test_exact_token_requires_vendor_unit(self) -> None:
        result, output, temporary = self.run_generator(
            "root=/dev/vda rw tryomarchy.ssh_access=1", vendor_unit_exists=False
        )
        with temporary:
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((output / "multi-user.target.wants").exists())

    def test_enabled_path_rejects_a_symlinked_wants_directory(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        with temporary:
            root = Path(temporary.name)
            escaped = root / "escaped"
            escaped.mkdir()
            output = root / "normal"
            output.mkdir()
            (output / "multi-user.target.wants").symlink_to(escaped)
            cmdline = root / "cmdline"
            cmdline.write_text(
                "root=/dev/vda rw tryomarchy.ssh_access=1\n", encoding="ascii"
            )
            vendor = root / "sshd.service"
            vendor.write_text("[Service]\n", encoding="ascii")
            test_generator = root / "generator"
            source = GENERATOR.read_text(encoding="utf-8")
            source = source.replace("/proc/cmdline", str(cmdline)).replace(
                "/usr/lib/systemd/system/sshd.service", str(vendor)
            )
            test_generator.write_text(source, encoding="utf-8")
            test_generator.chmod(0o755)
            result = subprocess.run(
                [
                    str(test_generator),
                    str(output),
                    str(root / "early"),
                    str(root / "late"),
                ],
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(list(escaped.iterdir()), [])

    def test_malformed_invocation_fails(self) -> None:
        result = subprocess.run([str(GENERATOR)], check=False)
        self.assertEqual(result.returncode, 64)


if __name__ == "__main__":
    unittest.main()
