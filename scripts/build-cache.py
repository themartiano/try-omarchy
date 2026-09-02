#!/usr/bin/env python3
"""Run expensive project builds only when their effective inputs changed."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
from typing import Any


SCHEMA_VERSION = 2
GUEST_ARTIFACTS = {
    "LICENSE.omarchy",
    "build-spec.json",
    "initramfs-linux.img",
    "packages.lock.txt",
    "provenance.json",
    "rootfs.ext4",
    "rootfs.ext4.zst",
    "vmlinuz-linux",
}
GUEST_FILES = GUEST_ARTIFACTS | {"guest-manifest.json", "SHA256SUMS"}


def read_runtime_manifest(path: Path) -> frozenset[str]:
    try:
        entries = path.read_text(encoding="ascii").splitlines()
    except (OSError, UnicodeError) as error:
        raise RuntimeError(f"cannot read runtime file manifest: {error}") from error
    if not entries:
        raise RuntimeError("runtime file manifest is empty")
    if len(entries) != len(set(entries)):
        raise RuntimeError("runtime file manifest contains duplicate paths")
    for entry in entries:
        if re.fullmatch(r"(?:bin|lib)/[A-Za-z0-9][A-Za-z0-9._+-]*", entry) is None:
            raise RuntimeError(f"runtime file manifest contains an unsafe path: {entry!r}")
    return frozenset(entries)


RUNTIME_FILES = read_runtime_manifest(
    Path(__file__).resolve().parents[1] / "macos/runtime-files.txt"
)


class CacheError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def regular_files(
    root: Path, excluded_directories: set[str] | None = None
) -> list[Path]:
    excluded_directories = excluded_directories or set()
    result: list[Path] = []
    for current_text, directory_names, file_names in os.walk(root, followlinks=False):
        current = Path(current_text)
        kept_directories: list[str] = []
        for name in sorted(directory_names):
            path = current / name
            relative = path.relative_to(root)
            if relative.parts[0] in excluded_directories or name == "__pycache__":
                continue
            if path.is_symlink():
                result.append(path)
            else:
                kept_directories.append(name)
        directory_names[:] = kept_directories
        for name in sorted(file_names):
            path = current / name
            if (
                path.relative_to(root).parts[0] not in excluded_directories
                and path.suffix not in {".pyc", ".pyo"}
            ):
                result.append(path)
    return sorted(result)


def component_files(root: Path, component: str) -> list[Path]:
    if component == "guest":
        guest = root / "guest"
        return [
            path
            for path in regular_files(guest, {".work", "tests"})
            if path.relative_to(guest).as_posix() not in {"README.md", "test"}
        ]

    if component == "runtime":
        paths = [
            root / "macos/build-qemu-gpu-runtime.sh",
            root / "macos/bundle-macho-dependencies.sh",
            root / "macos/pinned-runtime-bottles.sh",
            root / "macos/prepare-qemu-gpu-runtime.sh",
            root / "macos/qemu-hvf.entitlements",
            root / "macos/runtime-files.txt",
            root / "macos/verify-macos-compatibility.sh",
        ]
        paths.extend(regular_files(root / "macos/patches"))
        return sorted(paths)

    if component == "app":
        macos = root / "macos"
        excluded_names = {
            "README.md",
            "build-qemu-gpu-runtime.sh",
            "dmg-layout.applescript",
            "package-dmg.sh",
            "prepare-qemu-gpu-runtime.sh",
        }
        paths = [
            path
            for path in regular_files(macos, {".build", ".swiftpm", "Tests", "patches"})
            if path.relative_to(macos).as_posix() not in excluded_names
        ]
        paths.extend(
            [
                root / ".build/state/guest.json",
                root / ".build/state/runtime.json",
                root / "dist/guest/guest-manifest.json",
                root / "dist/guest/SHA256SUMS",
            ]
        )
        return sorted(paths)

    raise CacheError(f"unknown component: {component}")


def command_output(argv: list[str]) -> str:
    try:
        result = subprocess.run(
            argv,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return f"<unavailable: {error}>"
    return f"exit={result.returncode}\n{result.stdout.strip()}"


def app_external_files(root: Path) -> list[Path]:
    runtime = root / "macos/.build/qemu-gpu-runtime"
    return [runtime / relative for relative in sorted(RUNTIME_FILES)]


def context(component: str) -> dict[str, str]:
    values = {
        "architecture": command_output(["uname", "-m"]),
        "macOS": command_output(["sw_vers", "-productVersion"]),
    }
    if component == "runtime":
        values.update(
            {
                "clang": command_output(["xcrun", "clang", "--version"]),
                "pkg-config": command_output(["pkg-config", "--version"]),
            }
        )
    elif component == "app":
        values.update({"swift": command_output(["swift", "--version"])})
    environment_names = {
        "runtime": {
            "CC",
            "CFLAGS",
            "CXX",
            "CXXFLAGS",
            "CPPFLAGS",
            "DEVELOPER_DIR",
            "LDFLAGS",
            "OBJCFLAGS",
            "SDKROOT",
        },
        "app": {
            "DEVELOPER_DIR",
            "OMARCHY_CODESIGN_IDENTITY",
            "SDKROOT",
            "SWIFTFLAGS",
        },
    }
    for name in sorted(environment_names.get(component, set())):
        values[f"environment:{name}"] = os.environ.get(name, "")
    return values


def normalized_command(root: Path, command: list[str]) -> list[str]:
    root_text = str(root)
    return [argument.replace(root_text, "<ROOT>") for argument in command]


def fingerprint(root: Path, component: str, command: list[str]) -> str:
    digest = hashlib.sha256()
    digest.update(f"try-omarchy-build-cache-v{SCHEMA_VERSION}\0{component}\0".encode())
    digest.update(
        json.dumps(normalized_command(root, command), separators=(",", ":")).encode()
    )
    digest.update(
        json.dumps(context(component), sort_keys=True, separators=(",", ":")).encode()
    )

    paths = component_files(root, component)
    if component == "app":
        paths.extend(app_external_files(root))
    paths.append(Path(__file__).resolve())

    seen: set[str] = set()
    for path in sorted(paths, key=lambda item: str(item)):
        resolved_label = (
            str(path.relative_to(root)) if path.is_relative_to(root) else str(path)
        )
        if resolved_label in seen:
            continue
        seen.add(resolved_label)
        if not path.exists() and not path.is_symlink():
            raise CacheError(f"build input is missing: {resolved_label}")
        metadata = path.lstat()
        digest.update(b"input\0" + resolved_label.encode() + b"\0")
        digest.update(f"{stat.S_IMODE(metadata.st_mode):o}\0".encode())
        if path.is_symlink():
            digest.update(b"symlink\0" + os.readlink(path).encode() + b"\0")
        elif path.is_file():
            digest.update(b"file\0" + sha256_file(path).encode() + b"\0")
        else:
            raise CacheError(
                f"build input is not a regular file or symlink: {resolved_label}"
            )
    return digest.hexdigest()


def direct_file_set(directory: Path) -> set[str]:
    result: set[str] = set()
    for path in directory.iterdir():
        if path.is_file() and not path.is_symlink():
            result.add(path.name)
        else:
            raise CacheError(f"unexpected non-file build artifact: {path}")
    return result


def guest_snapshot(directory: Path) -> dict[str, dict[str, int]]:
    return {
        name: {
            "bytes": (directory / name).stat().st_size,
            "ctimeNs": (directory / name).stat().st_ctime_ns,
            "mtimeNs": (directory / name).stat().st_mtime_ns,
        }
        for name in sorted(GUEST_FILES)
    }


def validate_guest(root: Path, previous: dict[str, Any] | None) -> dict[str, Any]:
    directory = root / "dist/guest"
    if not directory.is_dir() or directory.is_symlink():
        raise CacheError("guest artifact directory is missing or unsafe")
    if direct_file_set(directory) != GUEST_FILES:
        raise CacheError("guest artifact directory has a missing or unexpected file")

    manifest_path = directory / "guest-manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text())
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise CacheError(f"guest manifest is unreadable: {error}") from error
    if not isinstance(manifest, dict):
        raise CacheError("guest manifest is not an object")
    if (
        manifest.get("schemaVersion") != 1
        or manifest.get("kind") != "try-omarchy-guest-artifacts"
    ):
        raise CacheError("guest manifest identity is invalid")
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list):
        raise CacheError("guest manifest artifacts are invalid")

    manifest_records: dict[str, dict[str, Any]] = {}
    for record in artifacts:
        if not isinstance(record, dict) or not isinstance(record.get("path"), str):
            raise CacheError("guest manifest contains an invalid artifact record")
        name = record["path"]
        if name in manifest_records:
            raise CacheError(f"guest manifest repeats artifact: {name}")
        manifest_records[name] = record
    if set(manifest_records) != GUEST_ARTIFACTS:
        raise CacheError("guest manifest artifact set is incomplete")

    checksums: dict[str, str] = {}
    try:
        checksum_lines = (
            (directory / "SHA256SUMS").read_text(encoding="ascii").splitlines()
        )
    except (OSError, UnicodeError) as error:
        raise CacheError(f"guest SHA256SUMS is unreadable: {error}") from error
    for line in checksum_lines:
        fields = line.split(maxsplit=1)
        if len(fields) != 2 or len(fields[0]) != 64:
            raise CacheError("guest SHA256SUMS has an invalid record")
        name = fields[1].lstrip("*")
        if name in checksums:
            raise CacheError(f"guest SHA256SUMS repeats artifact: {name}")
        checksums[name] = fields[0]
    if set(checksums) != GUEST_ARTIFACTS | {"guest-manifest.json"}:
        raise CacheError("guest SHA256SUMS artifact set is incomplete")
    if checksums["guest-manifest.json"] != sha256_file(manifest_path):
        raise CacheError("guest manifest checksum is stale")

    for name, record in manifest_records.items():
        path = directory / name
        if not path.is_file() or path.is_symlink() or path.stat().st_size <= 0:
            raise CacheError(f"guest artifact is missing or unsafe: {name}")
        if (
            record.get("bytes") != path.stat().st_size
            or record.get("sha256") != checksums[name]
        ):
            raise CacheError(f"guest metadata does not match artifact: {name}")
    if (directory / "build-spec.json").read_bytes() != (
        root / "guest/spec.json"
    ).read_bytes():
        raise CacheError("guest build-spec.json does not match the current spec")

    snapshot = guest_snapshot(directory)
    if previous is not None and previous.get("outputs") != snapshot:
        raise CacheError("guest artifact metadata changed since the successful build")
    return snapshot


def runtime_snapshot(directory: Path) -> dict[str, str]:
    return {name: sha256_file(directory / name) for name in sorted(RUNTIME_FILES)}


def validate_runtime(root: Path, previous: dict[str, Any] | None) -> dict[str, Any]:
    directory = root / "macos/.build/qemu-gpu-runtime"
    if not directory.is_dir() or directory.is_symlink():
        raise CacheError("runtime artifact directory is missing or unsafe")
    actual: set[str] = set()
    for path in directory.rglob("*"):
        relative = path.relative_to(directory).as_posix()
        if path.is_symlink():
            raise CacheError(f"runtime artifact contains an unsafe symlink: {relative}")
        if path.is_dir():
            if relative not in {"bin", "lib"}:
                raise CacheError(
                    f"runtime artifact contains an unexpected directory: {relative}"
                )
        elif path.is_file():
            actual.add(relative)
        else:
            raise CacheError(f"runtime artifact contains an unsafe entry: {relative}")
    if actual != RUNTIME_FILES:
        raise CacheError("runtime artifact directory has a missing or unexpected file")
    for name in RUNTIME_FILES:
        path = directory / name
        if not path.is_file() or path.is_symlink() or path.stat().st_size <= 0:
            raise CacheError(f"runtime artifact is missing or unsafe: {name}")
        result = subprocess.run(
            ["codesign", "--verify", "--strict", str(path)],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode != 0:
            raise CacheError(f"runtime artifact has an invalid code signature: {name}")
    for command, label in (
        (
            [
                str(root / "macos/bundle-macho-dependencies.sh"),
                "--verify-only",
                str(directory),
            ],
            "self-contained dependency closure",
        ),
        (
            [str(root / "macos/verify-macos-compatibility.sh"), str(directory)],
            "macOS 15 compatibility contract",
        ),
    ):
        result = subprocess.run(
            command,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode != 0:
            raise CacheError(f"runtime artifact violates its {label}")
    snapshot = runtime_snapshot(directory)
    if previous is not None and previous.get("outputs") != snapshot:
        raise CacheError("runtime artifact content changed since the successful build")
    return snapshot


def validate_app(root: Path, previous: dict[str, Any] | None) -> dict[str, Any]:
    app = root / "dist/Try Omarchy.app"
    required = [
        app / "Contents/MacOS/omarchy-vm-helper",
        app / "Contents/Resources/TryOmarchy.icns",
        app / "Contents/Resources/runtime/bin/Try Omarchy",
        app / "Contents/Resources/guest/rootfs.ext4.zst",
        app / "Contents/Resources/guest/launch.plist",
    ]
    if (
        not app.is_dir()
        or app.is_symlink()
        or any(not path.is_file() or path.is_symlink() for path in required)
    ):
        raise CacheError("app bundle is missing or unsafe")
    result = subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", str(app)],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode != 0:
        raise CacheError("app bundle has an invalid code signature")
    result = subprocess.run(
        [str(root / "macos/verify-macos-compatibility.sh"), str(app)],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode != 0:
        raise CacheError("app bundle violates the macOS 15 compatibility contract")
    details = subprocess.run(
        ["codesign", "--display", "--verbose=4", str(app)],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if details.returncode != 0:
        raise CacheError("app bundle code-signing identity is unreadable")
    snapshot = {"codeSignature": hashlib.sha256(details.stdout).hexdigest()}
    if previous is not None and previous.get("outputs") != snapshot:
        raise CacheError("app bundle identity changed since the successful build")
    return snapshot


def validate_outputs(
    root: Path, component: str, previous: dict[str, Any] | None
) -> dict[str, Any]:
    if component == "guest":
        return validate_guest(root, previous)
    if component == "runtime":
        return validate_runtime(root, previous)
    if component == "app":
        return validate_app(root, previous)
    raise CacheError(f"unknown component: {component}")


def read_state(path: Path) -> dict[str, Any] | None:
    try:
        state = json.loads(path.read_text())
    except FileNotFoundError:
        return None
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    if not isinstance(state, dict) or state.get("schemaVersion") != SCHEMA_VERSION:
        return None
    return state


def write_state(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(state, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def force_requested(argument: bool) -> bool:
    value = os.environ.get("OMARCHY_FORCE_BUILD", "0").lower()
    if value not in {"0", "1", "false", "true", "no", "yes"}:
        raise CacheError("FORCE must be 0 or 1")
    return argument or value in {"1", "true", "yes"}


def run(
    root: Path, state_dir: Path, component: str, command: list[str], force: bool
) -> None:
    if not command:
        raise CacheError("a build command is required after --")
    if state_dir != root / ".build/state":
        raise CacheError("state directory must be <repository>/.build/state")
    state_dir.mkdir(parents=True, exist_ok=True)
    state_path = state_dir / f"{component}.json"
    lock_path = state_dir / f"{component}.lock"

    with lock_path.open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        before = fingerprint(root, component, command)
        previous = read_state(state_path)
        if (
            not force
            and previous is not None
            and previous.get("component") == component
            and previous.get("fingerprint") == before
        ):
            try:
                validate_outputs(root, component, previous)
            except CacheError as error:
                print(f"[build-cache] {component} is stale: {error}")
            else:
                print(f"[build-cache] {component} is up to date")
                return

        reason = "forced" if force else "inputs or outputs changed"
        print(f"[build-cache] rebuilding {component}: {reason}", flush=True)
        state_path.unlink(missing_ok=True)
        result = subprocess.run(command, check=False)
        if result.returncode != 0:
            raise CacheError(
                f"{component} build failed with exit status {result.returncode}"
            )

        after = fingerprint(root, component, command)
        if after != before:
            raise CacheError(
                f"{component} inputs changed while it was building; run it again"
            )
        outputs = validate_outputs(root, component, None)
        write_state(
            state_path,
            {
                "schemaVersion": SCHEMA_VERSION,
                "component": component,
                "fingerprint": after,
                "outputs": outputs,
            },
        )
        print(f"[build-cache] recorded successful {component} build")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--state-dir", required=True, type=Path)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("component", choices=("guest", "runtime", "app"))
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    return args


def main() -> None:
    args = parse_args()
    root = args.root.resolve()
    state_dir = args.state_dir.resolve()
    if not root.is_dir():
        raise CacheError(f"repository root is missing: {root}")
    run(root, state_dir, args.component, args.command, force_requested(args.force))


if __name__ == "__main__":
    try:
        main()
    except CacheError as error:
        print(f"build-cache: {error}", file=sys.stderr)
        raise SystemExit(1)
