#!/usr/bin/env python3
"""Contract and failure-recovery tests for offline guest updates."""

from __future__ import annotations

import hashlib
import importlib.util
from importlib.machinery import SourceFileLoader
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import unittest


GUEST = Path(__file__).resolve().parents[1]
CONTRACT_WRITER = GUEST / "scripts/write-update-contract.py"
PREPARE_UPDATE = GUEST / "scripts/prepare-update-root.py"
HEALTH_REPORT = GUEST / "native-overlay/usr/local/lib/try-omarchy/health-report"
UPDATE_RUNNER = GUEST / "native-overlay/usr/local/lib/try-omarchy/update-runner"
OWNED_PAYLOAD = GUEST / "native-overlay/usr/local/lib/try-omarchy/owned-payload"
BOOTSTRAP_MIGRATION = GUEST / "migrations/0000-0001-bootstrap-update-v1.sh"
YAY_MIGRATION = GUEST / "migrations/0001-0002-add-yay.sh"
HYPR_TOGGLE_MIGRATION = GUEST / "migrations/0002-0003-repair-hypr-toggle-defaults.sh"


def load_module(name: str, path: Path):
    loader = SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot import {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


prepare = load_module("prepare_update_root", PREPARE_UPDATE)


class UpdateContractTests(unittest.TestCase):
    def test_contract_writer_publishes_canonical_state_and_initramfs_environment(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "root"
            root.mkdir()
            digest = "a" * 64
            release_id = "c" * 64
            owned_payload = "d" * 64
            subprocess.run(
                [
                    str(CONTRACT_WRITER),
                    "--root",
                    str(root),
                    "--spec",
                    str(GUEST / "spec.json"),
                    "--release-id",
                    release_id,
                    "--owned-payload-sha256",
                    owned_payload,
                    "--update-sums-sha256",
                    digest,
                ],
                check=True,
            )

            state_path = root / "var/lib/try-omarchy/state.json"
            release_path = root / "usr/share/try-omarchy/update/release.json"
            environment_path = root / "usr/share/try-omarchy/update/release.env"
            state = json.loads(state_path.read_text())
            release = json.loads(release_path.read_text())
            self.assertEqual(state["guestStateSchema"], 3)
            self.assertEqual(state["bootABI"], "arm64-qemu-direct-v1")
            self.assertEqual(state["releaseId"], release_id)
            self.assertEqual(state["kind"], "try-omarchy-guest-state")
            self.assertEqual(release["kind"], "try-omarchy-release-contract")
            self.assertEqual(release["controlPort"], "dev.tryomarchy.control")
            self.assertEqual(release["ownedPayloadSha256"], owned_payload)
            self.assertEqual(
                state_path.read_text(),
                json.dumps(state, separators=(",", ":"), sort_keys=True) + "\n",
            )
            environment = environment_path.read_text()
            self.assertIn("TRY_OMARCHY_GUEST_STATE_SCHEMA=3\n", environment)
            self.assertIn(f"TRY_OMARCHY_UPDATE_SHA256SUMS={digest}\n", environment)


class UpdateRootTests(unittest.TestCase):
    @staticmethod
    def write_archive(path: Path, package: str, version: str) -> None:
        path.write_text(
            f"pkgname = {package}\npkgver = {version}\narch = aarch64\n",
            encoding="ascii",
        )

    @staticmethod
    def populate_owned_root(root: Path) -> None:
        regular_exact = set(prepare.EXACT_OWNED_PATHS)
        symlinks = {
            "/etc/fonts/conf.d/50-omarchy.conf": "/usr/share/fontconfig/conf.avail/50-omarchy.conf",
            "/etc/systemd/system/multi-user.target.wants/omarchy-native-mac-share.service": "/usr/lib/systemd/system/omarchy-native-mac-share.service",
            "/etc/systemd/system/multi-user.target.wants/try-omarchy-health.service": "/usr/lib/systemd/system/try-omarchy-health.service",
            "/etc/systemd/user/default.target.wants/omarchy-native-audio-bridge.service": "/usr/lib/systemd/user/omarchy-native-audio-bridge.service",
            "/etc/systemd/user/default.target.wants/omarchy-native-mac-share-link.service": "/usr/lib/systemd/user/omarchy-native-mac-share-link.service",
            "/etc/systemd/user/default.target.wants/try-omarchy-user-migrate.service": "/usr/lib/systemd/user/try-omarchy-user-migrate.service",
            "/etc/systemd/user/graphical-session.target.wants/omarchy-native-clipboard-bridge.service": "/usr/lib/systemd/user/omarchy-native-clipboard-bridge.service",
            "/etc/systemd/user/graphical-session.target.wants/try-omarchy-graphical-health.service": "/usr/lib/systemd/user/try-omarchy-graphical-health.service",
        }
        for relative in regular_exact:
            path = root / relative.removeprefix("/")
            path.parent.mkdir(parents=True, exist_ok=True)
            if relative in symlinks:
                path.symlink_to(symlinks[relative])
            else:
                path.write_text(f"target:{relative}\n", encoding="utf-8")

        managed_files = {
            "/etc/skel/.config/omarchy/target.conf": "target skel\n",
            "/usr/share/licenses/omarchy/LICENSE": "target license\n",
            "/usr/share/omarchy/version": "target-version\n",
            "/usr/share/omarchy/applications/icons/target.png": "target icon\n",
        }
        for source_root, _ in prepare.SOURCE_TREE_MAPPINGS:
            managed_files[f"{source_root}/target.conf"] = f"source:{source_root}\n"
        for relative, content in managed_files.items():
            path = root / relative.removeprefix("/")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        for source_root, target_root in prepare.SOURCE_TREE_MAPPINGS:
            target = root / target_root.removeprefix("/") / "target.conf"
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(f"source:{source_root}\n", encoding="utf-8")
        target_icon = root / "usr/share/icons/hicolor/256x256/apps/target.png"
        target_icon.parent.mkdir(parents=True, exist_ok=True)
        target_icon.write_text("target icon\n", encoding="utf-8")
        command = root / "usr/bin/omarchy-menu"
        command.parent.mkdir(parents=True, exist_ok=True)
        command.write_text("#!/bin/sh\necho target-command\n", encoding="ascii")
        command.chmod(0o755)
        owned_payload = root / "usr/local/lib/try-omarchy/owned-payload"
        owned_payload.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(OWNED_PAYLOAD, owned_payload)
        owned_payload.chmod(0o755)

        for overlay_name in ("factory-overlay", "native-overlay"):
            overlay = GUEST / overlay_name
            for source in overlay.rglob("*"):
                if source.is_dir():
                    continue
                relative = source.relative_to(overlay)
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)
                destination.chmod(source.stat().st_mode & 0o777)

    def test_release_identity_is_deterministic_and_binds_target_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "base-1-1-aarch64.pkg.tar.zst"
            archive.write_bytes(b"package bytes\n")
            spec = json.loads((GUEST / "spec.json").read_text())
            package_lock = {"architecture": "aarch64", "packages": {"base": "1-1"}}
            selected = {"base": ("1-1", archive)}
            payload = [
                ("f", "a" * 64, "0755", "/usr/local/lib/try-omarchy/update-runner")
            ]
            migrations = [(0, 1, "bootstrap", "b" * 64)]

            identity = prepare.compute_release_id(
                spec, package_lock, selected, payload, migrations
            )
            self.assertEqual(
                identity,
                prepare.compute_release_id(
                    spec, package_lock, selected, payload, migrations
                ),
            )
            self.assertRegex(identity, r"^[0-9a-f]{64}$")
            changed_payload = [("f", "d" * 64, payload[0][2], payload[0][3])]
            self.assertNotEqual(
                identity,
                prepare.compute_release_id(
                    spec, package_lock, selected, changed_payload, migrations
                ),
            )
            archive.write_bytes(b"different package bytes\n")
            self.assertNotEqual(
                identity,
                prepare.compute_release_id(
                    spec, package_lock, selected, payload, migrations
                ),
            )

    def test_preparer_collects_exact_package_closure_migrations_and_owned_payload(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            root = temporary_path / "root"
            cache = temporary_path / "cache"
            migrations = temporary_path / "migrations"
            destination = temporary_path / "update"
            local_repo = root / "usr/share/try-omarchy/repo"
            for directory in (cache, migrations, local_repo):
                directory.mkdir(parents=True)

            self.write_archive(cache / "base-1-1-aarch64.pkg.tar.xz", "base", "1-1")
            self.write_archive(
                cache / "linux-aarch64-7.2-2-aarch64.pkg.tar.zst",
                "linux-aarch64",
                "7.2-2",
            )
            self.write_archive(
                local_repo / "try-omarchy-runtime-4.0.0-1-any.pkg.tar.zst",
                "try-omarchy-runtime",
                "4.0.0-1",
            )
            package_lock = temporary_path / "packages.lock.json"
            package_lock.write_text(
                json.dumps(
                    {"packages": {"base": "1-1", "linux-aarch64": "7.2-2"}}
                ),
                encoding="utf-8",
            )
            migration = migrations / "0000-0001-bootstrap.sh"
            migration.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")

            self.populate_owned_root(root)
            (
                root / "usr/share/try-omarchy/packages.explicit.txt"
            ).write_text(
                "base\nlinux-aarch64\ntry-omarchy-runtime\n", encoding="ascii"
            )
            (local_repo / "try-omarchy.db").write_text("target repo database\n")
            fake_bsdtar = temporary_path / "bsdtar"
            fake_bsdtar.write_text(
                '#!/bin/sh\n[ "$1" = -xOf ] && [ "$3" = .PKGINFO ] || exit 2\ncat "$2"\n',
                encoding="ascii",
            )
            fake_bsdtar.chmod(0o755)

            subprocess.run(
                [
                    str(PREPARE_UPDATE),
                    "--root",
                    str(root),
                    "--package-cache",
                    str(cache),
                    "--package-lock",
                    str(package_lock),
                    "--migrations",
                    str(migrations),
                    "--destination",
                    str(destination),
                    "--spec",
                    str(GUEST / "spec.json"),
                    "--bsdtar",
                    str(fake_bsdtar),
                ],
                check=True,
            )

            self.assertEqual(
                (destination / "targets.txt").read_text().splitlines(),
                [
                    "base=1-1",
                    "linux-aarch64=7.2-2",
                    "try-omarchy-runtime=4.0.0-1",
                ],
            )
            self.assertEqual(
                (destination / "explicit-targets.txt").read_text().splitlines(),
                ["base", "linux-aarch64", "try-omarchy-runtime"],
            )
            metadata = json.loads((destination / "update.json").read_text())
            self.assertEqual(metadata["packageCount"], 3)
            self.assertTrue((destination / "repo/base-1-1-aarch64.pkg.tar.xz").is_file())
            catalog = (destination / "migrations/catalog.tsv").read_text().split("\t")
            self.assertEqual(catalog[:3], ["0", "1", "bootstrap"])
            self.assertEqual(
                hashlib.sha256((destination / "migrations/bootstrap.sh").read_bytes()).hexdigest(),
                catalog[3].strip(),
            )
            payload_lines = (destination / "payload.tsv").read_text().splitlines()
            self.assertGreater(len(payload_lines), len(prepare.STATIC_PAYLOAD_PATHS))
            payload_paths = set(
                (destination / "payload-paths.txt").read_text().splitlines()
            )
            for representative in (
                "/usr/share/omarchy/version",
                "/usr/bin/omarchy-menu",
                "/etc/skel/.config/omarchy/target.conf",
                "/usr/share/uwsm/env.d/10-omarchy",
                "/usr/share/try-omarchy/repo/try-omarchy.db",
                "/usr/share/try-omarchy/build-spec.json",
                "/usr/local/bin/omarchy-native-mac-share",
                "/etc/systemd/system/multi-user.target.wants/omarchy-native-mac-share.service",
                "/etc/systemd/user/default.target.wants/omarchy-native-mac-share-link.service",
            ):
                self.assertIn(representative, payload_paths)
            self.assertFalse(any(path.startswith("/home/") for path in payload_paths))
            self.assertTrue((destination / "target-state.json").is_file())
            self.assertTrue((destination / "release.json").is_file())
            release_id = json.loads(
                (destination / "target-state.json").read_text()
            )["releaseId"]
            self.assertRegex(release_id, r"^[0-9a-f]{64}$")


class BootstrapMigrationTests(unittest.TestCase):
    def test_full_owned_release_converges_without_touching_home(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            candidate = temporary_path / "candidate"
            update = temporary_path / "update"
            initramfs = temporary_path / "initramfs"
            candidate.mkdir()
            sentinel = candidate / "home/user/state.txt"
            sentinel.parent.mkdir(parents=True)
            sentinel.write_text("irreplaceable user state\n", encoding="utf-8")
            representative = {
                "/usr/share/omarchy/version": "target-version\n",
                "/usr/bin/omarchy-menu": "#!/bin/sh\necho target-command\n",
                "/etc/skel/.config/omarchy/target.conf": "target skel\n",
                "/usr/share/uwsm/env.d/10-omarchy": "target integration\n",
                "/usr/share/try-omarchy/repo/try-omarchy.db": "target repo\n",
                "/usr/share/try-omarchy/repo/try-omarchy.db.tar.gz": "target repo\n",
                "/usr/share/try-omarchy/build-spec.json": "target build metadata\n",
            }
            records = []
            for destination, content in representative.items():
                source = update / "payload/files" / destination.removeprefix("/")
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_text(content, encoding="utf-8")
                mode = "0755" if destination == "/usr/bin/omarchy-menu" else "0644"
                records.append(
                    ("f", hashlib.sha256(source.read_bytes()).hexdigest(), mode, destination)
                )
                installed = candidate / destination.removeprefix("/")
                installed.parent.mkdir(parents=True, exist_ok=True)
                installed.write_text("old release bytes\n", encoding="utf-8")
            stale_repo = candidate / "usr/share/try-omarchy/repo/obsolete.pkg.tar.zst"
            stale_repo.write_text("old archive\n", encoding="utf-8")

            update.mkdir(exist_ok=True)
            (update / "payload.tsv").write_text(
                "".join("\t".join(record) + "\n" for record in records),
                encoding="utf-8",
            )
            (update / "payload-paths.txt").write_text(
                "".join(f"{record[3]}\n" for record in records), encoding="utf-8"
            )
            (update / "managed-roots.txt").write_text(
                "/etc/skel\n/usr/share/omarchy\n/usr/share/try-omarchy/repo\n",
                encoding="ascii",
            )
            release_id = "e" * 64
            (update / "target-state.json").write_text(
                json.dumps({"releaseId": release_id}, separators=(",", ":")) + "\n",
                encoding="ascii",
            )
            (update / "release.json").write_text(
                '{"kind":"target-release"}\n', encoding="ascii"
            )
            initramfs.mkdir()
            (initramfs / "release.env").write_text("SIGNED=1\n", encoding="ascii")
            environment = os.environ.copy()
            environment["TRY_OMARCHY_INITRAMFS_ROOT"] = str(initramfs)
            environment["TRY_OMARCHY_OWNED_PAYLOAD_RUNNER"] = str(OWNED_PAYLOAD)

            for mode in ("apply", "verify", "apply", "verify"):
                subprocess.run(
                    ["/bin/sh", str(BOOTSTRAP_MIGRATION), mode, str(candidate), str(update)],
                    check=True,
                    env=environment,
                )
            for destination, content in representative.items():
                self.assertEqual(
                    (candidate / destination.removeprefix("/")).read_text(), content
                )
            self.assertEqual(
                (candidate / "usr/share/try-omarchy/update/release.env").read_text(),
                "SIGNED=1\n",
            )
            self.assertEqual(sentinel.read_text(), "irreplaceable user state\n")
            self.assertEqual(
                (candidate / "var/lib/pacman/sync/try-omarchy.db").read_text(),
                "target repo\n",
            )
            self.assertFalse(stale_repo.exists())
            preserved_stale = (
                candidate
                / f"var/lib/try-omarchy/preserved/{release_id}"
                / stale_repo.relative_to(candidate)
            )
            self.assertEqual(preserved_stale.read_text(), "old archive\n")

    def test_yay_migration_verifies_package_transaction_postconditions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidate = root / "candidate"
            update = root / "update"
            candidate.mkdir()
            update.mkdir()

            before = subprocess.run(
                ["/bin/sh", str(YAY_MIGRATION), "verify", str(candidate), str(update)],
                check=False,
            )
            self.assertNotEqual(before.returncode, 0)
            subprocess.run(
                ["/bin/sh", str(YAY_MIGRATION), "apply", str(candidate), str(update)],
                check=True,
            )

            for relative in ("usr/bin/yay", "usr/bin/fakeroot"):
                executable = candidate / relative
                executable.parent.mkdir(parents=True, exist_ok=True)
                executable.write_text("#!/bin/sh\n", encoding="ascii")
                executable.chmod(0o755)
            license_file = (
                candidate / "usr/share/licenses/try-omarchy-yay/LICENSE"
            )
            license_file.parent.mkdir(parents=True, exist_ok=True)
            license_file.write_text("GPL-3.0-or-later\n", encoding="ascii")

            for mode in ("verify", "apply", "verify"):
                subprocess.run(
                    ["/bin/sh", str(YAY_MIGRATION), mode, str(candidate), str(update)],
                    check=True,
                )

    def test_hypr_toggle_migration_verifies_deferred_repair_support(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidate = root / "candidate"
            update = root / "update"
            candidate.mkdir()
            update.mkdir()
            runner = root / "owned-payload"
            runner_log = root / "owned-payload.log"
            runner.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$1" >>"$TRY_OMARCHY_TEST_RUNNER_LOG"\n',
                encoding="ascii",
            )
            runner.chmod(0o755)
            environment = os.environ.copy()
            environment["TRY_OMARCHY_OWNED_PAYLOAD_RUNNER"] = str(runner)
            environment["TRY_OMARCHY_TEST_RUNNER_LOG"] = str(runner_log)

            before = subprocess.run(
                [
                    "/bin/sh",
                    str(HYPR_TOGGLE_MIGRATION),
                    "verify",
                    str(candidate),
                    str(update),
                ],
                check=False,
                env=environment,
            )
            self.assertNotEqual(before.returncode, 0)

            helper = candidate / "usr/local/lib/try-omarchy/user-migrate"
            manifest = (
                candidate
                / "usr/share/try-omarchy/user-migrations/0003-hypr-toggle-defaults.tsv"
            )
            service = (
                candidate
                / "usr/lib/systemd/user/try-omarchy-user-migrate.service"
            )
            for path in (helper, manifest, service):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("present\n", encoding="ascii")
            helper.chmod(0o755)
            wants = (
                candidate
                / "etc/systemd/user/default.target.wants/try-omarchy-user-migrate.service"
            )
            wants.parent.mkdir(parents=True)
            wants.symlink_to("/usr/lib/systemd/user/try-omarchy-user-migrate.service")

            for mode in ("verify", "apply", "verify"):
                subprocess.run(
                    [
                        "/bin/sh",
                        str(HYPR_TOGGLE_MIGRATION),
                        mode,
                        str(candidate),
                        str(update),
                    ],
                    check=True,
                    env=environment,
                )
            self.assertEqual(
                runner_log.read_text(encoding="ascii").splitlines(),
                ["verify", "verify", "apply", "verify"],
            )


class UpdateRunnerTests(unittest.TestCase):
    release_id = "c" * 64
    transaction = "b" * 64

    def state(self, release_id: str | None = None) -> str:
        value = {
            "bootABI": "arm64-qemu-direct-v1",
            "guestStateSchema": 1,
            "kind": "try-omarchy-guest-state",
            "protocolVersion": 1,
            "releaseId": release_id or self.release_id,
            "schemaVersion": 1,
        }
        return json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n"

    def make_fixture(self, root: Path, installed_release: str | None = None) -> tuple[Path, Path, Path, dict[str, str]]:
        candidate = root / "candidate"
        update = candidate / "run/try-omarchy-update"
        control = root / "control"
        release_env = root / "release.env"
        state_path = candidate / "var/lib/try-omarchy/state.json"
        state_path.parent.mkdir(parents=True)
        state_path.write_text(self.state(installed_release), encoding="ascii")
        (candidate / "usr/lib/modules/test-kernel").mkdir(parents=True)
        for top_level in ("etc", "home", "root"):
            (candidate / top_level).mkdir()
        update.mkdir(parents=True)
        (update / "target-state.json").write_text(self.state(), encoding="ascii")
        (update / "payload.tsv").write_bytes(b"")
        digest = hashlib.sha256((update / "target-state.json").read_bytes()).hexdigest()
        payload_digest = hashlib.sha256(b"").hexdigest()
        (update / "SHA256SUMS").write_text(
            f"{payload_digest}  payload.tsv\n{digest}  target-state.json\n",
            encoding="ascii",
        )
        sums_digest = hashlib.sha256((update / "SHA256SUMS").read_bytes()).hexdigest()
        release_env.write_text(
            "\n".join(
                [
                    "TRY_OMARCHY_BOOT_ABI=arm64-qemu-direct-v1",
                    "TRY_OMARCHY_CONTROL_PORT=dev.tryomarchy.control",
                    "TRY_OMARCHY_GUEST_STATE_SCHEMA=1",
                    f"TRY_OMARCHY_OWNED_PAYLOAD_SHA256={payload_digest}",
                    "TRY_OMARCHY_PROTOCOL_VERSION=1",
                    f"TRY_OMARCHY_RELEASE_ID={self.release_id}",
                    f"TRY_OMARCHY_UPDATE_SHA256SUMS={sums_digest}",
                    "",
                ]
            ),
            encoding="ascii",
        )
        control.touch()
        commands = root / "commands"
        commands.mkdir()
        (commands / "chroot").write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
        (commands / "owned-payload").write_text(
            "#!/bin/sh\nexit 0\n", encoding="ascii"
        )
        (commands / "uname").write_text(
            '#!/bin/sh\n[ "$1" = -r ] && printf "test-kernel\\n"\n', encoding="ascii"
        )
        for command in commands.iterdir():
            command.chmod(0o755)
        environment = os.environ.copy()
        environment["PATH"] = f"{commands}:{environment['PATH']}"
        environment["TRY_OMARCHY_OWNED_PAYLOAD_RUNNER"] = str(
            commands / "owned-payload"
        )
        environment["TRY_OMARCHY_RELEASE_ENV"] = str(release_env)
        return candidate, update, control, environment

    def test_completed_candidate_resumes_idempotently(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            candidate, update, control, environment = self.make_fixture(Path(temporary))
            subprocess.run(
                [
                    "/bin/sh",
                    str(UPDATE_RUNNER),
                    str(candidate),
                    str(update),
                    self.transaction,
                    str(control),
                ],
                check=True,
                env=environment,
            )
            self.assertEqual(
                json.loads(control.read_text()),
                {
                    "bootABI": "arm64-qemu-direct-v1",
                    "fromGuestStateSchema": 1,
                    "guestStateSchema": 1,
                    "protocolVersion": 1,
                    "status": "complete",
                    "transaction": self.transaction,
                    "type": "update",
                },
            )

    def test_same_schema_with_different_release_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            candidate, update, control, environment = self.make_fixture(
                Path(temporary), installed_release="1" * 64
            )
            result = subprocess.run(
                [
                    "/bin/sh",
                    str(UPDATE_RUNNER),
                    str(candidate),
                    str(update),
                    self.transaction,
                    str(control),
                ],
                check=False,
                env=environment,
            )
            self.assertEqual(result.returncode, 1)
            message = json.loads(control.read_text())
            self.assertEqual(message["status"], "failed")
            self.assertEqual(message["errorCode"], "release-schema-not-advanced")
            self.assertEqual(message["fromGuestStateSchema"], 1)


class HealthReportTests(unittest.TestCase):
    def test_transaction_health_echoes_nonce_and_requests_no_test_poweroff(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            contract_root = root / "guest"
            contract_root.mkdir()
            release_id = "c" * 64
            subprocess.run(
                [
                    str(CONTRACT_WRITER),
                    "--root",
                    str(contract_root),
                    "--spec",
                    str(GUEST / "spec.json"),
                    "--release-id",
                    release_id,
                    "--owned-payload-sha256",
                    hashlib.sha256(b"").hexdigest(),
                ],
                check=True,
            )
            (
                contract_root / "usr/share/try-omarchy/update/payload.tsv"
            ).write_bytes(b"")
            required = [
                "usr/local/bin/omarchy-native-audio-bridge",
                "usr/local/bin/omarchy-native-clipboard-bridge",
                "usr/local/bin/omarchy-native-display-sync",
                "usr/local/bin/omarchy-native-mac-share",
                "usr/local/lib/try-omarchy/owned-payload",
                "usr/local/lib/try-omarchy/user-migrate",
                "usr/share/try-omarchy/user-migrations/0003-hypr-toggle-defaults.tsv",
                "usr/lib/systemd/system/omarchy-native-mac-share.service",
                "usr/lib/systemd/system/try-omarchy-health.service",
                "usr/lib/systemd/user/omarchy-native-audio-bridge.service",
                "usr/lib/systemd/user/omarchy-native-clipboard-bridge.service",
                "usr/lib/systemd/user/omarchy-native-mac-share-link.service",
                "usr/lib/systemd/user/try-omarchy-graphical-health.service",
                "usr/lib/systemd/user/try-omarchy-user-migrate.service",
            ]
            for relative in required:
                path = contract_root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("present\n", encoding="ascii")
            (contract_root / "usr/lib/modules/test-kernel").mkdir(parents=True)
            cmdline = root / "cmdline"
            cmdline.write_text(
                f"root=/dev/vda tryomarchy.transaction={UpdateRunnerTests.transaction}\n",
                encoding="ascii",
            )
            control = root / "control"
            control.touch()
            environment = os.environ.copy()
            environment.update(
                {
                    "TRY_OMARCHY_CMDLINE_PATH": str(cmdline),
                    "TRY_OMARCHY_CONTROL_PATH": str(control),
                    "TRY_OMARCHY_HEALTH_ROOT": str(contract_root),
                    "TRY_OMARCHY_KERNEL_RELEASE": "test-kernel",
                    "TRY_OMARCHY_RELEASE_PATH": str(
                        contract_root / "usr/share/try-omarchy/update/release.json"
                    ),
                    "TRY_OMARCHY_SKIP_POWEROFF": "1",
                    "TRY_OMARCHY_STATE_PATH": str(
                        contract_root / "var/lib/try-omarchy/state.json"
                    ),
                }
            )
            subprocess.run([str(HEALTH_REPORT)], check=True, env=environment)
            message = json.loads(control.read_text())
            self.assertEqual(message["status"], "ready")
            self.assertEqual(message["readiness"], "system")
            self.assertEqual(message["transaction"], UpdateRunnerTests.transaction)
            self.assertEqual(message["guestStateSchema"], 3)
            self.assertEqual(message["bootABI"], "arm64-qemu-direct-v1")

    def test_normal_health_requires_live_graphical_session_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            contract_root = root / "guest"
            contract_root.mkdir()
            release_id = "c" * 64
            subprocess.run(
                [
                    str(CONTRACT_WRITER),
                    "--root",
                    str(contract_root),
                    "--spec",
                    str(GUEST / "spec.json"),
                    "--release-id",
                    release_id,
                    "--owned-payload-sha256",
                    hashlib.sha256(b"").hexdigest(),
                ],
                check=True,
            )
            (
                contract_root / "usr/share/try-omarchy/update/payload.tsv"
            ).write_bytes(b"")
            required = [
                "usr/local/bin/omarchy-native-audio-bridge",
                "usr/local/bin/omarchy-native-clipboard-bridge",
                "usr/local/bin/omarchy-native-display-sync",
                "usr/local/bin/omarchy-native-mac-share",
                "usr/local/lib/try-omarchy/owned-payload",
                "usr/local/lib/try-omarchy/user-migrate",
                "usr/share/try-omarchy/user-migrations/0003-hypr-toggle-defaults.tsv",
                "usr/lib/systemd/system/omarchy-native-mac-share.service",
                "usr/lib/systemd/system/try-omarchy-health.service",
                "usr/lib/systemd/user/omarchy-native-audio-bridge.service",
                "usr/lib/systemd/user/omarchy-native-clipboard-bridge.service",
                "usr/lib/systemd/user/omarchy-native-mac-share-link.service",
                "usr/lib/systemd/user/try-omarchy-graphical-health.service",
                "usr/lib/systemd/user/try-omarchy-user-migrate.service",
            ]
            for relative in required:
                path = contract_root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("present\n", encoding="ascii")
            (contract_root / "usr/lib/modules/test-kernel").mkdir(parents=True)

            cmdline = root / "cmdline"
            cmdline.write_text("root=/dev/vda rw\n", encoding="ascii")
            control = root / "control"
            control.touch()
            boot_id = root / "boot-id"
            boot_id.write_text(
                "12345678-1234-1234-1234-123456789abc\n", encoding="ascii"
            )
            run_user_root = root / "run-user"
            runtime = run_user_root / str(os.getuid())
            runtime.mkdir(parents=True, mode=0o700)
            runtime.chmod(0o700)
            hyprctl = root / "hyprctl"
            hyprctl.write_text(
                '#!/bin/sh\n[ "$1 $2" = "-j monitors" ] || exit 2\n'
                "printf '[{\"name\":\"Virtual-1\"}]\\n'\n",
                encoding="ascii",
            )
            hyprctl.chmod(0o755)

            environment = os.environ.copy()
            environment.update(
                {
                    "TRY_OMARCHY_BOOT_ID_PATH": str(boot_id),
                    "TRY_OMARCHY_CMDLINE_PATH": str(cmdline),
                    "TRY_OMARCHY_CONTROL_PATH": str(control),
                    "TRY_OMARCHY_GRAPHICAL_WAIT_SECONDS": "0",
                    "TRY_OMARCHY_HEALTH_ROOT": str(contract_root),
                    "TRY_OMARCHY_HYPRCTL": str(hyprctl),
                    "TRY_OMARCHY_KERNEL_RELEASE": "test-kernel",
                    "TRY_OMARCHY_RELEASE_PATH": str(
                        contract_root / "usr/share/try-omarchy/update/release.json"
                    ),
                    "TRY_OMARCHY_RUN_USER_ROOT": str(run_user_root),
                    "TRY_OMARCHY_STATE_PATH": str(
                        contract_root / "var/lib/try-omarchy/state.json"
                    ),
                    "WAYLAND_DISPLAY": "wayland-1",
                    "XDG_RUNTIME_DIR": str(runtime),
                }
            )

            missing = subprocess.run(
                [str(HEALTH_REPORT), "--report"],
                check=False,
                env=environment,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            self.assertNotEqual(missing.returncode, 0)
            self.assertEqual(control.read_bytes(), b"")

            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as wayland:
                wayland.bind(str(runtime / "wayland-1"))
                subprocess.run(
                    [str(HEALTH_REPORT), "--mark-graphical-ready"],
                    check=True,
                    env=environment,
                )

            subprocess.run(
                [str(HEALTH_REPORT), "--report"], check=True, env=environment
            )
            message = json.loads(control.read_text())
            self.assertEqual(message["status"], "ready")
            self.assertEqual(message["readiness"], "graphical")
            self.assertNotIn("transaction", message)


if __name__ == "__main__":
    unittest.main()
