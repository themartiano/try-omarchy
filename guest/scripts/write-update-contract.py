#!/usr/bin/env python3
"""Publish a precomputed guest release identity and signed update digest."""

from __future__ import annotations

import argparse
from pathlib import Path

from update_contract import write_contract


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--spec", required=True, type=Path)
    parser.add_argument("--release-id", required=True)
    parser.add_argument("--owned-payload-sha256", required=True)
    parser.add_argument("--update-sums-sha256")
    args = parser.parse_args()

    if not args.root.is_absolute() or not args.root.is_dir():
        raise SystemExit("--root must be an absolute staged root")
    try:
        write_contract(
            args.root,
            args.spec,
            args.release_id,
            args.owned_payload_sha256,
            args.update_sums_sha256,
        )
    except ValueError as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
