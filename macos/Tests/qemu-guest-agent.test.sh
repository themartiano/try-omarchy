#!/bin/bash

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd -P)
repo_dir=$(cd "$test_dir/../.." && pwd -P)

python3 - "$repo_dir" <<'PY'
import json
from pathlib import Path
import sys

repo = Path(sys.argv[1])
launcher = (repo / "macos/run-qemu-gpu.sh").read_text()
packages = (repo / "guest/packages.txt").read_text().splitlines()
package_lock = json.loads((repo / "guest/packages.lock.json").read_text())
spec = json.loads((repo / "guest/spec.json").read_text())

assert packages.count("qemu-guest-agent") == 1, "qemu-guest-agent must be a direct guest package"
assert "qemu-guest-agent" in package_lock["packages"], "qemu-guest-agent must be pinned in the package lock"
assert spec["runtime"]["guestAgent"] == {
    "device": "virtserialport",
    "port": "org.qemu.guest_agent.0",
}
assert 'case ${OMARCHY_QEMU_GUEST_AGENT:-0} in' in launcher
assert '*) fail "OMARCHY_QEMU_GUEST_AGENT must be 0 or 1" ;;' in launcher
assert launcher.count("socket,id=omarchy-guest-agent,path=$guest_agent_socket,server=on,wait=off") == 1
assert launcher.count(
    "virtserialport,bus=omarchy-serial.0,nr=3,chardev=omarchy-guest-agent,name=org.qemu.guest_agent.0"
) == 1
assert "if ((guest_agent_enabled)); then\n  qemu_args+=(" in launcher
assert "guest agent: disabled" in launcher
assert "guest agent socket: %q" in launcher
assert "[[ -S $guest_agent_socket ]] || fail \"QEMU did not create its private guest-agent socket\"" in launcher
assert 'guest_agent_socket="/tmp/${work_dir##*/}/qga.sock"' in launcher
assert "umask 077\nwork_dir=$(mktemp -d '/private/tmp/omarchy-qemu-gpu.XXXXXX')" in launcher
PY

printf 'qemu-guest-agent.test: PASS\n'
