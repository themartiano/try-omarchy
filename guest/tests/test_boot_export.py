#!/usr/bin/env python3
"""Isolated contracts for the one-time initramfs boot export."""

from __future__ import annotations

import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


GUEST = Path(__file__).resolve().parents[1]
INSTALL_HOOK = (
    GUEST
    / "native-overlay/usr/lib/initcpio/install/try-omarchy-boot-export"
)
RUNTIME_HOOK = (
    GUEST
    / "native-overlay/usr/lib/initcpio/hooks/try-omarchy-boot-export"
)
MKINITCPIO_CONFIG = (
    GUEST / "factory-overlay/etc/mkinitcpio.conf.d/90-try-omarchy.conf"
)


class BootExportStaticTests(unittest.TestCase):
    def test_install_hook_adds_only_the_needed_runtime(self) -> None:
        source = INSTALL_HOOK.read_text(encoding="utf-8")
        self.assertTrue(INSTALL_HOOK.stat().st_mode & stat.S_IXUSR)
        self.assertIn("add_runscript", source)
        for module in ("9p", "9pnet", "9pnet_virtio"):
            self.assertIn(f"add_module {module}\n", source)
        for binary in ("cp", "mkdir", "mv", "rm", "stat", "sync"):
            self.assertIn(binary, source)

    def test_runtime_hook_is_enabled_in_the_factory_initramfs(self) -> None:
        config = MKINITCPIO_CONFIG.read_text(encoding="utf-8")
        self.assertEqual(config.count("try-omarchy-boot-export"), 1)
        self.assertIn("fsck try-omarchy-boot-export)", config)
        self.assertTrue(RUNTIME_HOOK.stat().st_mode & stat.S_IXUSR)

    def test_runtime_hook_reads_the_root_mounted_by_mkinitcpio(self) -> None:
        source = RUNTIME_HOOK.read_text(encoding="utf-8")
        self.assertIn("old_root=/new_root\n", source)
        self.assertNotIn("old_root=/sysroot\n", source)


class BootExportRuntimeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.old_root = self.root / "new_root"
        self.boot = self.old_root / "boot"
        self.boot.mkdir(parents=True)
        self.export = self.root / "export"
        self.cmdline = self.root / "cmdline"
        self.log = self.root / "commands.log"
        self.fake_bin = self.root / "bin"
        self.fake_bin.mkdir()
        self._write_fake_commands()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_fake(self, name: str, body: str) -> None:
        path = self.fake_bin / name
        path.write_text("#!/bin/sh\n" + body, encoding="utf-8")
        path.chmod(0o755)

    def _write_fake_commands(self) -> None:
        record = 'printf \'%s:%s\\n\' "$0" "$*" >>"$BOOT_EXPORT_TEST_LOG"\n'
        self._write_fake(
            "mount",
            record + 'exit "${BOOT_EXPORT_TEST_MOUNT_STATUS:-0}"\n',
        )
        self._write_fake(
            "umount",
            record + 'exit "${BOOT_EXPORT_TEST_UMOUNT_STATUS:-0}"\n',
        )
        self._write_fake("poweroff", record + "exit 0\n")
        self._write_fake(
            "sync",
            record + '[ "${BOOT_EXPORT_TEST_SYNC_FAIL:-0}" -ne 0 ] && exit 1\nexit 0\n',
        )
        self._write_fake(
            "stat",
            'if [ "$1" != -c ] || [ "$2" != %s ] || [ "$3" != -- ]; then exit 64; fi\n'
            'exec /usr/bin/stat -f %z "$4"\n',
        )

    def _run_hook(
        self,
        command_line: str,
        *,
        mount_status: int = 0,
        sync_fails: bool = False,
        umount_status: int = 0,
    ) -> subprocess.CompletedProcess[str]:
        self.cmdline.write_text(command_line + "\n", encoding="ascii")
        test_hook = self.root / "try-omarchy-boot-export"
        source = RUNTIME_HOOK.read_text(encoding="utf-8")
        source = source.replace("/proc/cmdline", str(self.cmdline))
        source = source.replace("/usr/bin/stat", str(self.fake_bin / "stat"))
        source = source.replace("/new_root", str(self.old_root))
        source = source.replace("/run/try-omarchy-boot-export", str(self.export))
        test_hook.write_text(source, encoding="utf-8")

        environment = os.environ.copy()
        environment["PATH"] = f"{self.fake_bin}:{environment['PATH']}"
        environment["BOOT_EXPORT_TEST_LOG"] = str(self.log)
        environment["BOOT_EXPORT_TEST_MOUNT_STATUS"] = str(mount_status)
        environment["BOOT_EXPORT_TEST_SYNC_FAIL"] = "1" if sync_fails else "0"
        environment["BOOT_EXPORT_TEST_UMOUNT_STATUS"] = str(umount_status)
        harness = """
err() {
  printf 'err:%s\\n' "$*" >>"$BOOT_EXPORT_TEST_LOG"
}
. "$1"
run_latehook
"""
        return subprocess.run(
            ["/bin/sh", "-c", harness, "boot-export-test", str(test_hook)],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
        )

    def _write_boot_files(self) -> None:
        (self.boot / "Image").write_bytes(b"installed kernel\n".ljust(64, b"\0"))
        (self.boot / "initramfs-linux.img").write_bytes(b"installed initramfs\n")
        build_spec = self.old_root / "usr/share/try-omarchy/build-spec.json"
        build_spec.parent.mkdir(parents=True)
        build_spec.write_text(
            '{"runtime":{"kernelCommandLine":"root=/dev/vda rw rootwait '
            'console=tty0 console=hvc0"}}\n',
            encoding="ascii",
        )

    def _log_text(self) -> str:
        return self.log.read_text(encoding="utf-8") if self.log.exists() else ""

    def test_absent_and_lookalike_tokens_leave_boot_untouched(self) -> None:
        for command_line in (
            "root=/dev/vda rw",
            "root=/dev/vda tryomarchy.export_boot=0",
            "root=/dev/vda xtryomarchy.export_boot=1",
            "root=/dev/vda tryomarchy.export_boot=1x",
        ):
            with self.subTest(command_line=command_line):
                result = self._run_hook(command_line)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(self.export.exists())
                self.assertEqual(self._log_text(), "")

    def test_exact_token_exports_files_then_publishes_marker_and_powers_off(self) -> None:
        self._write_boot_files()

        result = self._run_hook(
            "root=/dev/vda rw tryomarchy.export_boot=1 console=hvc0"
        )

        # The mocked poweroff returns, so the hook deliberately reports failure
        # instead of allowing this recovery boot to continue.
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(
            (self.export / "kernel").read_bytes(),
            b"installed kernel\n".ljust(64, b"\0"),
        )
        self.assertEqual(
            (self.export / "initramfs").read_bytes(), b"installed initramfs\n"
        )
        self.assertIn(
            '"kernelCommandLine"',
            (self.export / "build-spec.json").read_text(encoding="ascii"),
        )
        self.assertEqual(
            (self.export / "complete").read_text(encoding="ascii"),
            "try-omarchy-boot-export-v1\n",
        )
        log = self._log_text()
        self.assertIn(
            "mount:-t 9p -o "
            "trans=virtio,version=9p2000.L,msize=1048576,cache=none,nosuid,nodev,noexec "
            f"try-omarchy-boot-export {self.export}",
            log,
        )
        self.assertEqual(log.count("sync:"), 4)
        self.assertLess(log.rfind("sync:"), log.find("umount:"))
        self.assertLess(log.find("umount:"), log.find("poweroff:-f"))

    def test_mount_failure_powers_off_without_writing_an_export(self) -> None:
        self._write_boot_files()

        result = self._run_hook(
            "tryomarchy.export_boot=1 root=/dev/vda", mount_status=1
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.export / "complete").exists())
        log = self._log_text()
        self.assertIn("mount:", log)
        self.assertIn("poweroff:-f", log)
        self.assertNotIn("sync:", log)

    def test_oversized_source_is_rejected_before_mount_or_copy(self) -> None:
        self._write_boot_files()
        build_spec = self.old_root / "usr/share/try-omarchy/build-spec.json"
        build_spec.write_bytes(b"{" + b"x" * 1_048_576)

        result = self._run_hook("root=/dev/vda tryomarchy.export_boot=1")

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.export.exists())
        log = self._log_text()
        self.assertNotIn("mount:", log)
        self.assertIn("poweroff:-f", log)

    def test_symlinked_source_is_rejected_before_mounting(self) -> None:
        (self.boot / "Image").write_bytes(b"installed kernel\n")
        outside = self.root / "outside-initramfs"
        outside.write_bytes(b"not a direct boot file\n")
        (self.boot / "initramfs-linux.img").symlink_to(outside)

        result = self._run_hook("root=/dev/vda tryomarchy.export_boot=1")

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.export.exists())
        log = self._log_text()
        self.assertNotIn("mount:", log)
        self.assertIn("poweroff:-f", log)

    def test_sync_failure_never_publishes_complete_marker(self) -> None:
        self._write_boot_files()

        result = self._run_hook(
            "root=/dev/vda tryomarchy.export_boot=1", sync_fails=True
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.export / "complete").exists())
        self.assertIn("poweroff:-f", self._log_text())

    def test_unmount_failure_withdraws_complete_marker(self) -> None:
        self._write_boot_files()

        result = self._run_hook(
            "root=/dev/vda tryomarchy.export_boot=1", umount_status=1
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.export / "complete").exists())
        log = self._log_text()
        self.assertIn("umount:", log)
        self.assertIn("poweroff:-f", log)


if __name__ == "__main__":
    unittest.main()
