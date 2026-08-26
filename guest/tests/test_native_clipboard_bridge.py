#!/usr/bin/env python3
"""Behavior tests for the guest side of macOS clipboard sharing."""

from __future__ import annotations

import base64
import importlib.util
from importlib.machinery import SourceFileLoader
import json
import os
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

    def test_opposite_change_clears_the_echo_marker(self) -> None:
        clock = [0.0]
        recorder = Recorder()
        sync = bridge.ClipboardSync(recorder.send, recorder.copy, clock=lambda: clock[0])

        # Guest copies B, the Mac copies A, then the Mac copies B right away.
        # The final B is new content, not an echo of the guest's write.
        self.assertTrue(sync.guest_changed(bridge.TEXT_FORMAT, b"B"))
        self.assertTrue(sync.host_changed(bridge.TEXT_FORMAT, b"A"))
        self.assertTrue(sync.host_changed(bridge.TEXT_FORMAT, b"B"))
        self.assertEqual([payload for _, payload in recorder.copied], [b"A", b"B"])

        # Mirror image: Mac copies C, guest copies D, guest copies C again.
        self.assertTrue(sync.host_changed(bridge.TEXT_FORMAT, b"C"))
        self.assertFalse(sync.guest_changed(bridge.TEXT_FORMAT, b"C"))  # the wl-copy echo
        self.assertTrue(sync.guest_changed(bridge.TEXT_FORMAT, b"D"))
        self.assertTrue(sync.guest_changed(bridge.TEXT_FORMAT, b"C"))
        self.assertEqual(len(recorder.sent), 3)

    def test_echo_markers_expire(self) -> None:
        clock = [0.0]
        recorder = Recorder()
        sync = bridge.ClipboardSync(recorder.send, recorder.copy, clock=lambda: clock[0])

        self.assertTrue(sync.host_changed(bridge.TEXT_FORMAT, b"B"))
        # Inside the window the mirrored write is recognized as an echo.
        clock[0] += 0.1
        self.assertFalse(sync.guest_changed(bridge.TEXT_FORMAT, b"B"))
        # Long after, the same content from the guest is a real change.
        clock[0] += bridge.ECHO_WINDOW_SECONDS + 1
        self.assertTrue(sync.guest_changed(bridge.TEXT_FORMAT, b"B"))

    def test_unsupported_or_oversized_guest_selections_are_dropped(self) -> None:
        recorder = Recorder()
        sync = bridge.ClipboardSync(recorder.send, recorder.copy)
        self.assertFalse(sync.guest_changed("text/html", b"<b>x</b>"))
        self.assertFalse(sync.guest_changed(bridge.TEXT_FORMAT, b""))
        self.assertFalse(sync.guest_changed(bridge.TEXT_FORMAT, b"x" * (bridge.MAX_PAYLOAD_BYTES + 1)))
        self.assertEqual(recorder.sent, [])


class BoundedReadTests(unittest.TestCase):
    def read_pipe(self, payload: bytes, limit: int) -> bytes | None:
        reader, writer = os.pipe()
        try:
            with os.fdopen(writer, "wb") as sink:
                sink.write(payload)
            return bridge.read_bounded(reader, limit, 5)
        finally:
            os.close(reader)

    def test_reads_selection_within_limit(self) -> None:
        self.assertEqual(self.read_pipe(b"x" * 1000, 1000), b"x" * 1000)
        self.assertEqual(self.read_pipe(b"", 1000), b"")

    def test_rejects_oversized_selection_without_buffering_it(self) -> None:
        self.assertIsNone(self.read_pipe(b"x" * 1001, 1000))

    def test_gives_up_on_a_silent_writer(self) -> None:
        reader, writer = os.pipe()
        try:
            self.assertIsNone(bridge.read_bounded(reader, 1000, 0.05))
        finally:
            os.close(reader)
            os.close(writer)


if __name__ == "__main__":
    unittest.main()
