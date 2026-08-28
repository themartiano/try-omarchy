#!/usr/bin/env python3
"""Protocol and V4L2 contract tests for the native macOS camera bridge."""

from __future__ import annotations

import ctypes
from importlib.machinery import SourceFileLoader
from pathlib import Path
import struct
import unittest


GUEST = Path(__file__).resolve().parents[1]
BRIDGE_PATH = GUEST / "native-overlay/usr/local/bin/omarchy-native-camera-bridge"
bridge = SourceFileLoader("omarchy_native_camera_bridge", str(BRIDGE_PATH)).load_module()


class NativeCameraBridgeTests(unittest.TestCase):
    def message(self, kind: int, payload: bytes, sequence: int = 0) -> bytes:
        return bridge.HEADER.pack(
            bridge.MAGIC,
            bridge.VERSION,
            kind,
            0,
            len(payload),
            sequence,
        ) + payload

    def test_fragmented_status_and_frame_messages_are_reassembled(self) -> None:
        status = b'{"status":"streaming"}'
        frame = bytes([37]) * bridge.FRAME_BYTES
        encoded = self.message(bridge.KIND_STATUS, status) + self.message(
            bridge.KIND_FRAME, frame, sequence=42
        )
        parser = bridge.MessageParser()
        messages = []
        for offset in range(0, len(encoded), 65537):
            messages.extend(parser.feed(encoded[offset : offset + 65537]))
        self.assertEqual(messages[0], (bridge.KIND_STATUS, 0, status))
        self.assertEqual(messages[1], (bridge.KIND_FRAME, 42, frame))
        self.assertEqual(parser.buffer, b"")

    def test_invalid_frame_size_is_rejected_before_buffering_payload(self) -> None:
        parser = bridge.MessageParser()
        header = bridge.HEADER.pack(
            bridge.MAGIC,
            bridge.VERSION,
            bridge.KIND_FRAME,
            0,
            bridge.FRAME_BYTES - 1,
            1,
        )
        with self.assertRaisesRegex(ValueError, "invalid size"):
            parser.feed(header)

    def test_black_frame_is_video_range_nv12(self) -> None:
        frame = bridge.black_frame()
        self.assertEqual(len(frame), bridge.FRAME_BYTES)
        luma_bytes = bridge.WIDTH * bridge.HEIGHT
        self.assertEqual(set(frame[:luma_bytes]), {16})
        self.assertEqual(set(frame[luma_bytes:]), {128})

    def test_v4l2_ioctl_layout_matches_linux_uapi(self) -> None:
        self.assertEqual(ctypes.sizeof(bridge.V4L2PixFormat), 48)
        self.assertEqual(ctypes.sizeof(bridge.V4L2Format), 208)
        self.assertEqual(ctypes.sizeof(bridge.V4L2EventSubscription), 32)
        self.assertEqual(ctypes.sizeof(bridge.V4L2Event), 136)
        self.assertEqual(bridge.VIDIOC_S_FMT, 0xC0D05605)
        self.assertEqual(bridge.VIDIOC_DQEVENT, 0x80885659)
        self.assertEqual(bridge.VIDIOC_SUBSCRIBE_EVENT, 0x4020565A)

    def test_wire_header_is_little_endian_and_fixed_size(self) -> None:
        self.assertEqual(bridge.HEADER.size, 16)
        encoded = self.message(bridge.KIND_STATUS, b"ok", sequence=0x01020304)
        self.assertEqual(encoded[:4], b"TOCM")
        self.assertEqual(encoded[8:12], struct.pack("<I", 2))
        self.assertEqual(encoded[12:16], b"\x04\x03\x02\x01")


if __name__ == "__main__":
    unittest.main()
