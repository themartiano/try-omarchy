#!/usr/bin/env python3
"""Pin an exact official Omarchy release in the native guest build spec."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_SPEC = SCRIPT_DIR.parent / "spec.json"
RELEASE_PATTERN = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-.][A-Za-z0-9.]+)?")


def fail(message: str) -> None:
    raise SystemExit(f"update-upstream-pin: {message}")


def git(source: Path, *arguments: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", "-C", str(source), *arguments],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        fail(f"git {' '.join(arguments)} failed: {detail}")
    return result.stdout.strip()


def canonical_repository(value: str) -> str:
    return value.removesuffix(".git").rstrip("/")


def load_digest_module():
    module_spec = importlib.util.spec_from_file_location(
        "try_omarchy_source_digest", SCRIPT_DIR / "source-digest.py"
    )
    if module_spec is None or module_spec.loader is None:
        fail("could not load source-digest.py")
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    return module


def prepare_source(repository: str, release: str, source: Path | None, cache_dir: Path) -> Path:
    tag = f"v{release}"
    if source is None:
        source = cache_dir / f"omarchy-{tag}"
        if not source.exists():
            cache_dir.mkdir(parents=True, exist_ok=True)
            subprocess.run(
                [
                    "git",
                    "clone",
                    "--branch",
                    tag,
                    "--depth",
                    "1",
                    "--single-branch",
                    f"{repository}.git",
                    str(source),
                ],
                check=True,
            )
    source = source.resolve()
    if not (source / ".git").is_dir():
        fail(f"source is not a Git checkout: {source}")
    return source


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--release", required=True)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--spec", type=Path, default=DEFAULT_SPEC)
    parser.add_argument("--cache-dir", type=Path, default=DEFAULT_SPEC.parent.parent / ".build/upstream")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    release = args.release.removeprefix("v")
    if RELEASE_PATTERN.fullmatch(release) is None:
        fail(f"invalid release: {args.release}")

    spec_path = args.spec.resolve()
    try:
        build_spec = json.loads(spec_path.read_text(encoding="utf-8"))
        repository = build_spec["upstream"]["repository"]
    except (OSError, KeyError, json.JSONDecodeError) as error:
        fail(f"could not read build spec {spec_path}: {error}")

    source = prepare_source(repository, release, args.source, args.cache_dir.resolve())
    if git(source, "status", "--porcelain", "--untracked-files=all"):
        fail(f"source checkout is not clean: {source}")
    origin = git(source, "remote", "get-url", "origin")
    if canonical_repository(origin) != canonical_repository(repository):
        fail(f"source origin is {origin}, expected {repository}")

    commit = git(source, "rev-parse", "HEAD")
    tagged_commit = git(source, "rev-parse", f"v{release}^{{commit}}")
    if commit != tagged_commit:
        fail(f"source HEAD {commit} is not the v{release} commit {tagged_commit}")
    tree = git(source, "rev-parse", "HEAD^{tree}")
    timestamp_text = git(source, "show", "-s", "--format=%ct", "HEAD")
    if not timestamp_text.isdigit():
        fail(f"invalid commit timestamp: {timestamp_text}")
    source_version = (source / "version").read_text(encoding="utf-8").strip()
    if not source_version or "\n" in source_version:
        fail("upstream version file is invalid")

    digest_module = load_digest_module()
    tree_digest, file_count = digest_module.digest_source(source)
    expected = {
        "commit": commit,
        "tree": tree,
        "treeSha256": tree_digest,
        "release": release,
        "version": source_version,
    }

    mismatches = {
        key: (build_spec["upstream"].get(key), value)
        for key, value in expected.items()
        if build_spec["upstream"].get(key) != value
    }
    current_epoch = build_spec["image"].get("sourceDateEpoch")
    timestamp = int(timestamp_text)
    if current_epoch != timestamp:
        mismatches["sourceDateEpoch"] = (current_epoch, timestamp)

    if args.check:
        if mismatches:
            rendered = ", ".join(
                f"{key}={actual!r} (expected {wanted!r})"
                for key, (actual, wanted) in mismatches.items()
            )
            fail(f"build spec does not match v{release}: {rendered}")
    else:
        build_spec["upstream"].update(expected)
        build_spec["image"]["sourceDateEpoch"] = timestamp
        rendered = json.dumps(build_spec, indent=2) + "\n"
        spec_path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{spec_path.name}.", dir=spec_path.parent
        )
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as temporary:
                temporary.write(rendered)
                temporary.flush()
                os.fsync(temporary.fileno())
            os.chmod(temporary_name, spec_path.stat().st_mode)
            os.replace(temporary_name, spec_path)
        finally:
            if os.path.exists(temporary_name):
                os.unlink(temporary_name)

    action = "Verified" if args.check else "Pinned"
    print(f"{action} Omarchy v{release}")
    print(f"  commit: {commit}")
    print(f"  tree: {tree}")
    print(f"  normalized source: {tree_digest} ({file_count} files)")
    print(f"  source version: {source_version}")


if __name__ == "__main__":
    main()
