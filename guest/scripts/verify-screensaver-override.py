#!/usr/bin/env python3

"""Require the native screensaver override to be a one-line upstream patch."""

from __future__ import annotations

import argparse
from pathlib import Path


UPSTREAM_CURSOR_RESTORE = (
    "  hyprctl eval 'hl.config({ cursor = { invisible = false } })' &>/dev/null "
    "|| hyprctl keyword cursor:invisible false &>/dev/null || true"
)
NATIVE_CURSOR_RESTORE = (
    "  /usr/local/bin/omarchy-native-cursor-restore 2>/dev/null || true"
)


def read(path: Path, label: str) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise SystemExit(f"verify-screensaver-override: cannot read {label}: {error}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--override", required=True, type=Path)
    args = parser.parse_args()

    upstream = read(args.source, "pinned upstream screensaver")
    native = read(args.override, "native screensaver override")
    if upstream.count(UPSTREAM_CURSOR_RESTORE) != 1:
        raise SystemExit(
            "verify-screensaver-override: pinned upstream cursor cleanup changed; "
            "review the native override"
        )
    expected = upstream.replace(UPSTREAM_CURSOR_RESTORE, NATIVE_CURSOR_RESTORE)
    if native != expected:
        raise SystemExit(
            "verify-screensaver-override: native screensaver must differ from pinned "
            "upstream only at cursor restoration"
        )


if __name__ == "__main__":
    main()
