#!/usr/bin/env python3
"""Apply reviewed backports to a staged, already-verified Omarchy tree."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path, PurePosixPath


def fail(message: str) -> None:
    raise SystemExit(f"apply-omarchy-backports: {message}")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def contained_file(base: Path, relative: str, label: str) -> Path:
    logical = PurePosixPath(relative)
    if logical.is_absolute() or ".." in logical.parts or logical.as_posix() != relative:
        fail(f"unsafe {label} path: {relative}")

    candidate = base.joinpath(*logical.parts)
    if candidate.is_symlink() or not candidate.is_file():
        fail(f"{label} is not a regular file: {relative}")
    try:
        candidate.resolve().relative_to(base.resolve())
    except ValueError:
        fail(f"{label} escapes its root: {relative}")
    return candidate


def staged_target_file(root: Path, omarchy_root: Path, relative: str) -> Path:
    logical = PurePosixPath(relative)
    if logical.is_absolute() or ".." in logical.parts or logical.as_posix() != relative:
        fail(f"unsafe target path: {relative}")

    candidate = omarchy_root.joinpath(*logical.parts)
    if candidate.is_symlink():
        link = PurePosixPath(os.readlink(candidate))
        if not link.is_absolute() or ".." in link.parts:
            fail(f"target has an unsafe staged-root symlink: {relative}")
        candidate = root.joinpath(*link.parts[1:])

    if candidate.is_symlink() or not candidate.is_file():
        fail(f"target is not a regular file: {relative}")
    try:
        candidate.resolve().relative_to(root.resolve())
    except ValueError:
        fail(f"target escapes the staged root: {relative}")
    return candidate


def require_digest(value: object, label: str) -> str:
    rendered = str(value or "")
    if len(rendered) != 64 or any(character not in "0123456789abcdef" for character in rendered):
        fail(f"invalid {label}: {rendered}")
    return rendered


def verify_target(path: Path, target: dict, digest_key: str, backport_id: str) -> None:
    if not isinstance(target, dict):
        fail(f"backport {backport_id} has a non-object target")
    relative = str(target.get("path", ""))
    expected = require_digest(target.get(digest_key), f"{backport_id} {relative} {digest_key}")
    actual = sha256(path)
    if actual != expected:
        fail(
            f"backport {backport_id} target {relative} {digest_key} mismatch: "
            f"expected {expected}, got {actual}"
        )


def apply_backport(spec_dir: Path, root: Path, omarchy_root: Path, backport: dict) -> None:
    if not isinstance(backport, dict):
        fail("backport metadata must contain JSON objects")
    backport_id = str(backport.get("id", ""))
    if not backport_id:
        fail("backport id is required")

    relative_patch = str(backport.get("patch", ""))
    patch = contained_file(spec_dir, relative_patch, "patch")
    expected_patch_digest = require_digest(
        backport.get("patchSha256"), f"{backport_id} patchSha256"
    )
    actual_patch_digest = sha256(patch)
    if actual_patch_digest != expected_patch_digest:
        fail(
            f"backport {backport_id} patch digest mismatch: "
            f"expected {expected_patch_digest}, got {actual_patch_digest}"
        )

    targets = backport.get("targets")
    if not isinstance(targets, list) or not targets:
        fail(f"backport {backport_id} must declare at least one target")
    target_paths: dict[str, Path] = {}
    for target in targets:
        if not isinstance(target, dict):
            fail(f"backport {backport_id} has a non-object target")
        relative = str(target.get("path", ""))
        if relative in target_paths:
            fail(f"backport {backport_id} repeats target: {relative}")
        target_path = staged_target_file(root, omarchy_root, relative)
        verify_target(target_path, target, "beforeSha256", backport_id)
        target_paths[relative] = target_path

    # Patch isolated regular-file copies so package-path symlinks such as
    # /usr/share/omarchy/bin/* remain intact and no undeclared staged file can
    # be changed by a reviewed patch.
    with tempfile.TemporaryDirectory() as temporary:
        patch_root = Path(temporary)
        for relative, target_path in target_paths.items():
            destination = patch_root.joinpath(*PurePosixPath(relative).parts)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(target_path, destination)

        result = subprocess.run(
            ["git", "apply", "--no-index", "--whitespace=error", str(patch)],
            cwd=patch_root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip() or "git apply failed"
            fail(f"backport {backport_id} did not apply: {detail}")

        actual_paths = {
            path.relative_to(patch_root).as_posix()
            for path in patch_root.rglob("*")
            if path.is_file() or path.is_symlink()
        }
        if actual_paths != set(target_paths):
            fail(f"backport {backport_id} changed files outside its declared targets")

        for target in targets:
            relative = str(target["path"])
            verify_target(
                patch_root.joinpath(*PurePosixPath(relative).parts),
                target,
                "afterSha256",
                backport_id,
            )
        for relative, target_path in target_paths.items():
            shutil.copy2(
                patch_root.joinpath(*PurePosixPath(relative).parts),
                target_path,
            )
    print(f"Applied Omarchy backport {backport_id}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--spec", required=True, type=Path)
    args = parser.parse_args()

    if not args.root.is_absolute() or args.root.resolve() == Path("/"):
        fail("--root must be an absolute staged root")
    spec = args.spec.resolve()
    if not spec.is_file():
        fail(f"spec not found: {spec}")
    root = args.root.resolve()
    omarchy_root = root / "usr/share/omarchy"
    if not omarchy_root.is_dir():
        fail(f"materialized Omarchy tree not found: {omarchy_root}")

    try:
        build_spec = json.loads(spec.read_text(encoding="utf-8"))
        backports = build_spec["authenticity"]["backports"]
    except (KeyError, json.JSONDecodeError) as error:
        fail(f"could not read backport metadata: {error}")
    if not isinstance(backports, list):
        fail("authenticity.backports must be an array")

    for backport in backports:
        apply_backport(spec.parent, root, omarchy_root, backport)


if __name__ == "__main__":
    main()
