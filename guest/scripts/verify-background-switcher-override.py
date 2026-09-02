#!/usr/bin/env python3

"""Require the background switcher override to be an order-only upstream patch."""

from __future__ import annotations

import argparse
from pathlib import Path


UPSTREAM_INVOCATION = """\
omarchy-menu-images \\
  --selected "$current_background" \\
  "$HOME/.local/state/omarchy/current/theme/backgrounds" \\
  "$HOME/.config/omarchy/backgrounds/$theme_name"
"""
NATIVE_INVOCATION = """\
# Try Omarchy seeds its wallpaper in the supported user background directory.
# List that directory first so the seeded wallpaper is the picker's first card.
omarchy-menu-images \\
  --selected "$current_background" \\
  "$HOME/.config/omarchy/backgrounds/$theme_name" \\
  "$HOME/.local/state/omarchy/current/theme/backgrounds"
"""


def read(path: Path, label: str) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise SystemExit(
            f"verify-background-switcher-override: cannot read {label}: {error}"
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--override", required=True, type=Path)
    args = parser.parse_args()

    upstream = read(args.source, "pinned upstream background switcher")
    native = read(args.override, "native background switcher override")
    if upstream.count(UPSTREAM_INVOCATION) != 1:
        raise SystemExit(
            "verify-background-switcher-override: pinned upstream invocation changed; "
            "review the native override"
        )

    if native != upstream.replace(UPSTREAM_INVOCATION, NATIVE_INVOCATION):
        raise SystemExit(
            "verify-background-switcher-override: native background switcher must "
            "differ from pinned upstream only by documenting and reversing the two "
            "image-directory arguments"
        )


if __name__ == "__main__":
    main()
