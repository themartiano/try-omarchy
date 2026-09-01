#!/usr/bin/env python3
"""Write deterministic content digests for the authentic Omarchy payload."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath


def digest_path(path: Path) -> str:
    digest = hashlib.sha256()
    for current, directories, files in os.walk(path, topdown=True, followlinks=False):
        directories.sort()
        files.sort()
        base = Path(current)
        for name in directories + files:
            item = base / name
            relative = item.relative_to(path).as_posix()
            if item.is_symlink():
                kind = b"L"
                payload = os.readlink(item).encode()
            elif item.is_dir():
                kind = b"D"
                payload = b""
            else:
                kind = b"F"
                payload = item.read_bytes()
            digest.update(kind)
            digest.update(relative.encode())
            digest.update(b"\0")
            digest.update(payload)
            digest.update(b"\0")
    return digest.hexdigest()


def digest_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def installed_target_file(root: Path, omarchy: Path, relative: str) -> Path:
    logical = PurePosixPath(relative)
    if logical.is_absolute() or ".." in logical.parts or logical.as_posix() != relative:
        raise SystemExit(f"unsafe backport target path: {relative}")

    installed = omarchy.joinpath(*logical.parts)
    if installed.is_symlink():
        link = PurePosixPath(os.readlink(installed))
        if not link.is_absolute() or ".." in link.parts:
            raise SystemExit(f"unsafe backport target symlink: {relative}")
        installed = root.joinpath(*link.parts[1:])

    if installed.is_symlink() or not installed.is_file():
        raise SystemExit(f"missing installed backport target: {relative}")
    try:
        installed.resolve().relative_to(root.resolve())
    except ValueError:
        raise SystemExit(f"backport target escapes staged root: {relative}")
    return installed


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--spec", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    spec = json.loads(args.spec.read_text())
    root = args.root.resolve()
    omarchy = root / "usr/share/omarchy"
    authenticity = spec["authenticity"]
    verbatim_trees = authenticity["verbatimRuntimeTrees"]
    backported_trees = authenticity.get("backportedRuntimeTrees", [])
    if set(verbatim_trees) & set(backported_trees):
        raise SystemExit("runtime trees cannot be both verbatim and backported")

    trees = {}
    for name in verbatim_trees + backported_trees:
        installed = omarchy / name
        if not installed.exists():
            raise SystemExit(f"missing installed authenticity tree: {installed}")
        trees[name] = digest_path(installed)
    trees["themes"] = digest_path(omarchy / "themes")

    backports = authenticity.get("backports", [])
    for backport in backports:
        patch = args.spec.parent / backport["patch"]
        patch_digest = digest_file(patch)
        if patch_digest != backport["patchSha256"]:
            raise SystemExit(f"backport patch digest mismatch: {backport['id']}")
        for target in backport["targets"]:
            installed = installed_target_file(root, omarchy, target["path"])
            if digest_file(installed) != target["afterSha256"]:
                raise SystemExit(f"backport target digest mismatch: {backport['id']} {target['path']}")

    payload = {
        "schemaVersion": 1,
        "claim": "Desktop runtime derived from pinned Basecamp Omarchy source plus the enumerated reviewed backports.",
        "upstream": spec["upstream"],
        "includedThemes": spec["themes"],
        "verbatimRuntimeTrees": verbatim_trees,
        "backportedRuntimeTrees": backported_trees,
        "backports": backports,
        "sha256Trees": trees,
    }
    source_digest = args.root / "usr/share/try-omarchy/upstream-tree.json"
    if source_digest.exists():
        payload["normalizedUpstreamTree"] = json.loads(source_digest.read_text())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
