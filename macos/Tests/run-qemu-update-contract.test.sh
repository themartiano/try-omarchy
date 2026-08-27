#!/bin/bash

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd -P)
macos_dir=$(cd "$test_dir/.." && pwd -P)
repo_dir=$(cd "$macos_dir/.." && pwd -P)

fail() {
  printf 'run-qemu-update-contract.test: %s\n' "$*" >&2
  exit 1
}

assert() {
  "$@" || fail "assertion failed: $*"
}

assert_eq() {
  [[ $1 == "$2" ]] || fail "expected [$2], got [$1]"
}

assert_contains() {
  [[ $1 == *"$2"* ]] || fail "expected output to contain [$2], got [$1]"
}

assert_not_contains() {
  [[ $1 != *"$2"* ]] || fail "expected output not to contain [$2], got [$1]"
}

assert_line_pair() {
  local path=$1
  local first=$2
  local second=$3
  awk -v first="$first" -v second="$second" \
    'previous == first && $0 == second { found = 1 } { previous = $0 } END { exit !found }' \
    "$path" || fail "expected adjacent log lines [$first] and [$second] in $path"
}

assert_before() {
  local path=$1
  local first=$2
  local second=$3
  awk -v first="$first" -v second="$second" '
    index($0, first) && !first_line { first_line = NR }
    index($0, second) && !second_line { second_line = NR }
    END { exit !(first_line && second_line && first_line < second_line) }
  ' "$path" || fail "expected [$first] before [$second] in $path"
}

test_root=$(mktemp -d '/private/tmp/omarchy-qemu-update-contract.XXXXXX')
case "$test_root" in
  /private/tmp/omarchy-qemu-update-contract.??????) ;;
  *) fail "unexpected test root: $test_root" ;;
esac
cleanup() {
  /bin/rm -rf "$test_root"
}
trap cleanup EXIT HUP INT TERM

fixture_repo="$test_root/repo"
fixture_macos="$fixture_repo/macos"
fixture_guest="$test_root/guest"
shim_dir="$test_root/bin"
mkdir -p \
  "$fixture_macos/.build/qemu-gpu-runtime/bin" \
  "$fixture_macos/.build/release" \
  "$fixture_guest" \
  "$shim_dir"

for source in \
  Info.plist \
  Omarchy.icns \
  OmarchyIcon.svg \
  build-app.sh \
  omarchy-vm-helper.entitlements \
  qemu-hvf.entitlements \
  qemu-persistent-storage.sh \
  render-app-icon.swift \
  run-qemu-gpu.sh; do
  /bin/cp "$macos_dir/$source" "$fixture_macos/$source"
done
chmod 755 "$fixture_macos/build-app.sh" "$fixture_macos/run-qemu-gpu.sh"

cat >"$fixture_macos/bundle-macho-dependencies.sh" <<'SH'
#!/bin/bash
set -euo pipefail
[[ -d $1 ]]
SH
chmod 755 "$fixture_macos/bundle-macho-dependencies.sh"

cat >"$fixture_macos/.build/release/omarchy-vm-helper" <<'SH'
#!/bin/bash
set -euo pipefail
if [[ ${1:-} == --bridge-native-control ]]; then
  if [[ -n ${FAKE_CONTROL_LOG:-} ]]; then
    printf '%s\n' "$@" >"$FAKE_CONTROL_LOG"
  fi
  if [[ ${FAKE_CONTROL_EVENT:-validated} == validated ]]; then
    printf '%s\n' validated >"$4"
    chmod 600 "$4"
  fi
  exit "${FAKE_CONTROL_STATUS:-0}"
fi
if [[ ${1:-} == --bridge-native-audio || ${1:-} == --bridge-native-clipboard ]]; then
  while kill -0 "$2" 2>/dev/null; do
    sleep 0.05
  done
fi
exit 0
SH
chmod 755 "$fixture_macos/.build/release/omarchy-vm-helper"

cat >"$fixture_macos/.build/qemu-gpu-runtime/bin/qemu-system-aarch64" <<'SH'
#!/bin/bash
# Binary identity markers inspected by run-qemu-gpu.sh:
# TryOmarchy.icns
# OMARCHY_SDL_AUDIO_CONTROL_DIRECTORY
# OMARCHY_SDL_INPUT_DEVICE_NAME
# OMARCHY_SDL_OUTPUT_DEVICE_NAME
# guest_owner_uid
# guest_owner_gid
case " $* " in
  *' -accel help '*) printf '%s\n' hvf ;;
  *' -machine help '*) printf '%s\n' 'virt                 ARM Virtual Machine' ;;
  *' -cpu help '*) printf '%s\n' '  host' ;;
  *' -display help '*) printf '%s\n' cocoa ;;
  *' -device help '*)
    for device in \
      hda-micro intel-hda virtconsole virtserialport virtio-balloon-pci \
      virtio-9p-pci virtio-blk-pci virtio-gpu-gl-pci virtio-keyboard-pci virtio-net-pci \
      virtio-rng-pci virtio-serial-pci virtio-tablet-pci; do
      printf 'name "%s"\n' "$device"
    done
    ;;
  *' -help '*)
    printf '%s\n' \
      '-add-fd fd=fd,set=set[,opaque=opaque]' \
      'full-grab=on|off'
    ;;
  *' -machine virt -netdev help '*) printf '%s\n' user ;;
  *' -machine virt -audiodev help '*) printf '%s\n' sdl ;;
  *' -device virtio-gpu-gl-pci,help '*) printf '%s\n' 'romfile=<str>' ;;
  *)
    exec /usr/bin/python3 - "$@" <<'PY'
import os
from pathlib import Path
import socket
import sys
import time

arguments = sys.argv[1:]
log = os.environ.get("FAKE_QEMU_LOG")
if log:
    Path(log).write_text("\n".join(arguments) + "\n")

socket_paths = []
for argument in arguments:
    if argument.startswith("unix:"):
        socket_paths.append(argument[5:].split(",", 1)[0])
    elif argument.startswith("socket,"):
        for field in argument.split(","):
            if field.startswith("path="):
                socket_paths.append(field[5:])

servers = []
for path in socket_paths:
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX)
    server.bind(path)
    server.listen(1)
    servers.append(server)

time.sleep(float(os.environ.get("FAKE_QEMU_LIFETIME", "0.35")))
for server in servers:
    server.close()
status = int(os.environ.get("FAKE_QEMU_STATUS", "0"))
lifecycle_log = os.environ.get("FAKE_LIFECYCLE_LOG")
if lifecycle_log:
    with Path(lifecycle_log).open("a") as stream:
        stream.write(f"qemu-exit {status}\n")
raise SystemExit(status)
PY
    ;;
esac
SH
chmod 755 "$fixture_macos/.build/qemu-gpu-runtime/bin/qemu-system-aarch64"

cat >"$shim_dir/codesign" <<'SH'
#!/bin/bash
set -euo pipefail
for argument in "$@"; do
  if [[ $argument == -d ]]; then
    printf '%s\n' '<key>com.apple.security.hypervisor</key>' >&2
    break
  fi
done
SH

cat >"$shim_dir/file" <<'SH'
#!/bin/bash
printf '%s: Mach-O 64-bit executable arm64\n' "$1"
SH

cat >"$shim_dir/sysctl" <<'SH'
#!/bin/bash
set -euo pipefail
if [[ $# == 2 && $1 == -n && ($2 == hw.logicalcpu || $2 == hw.ncpu) ]]; then
  printf '8\n'
  exit 0
fi
exec /usr/sbin/sysctl "$@"
SH

cat >"$shim_dir/swift" <<'SH'
#!/bin/bash
exit 0
SH

cat >"$shim_dir/xcrun" <<'SH'
#!/bin/bash
set -euo pipefail
output=''
while (($#)); do
  if [[ $1 == -o ]]; then
    output=$2
    shift 2
  else
    shift
  fi
done
[[ -n $output ]]
cat >"$output" <<'RENDERER'
#!/bin/bash
set -euo pipefail
: >"$2"
RENDERER
chmod 755 "$output"
SH

cat >"$shim_dir/sips" <<'SH'
#!/bin/bash
set -euo pipefail
output=''
while (($#)); do
  if [[ $1 == --out ]]; then
    output=$2
    shift 2
  else
    shift
  fi
done
[[ -n $output ]]
: >"$output"
SH

cat >"$shim_dir/iconutil" <<'SH'
#!/bin/bash
# Exercise build-app's tracked-icon fallback.
exit 1
SH

cat >"$shim_dir/ditto" <<'SH'
#!/bin/bash
set -euo pipefail
mkdir -p "$2"
/bin/cp -R "$1"/. "$2"/
SH

cat >"$shim_dir/zstd" <<'SH'
#!/bin/bash
exit 0
SH
chmod 755 "$shim_dir"/*

# The fixture intentionally omits the multi-gigabyte raw images, just like the
# release app. Their signed raw sizes and digests remain present in the
# manifest while tiny compressed transport fixtures exercise the build path.
python3 - "$repo_dir/guest/spec.json" "$fixture_guest" <<'PY'
import hashlib
import json
from pathlib import Path
import shutil
import sys

spec_path = Path(sys.argv[1])
guest = Path(sys.argv[2])
spec = json.loads(spec_path.read_text())
shutil.copyfile(spec_path, guest / "build-spec.json")

contents = {
    "LICENSE.omarchy": b"MIT fixture\n",
    "initramfs-linux.img": b"070701fixture-initramfs",
    "packages.lock.txt": b"fixture-package 1\n",
    "provenance.json": b'{"normalizedUpstreamTree":"fixture-tree"}\n',
    "rootfs.ext4.zst": b"\x28\xb5\x2f\xfdroot-fixture",
    "update.ext4.zst": b"\x28\xb5\x2f\xfdupdate-fixture",
    "vmlinuz-linux": b"\0" * 56 + b"ARM\x64" + b"fixture-kernel",
}
for name, data in contents.items():
    (guest / name).write_bytes(data)

contracts = {
    "LICENSE.omarchy": ("guest-license", "text/plain"),
    "build-spec.json": ("guest-metadata", "application/json"),
    "initramfs-linux.img": ("guest-initramfs", "application/vnd.linux.initramfs"),
    "packages.lock.txt": ("guest-metadata", "text/plain"),
    "provenance.json": ("guest-metadata", "application/json"),
    "rootfs.ext4": ("guest-rootfs", "application/vnd.omarchy.ext4"),
    "rootfs.ext4.zst": ("guest-rootfs-compressed", "application/zstd"),
    "update.ext4": ("guest-update-disk", "application/vnd.try-omarchy.update-ext4"),
    "update.ext4.zst": ("guest-update-disk-compressed", "application/zstd"),
    "vmlinuz-linux": ("guest-kernel", "application/vnd.linux.kernel"),
}
raw_contracts = {
    "rootfs.ext4": (6144 * 1024 * 1024, "a" * 64),
    "update.ext4": (8 * 1024 * 1024, "b" * 64),
}
artifacts = []
checksums = {}
for name, (role, media_type) in contracts.items():
    if name in raw_contracts:
        size, digest = raw_contracts[name]
    else:
        data = (guest / name).read_bytes()
        size = len(data)
        digest = hashlib.sha256(data).hexdigest()
    artifacts.append(
        {
            "bytes": size,
            "mediaType": media_type,
            "path": name,
            "role": role,
            "sha256": digest,
        }
    )
    checksums[name] = digest

manifest = {
    "artifacts": artifacts,
    "build": {
        "builderImageDigest": None,
        "builtAt": "2026-08-16T00:27:41Z",
        "sourceDateEpoch": spec["image"]["sourceDateEpoch"],
    },
    "guest": {
        "architecture": "aarch64",
        "display": spec["guest"]["virtualDisplay"],
        "distribution": "Arch Linux",
        "kernelCommandLine": spec["runtime"]["kernelCommandLine"],
        "profile": "factory",
        "username": None,
    },
    "kind": "try-omarchy-guest-artifacts",
    "normalizedUpstreamTree": "fixture-tree",
    "schemaVersion": 1,
    "upstream": spec["upstream"],
}
manifest_data = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
(guest / "guest-manifest.json").write_bytes(manifest_data)
checksums["guest-manifest.json"] = hashlib.sha256(manifest_data).hexdigest()
(guest / "SHA256SUMS").write_text(
    "".join(f"{checksums[name]}  {name}\n" for name in sorted(checksums))
)
PY

if ! PATH="$shim_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
  "$fixture_macos/build-app.sh" --guest-dir "$fixture_guest" \
  >"$test_root/build.stdout" 2>"$test_root/build.stderr"; then
  /bin/cat "$test_root/build.stderr" >&2
  fail "fixture app build failed"
fi

app="$fixture_repo/dist/Try Omarchy.app"
launch_plist="$app/Contents/Resources/guest/launch.plist"
assert test -f "$app/Contents/Resources/guest/update.ext4.zst"
assert test -f "$launch_plist"

plist_read() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$launch_plist"
}

expected_bundle_identity=$(shasum -a 256 "$fixture_guest/guest-manifest.json" | awk '{print $1}')
expected_kernel_command_line=$(python3 -c \
  'import json,sys; print(json.load(open(sys.argv[1]))["runtime"]["kernelCommandLine"])' \
  "$fixture_guest/build-spec.json")
assert_eq "$(plist_read bundleIdentity)" "$expected_bundle_identity"
assert_eq "$(plist_read sourceDiskSHA256)" "$(printf 'a%.0s' {1..64})"
assert_eq "$(plist_read sourceDiskBytes)" 6442450944
assert_eq "$(plist_read compressedDiskBytes)" \
  "$(stat -f '%z' "$fixture_guest/rootfs.ext4.zst")"
assert_eq "$(plist_read workingDiskBytes)" 25769803776
assert_eq "$(plist_read kernelCommandLine)" "$expected_kernel_command_line"
assert_eq "$(plist_read updateDiskSHA256)" "$(printf 'b%.0s' {1..64})"
assert_eq "$(plist_read updateDiskBytes)" 8388608
assert_eq "$(plist_read compressedUpdateDiskBytes)" \
  "$(stat -f '%z' "$fixture_guest/update.ext4.zst")"
assert_eq "$(plist_read guestStateSchema)" 2
assert_eq "$(plist_read bootABI)" arm64-qemu-direct-v1
assert_eq "$(plist_read controlPort)" dev.tryomarchy.control
assert_eq "$(plist_read protocolVersion)" 1

# Re-read the release configuration through the launcher. This confirms that
# a clean release app consumes exactly the same thirteen-field record that the
# build wrote, without Python or any raw disk being present.
inspect_record=$(PATH="$shim_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
  OMARCHY_QEMU_GPU_INSPECT_ONLY=1 \
  "$app/Contents/Resources/scripts/run-qemu-gpu.sh")
IFS=$'\t' read -r \
  inspect_identity inspect_root_sha inspect_root_bytes inspect_root_zst_bytes \
  inspect_working_bytes inspect_command_line inspect_update_sha \
  inspect_update_bytes inspect_update_zst_bytes inspect_schema inspect_abi \
  inspect_control_port inspect_protocol inspect_extra <<<"$inspect_record"
assert_eq "$inspect_identity" "$expected_bundle_identity"
assert_eq "$inspect_root_sha" "$(printf 'a%.0s' {1..64})"
assert_eq "$inspect_root_bytes" 6442450944
assert_eq "$inspect_root_zst_bytes" "$(stat -f '%z' "$fixture_guest/rootfs.ext4.zst")"
assert_eq "$inspect_working_bytes" 25769803776
assert_eq "$inspect_command_line" "$expected_kernel_command_line"
assert_eq "$inspect_update_sha" "$(printf 'b%.0s' {1..64})"
assert_eq "$inspect_update_bytes" 8388608
assert_eq "$inspect_update_zst_bytes" "$(stat -f '%z' "$fixture_guest/update.ext4.zst")"
assert_eq "$inspect_schema" 2
assert_eq "$inspect_abi" arm64-qemu-direct-v1
assert_eq "$inspect_control_port" dev.tryomarchy.control
assert_eq "$inspect_protocol" 1
assert_eq "$inspect_extra" ''

# The signed base command line cannot pre-populate arguments owned by the
# launcher. In particular, a bundled transaction nonce would make a normal
# health report look like an update trial and could power the guest off.
reserved_guest="$test_root/reserved-argument-guest"
/bin/cp -R "$app/Contents/Resources/guest" "$reserved_guest"
/bin/rm -f "$reserved_guest/launch.plist"
python3 - "$reserved_guest" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

guest = Path(sys.argv[1])
spec_path = guest / "build-spec.json"
spec = json.loads(spec_path.read_text())
spec["runtime"]["kernelCommandLine"] += " tryomarchy.transaction=" + "d" * 64
spec_path.write_text(json.dumps(spec, indent=2, sort_keys=True) + "\n")

manifest_path = guest / "guest-manifest.json"
manifest = json.loads(manifest_path.read_text())
manifest["guest"]["kernelCommandLine"] = spec["runtime"]["kernelCommandLine"]
for record in manifest["artifacts"]:
    if record["path"] == "build-spec.json":
        payload = spec_path.read_bytes()
        record["bytes"] = len(payload)
        record["sha256"] = hashlib.sha256(payload).hexdigest()
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")

checksums = {}
for line in (guest / "SHA256SUMS").read_text().splitlines():
    digest, name = line.split("  ", 1)
    checksums[name] = digest
checksums["build-spec.json"] = hashlib.sha256(spec_path.read_bytes()).hexdigest()
checksums["guest-manifest.json"] = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
(guest / "SHA256SUMS").write_text(
    "".join(f"{checksums[name]}  {name}\n" for name in sorted(checksums))
)
PY
if env \
  PATH="$shim_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
  OMARCHY_QEMU_GPU_INSPECT_ONLY=1 \
  "$app/Contents/Resources/scripts/run-qemu-gpu.sh" "$reserved_guest" \
  >"$test_root/reserved.stdout" 2>"$test_root/reserved.stderr"; then
  fail 'launcher accepted a reserved kernel command-line argument'
fi
assert_contains "$(<"$test_root/reserved.stderr")" \
  'kernel command line contains a launcher-owned argument'

# Replace only the app's storage implementation with a recording test double.
# The production launcher, launch.plist parsing, QEMU command construction,
# child-process supervision, control-event validation, and outcome decisions
# continue to run unchanged.
cat >"$app/Contents/Resources/scripts/qemu-persistent-storage.sh" <<'SH'
#!/bin/bash

QEMU_PERSISTENT_STORAGE_INCOMPATIBLE_STATUS=78
QEMU_PERSISTENT_STORAGE_UPDATE_REQUIRED_STATUS=79
QEMU_PERSISTENT_STORAGE_QEMU_ADD_FD='fd=9,set=77,opaque=omarchy-persistent-lock'
QEMU_PERSISTENT_STORAGE_UPDATE_IMAGE=''
QEMU_PERSISTENT_STORAGE_UPDATE_STATE=''
QEMU_PERSISTENT_STORAGE_UPDATE_HEALTH_TOKEN=''
QEMU_PERSISTENT_STORAGE_CANDIDATE_DISK=''
QEMU_PERSISTENT_STORAGE_CANDIDATE_KERNEL=''
QEMU_PERSISTENT_STORAGE_CANDIDATE_INITRAMFS=''
QEMU_PERSISTENT_STORAGE_ACTIVE_KERNEL=''
QEMU_PERSISTENT_STORAGE_ACTIVE_INITRAMFS=''
QEMU_IMMUTABLE_SOURCE_DISK=''
QEMU_SELECTED_DISK=''
QEMU_SELECTED_STORAGE_MODE=''
QEMU_PERSISTENT_STORAGE_DIRECTORY=''

qps_test_log() {
  printf '%s\n' "$*" >>"$FAKE_STORAGE_LOG"
}

qemu_persistent_storage_materialize_update_image() {
  qps_test_log "materialize-update $*"
  mkdir -p "$OMARCHY_TEST_RUNTIME_DIR"
  QEMU_PERSISTENT_STORAGE_UPDATE_IMAGE="$OMARCHY_TEST_RUNTIME_DIR/update.ext4"
  printf '%s\n' update >"$QEMU_PERSISTENT_STORAGE_UPDATE_IMAGE"
  chmod 600 "$QEMU_PERSISTENT_STORAGE_UPDATE_IMAGE"
}

qemu_persistent_storage_prepare_update() {
  qps_test_log "prepare-update $*"
  mkdir -p "$OMARCHY_TEST_RUNTIME_DIR/candidate" "$OMARCHY_TEST_RUNTIME_DIR/boot"
  QEMU_PERSISTENT_STORAGE_CANDIDATE_DISK="$OMARCHY_TEST_RUNTIME_DIR/candidate/rootfs.ext4"
  QEMU_PERSISTENT_STORAGE_CANDIDATE_KERNEL="$OMARCHY_TEST_RUNTIME_DIR/boot/kernel"
  QEMU_PERSISTENT_STORAGE_CANDIDATE_INITRAMFS="$OMARCHY_TEST_RUNTIME_DIR/boot/initramfs"
  printf '%s\n' candidate >"$QEMU_PERSISTENT_STORAGE_CANDIDATE_DISK"
  /bin/cp "$5" "$QEMU_PERSISTENT_STORAGE_CANDIDATE_KERNEL"
  /bin/cp "$6" "$QEMU_PERSISTENT_STORAGE_CANDIDATE_INITRAMFS"
  chmod 600 \
    "$QEMU_PERSISTENT_STORAGE_CANDIDATE_DISK" \
    "$QEMU_PERSISTENT_STORAGE_CANDIDATE_KERNEL" \
    "$QEMU_PERSISTENT_STORAGE_CANDIDATE_INITRAMFS"
  QEMU_PERSISTENT_STORAGE_UPDATE_STATE=${FAKE_STORAGE_UPDATE_STATE:-candidate}
  QEMU_PERSISTENT_STORAGE_UPDATE_HEALTH_TOKEN=$(printf 'c%.0s' {1..64})
}

qemu_persistent_storage_commit_update() {
  qps_test_log "commit-update $*"
  [[ ${FAKE_STORAGE_COMMIT_STATUS:-0} == 0 ]] || return "$FAKE_STORAGE_COMMIT_STATUS"
}

qemu_persistent_storage_finalize_update() {
  qps_test_log 'finalize-update'
  [[ ${FAKE_STORAGE_FINALIZE_STATUS:-0} == 0 ]] || return "$FAKE_STORAGE_FINALIZE_STATUS"
}

qemu_persistent_storage_rollback_update() {
  qps_test_log 'rollback-update'
  [[ ${FAKE_STORAGE_ROLLBACK_STATUS:-0} == 0 ]] || return "$FAKE_STORAGE_ROLLBACK_STATUS"
}

qemu_persistent_storage_release_lock() {
  qps_test_log 'release-lock'
}

qemu_persistent_storage_materialize_source() {
  qps_test_log "materialize-source $*"
  mkdir -p "$OMARCHY_TEST_RUNTIME_DIR/source"
  QEMU_IMMUTABLE_SOURCE_DISK="$OMARCHY_TEST_RUNTIME_DIR/source/rootfs.ext4"
  printf '%s\n' source >"$QEMU_IMMUTABLE_SOURCE_DISK"
  chmod 600 "$QEMU_IMMUTABLE_SOURCE_DISK"
}
qemu_persistent_storage_stage_boot_kit() {
  qps_test_log "stage-boot-kit $*"
}
qemu_persistent_storage_select() {
  qps_test_log "select $*"
  mkdir -p "$OMARCHY_TEST_RUNTIME_DIR/active"
  QEMU_SELECTED_DISK="$OMARCHY_TEST_RUNTIME_DIR/active/rootfs.ext4"
  printf '%s\n' active >"$QEMU_SELECTED_DISK"
  chmod 600 "$QEMU_SELECTED_DISK"
  QEMU_SELECTED_STORAGE_MODE=persistent
  QEMU_PERSISTENT_STORAGE_DIRECTORY="$OMARCHY_TEST_RUNTIME_DIR/active"
  QEMU_PERSISTENT_STORAGE_UPDATE_STATE=${FAKE_NORMAL_UPDATE_STATE:-committed}
}
SH
chmod 644 "$app/Contents/Resources/scripts/qemu-persistent-storage.sh"

launcher="$app/Contents/Resources/scripts/run-qemu-gpu.sh"
control_token=$(printf 'c%.0s' {1..64})

run_update() {
  local scenario=$1
  local expected_status=$2
  shift 2
  local scenario_dir="$test_root/$scenario"
  local actual_status=0
  mkdir -p "$scenario_dir/runtime"
  : >"$scenario_dir/storage.log"
  if env \
    PATH="$shim_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
    OMARCHY_TEST_RUNTIME_DIR="$scenario_dir/runtime" \
    FAKE_STORAGE_LOG="$scenario_dir/storage.log" \
    FAKE_QEMU_LOG="$scenario_dir/qemu.log" \
    FAKE_LIFECYCLE_LOG="$scenario_dir/storage.log" \
    FAKE_CONTROL_LOG="$scenario_dir/control.log" \
    "$@" \
    "$launcher" --update-storage-only \
    >"$scenario_dir/stdout" 2>"$scenario_dir/stderr"; then
    actual_status=0
  else
    actual_status=$?
  fi
  if [[ $actual_status != "$expected_status" ]]; then
    printf '%s\n' "--- $scenario stderr ---" >&2
    /bin/cat "$scenario_dir/stderr" >&2 || true
    printf '%s\n' "--- $scenario storage log ---" >&2
    /bin/cat "$scenario_dir/storage.log" >&2 || true
    fail "scenario $scenario: expected status $expected_status, got $actual_status"
  fi
}

run_normal_launch() {
  local scenario=$1
  local expected_status=$2
  shift 2
  local scenario_dir="$test_root/$scenario"
  local actual_status=0
  mkdir -p "$scenario_dir/runtime"
  : >"$scenario_dir/storage.log"
  if env \
    PATH="$shim_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
    OMARCHY_TEST_RUNTIME_DIR="$scenario_dir/runtime" \
    FAKE_STORAGE_LOG="$scenario_dir/storage.log" \
    FAKE_QEMU_LOG="$scenario_dir/qemu.log" \
    FAKE_LIFECYCLE_LOG="$scenario_dir/storage.log" \
    FAKE_CONTROL_LOG="$scenario_dir/control.log" \
    FAKE_NORMAL_UPDATE_STATE=committed \
    "$@" \
    "$launcher" \
    >"$scenario_dir/stdout" 2>"$scenario_dir/stderr"; then
    actual_status=0
  else
    actual_status=$?
  fi
  if [[ $actual_status != "$expected_status" ]]; then
    printf '%s\n' "--- $scenario stderr ---" >&2
    /bin/cat "$scenario_dir/stderr" >&2 || true
    printf '%s\n' "--- $scenario storage log ---" >&2
    /bin/cat "$scenario_dir/storage.log" >&2 || true
    fail "scenario $scenario: expected status $expected_status, got $actual_status"
  fi
}

run_update success 0 \
  FAKE_CONTROL_EVENT=validated \
  FAKE_CONTROL_STATUS=0 \
  FAKE_QEMU_STATUS=0

success_qemu_log="$test_root/success/qemu.log"
success_control_log="$test_root/success/control.log"
success_storage_log="$test_root/success/storage.log"
success_stderr=$(<"$test_root/success/stderr")
assert_contains "$success_stderr" '[qemu-gpu] Updating a protected clone of the saved VM.'
assert_contains "$success_stderr" \
  '[qemu-gpu] Update complete; rollback is retained through the first normal launch.'
assert_line_pair "$success_qemu_log" -display none
assert_line_pair "$success_qemu_log" -device \
  'virtserialport,bus=omarchy-serial.0,nr=3,chardev=omarchy-control,name=dev.tryomarchy.control'
success_qemu_arguments=$(<"$success_qemu_log")
assert_contains "$success_qemu_arguments" \
  'id=omarchy-update,file='
assert_contains "$success_qemu_arguments" \
  'format=raw,media=disk,readonly=on,cache=none'
assert_contains "$success_qemu_arguments" 'tryomarchy.update=1'
assert_contains "$success_qemu_arguments" "tryomarchy.transaction=$control_token"
assert_contains "$success_qemu_arguments" 'systemd.unit=multi-user.target'
assert_not_contains "$success_qemu_arguments" '-netdev'
assert_not_contains "$success_qemu_arguments" '-audiodev'
assert_not_contains "$success_qemu_arguments" 'display cocoa'

assert_eq "$(sed -n '1p' "$success_control_log")" --bridge-native-control
assert_eq "$(sed -n '5p' "$success_control_log")" update
assert_eq "$(sed -n '6p' "$success_control_log")" "$control_token"
assert_eq "$(sed -n '7p' "$success_control_log")" arm64-qemu-direct-v1
assert_eq "$(sed -n '8p' "$success_control_log")" 2
assert_contains "$(<"$success_storage_log")" 'materialize-update '
assert_contains "$(<"$success_storage_log")" 'prepare-update '
assert_before "$success_storage_log" prepare-update 'qemu-exit 0'
assert_before "$success_storage_log" 'qemu-exit 0' commit-update
assert_not_contains "$(<"$success_storage_log")" finalize-update
assert_not_contains "$(<"$success_storage_log")" rollback-update

# A bridge that exits without publishing the O_EXCL health marker must leave
# the old workspace active and must never reach commit or finalization.
run_update missing-health 1 \
  FAKE_CONTROL_EVENT=missing \
  FAKE_CONTROL_STATUS=0 \
  FAKE_QEMU_LIFETIME=10 \
  FAKE_QEMU_STATUS=0
missing_health_storage=$(<"$test_root/missing-health/storage.log")
assert_contains "$missing_health_storage" rollback-update
assert_not_contains "$missing_health_storage" commit-update
assert_not_contains "$missing_health_storage" finalize-update
assert_contains "$(<"$test_root/missing-health/stderr")" \
  'the original VM was restored'

# Even a fully validated guest event cannot activate a candidate if the update
# VM itself exits unsuccessfully.
run_update qemu-failure 1 \
  FAKE_CONTROL_EVENT=validated \
  FAKE_CONTROL_STATUS=0 \
  FAKE_QEMU_STATUS=9
qemu_failure_storage=$(<"$test_root/qemu-failure/storage.log")
assert_contains "$qemu_failure_storage" rollback-update
assert_not_contains "$qemu_failure_storage" commit-update
assert_not_contains "$qemu_failure_storage" finalize-update

# A failed atomic publication is also rolled back; successful health alone is
# insufficient to discard the predecessor generation.
run_update commit-failure 1 \
  FAKE_CONTROL_EVENT=validated \
  FAKE_CONTROL_STATUS=0 \
  FAKE_QEMU_STATUS=0 \
  FAKE_STORAGE_COMMIT_STATUS=7
commit_failure_storage=$(<"$test_root/commit-failure/storage.log")
assert_before "$test_root/commit-failure/storage.log" commit-update rollback-update
assert_not_contains "$commit_failure_storage" finalize-update
assert_contains "$(<"$test_root/commit-failure/stderr")" \
  'the original VM was restored'

# The retained predecessor is discarded only after the auto-launched normal
# graphical VM reaches the signed health service and then exits cleanly.
run_normal_launch clean-normal-launch 0 FAKE_QEMU_STATUS=0
clean_launch_storage="$test_root/clean-normal-launch/storage.log"
assert_before "$clean_launch_storage" select 'qemu-exit 0'
assert_before "$clean_launch_storage" 'qemu-exit 0' finalize-update
assert_not_contains "$(<"$clean_launch_storage")" commit-update
assert_not_contains "$(<"$clean_launch_storage")" rollback-update
clean_launch_qemu=$(<"$test_root/clean-normal-launch/qemu.log")
assert_contains "$clean_launch_qemu" 'cocoa,gl=es'
assert_not_contains "$clean_launch_qemu" tryomarchy.update=1
assert_line_pair "$test_root/clean-normal-launch/qemu.log" -device \
  'virtserialport,bus=omarchy-serial.0,nr=3,chardev=omarchy-control,name=dev.tryomarchy.control'
clean_control_log="$test_root/clean-normal-launch/control.log"
assert_eq "$(sed -n '5p' "$clean_control_log")" health
assert_eq "$(sed -n '6p' "$clean_control_log")" -
assert_eq "$(sed -n '7p' "$clean_control_log")" arm64-qemu-direct-v1
assert_eq "$(sed -n '8p' "$clean_control_log")" 2

# QEMU status zero alone is not a guest-health proof. If the normal boot never
# publishes the validated marker, keep the predecessor for the next retry.
run_normal_launch normal-health-missing 0 \
  FAKE_CONTROL_EVENT=missing \
  FAKE_QEMU_STATUS=0
missing_normal_health_storage=$(<"$test_root/normal-health-missing/storage.log")
assert_not_contains "$missing_normal_health_storage" finalize-update
assert_contains "$(<"$test_root/normal-health-missing/stderr")" \
  'rollback was retained'

# A failed first normal run keeps the predecessor available for rollback and
# propagates QEMU's failure without attempting finalization.
run_normal_launch failed-normal-launch 9 FAKE_QEMU_STATUS=9
failed_launch_storage=$(<"$test_root/failed-normal-launch/storage.log")
assert_before "$test_root/failed-normal-launch/storage.log" select 'qemu-exit 9'
assert_not_contains "$failed_launch_storage" finalize-update
assert_not_contains "$failed_launch_storage" rollback-update

printf '%s\n' 'run-qemu-update-contract.test: all tests passed'
