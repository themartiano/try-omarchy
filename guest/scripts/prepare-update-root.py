#!/usr/bin/env python3
"""Assemble the deterministic file tree for the offline guest update disk."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from update_contract import canonical_json, load_release_fields, write_contract


PACKAGE_NAME = re.compile(r"[a-z0-9@._+-]+")
PACKAGE_VERSION = re.compile(r"[^/\x00\r\n\t ]+")
MIGRATION_NAME = re.compile(r"([0-9]{4})-([0-9]{4})-([a-z0-9-]+)\.sh")
STATIC_PAYLOAD_PATHS = (
    "/etc/mkinitcpio.conf.d/90-try-omarchy.conf",
    "/etc/udev/rules.d/93-try-omarchy-control.rules",
    "/usr/lib/initcpio/hooks/try-omarchy-update",
    "/usr/lib/initcpio/install/try-omarchy-update",
    "/usr/lib/systemd/system/try-omarchy-health.service",
    "/usr/local/lib/try-omarchy/health-report",
    "/usr/local/lib/try-omarchy/owned-payload",
    "/usr/local/lib/try-omarchy/update-runner",
)
MANAGED_TREE_ROOTS = (
    "/etc/skel",
    "/usr/share/licenses/omarchy",
    "/usr/share/omarchy",
    "/usr/share/try-omarchy/repo",
)
EXACT_OWNED_PATHS = (
    "/etc/fastfetch/config.jsonc",
    "/etc/fonts/conf.d/50-omarchy.conf",
    "/etc/profile.d/omarchy.sh",
    "/etc/systemd/system.conf.d/10-faster-shutdown.conf",
    "/etc/systemd/system/multi-user.target.wants/omarchy-native-mac-share.service",
    "/etc/systemd/system/multi-user.target.wants/try-omarchy-health.service",
    "/etc/systemd/system/omarchy-provision-owner.service",
    "/etc/systemd/user/default.target.wants/omarchy-native-audio-bridge.service",
    "/etc/systemd/user/default.target.wants/omarchy-native-mac-share-link.service",
    "/etc/systemd/user/graphical-session.target.wants/omarchy-native-clipboard-bridge.service",
    "/etc/systemd/user/graphical-session.target.wants/try-omarchy-graphical-health.service",
    "/usr/local/bin/ttfx",
    "/usr/local/share/wayland-sessions/omarchy.desktop",
    "/usr/share/applications/mimeapps.list",
    "/usr/share/fontconfig/conf.avail/50-omarchy.conf",
    "/usr/share/fonts/omarchy/omarchy.ttf",
    "/usr/share/icons/hicolor/256x256/apps/omarchy.png",
    "/usr/share/pixmaps/omarchy.png",
    "/usr/share/try-omarchy/build-spec.json",
    "/usr/share/try-omarchy/packages.explicit.txt",
    "/usr/share/try-omarchy/packages.lock.txt",
    "/usr/share/try-omarchy/provenance.json",
    "/usr/share/try-omarchy/upstream-tree.json",
    "/usr/share/uwsm/env.d/10-omarchy",
)
SOURCE_TREE_MAPPINGS = (
    ("/usr/share/omarchy/default/environment.d", "/usr/lib/environment.d"),
    ("/usr/share/omarchy/default/systemd/user", "/usr/lib/systemd/user"),
    (
        "/usr/share/omarchy/default/systemd/user@.service.d",
        "/usr/lib/systemd/system/user@.service.d",
    ),
    (
        "/usr/share/omarchy/default/systemd/zram-generator.conf.d",
        "/usr/lib/systemd/zram-generator.conf.d",
    ),
    (
        "/usr/share/omarchy/default/xdg-terminal-exec",
        "/usr/share/xdg-terminal-exec",
    ),
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def parse_pkginfo(archive: Path, bsdtar: str) -> tuple[str, str, str]:
    result = subprocess.run(
        [bsdtar, "-xOf", str(archive), ".PKGINFO"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    fields: dict[str, list[str]] = {}
    for line in result.stdout.splitlines():
        name, separator, value = line.partition(" = ")
        if separator:
            fields.setdefault(name, []).append(value)
    values = []
    for name in ("pkgname", "pkgver", "arch"):
        records = fields.get(name, [])
        if len(records) != 1:
            raise ValueError(f"{archive} has no unique {name}")
        values.append(records[0])
    package, version, architecture = values
    if PACKAGE_NAME.fullmatch(package) is None:
        raise ValueError(f"{archive} has unsafe package name {package!r}")
    if PACKAGE_VERSION.fullmatch(version) is None:
        raise ValueError(f"{archive} has unsafe package version {version!r}")
    if architecture not in {"aarch64", "any"}:
        raise ValueError(f"{archive} has incompatible package architecture {architecture!r}")
    return package, version, architecture


def copy_regular(source: Path, destination: Path, mode: int | None = None) -> None:
    if not source.is_file() or source.is_symlink():
        raise ValueError(f"source is not a direct regular file: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with source.open("rb") as reader, destination.open("xb") as writer:
        shutil.copyfileobj(reader, writer, length=1024 * 1024)
    destination.chmod(mode if mode is not None else stat.S_IMODE(source.stat().st_mode))


def select_archives(
    package_cache: Path,
    local_repository: Path,
    package_lock: dict[str, str],
    bsdtar: str,
) -> dict[str, tuple[str, Path]]:
    # Arch Linux ARM currently publishes .pkg.tar.xz while Try Omarchy's local
    # packages use .pkg.tar.zst. Both are valid pacman package archives.
    candidates = sorted(package_cache.glob("*.pkg.tar.zst"))
    candidates.extend(sorted(package_cache.glob("*.pkg.tar.xz")))
    local_archives = sorted(local_repository.glob("*.pkg.tar.zst"))
    local_archives.extend(sorted(local_repository.glob("*.pkg.tar.xz")))
    candidates.extend(local_archives)
    if not candidates:
        raise ValueError("no package archives were found")

    indexed: dict[tuple[str, str], list[Path]] = {}
    local_targets: dict[str, tuple[str, Path]] = {}
    local_set = set(local_archives)
    for archive in candidates:
        package, version, _ = parse_pkginfo(archive, bsdtar)
        indexed.setdefault((package, version), []).append(archive)
        if archive in local_set:
            if package in local_targets:
                raise ValueError(f"duplicate custom package {package}")
            local_targets[package] = (version, archive)

    desired = dict(package_lock)
    for package, (version, _) in local_targets.items():
        if package in desired and desired[package] != version:
            raise ValueError(f"custom package {package} conflicts with the package lock")
        desired[package] = version
    if "linux-aarch64" not in desired:
        raise ValueError("offline target does not include linux-aarch64")

    selected: dict[str, tuple[str, Path]] = {}
    for package, version in sorted(desired.items()):
        matches = indexed.get((package, version), [])
        if not matches:
            raise ValueError(f"package cache lacks {package}={version}")
        digests = {sha256(path) for path in matches}
        if len(digests) != 1:
            raise ValueError(f"package cache has conflicting archives for {package}={version}")
        selected[package] = (version, min(matches))
    return selected


def tree_entries(root: Path, relative_root: str) -> list[str]:
    source_root = root / relative_root.removeprefix("/")
    if not source_root.is_dir() or source_root.is_symlink():
        raise ValueError(f"owned tree is missing or unsafe: {relative_root}")
    entries: list[str] = []
    for source in sorted(source_root.rglob("*")):
        if source.is_dir() and not source.is_symlink():
            continue
        if not source.is_file() and not source.is_symlink():
            raise ValueError(f"owned tree has an unsupported entry: {source}")
        relative = source.relative_to(root).as_posix()
        if "\t" in relative or "\n" in relative:
            raise ValueError(f"owned path cannot be represented safely: {source}")
        entries.append("/" + relative)
    return entries


def mapped_tree_entries(root: Path, source_root: str, target_root: str) -> list[str]:
    source = root / source_root.removeprefix("/")
    if not source.is_dir() or source.is_symlink():
        raise ValueError(f"Omarchy source integration tree is missing: {source_root}")
    targets: list[str] = []
    for entry in sorted(source.rglob("*")):
        if entry.is_dir() and not entry.is_symlink():
            continue
        relative = entry.relative_to(source).as_posix()
        target = f"{target_root.rstrip('/')}/{relative}"
        installed = root / target.removeprefix("/")
        if not installed.is_file() and not installed.is_symlink():
            raise ValueError(f"materialized Omarchy integration is missing: {target}")
        targets.append(target)
    return targets


def collect_owned_paths(root: Path) -> list[str]:
    """Enumerate only release-owned paths; /home and mutable machine state are excluded."""

    paths = set(STATIC_PAYLOAD_PATHS)
    for managed_root in MANAGED_TREE_ROOTS:
        paths.update(tree_entries(root, managed_root))
    for overlay_name in ("factory-overlay", "native-overlay"):
        overlay = SCRIPT_DIR.parent / overlay_name
        for source in sorted(overlay.rglob("*")):
            if source.is_dir() and not source.is_symlink():
                continue
            if "__pycache__" in source.parts or source.suffix == ".pyc":
                raise ValueError(f"generated Python cache entered an overlay: {source}")
            relative = "/" + source.relative_to(overlay).as_posix()
            installed = root / relative.removeprefix("/")
            if not installed.is_file() and not installed.is_symlink():
                raise ValueError(f"configured overlay path is missing: {relative}")
            paths.add(relative)
    for relative in EXACT_OWNED_PATHS:
        installed = root / relative.removeprefix("/")
        # upstream-tree.json is intentionally absent only in source-fixture builds.
        if relative == "/usr/share/try-omarchy/upstream-tree.json" and not installed.exists():
            continue
        if not installed.is_file() and not installed.is_symlink():
            raise ValueError(f"release-owned path is missing: {relative}")
        paths.add(relative)
    for source_root, target_root in SOURCE_TREE_MAPPINGS:
        paths.update(mapped_tree_entries(root, source_root, target_root))

    for command in sorted((root / "usr/bin").glob("omarchy*")):
        if command.is_file() or command.is_symlink():
            paths.add("/" + command.relative_to(root).as_posix())

    icons = root / "usr/share/omarchy/applications/icons"
    if not icons.is_dir() or icons.is_symlink():
        raise ValueError("Omarchy application icons are missing")
    for icon in sorted(icons.iterdir()):
        if not icon.is_file() or icon.is_symlink():
            continue
        relative = f"/usr/share/icons/hicolor/256x256/apps/{icon.name}"
        if not (root / relative.removeprefix("/")).is_file():
            raise ValueError(f"materialized Omarchy icon is missing: {relative}")
        paths.add(relative)

    for relative in paths:
        if not relative.startswith(("/etc/", "/usr/")) or "/../" in f"{relative}/":
            raise ValueError(f"release-owned path escapes its policy: {relative}")
        if "\t" in relative or "\n" in relative:
            raise ValueError(f"release-owned path cannot be represented: {relative}")
    return sorted(paths)


def stage_owned_payload(
    root: Path, destination: Path, paths: list[str]
) -> list[tuple[str, str, str, str]]:
    records: list[tuple[str, str, str, str]] = []
    for relative in paths:
        source = root / relative.removeprefix("/")
        if source.is_symlink():
            target = os.readlink(source)
            if not target or "\t" in target or "\n" in target:
                raise ValueError(f"owned symlink has an unsafe target: {relative}")
            records.append(("l", target, "-", relative))
            continue
        mode = stat.S_IMODE(source.stat().st_mode)
        payload = destination / "payload/files" / relative.removeprefix("/")
        copy_regular(source, payload, mode)
        records.append(("f", sha256(payload), f"0{mode:o}", relative))
    return records


def compute_release_id(
    spec: dict[str, object],
    package_lock: dict[str, object],
    selected: dict[str, tuple[str, Path]],
    payload_records: list[tuple[str, str, str, str]],
    migration_records: list[tuple[int, int, str, str]],
    managed_roots: tuple[str, ...] = MANAGED_TREE_ROOTS,
) -> str:
    """Hash every reviewed pre-image input that can change the offline target."""

    package_records = []
    for package, (version, archive) in sorted(selected.items()):
        signature = archive.with_name(archive.name + ".sig")
        package_records.append(
            {
                "archive": archive.name,
                "archiveSha256": sha256(archive),
                "name": package,
                "signatureSha256": sha256(signature) if signature.is_file() else None,
                "version": version,
            }
        )
    upstream = spec.get("upstream")
    if not isinstance(upstream, dict):
        raise ValueError("spec has no upstream identity")
    normalized_upstream = {
        name: upstream.get(name) for name in ("commit", "tree", "treeSha256")
    }
    if any(not isinstance(value, str) or not value for value in normalized_upstream.values()):
        raise ValueError("spec has an incomplete normalized upstream identity")

    preimage = {
        "format": "try-omarchy-release-id-v1",
        "migrations": [
            {
                "fromGuestStateSchema": start,
                "id": identifier,
                "sha256": digest,
                "toGuestStateSchema": end,
            }
            for start, end, identifier, digest in migration_records
        ],
        "managedRoots": list(managed_roots),
        "normalizedUpstreamTree": normalized_upstream,
        "packageLock": package_lock,
        "packages": package_records,
        "payload": [
            {"identity": identity, "kind": kind, "mode": mode, "path": path}
            for kind, identity, mode, path in payload_records
        ],
        "spec": spec,
    }
    return hashlib.sha256(canonical_json(preimage)).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--package-cache", required=True, type=Path)
    parser.add_argument("--package-lock", required=True, type=Path)
    parser.add_argument("--migrations", required=True, type=Path)
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("--spec", required=True, type=Path)
    parser.add_argument("--bsdtar", default="bsdtar")
    args = parser.parse_args()

    for path, label in (
        (args.root, "--root"),
        (args.package_cache, "--package-cache"),
        (args.migrations, "--migrations"),
    ):
        if not path.is_absolute() or not path.is_dir():
            raise SystemExit(f"{label} must be an absolute directory")
    if not args.destination.is_absolute():
        raise SystemExit("--destination must be absolute")
    if args.destination.exists() and any(args.destination.iterdir()):
        raise SystemExit("--destination must be empty")
    args.destination.mkdir(parents=True, exist_ok=True)

    package_lock_value = json.loads(args.package_lock.read_text(encoding="utf-8"))
    packages = package_lock_value.get("packages")
    if not isinstance(packages, dict) or not packages:
        raise SystemExit("package lock has no package mapping")
    if any(
        not isinstance(name, str)
        or PACKAGE_NAME.fullmatch(name) is None
        or not isinstance(version, str)
        or PACKAGE_VERSION.fullmatch(version) is None
        for name, version in packages.items()
    ):
        raise SystemExit("package lock contains an unsafe package record")
    try:
        spec, update = load_release_fields(args.spec)
    except ValueError as error:
        raise SystemExit(str(error)) from error

    local_repository = args.root / "usr/share/try-omarchy/repo"
    selected = select_archives(
        args.package_cache, local_repository, packages, args.bsdtar
    )
    repository = args.destination / "repo"
    repository.mkdir()
    for package, (_, archive) in selected.items():
        destination = repository / archive.name
        copy_regular(archive, destination, 0o644)
        signature = archive.with_name(archive.name + ".sig")
        if signature.exists():
            copy_regular(signature, destination.with_name(destination.name + ".sig"), 0o644)

    targets = "".join(
        f"{package}={version}\n"
        for package, (version, _) in sorted(selected.items())
    )
    (args.destination / "targets.txt").write_text(targets, encoding="ascii")
    explicit_source = args.root / "usr/share/try-omarchy/packages.explicit.txt"
    explicit_packages = explicit_source.read_text(encoding="ascii").splitlines()
    if (
        not explicit_packages
        or explicit_packages != sorted(set(explicit_packages))
        or any(
            PACKAGE_NAME.fullmatch(package) is None or package not in selected
            for package in explicit_packages
        )
    ):
        raise ValueError("target explicit-package inventory is invalid")
    (args.destination / "explicit-targets.txt").write_text(
        "".join(f"{package}\n" for package in explicit_packages), encoding="ascii"
    )
    (args.destination / "empty-hooks").mkdir()
    (args.destination / "pacman.conf").write_text(
        """[options]
Architecture = aarch64
CheckSpace
ParallelDownloads = 1
SigLevel = Optional TrustAll
LocalFileSigLevel = Optional
HookDir = /run/try-omarchy-update/empty-hooks

[try-omarchy-update]
SigLevel = Optional TrustAll
Server = file:///run/try-omarchy-update/repo
""",
        encoding="ascii",
    )

    migrations_destination = args.destination / "migrations"
    migrations_destination.mkdir()
    catalog: list[tuple[int, int, str, str]] = []
    for source in sorted(args.migrations.iterdir()):
        match = MIGRATION_NAME.fullmatch(source.name)
        if match is None:
            raise ValueError(f"unexpected migration filename: {source.name}")
        start = int(match.group(1))
        end = int(match.group(2))
        identifier = match.group(3)
        if end <= start:
            raise ValueError(f"migration does not advance state: {source.name}")
        destination = migrations_destination / f"{identifier}.sh"
        copy_regular(source, destination, 0o644)
        catalog.append((start, end, identifier, sha256(destination)))
    if not catalog:
        raise ValueError("update contains no migrations")
    (migrations_destination / "catalog.tsv").write_text(
        "".join(f"{start}\t{end}\t{name}\t{digest}\n" for start, end, name, digest in catalog),
        encoding="ascii",
    )

    owned_paths = collect_owned_paths(args.root)
    payload_records = stage_owned_payload(args.root, args.destination, owned_paths)
    payload_manifest = args.destination / "payload.tsv"
    payload_manifest.write_text(
        "".join(
            f"{kind}\t{identity}\t{mode}\t{relative}\n"
            for kind, identity, mode, relative in payload_records
        ),
        encoding="utf-8",
    )
    payload_paths = args.destination / "payload-paths.txt"
    payload_paths.write_text("".join(f"{path}\n" for path in owned_paths), encoding="utf-8")
    managed_roots = args.destination / "managed-roots.txt"
    managed_roots.write_text(
        "".join(f"{path}\n" for path in MANAGED_TREE_ROOTS), encoding="ascii"
    )
    owned_payload_sha = sha256(payload_manifest)

    release_id = compute_release_id(
        spec,
        package_lock_value,
        selected,
        payload_records,
        catalog,
    )
    write_contract(
        args.root,
        args.spec,
        release_id,
        owned_payload_sha,
    )
    copy_regular(
        args.root / "usr/share/try-omarchy/update/release.json",
        args.destination / "release.json",
        0o644,
    )
    copy_regular(
        args.root / "var/lib/try-omarchy/state.json",
        args.destination / "target-state.json",
        0o644,
    )
    installed_update = args.root / "usr/share/try-omarchy/update"
    copy_regular(payload_manifest, installed_update / "payload.tsv", 0o644)
    copy_regular(payload_paths, installed_update / "payload-paths.txt", 0o644)
    copy_regular(managed_roots, installed_update / "managed-roots.txt", 0o644)

    metadata = {
        "bootABI": update["bootABI"],
        "guestStateSchema": update["guestStateSchema"],
        "kind": "try-omarchy-offline-update",
        "packageCount": len(selected),
        "protocolVersion": update["protocolVersion"],
        "releaseId": release_id,
        "schemaVersion": 1,
    }
    (args.destination / "update.json").write_text(
        json.dumps(metadata, separators=(",", ":"), sort_keys=True) + "\n",
        encoding="ascii",
    )


if __name__ == "__main__":
    main()
