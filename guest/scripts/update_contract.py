#!/usr/bin/env python3
"""Shared validation and writers for the versioned guest update contract."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shlex


UPDATE_KEYS = {
    "bootABI",
    "compressedImage",
    "controlPort",
    "guestStateSchema",
    "image",
    "protocolVersion",
}


def canonical_json(value: object) -> bytes:
    return (
        json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
        + "\n"
    ).encode("ascii")


def atomic_write(path: Path, payload: bytes, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    try:
        with temporary.open("xb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.chmod(mode)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def load_release_fields(spec_path: Path) -> tuple[dict[str, object], dict[str, object]]:
    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    update = spec.get("runtime", {}).get("update")
    if not isinstance(update, dict) or set(update) != UPDATE_KEYS:
        raise ValueError("runtime.update has an unexpected schema")
    schema = update.get("guestStateSchema")
    protocol = update.get("protocolVersion")
    boot_abi = update.get("bootABI")
    control_port = update.get("controlPort")
    if not isinstance(schema, int) or isinstance(schema, bool) or schema < 1:
        raise ValueError("runtime.update.guestStateSchema must be a positive integer")
    if not isinstance(protocol, int) or isinstance(protocol, bool) or protocol < 1:
        raise ValueError("runtime.update.protocolVersion must be a positive integer")
    if not isinstance(boot_abi, str) or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", boot_abi
    ):
        raise ValueError("runtime.update.bootABI is unsafe")
    if not isinstance(control_port, str) or not re.fullmatch(
        r"dev\.tryomarchy\.[a-z0-9-]+", control_port
    ):
        raise ValueError("runtime.update.controlPort is unsafe")
    return spec, update


def make_contract(
    spec_path: Path, release_id: str
) -> tuple[dict[str, object], dict[str, object]]:
    _, update = load_release_fields(spec_path)
    if re.fullmatch(r"[0-9a-f]{64}", release_id) is None:
        raise ValueError("release identity must be a lowercase SHA-256 digest")
    state = {
        "bootABI": update["bootABI"],
        "guestStateSchema": update["guestStateSchema"],
        "kind": "try-omarchy-guest-state",
        "protocolVersion": update["protocolVersion"],
        "releaseId": release_id,
        "schemaVersion": 1,
    }
    release = dict(state)
    release["kind"] = "try-omarchy-release-contract"
    release["controlPort"] = update["controlPort"]
    return state, release


def write_contract(
    root: Path,
    spec_path: Path,
    release_id: str,
    owned_payload_sha256: str,
    update_sums_sha256: str | None = None,
) -> tuple[dict[str, object], dict[str, object]]:
    state, release = make_contract(spec_path, release_id)
    if re.fullmatch(r"[0-9a-f]{64}", owned_payload_sha256) is None:
        raise ValueError("owned payload identity must be a lowercase SHA-256 digest")
    release["ownedPayloadSha256"] = owned_payload_sha256
    atomic_write(root / "var/lib/try-omarchy/state.json", canonical_json(state))
    atomic_write(
        root / "usr/share/try-omarchy/update/release.json", canonical_json(release)
    )

    if update_sums_sha256 is not None:
        if re.fullmatch(r"[0-9a-f]{64}", update_sums_sha256) is None:
            raise ValueError("update sums identity must be a lowercase SHA-256 digest")
        environment = {
            "TRY_OMARCHY_BOOT_ABI": release["bootABI"],
            "TRY_OMARCHY_CONTROL_PORT": release["controlPort"],
            "TRY_OMARCHY_GUEST_STATE_SCHEMA": str(release["guestStateSchema"]),
            "TRY_OMARCHY_PROTOCOL_VERSION": str(release["protocolVersion"]),
            "TRY_OMARCHY_RELEASE_ID": release["releaseId"],
            "TRY_OMARCHY_OWNED_PAYLOAD_SHA256": owned_payload_sha256,
            "TRY_OMARCHY_UPDATE_SHA256SUMS": update_sums_sha256,
        }
        lines = [
            f"{name}={shlex.quote(str(value))}" for name, value in environment.items()
        ]
        atomic_write(
            root / "usr/share/try-omarchy/update/release.env",
            ("\n".join(lines) + "\n").encode("ascii"),
        )
    return state, release
