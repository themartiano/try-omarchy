#!/usr/bin/env python3
"""Pack a validated macOS iconset into a deterministic ICNS container."""

from __future__ import annotations

import os
from pathlib import Path
import struct
import sys
import tempfile
import zlib


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
ICNS_SIGNATURE = b"icns"
UINT32_LIMIT = 1 << 32

# The Retina chunk types deliberately duplicate some pixel dimensions. For
# example, icp5 is 32 pt at 1x while ic11 is 16 pt at 2x. Keeping both lets
# AppKit select the intended representation at every supported scale.
REPRESENTATIONS = (
    ("icon_16x16.png", 16, b"icp4"),
    ("icon_16x16@2x.png", 32, b"ic11"),
    ("icon_32x32.png", 32, b"icp5"),
    ("icon_32x32@2x.png", 64, b"ic12"),
    ("icon_128x128.png", 128, b"ic07"),
    ("icon_128x128@2x.png", 256, b"ic13"),
    ("icon_256x256.png", 256, b"ic08"),
    ("icon_256x256@2x.png", 512, b"ic14"),
    ("icon_512x512.png", 512, b"ic09"),
    ("icon_512x512@2x.png", 1024, b"ic10"),
)


class IconPackError(RuntimeError):
    pass


def checked_png_dimensions(contents: bytes, label: str) -> tuple[int, int]:
    if not contents.startswith(PNG_SIGNATURE):
        raise IconPackError(f"{label} is not a PNG file")

    offset = len(PNG_SIGNATURE)
    dimensions: tuple[int, int] | None = None
    image_data = bytearray()
    saw_image_data = False
    saw_end = False
    chunk_index = 0

    while offset < len(contents):
        if len(contents) - offset < 12:
            raise IconPackError(f"{label} has a truncated PNG chunk")

        length = struct.unpack_from(">I", contents, offset)[0]
        chunk_type = contents[offset + 4 : offset + 8]
        chunk_end = offset + 12 + length
        if chunk_end > len(contents):
            raise IconPackError(f"{label} has a truncated PNG chunk")
        if not all(
            ord("A") <= byte <= ord("Z") or ord("a") <= byte <= ord("z")
            for byte in chunk_type
        ):
            raise IconPackError(f"{label} has an invalid PNG chunk type")

        chunk_data = contents[offset + 8 : offset + 8 + length]
        expected_crc = struct.unpack_from(">I", contents, offset + 8 + length)[0]
        actual_crc = zlib.crc32(chunk_type)
        actual_crc = zlib.crc32(chunk_data, actual_crc) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            name = chunk_type.decode("ascii", errors="replace")
            raise IconPackError(f"{label} has an invalid {name} CRC")

        if chunk_index == 0 and chunk_type != b"IHDR":
            raise IconPackError(f"{label} does not begin with a PNG IHDR chunk")
        if chunk_type == b"IHDR":
            if dimensions is not None or length != 13:
                raise IconPackError(f"{label} has an invalid PNG IHDR chunk")
            width, height, depth, color_type, compression, filtering, interlace = (
                struct.unpack(">IIBBBBB", chunk_data)
            )
            valid_depths = {
                0: {1, 2, 4, 8, 16},
                2: {8, 16},
                3: {1, 2, 4, 8},
                4: {8, 16},
                6: {8, 16},
            }
            if width == 0 or height == 0 or depth not in valid_depths.get(
                color_type, set()
            ):
                raise IconPackError(f"{label} has invalid PNG image metadata")
            if (
                depth != 8
                or color_type != 6
                or compression != 0
                or filtering != 0
                or interlace != 0
            ):
                raise IconPackError(
                    f"{label} must be a noninterlaced 8-bit RGBA PNG"
                )
            dimensions = (width, height)
        elif chunk_type == b"IDAT":
            saw_image_data = True
            image_data.extend(chunk_data)
        elif chunk_type == b"IEND":
            if length != 0:
                raise IconPackError(f"{label} has an invalid PNG IEND chunk")
            saw_end = True
            offset = chunk_end
            break

        offset = chunk_end
        chunk_index += 1

    if dimensions is None or not saw_image_data or not saw_end:
        raise IconPackError(f"{label} is missing required PNG chunks")
    if offset != len(contents):
        raise IconPackError(f"{label} has data after its PNG IEND chunk")
    try:
        decoded = zlib.decompress(image_data)
    except zlib.error as error:
        raise IconPackError(f"{label} has invalid compressed PNG image data") from error
    width, height = dimensions
    row_bytes = width * 4 + 1
    if len(decoded) != row_bytes * height or any(
        decoded[row * row_bytes] > 4 for row in range(height)
    ):
        raise IconPackError(f"{label} has invalid PNG scanline data")
    return dimensions


def icon_chunks(iconset: Path) -> list[bytes]:
    if not iconset.is_dir() or iconset.is_symlink():
        raise IconPackError(f"iconset is missing or unsafe: {iconset}")

    expected_names = {name for name, _, _ in REPRESENTATIONS}
    actual_names = {entry.name for entry in iconset.iterdir()}
    missing = sorted(expected_names - actual_names)
    unexpected = sorted(actual_names - expected_names)
    if missing:
        raise IconPackError(f"iconset is missing required image: {missing[0]}")
    if unexpected:
        raise IconPackError(f"iconset contains unexpected entry: {unexpected[0]}")

    chunks: list[bytes] = []
    for name, pixels, chunk_type in REPRESENTATIONS:
        image = iconset / name
        if not image.is_file() or image.is_symlink():
            raise IconPackError(f"iconset image is missing or unsafe: {name}")
        try:
            contents = image.read_bytes()
        except OSError as error:
            raise IconPackError(f"cannot read {name}: {error}") from error
        dimensions = checked_png_dimensions(contents, name)
        if dimensions != (pixels, pixels):
            raise IconPackError(
                f"{name} must be {pixels}x{pixels}, got "
                f"{dimensions[0]}x{dimensions[1]}"
            )

        chunk_size = len(contents) + 8
        if chunk_size >= UINT32_LIMIT:
            raise IconPackError(f"{name} is too large for an ICNS chunk")
        chunks.append(chunk_type + struct.pack(">I", chunk_size) + contents)
    return chunks


def pack_icon(iconset: Path, output: Path) -> None:
    chunks = icon_chunks(iconset)
    total_size = 8 + sum(len(chunk) for chunk in chunks)
    if total_size >= UINT32_LIMIT:
        raise IconPackError("packed icon is too large for an ICNS container")
    contents = ICNS_SIGNATURE + struct.pack(">I", total_size) + b"".join(chunks)

    parent = output.parent
    if not parent.is_dir() or parent.is_symlink():
        raise IconPackError(f"output directory is missing or unsafe: {parent}")
    if output.is_symlink() or (output.exists() and not output.is_file()):
        raise IconPackError(f"output path is unsafe: {output}")

    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{output.name}.", dir=parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o644)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(contents)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)


def main(arguments: list[str]) -> int:
    if len(arguments) != 2:
        print("Usage: pack-app-icon.py ICONSET OUTPUT_ICNS", file=sys.stderr)
        return 64
    try:
        pack_icon(Path(arguments[0]), Path(arguments[1]))
    except IconPackError as error:
        print(f"pack-app-icon: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
