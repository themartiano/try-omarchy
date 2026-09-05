#!/usr/bin/env python3
"""Resolve the complete empty-root Arch transaction without downloading it."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import subprocess
from pathlib import Path


def package_names(path: Path) -> list[str]:
    names = []
    for line in path.read_text().splitlines():
        name = line.split("#", 1)[0].strip()
        if name:
            names.append(name)
    return names


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--dbpath", required=True, type=Path)
    parser.add_argument("--packages", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--expect", type=Path)
    args = parser.parse_args()

    requested = package_names(args.packages)
    result = subprocess.run(
        [
            "pacman",
            "-Sp",
            "--config",
            str(args.config),
            "--dbpath",
            str(args.dbpath),
            "--print-format",
            "%n|%v",
            *requested,
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode:
        # pacman reports the failure on stderr but names each unsatisfied
        # dependency on stdout, so a diagnosis needs both streams.
        raise SystemExit("".join(part for part in (result.stderr, result.stdout) if part).strip())

    resolved: dict[str, str] = {}
    for line in result.stdout.splitlines():
        name, version = line.split("|", 1)
        previous = resolved.setdefault(name, version)
        if previous != version:
            raise SystemExit(f"conflicting versions resolved for {name}: {previous}, {version}")

    payload = {
        "schemaVersion": 1,
        "architecture": platform.machine(),
        "requestedFileSha256": hashlib.sha256(args.packages.read_bytes()).hexdigest(),
        "packages": dict(sorted(resolved.items())),
    }
    args.output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")

    if args.expect:
        expected = json.loads(args.expect.read_text())
        if payload != expected:
            old = expected.get("packages", {})
            new = payload["packages"]
            changed = [
                f"{name}: {old.get(name, '<missing>')} -> {new.get(name, '<missing>')}"
                for name in sorted(set(old) | set(new))
                if old.get(name) != new.get(name)
            ]
            details = "\n".join(changed[:30])
            raise SystemExit(
                f"package repository transaction differs from {args.expect.name}; "
                "refresh and review the lock intentionally\n" + details
            )


if __name__ == "__main__":
    main()
