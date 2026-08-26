#!/usr/bin/env python3
"""Describe the guest-only artifacts for the release manifest assembler."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path


FILES = {
    "vmlinuz-linux": ("guest-kernel", "application/vnd.linux.kernel"),
    "initramfs-linux.img": ("guest-initramfs", "application/vnd.linux.initramfs"),
    "rootfs.ext4": ("guest-rootfs", "application/vnd.omarchy.ext4"),
    "rootfs.ext4.zst": ("guest-rootfs-compressed", "application/zstd"),
    "update.ext4": ("guest-update-disk", "application/vnd.try-omarchy.update-ext4"),
    "update.ext4.zst": ("guest-update-disk-compressed", "application/zstd"),
    "provenance.json": ("guest-metadata", "application/json"),
    "build-spec.json": ("guest-metadata", "application/json"),
    "packages.lock.txt": ("guest-metadata", "text/plain"),
    "LICENSE.omarchy": ("guest-license", "text/plain"),
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--spec", required=True, type=Path)
    args = parser.parse_args()
    spec = json.loads(args.spec.read_text())
    artifacts = []
    for name, (role, media_type) in FILES.items():
        path = args.directory / name
        if not path.exists():
            continue
        artifacts.append(
            {
                "path": name,
                "role": role,
                "bytes": path.stat().st_size,
                "sha256": sha256(path),
                "mediaType": media_type,
            }
        )

    source_tree = json.loads((args.directory / "provenance.json").read_text()).get("normalizedUpstreamTree")
    epoch = spec["image"]["sourceDateEpoch"]
    guest = {
        "architecture": spec["image"]["architecture"],
        "distribution": "Arch Linux",
        "username": spec["guest"]["username"],
        "display": spec["guest"]["virtualDisplay"],
        "kernelCommandLine": spec["runtime"]["kernelCommandLine"],
    }
    if "profile" in spec["guest"]:
        guest["profile"] = spec["guest"]["profile"]
    payload = {
        "schemaVersion": 1,
        "kind": "try-omarchy-guest-artifacts",
        "upstream": spec["upstream"],
        "normalizedUpstreamTree": source_tree,
        "build": {
            "builtAt": dt.datetime.fromtimestamp(epoch, tz=dt.timezone.utc).isoformat().replace("+00:00", "Z"),
            "sourceDateEpoch": epoch,
            "builderImageDigest": os.environ.get("OMARCHY_BUILDER_IMAGE_DIGEST"),
        },
        "guest": guest,
        "artifacts": artifacts,
    }
    (args.directory / "guest-manifest.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
