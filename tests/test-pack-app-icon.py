#!/usr/bin/env python3

from __future__ import annotations

from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib


REPOSITORY = Path(__file__).resolve().parents[1]
PACKER = REPOSITORY / "macos/pack-app-icon.py"
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


def png_chunk(chunk_type: bytes, contents: bytes) -> bytes:
    checksum = zlib.crc32(chunk_type)
    checksum = zlib.crc32(contents, checksum) & 0xFFFFFFFF
    return (
        struct.pack(">I", len(contents))
        + chunk_type
        + contents
        + struct.pack(">I", checksum)
    )


def solid_png(width: int, height: int) -> bytes:
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    row = b"\x00" + b"\x9e\xce\x6a\xff" * width
    return (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", header)
        + png_chunk(b"IDAT", zlib.compress(row * height, level=9))
        + png_chunk(b"IEND", b"")
    )


def read_icns(path: Path) -> list[tuple[bytes, bytes]]:
    contents = path.read_bytes()
    if contents[:4] != b"icns" or len(contents) < 8:
        raise AssertionError("invalid ICNS header")
    declared_size = struct.unpack_from(">I", contents, 4)[0]
    if declared_size != len(contents):
        raise AssertionError("invalid ICNS size")

    chunks: list[tuple[bytes, bytes]] = []
    offset = 8
    while offset < len(contents):
        if len(contents) - offset < 8:
            raise AssertionError("truncated ICNS chunk")
        chunk_type = contents[offset : offset + 4]
        chunk_size = struct.unpack_from(">I", contents, offset + 4)[0]
        if chunk_size < 8 or offset + chunk_size > len(contents):
            raise AssertionError("invalid ICNS chunk size")
        chunks.append((chunk_type, contents[offset + 8 : offset + chunk_size]))
        offset += chunk_size
    return chunks


class AppIconPackerTests(unittest.TestCase):
    @staticmethod
    def create_iconset(root: Path) -> Path:
        iconset = root / "TryOmarchy.iconset"
        iconset.mkdir()
        for name, pixels, _ in REPRESENTATIONS:
            (iconset / name).write_bytes(solid_png(pixels, pixels))
        return iconset

    @staticmethod
    def invoke(iconset: Path, output: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(PACKER), str(iconset), str(output)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def test_packs_all_representations_with_stable_chunk_mapping(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            iconset = self.create_iconset(root)
            first = root / "first.icns"
            second = root / "second.icns"

            self.assertEqual(0, self.invoke(iconset, first).returncode)
            self.assertEqual(0, self.invoke(iconset, second).returncode)
            self.assertEqual(first.read_bytes(), second.read_bytes())

            chunks = read_icns(first)
            self.assertEqual(
                [chunk_type for _, _, chunk_type in REPRESENTATIONS],
                [chunk_type for chunk_type, _ in chunks],
            )
            self.assertEqual(
                [(iconset / name).read_bytes() for name, _, _ in REPRESENTATIONS],
                [payload for _, payload in chunks],
            )

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS image tools")
    def test_packed_icon_is_readable_by_macos_at_full_resolution(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            iconset = self.create_iconset(root)
            output = root / "TryOmarchy.icns"
            result = self.invoke(iconset, output)
            self.assertEqual(0, result.returncode, result.stderr)

            inspection = subprocess.run(
                ["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(output)],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            self.assertEqual(0, inspection.returncode, inspection.stdout)
            self.assertIn("pixelWidth: 1024", inspection.stdout)
            self.assertIn("pixelHeight: 1024", inspection.stdout)

    def test_rejects_a_missing_representation_without_replacing_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            iconset = self.create_iconset(root)
            (iconset / "icon_128x128@2x.png").unlink()
            output = root / "TryOmarchy.icns"
            output.write_bytes(b"keep existing output")

            result = self.invoke(iconset, output)
            self.assertNotEqual(0, result.returncode)
            self.assertIn("missing required image: icon_128x128@2x.png", result.stderr)
            self.assertEqual(b"keep existing output", output.read_bytes())

    def test_rejects_malformed_png_data(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            iconset = self.create_iconset(root)
            output = root / "TryOmarchy.icns"
            image = iconset / "icon_16x16.png"

            image.write_bytes(b"not a png")
            result = self.invoke(iconset, output)
            self.assertNotEqual(0, result.returncode)
            self.assertIn("icon_16x16.png is not a PNG file", result.stderr)
            self.assertFalse(output.exists())

            contents = bytearray(solid_png(16, 16))
            contents[-1] ^= 0xFF
            image.write_bytes(contents)
            result = self.invoke(iconset, output)
            self.assertNotEqual(0, result.returncode)
            self.assertIn("invalid IEND CRC", result.stderr)
            self.assertFalse(output.exists())

            header = struct.pack(">IIBBBBB", 16, 16, 8, 6, 0, 0, 0)
            image.write_bytes(
                b"\x89PNG\r\n\x1a\n"
                + png_chunk(b"IHDR", header)
                + png_chunk(b"IDAT", b"not compressed image data")
                + png_chunk(b"IEND", b"")
            )
            result = self.invoke(iconset, output)
            self.assertNotEqual(0, result.returncode)
            self.assertIn("invalid compressed PNG image data", result.stderr)
            self.assertFalse(output.exists())

    def test_rejects_a_representation_with_the_wrong_dimensions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            iconset = self.create_iconset(root)
            (iconset / "icon_32x32@2x.png").write_bytes(solid_png(63, 64))
            output = root / "TryOmarchy.icns"

            result = self.invoke(iconset, output)
            self.assertNotEqual(0, result.returncode)
            self.assertIn(
                "icon_32x32@2x.png must be 64x64, got 63x64", result.stderr
            )
            self.assertFalse(output.exists())

    def test_rejects_unexpected_iconset_entries(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            iconset = self.create_iconset(root)
            (iconset / "old-logo.png").write_bytes(solid_png(16, 16))
            output = root / "TryOmarchy.icns"

            result = self.invoke(iconset, output)
            self.assertNotEqual(0, result.returncode)
            self.assertIn("unexpected entry: old-logo.png", result.stderr)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
