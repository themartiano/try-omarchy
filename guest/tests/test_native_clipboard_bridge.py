#!/usr/bin/env python3
"""Behavior tests for the guest side of macOS clipboard sharing."""

from __future__ import annotations

import base64
import importlib.util
from importlib.machinery import SourceFileLoader
import json
from pathlib import Path
import unittest


BRIDGE_PATH = (
    Path(__file__).resolve().parents[1]
    / "native-overlay/usr/local/bin/omarchy-native-clipboard-bridge"
)
LOADER = SourceFileLoader("omarchy_native_clipboard_bridge", str(BRIDGE_PATH))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot import {BRIDGE_PATH}")
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)


class Recorder:
    def __init__(self) -> None:
        self.sent: list[bytes] = []
        self.copied: list[tuple[str, bytes]] = []

    def send(self, payload: bytes) -> None:
        self.sent.append(payload)

    def copy(self, mime: str, payload: bytes) -> None:
        self.copied.append((mime, payload))


class MessageCodingTests(unittest.TestCase):
    def test_encode_matches_host_schema(self) -> None:
        line = bridge.encode_message(bridge.TEXT_FORMAT, "héllo\n".encode())
        self.assertTrue(line.endswith(b"\n"))
        self.assertEqual(
            json.loads(line),
            {"type": "clipboard", "format": "text/plain;charset=utf-8", "data": "aMOpbGxvCg=="},
        )
        self.assertEqual(
            line,
            b'{"data":"aMOpbGxvCg==","format":"text/plain;charset=utf-8","type":"clipboard"}\n',
        )

    def test_decode_accepts_supported_formats_only(self) -> None:
        png = b"\x89PNG\r\n"
        line = json.dumps(
            {"type": "clipboard", "format": "image/png", "data": base64.b64encode(png).decode()}
        ).encode()
        self.assertEqual(bridge.decode_message(line), ("image/png", png))
        html = json.dumps({"type": "clipboard", "format": "text/html", "data": "AAAA"}).encode()
        self.assertIsNone(bridge.decode_message(html))
        empty = json.dumps({"type": "clipboard", "format": "image/png", "data": ""}).encode()
        self.assertIsNone(bridge.decode_message(empty))
        bad_utf8 = json.dumps(
            {"type": "clipboard", "format": bridge.TEXT_FORMAT, "data": base64.b64encode(b"\xff\xfe").decode()}
        ).encode()
        self.assertIsNone(bridge.decode_message(bad_utf8))

    def test_decode_rejects_malformed_messages(self) -> None:
        for line in (
            b'{"type":"catalog"}',
            b'{"type":"clipboard","format":"image/png"}',
            b'{"type":"clipboard","format":"image/png","data":"%%%"}',
            b'{"type":"clipboard","format":"image/png","data":"AAAA","extra":1}',
            b"[]",
        ):
            with self.assertRaises(ValueError):
                bridge.decode_message(line)

    def test_watch_lines_parse_format_and_payload(self) -> None:
        encoded = base64.b64encode(b"copied").decode()
        self.assertEqual(
            bridge.parse_watch_line(f"{bridge.TEXT_FORMAT}\t{encoded}".encode()),
            (bridge.TEXT_FORMAT, b"copied"),
        )
        self.assertIsNone(bridge.parse_watch_line(b"no separator"))
        self.assertIsNone(bridge.parse_watch_line(f"text/html\t{encoded}".encode()))
        self.assertIsNone(bridge.parse_watch_line(f"{bridge.TEXT_FORMAT}\t".encode()))


class ClipboardSyncTests(unittest.TestCase):
    def test_echoes_are_suppressed_in_both_directions(self) -> None:
        recorder = Recorder()
        sync = bridge.ClipboardSync(recorder.send, recorder.copy)

        self.assertTrue(sync.host_changed(bridge.TEXT_FORMAT, b"from mac"))
        self.assertEqual(recorder.copied, [(bridge.TEXT_FORMAT, b"from mac")])
        # wl-copy re-announces the selection through wl-paste --watch.
        self.assertFalse(sync.guest_changed(bridge.TEXT_FORMAT, b"from mac"))
        self.assertEqual(recorder.sent, [])

        self.assertTrue(sync.guest_changed(bridge.TEXT_FORMAT, b"from guest"))
        self.assertEqual(json.loads(recorder.sent[-1])["data"], base64.b64encode(b"from guest").decode())
        # The host applies it to the pasteboard and must not send it back.
        self.assertFalse(sync.host_changed(bridge.TEXT_FORMAT, b"from guest"))
        self.assertEqual(len(recorder.copied), 1)

        self.assertTrue(sync.host_changed(bridge.PNG_FORMAT, b"\x89PNG"))
        self.assertEqual(recorder.copied[-1], (bridge.PNG_FORMAT, b"\x89PNG"))
        self.assertFalse(sync.guest_changed(bridge.PNG_FORMAT, b"\x89PNG"))
        # Copying earlier guest content again is a real change once the host moved on.
        self.assertTrue(sync.guest_changed(bridge.TEXT_FORMAT, b"from guest"))
        self.assertTrue(sync.host_changed(bridge.TEXT_FORMAT, b"from mac"))
        self.assertFalse(sync.guest_changed(bridge.TEXT_FORMAT, b"from mac"))

    def test_unsupported_or_oversized_guest_selections_are_dropped(self) -> None:
        recorder = Recorder()
        sync = bridge.ClipboardSync(recorder.send, recorder.copy)
        self.assertFalse(sync.guest_changed("text/html", b"<b>x</b>"))
        self.assertFalse(sync.guest_changed(bridge.TEXT_FORMAT, b""))
        self.assertFalse(sync.guest_changed(bridge.TEXT_FORMAT, b"x" * (bridge.MAX_PAYLOAD_BYTES + 1)))
        self.assertEqual(recorder.sent, [])


if __name__ == "__main__":
    unittest.main()
