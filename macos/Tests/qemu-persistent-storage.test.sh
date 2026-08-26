#!/bin/bash

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd -P)
native_dir=$(cd "$test_dir/.." && pwd -P)
# shellcheck source=../qemu-persistent-storage.sh
source "$native_dir/qemu-persistent-storage.sh"

fail() {
  printf 'qemu-persistent-storage.test: %s\n' "$*" >&2
  exit 1
}

assert() {
  "$@" || fail "assertion failed: $*"
}

assert_eq() {
  [[ $1 == "$2" ]] || fail "expected [$2], got [$1]"
}

assert_fails() {
  if "$@"; then
    fail "command unexpectedly succeeded: $*"
  fi
}

assert_status() {
  local expected=$1
  shift
  local actual=0
  if "$@"; then
    fail "command unexpectedly succeeded: $*"
  else
    actual=$?
  fi
  assert_eq "$actual" "$expected"
}

wait_for_file() {
  local path=$1
  local attempt=0
  for ((attempt = 0; attempt < 100; attempt++)); do
    [[ -f $path ]] && return 0
    sleep 0.02
  done
  fail "timed out waiting for $path"
}

qmp_request() {
  local socket_path=$1
  local action=$2

  python3 - "$socket_path" "$action" <<'PY'
import json
import socket
import sys
import time

socket_path, action = sys.argv[1:]
connection = socket.socket(socket.AF_UNIX)
for attempt in range(250):
    try:
        connection.connect(socket_path)
        break
    except (FileNotFoundError, ConnectionRefusedError):
        if attempt == 249:
            raise
        time.sleep(0.02)
connection.settimeout(5)
stream = connection.makefile("rwb", buffering=0)


def receive():
    line = stream.readline()
    if not line:
        raise SystemExit("QMP disconnected before replying")
    return json.loads(line)


def command(name):
    stream.write(json.dumps({"execute": name}, separators=(",", ":")).encode("ascii") + b"\r\n")
    while True:
        message = receive()
        if "error" in message:
            raise SystemExit(f"QMP {name} failed: {message['error']}")
        if "return" in message:
            return message["return"]


greeting = receive()
if "QMP" not in greeting:
    raise SystemExit("QMP greeting is missing")
command("qmp_capabilities")
if action == "assert-lock-fdset":
    fdsets = command("query-fdsets")
    matches = [
        descriptor
        for fdset in fdsets
        if fdset.get("fdset-id") == 77
        for descriptor in fdset.get("fds", [])
        if descriptor.get("opaque") == "omarchy-persistent-lock"
    ]
    if len(matches) != 1 or not isinstance(matches[0].get("fd"), int):
        raise SystemExit(f"persistent lock fdset is missing or ambiguous: {fdsets!r}")
elif action == "quit":
    command("quit")
else:
    raise SystemExit(f"unknown QMP test action: {action}")
PY
}

test_root=$(mktemp -d '/private/tmp/omarchy-qemu-storage-test.XXXXXX')
case "$test_root" in
  /private/tmp/omarchy-qemu-storage-test.??????) ;;
  *) fail "unexpected test root: $test_root" ;;
esac
holder_pid=''
qemu_pid=''
cleanup() {
  qemu_persistent_storage_release_lock || true
  if [[ $holder_pid =~ ^[0-9]+$ ]]; then
    kill -TERM "$holder_pid" 2>/dev/null || true
  fi
  if [[ $qemu_pid =~ ^[0-9]+$ ]]; then
    kill -TERM "$qemu_pid" 2>/dev/null || true
  fi
  /bin/rm -rf "$test_root"
}
trap cleanup EXIT HUP INT TERM

export OMARCHY_QEMU_GPU_STATE_ROOT="$test_root/state"
export OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK=1
source_disk="$test_root/source.ext4"
dd if=/dev/zero of="$source_disk" bs=4096 count=1 >/dev/null 2>&1
printf 'immutable-base' | dd of="$source_disk" bs=1 seek=32 conv=notrunc >/dev/null 2>&1
printf '\x53\xef' | dd of="$source_disk" bs=1 seek=1080 conv=notrunc >/dev/null 2>&1
source_bytes=$(stat -f '%z' "$source_disk")
source_sha=$(shasum -a 256 "$source_disk" | awk '{print $1}')
source_disk_b="$test_root/source-b.ext4"
/bin/cp "$source_disk" "$source_disk_b"
printf 'updated-factory' | dd of="$source_disk_b" bs=1 seek=64 conv=notrunc >/dev/null 2>&1
source_bytes_b=$(stat -f '%z' "$source_disk_b")
source_sha_b=$(shasum -a 256 "$source_disk_b" | awk '{print $1}')
identity_a=$(printf 'bundle-a' | shasum -a 256 | awk '{print $1}')
identity_b=$(printf 'bundle-b' | shasum -a 256 | awk '{print $1}')
identity_c=$(printf 'bundle-c' | shasum -a 256 | awk '{print $1}')
identity_d=$(printf 'bundle-d' | shasum -a 256 | awk '{print $1}')
identity_bad=$(printf 'bundle-bad' | shasum -a 256 | awk '{print $1}')
identity_expanded=$(printf 'bundle-expanded' | shasum -a 256 | awk '{print $1}')
identity_compressed=$(printf 'bundle-compressed' | shasum -a 256 | awk '{print $1}')
identity_update_image=$(printf 'bundle-update-image' | shasum -a 256 | awk '{print $1}')

# A compressed app payload is expanded once into the private immutable-image
# cache, verified against the raw manifest digest, and reused thereafter.
compressed_disk="$test_root/source.ext4.zst"
zstd_source=$(command -v zstd)
zstd_test="$test_root/zstd"
printf '#!/bin/bash\nexec %q "$@"\n' "$zstd_source" >"$zstd_test"
chmod 700 "$zstd_test"
zstd -q -f "$source_disk" -o "$compressed_disk"
compressed_bytes=$(stat -f '%z' "$compressed_disk")
qemu_persistent_storage_materialize_source \
  "$identity_compressed" "$compressed_disk" "$compressed_bytes" \
  "$source_sha" "$source_bytes" "$zstd_test"
materialized_source=$QEMU_IMMUTABLE_SOURCE_DISK
assert cmp -s "$materialized_source" "$source_disk"
qemu_persistent_storage_materialize_source \
  "$identity_compressed" "$compressed_disk" "$compressed_bytes" \
  "$source_sha" "$source_bytes" "$zstd_test"
assert_eq "$QEMU_IMMUTABLE_SOURCE_DISK" "$materialized_source"

# A release update image has a separate immutable cache namespace from the
# factory rootfs, is digest-verified on both first use and reuse, and is exposed
# only through the update-image result global.
update_compressed_disk="$test_root/update.ext4.zst"
zstd -q -f "$source_disk_b" -o "$update_compressed_disk"
update_compressed_bytes=$(stat -f '%z' "$update_compressed_disk")
qemu_persistent_storage_materialize_update_image \
  "$identity_update_image" "$update_compressed_disk" "$update_compressed_bytes" \
  "$source_sha_b" "$source_bytes_b" "$zstd_test"
materialized_update_image=$QEMU_PERSISTENT_STORAGE_UPDATE_IMAGE
assert_eq \
  "$materialized_update_image" \
  "$OMARCHY_QEMU_GPU_STATE_ROOT/images/$identity_update_image.update.ext4"
assert cmp -s "$materialized_update_image" "$source_disk_b"
qemu_persistent_storage_materialize_update_image \
  "$identity_update_image" "$update_compressed_disk" "$update_compressed_bytes" \
  "$source_sha_b" "$source_bytes_b" "$zstd_test"
assert_eq "$QEMU_PERSISTENT_STORAGE_UPDATE_IMAGE" "$materialized_update_image"

# The factory workspace grows sparsely while its immutable source stays at the
# transport size. Relaunch validates and reuses the expanded workspace.
expanded_bytes=$((source_bytes + 16384))
qemu_persistent_storage_select \
  persistent "$identity_expanded" "$source_disk" "$source_sha" "$source_bytes" '' "$expanded_bytes"
expanded_disk=$QEMU_SELECTED_DISK
assert_eq "$(stat -f '%z' "$expanded_disk")" "$expanded_bytes"
printf 'expanded-persistence' | dd of="$expanded_disk" bs=1 seek="$source_bytes" conv=notrunc >/dev/null 2>&1
qemu_persistent_storage_release_lock
qemu_persistent_storage_select \
  persistent "$identity_expanded" "$source_disk" "$source_sha" "$source_bytes" '' "$expanded_bytes"
assert_eq "$(dd if="$QEMU_SELECTED_DISK" bs=1 skip="$source_bytes" count=20 2>/dev/null)" expanded-persistence
qemu_persistent_storage_release_lock

qemu_persistent_storage_select \
  persistent "$identity_a" "$source_disk" "$source_sha" "$source_bytes" ''
persistent_a=$QEMU_SELECTED_DISK
assert_eq "$QEMU_SELECTED_STORAGE_MODE" persistent
assert test -f "$persistent_a"
assert test -f "${persistent_a%/*}/metadata.json"
assert_eq "$(stat -f '%Lp' "$persistent_a")" 600
printf 'saved-user-data' | dd of="$persistent_a" bs=1 seek=128 conv=notrunc >/dev/null 2>&1
qemu_persistent_storage_release_lock

qemu_persistent_storage_select \
  persistent "$identity_a" "$source_disk" "$source_sha" "$source_bytes" ''
assert_eq "$QEMU_SELECTED_DISK" "$persistent_a"
saved=$(dd if="$QEMU_SELECTED_DISK" bs=1 skip=128 count=15 2>/dev/null)
assert_eq "$saved" saved-user-data

# An unrelated process cannot acquire the same identity while this descriptor
# remains locked.
assert_fails /bin/bash -c \
  'source "$1"; qemu_persistent_storage_select persistent "$2" "$3" "$4" "$5" ""' \
  qps-lock-test "$native_dir/qemu-persistent-storage.sh" \
  "$identity_a" "$source_disk" "$source_sha" "$source_bytes" 9>&-
qemu_persistent_storage_release_lock

qemu_persistent_storage_select \
  persistent "$identity_b" "$source_disk" "$source_sha" "$source_bytes" ''
persistent_b=$QEMU_SELECTED_DISK
assert test "$persistent_b" != "$persistent_a"
assert cmp -s "$persistent_b" "$source_disk"
qemu_persistent_storage_release_lock

# A user-facing launch must never relabel an older factory disk as a newer app
# build. A sole legacy disk is relocated into the stable `current` workspace,
# but the content mismatch is reported as update-required and every byte stays
# untouched. The old destructive reset path remains separately explicit.
export OMARCHY_QEMU_GPU_STATE_ROOT="$test_root/single-state"
export OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK=1
qemu_persistent_storage_select \
  persistent "$identity_a" "$source_disk" "$source_sha" "$source_bytes" ''
legacy_single_disk=$QEMU_SELECTED_DISK
printf 'single-user-data' | dd of="$legacy_single_disk" bs=1 seek=512 conv=notrunc >/dev/null 2>&1
legacy_single_metadata_sha=$(shasum -a 256 "${legacy_single_disk%/*}/metadata.json" | awk '{print $1}')
qemu_persistent_storage_release_lock

export OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK=0
assert_status "$QEMU_PERSISTENT_STORAGE_UPDATE_REQUIRED_STATUS" \
  qemu_persistent_storage_select \
    persistent "$identity_b" "$source_disk_b" "$source_sha_b" "$source_bytes_b" ''
migrated_single_disk="$OMARCHY_QEMU_GPU_STATE_ROOT/disks/current/rootfs.ext4"
assert test ! -e "$legacy_single_disk"
assert test -f "$migrated_single_disk"
assert_eq "$(dd if="$migrated_single_disk" bs=1 skip=512 count=16 2>/dev/null)" single-user-data
assert_eq \
  "$(shasum -a 256 "${migrated_single_disk%/*}/metadata.json" | awk '{print $1}')" \
  "$legacy_single_metadata_sha"

qemu_persistent_storage_select \
  reset "$identity_b" "$source_disk_b" "$source_sha_b" "$source_bytes_b" ''
single_disk=$QEMU_SELECTED_DISK
assert_eq "$single_disk" "$OMARCHY_QEMU_GPU_STATE_ROOT/disks/current/rootfs.ext4"
assert cmp -s "$single_disk" "$source_disk_b"
assert test ! -e "$legacy_single_disk"
assert grep -Fq '"schemaVersion":2' "${single_disk%/*}/metadata.json"
assert grep -Fq "\"bundleIdentity\":\"$identity_b\"" "${single_disk%/*}/metadata.json"
qemu_persistent_storage_release_lock

# Schema 1 is never trusted for launch, even if it claims the current bundle:
# the former adoption path could rewrite that metadata without changing the
# disk contents. Reset validates the recorded legacy shape, then recovers.
export OMARCHY_QEMU_GPU_STATE_ROOT="$test_root/schema-one-state"
export OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK=0
qemu_persistent_storage_select \
  persistent "$identity_a" "$source_disk" "$source_sha" "$source_bytes" ''
schema_one_disk=$QEMU_SELECTED_DISK
printf 'schema-one-user-data' | dd of="$schema_one_disk" bs=1 seek=896 conv=notrunc >/dev/null 2>&1
qemu_persistent_storage_release_lock
printf \
  '{"bundleIdentity":"%s","kind":"omarchy-qemu-persistent-disk","schemaVersion":1,"sourceRootfs":{"bytes":%s,"sha256":"%s"}}\n' \
  "$identity_b" "$source_bytes_b" "$source_sha_b" \
  >"${schema_one_disk%/*}/metadata.json"
chmod 600 "${schema_one_disk%/*}/metadata.json"

assert_status "$QEMU_PERSISTENT_STORAGE_UPDATE_REQUIRED_STATUS" \
  qemu_persistent_storage_select \
    persistent "$identity_b" "$source_disk_b" "$source_sha_b" "$source_bytes_b" ''
assert_eq \
  "$(dd if="$schema_one_disk" bs=1 skip=896 count=20 2>/dev/null)" \
  schema-one-user-data
assert grep -Fq '"schemaVersion":1' "${schema_one_disk%/*}/metadata.json"

qemu_persistent_storage_select \
  reset "$identity_b" "$source_disk_b" "$source_sha_b" "$source_bytes_b" ''
assert cmp -s "$QEMU_SELECTED_DISK" "$source_disk_b"
assert grep -Fq '"schemaVersion":2' "${QEMU_SELECTED_DISK%/*}/metadata.json"
qemu_persistent_storage_release_lock

# If reset is interrupted after detaching an incompatible schema-1 disk, the
# next launch validates that discarded transaction against its own metadata and
# reclaims it instead of leaking another multi-gigabyte VM disk.
interrupted_old_reset="$OMARCHY_QEMU_GPU_STATE_ROOT/disks/.current.discarded.interrupted"
mkdir "$interrupted_old_reset"
chmod 700 "$interrupted_old_reset"
/bin/cp "$source_disk" "$interrupted_old_reset/rootfs.ext4"
chmod 600 "$interrupted_old_reset/rootfs.ext4"
printf \
  '{"bundleIdentity":"%s","kind":"omarchy-qemu-persistent-disk","schemaVersion":1,"sourceRootfs":{"bytes":%s,"sha256":"%s"}}\n' \
  "$identity_a" "$source_bytes" "$source_sha" \
  >"$interrupted_old_reset/metadata.json"
chmod 600 "$interrupted_old_reset/metadata.json"
qemu_persistent_storage_select \
  persistent "$identity_b" "$source_disk_b" "$source_sha_b" "$source_bytes_b" ''
assert test ! -e "$interrupted_old_reset"
qemu_persistent_storage_release_lock

# Generational updates clone the complete active VM, keep the predecessor at
# disks/current until an explicit health-token commit, pair both generations
# with immutable boot kits, and retain a rollback workspace after commit.
export OMARCHY_QEMU_GPU_STATE_ROOT="$test_root/generational-state"
export OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK=0
generation_active_bytes=$((source_bytes + 8192))
generation_target_bytes=$((source_bytes_b + 32768))
qemu_persistent_storage_select \
  persistent "$identity_a" "$source_disk" "$source_sha" "$source_bytes" '' \
  "$generation_active_bytes"
generation_active_disk=$QEMU_SELECTED_DISK
printf 'generation-user-data' | dd \
  of="$generation_active_disk" bs=1 seek=$((source_bytes + 512)) conv=notrunc \
  >/dev/null 2>&1
qemu_persistent_storage_release_lock

assert_status "$QEMU_PERSISTENT_STORAGE_UPDATE_REQUIRED_STATUS" \
  qemu_persistent_storage_select \
    persistent "$identity_b" "$source_disk_b" "$source_sha_b" "$source_bytes_b" '' \
    "$generation_target_bytes"
qemu_persistent_storage_assess_update \
  "$identity_b" "$source_sha_b" "$source_bytes_b" "$generation_target_bytes"
assert_eq "$QEMU_PERSISTENT_STORAGE_UPDATE_STATE" required
assert_eq "$QEMU_PERSISTENT_STORAGE_ACTIVE_IDENTITY" "$identity_a"
assert_eq "$QEMU_PERSISTENT_STORAGE_ACTIVE_DISK" "$generation_active_disk"

active_kernel="$test_root/active-kernel"
active_initramfs="$test_root/active-initramfs"
target_kernel="$test_root/target-kernel"
target_initramfs="$test_root/target-initramfs"
printf 'active-kernel-bytes\n' >"$active_kernel"
printf 'active-initramfs-bytes\n' >"$active_initramfs"
printf 'target-kernel-bytes\n' >"$target_kernel"
printf 'target-initramfs-bytes\n' >"$target_initramfs"

# Boot-kit staging recovery accepts only private, identity-scoped files that
# hash-match the signed sources. Unknown, symlinked, and newline-crafted shapes
# are deliberately preserved.
generation_boot_root="$OMARCHY_QEMU_GPU_STATE_ROOT/boot"
recognized_boot_staging="$generation_boot_root/.${identity_b}.initializing.BOOTOK"
unknown_boot_staging="$generation_boot_root/.${identity_b}.initializing.BADBAD"
newline_boot_staging="$generation_boot_root/.${identity_b}.initializing.NLTEST"
linked_boot_staging="$generation_boot_root/.${identity_b}.initializing.LINKED"
mkdir "$recognized_boot_staging" "$unknown_boot_staging" "$newline_boot_staging"
chmod 700 "$recognized_boot_staging" "$unknown_boot_staging" "$newline_boot_staging"
/bin/cp "$target_kernel" "$recognized_boot_staging/kernel"
/bin/cp "$target_initramfs" "$recognized_boot_staging/initramfs"
chmod 600 "$recognized_boot_staging/kernel" "$recognized_boot_staging/initramfs"
printf 'must-survive\n' >"$unknown_boot_staging/unexpected"
chmod 600 "$unknown_boot_staging/unexpected"
boot_newline_entry=$'initramfs\nkernel\nmetadata.json'
printf 'must-survive\n' >"$newline_boot_staging/$boot_newline_entry"
chmod 600 "$newline_boot_staging/$boot_newline_entry"
ln -s "$test_root" "$linked_boot_staging"

# Prepare once, then rename its complete journal back to the initializing name
# and truncate only its candidate. This models a crash during a large clone;
# recovery must reclaim it without ever touching disks/current.
qemu_persistent_storage_prepare_update \
  "$identity_b" "$source_sha_b" "$source_bytes_b" "$generation_target_bytes" \
  "$target_kernel" "$target_initramfs"
qemu_persistent_storage_release_lock
assert test ! -e "$recognized_boot_staging"
assert test -f "$unknown_boot_staging/unexpected"
assert test -f "$newline_boot_staging/$boot_newline_entry"
assert test -L "$linked_boot_staging"

generation_updates_root="$OMARCHY_QEMU_GPU_STATE_ROOT/updates"
recognized_update_staging="$generation_updates_root/.current.initializing.REAPOK"
/bin/mv "$generation_updates_root/current" "$recognized_update_staging"
/usr/bin/truncate -s 2048 "$recognized_update_staging/candidate/rootfs.ext4"
unknown_update_staging="$generation_updates_root/.current.initializing.BADBAD"
newline_update_staging="$generation_updates_root/.current.initializing.NLTEST"
linked_update_staging="$generation_updates_root/.current.initializing.LINKED"
mkdir "$unknown_update_staging" "$newline_update_staging"
chmod 700 "$unknown_update_staging" "$newline_update_staging"
printf 'must-survive\n' >"$unknown_update_staging/unexpected"
chmod 600 "$unknown_update_staging/unexpected"
update_newline_entry=$'candidate\nstate\ntransaction.json'
printf 'must-survive\n' >"$newline_update_staging/$update_newline_entry"
chmod 600 "$newline_update_staging/$update_newline_entry"
ln -s "$OMARCHY_QEMU_GPU_STATE_ROOT/disks/current" "$linked_update_staging"

qemu_persistent_storage_assess_update \
  "$identity_b" "$source_sha_b" "$source_bytes_b" "$generation_target_bytes"
assert_eq "$QEMU_PERSISTENT_STORAGE_UPDATE_STATE" required
assert test ! -e "$recognized_update_staging"
assert test -f "$unknown_update_staging/unexpected"
assert test -f "$newline_update_staging/$update_newline_entry"
assert test -L "$linked_update_staging"
assert_eq \
  "$(dd if="$generation_active_disk" bs=1 skip=$((source_bytes + 512)) count=20 2>/dev/null)" \
  generation-user-data

# A discard first renames updates/current and fsyncs its parent. Model a crash
# at exactly that boundary for both a cancelled candidate and a completed
# rollback. Recovery reaps only journals whose reason, state, contents, and
# active generation all agree; malformed and symlinked lookalikes survive.
qemu_persistent_storage_prepare_update \
  "$identity_b" "$source_sha_b" "$source_bytes_b" "$generation_target_bytes" \
  "$target_kernel" "$target_initramfs"
qemu_persistent_storage_release_lock
recognized_rolled_back_tombstone="$generation_updates_root/.current.rolled-back.4242.010203"
/bin/cp -R \
  "$generation_updates_root/current" \
  "$recognized_rolled_back_tombstone"
printf 'rolling-back\n' >"$recognized_rolled_back_tombstone/state"
chmod 600 "$recognized_rolled_back_tombstone/state"
recognized_cancelled_tombstone="$generation_updates_root/.current.cancelled.4242.020304"
/bin/mv \
  "$generation_updates_root/current" \
  "$recognized_cancelled_tombstone"
_qps_fsync "$generation_updates_root"
unknown_detached_tombstone="$generation_updates_root/.current.cancelled.4242.030405"
linked_detached_tombstone="$generation_updates_root/.current.finalized.4242.040506"
unknown_reason_tombstone="$generation_updates_root/.current.unknown.4242.050607"
mkdir "$unknown_detached_tombstone" "$unknown_reason_tombstone"
chmod 700 "$unknown_detached_tombstone" "$unknown_reason_tombstone"
printf 'must-survive\n' >"$unknown_detached_tombstone/unexpected"
printf 'must-survive\n' >"$unknown_reason_tombstone/unexpected"
chmod 600 \
  "$unknown_detached_tombstone/unexpected" \
  "$unknown_reason_tombstone/unexpected"
ln -s "$OMARCHY_QEMU_GPU_STATE_ROOT/disks/current" "$linked_detached_tombstone"

qemu_persistent_storage_assess_update \
  "$identity_b" "$source_sha_b" "$source_bytes_b" "$generation_target_bytes"
assert_eq "$QEMU_PERSISTENT_STORAGE_UPDATE_STATE" required
assert test ! -e "$recognized_rolled_back_tombstone"
assert test ! -e "$recognized_cancelled_tombstone"
assert test -f "$unknown_detached_tombstone/unexpected"
assert test -L "$linked_detached_tombstone"
assert test -f "$unknown_reason_tombstone/unexpected"
assert_eq \
  "$(dd if="$generation_active_disk" bs=1 skip=$((source_bytes + 512)) count=20 2>/dev/null)" \
  generation-user-data

# The assertions above prove automatic recovery left every unrecognized path
# untouched. Remove only these test-owned fixtures before exercising retries.
/bin/rm -rf "$unknown_boot_staging" "$newline_boot_staging"
/bin/rm -f "$linked_boot_staging"
/bin/rm -rf "$unknown_update_staging" "$newline_update_staging"
/bin/rm -f "$linked_update_staging"
/bin/rm -rf "$unknown_detached_tombstone" "$unknown_reason_tombstone"
/bin/rm -f "$linked_detached_tombstone"

qemu_persistent_storage_prepare_update \
  "$identity_b" "$source_sha_b" "$source_bytes_b" "$generation_target_bytes" \
  "$target_kernel" "$target_initramfs"
assert_eq "$QEMU_PERSISTENT_STORAGE_UPDATE_STATE" candidate
assert_eq "$QEMU_PERSISTENT_STORAGE_ACTIVE_IDENTITY" "$identity_a"
assert_eq "$QEMU_PERSISTENT_STORAGE_CANDIDATE_IDENTITY" "$identity_b"
assert_eq "$QEMU_SELECTED_DISK" "$QEMU_PERSISTENT_STORAGE_CANDIDATE_DISK"
assert_eq "$QEMU_PERSISTENT_STORAGE_ACTIVE_KERNEL" ''
assert test ! -e "$OMARCHY_QEMU_GPU_STATE_ROOT/boot/$identity_a"
assert_eq \
  "$QEMU_PERSISTENT_STORAGE_CANDIDATE_KERNEL" \
  "$OMARCHY_QEMU_GPU_STATE_ROOT/boot/$identity_b/kernel"
generation_candidate_disk=$QEMU_PERSISTENT_STORAGE_CANDIDATE_DISK
generation_health_token=$QEMU_PERSISTENT_STORAGE_UPDATE_HEALTH_TOKEN
assert grep -Fq \
  '"fromBootKitAvailable":false' \
  "$OMARCHY_QEMU_GPU_STATE_ROOT/updates/current/transaction.json"
assert test -f "$generation_active_disk"
assert test -f "$generation_candidate_disk"
assert test "$generation_active_disk" != "$generation_candidate_disk"
assert_eq "$(stat -f '%z' "$generation_candidate_disk")" "$generation_target_bytes"
assert_eq \
  "$(dd if="$generation_candidate_disk" bs=1 skip=$((source_bytes + 512)) count=20 2>/dev/null)" \
  generation-user-data
printf 'candidate-migrated' | dd \
  of="$generation_candidate_disk" bs=1 seek=$((source_bytes + 4096)) conv=notrunc \
  >/dev/null 2>&1
qemu_persistent_storage_release_lock

qemu_persistent_storage_assess_update \
  "$identity_b" "$source_sha_b" "$source_bytes_b" "$generation_target_bytes"
assert_eq "$QEMU_PERSISTENT_STORAGE_UPDATE_STATE" candidate
assert_eq "$QEMU_PERSISTENT_STORAGE_UPDATE_HEALTH_TOKEN" "$generation_health_token"
assert_fails qemu_persistent_storage_commit_update "$identity_bad"
assert_eq \
  "$(dd if="$generation_active_disk" bs=1 skip=$((source_bytes + 4096)) count=18 2>/dev/null | tr -d '\000')" \
  ''

qemu_persistent_storage_commit_update "$generation_health_token"
generation_committed_disk="$OMARCHY_QEMU_GPU_STATE_ROOT/disks/current/rootfs.ext4"
assert_eq \
  "$(dd if="$generation_committed_disk" bs=1 skip=$((source_bytes + 4096)) count=18 2>/dev/null)" \
  candidate-migrated
assert test -f "$OMARCHY_QEMU_GPU_STATE_ROOT/updates/current/rollback/rootfs.ext4"

# Committed tombstones have the inverse layout: the target remains active and
# the detached journal contains the predecessor rollback. A durable orphan of
# that exact shape is also safe to reap without disturbing a live transaction.
recognized_finalized_tombstone="$generation_updates_root/.current.finalized.4242.060708"
/bin/cp -R \
  "$generation_updates_root/current" \
  "$recognized_finalized_tombstone"
qemu_persistent_storage_assess_update \
  "$identity_b" "$source_sha_b" "$source_bytes_b" "$generation_target_bytes"
assert_eq "$QEMU_PERSISTENT_STORAGE_UPDATE_STATE" committed
assert_eq "$QEMU_PERSISTENT_STORAGE_ACTIVE_IDENTITY" "$identity_b"
assert test ! -e "$recognized_finalized_tombstone"
assert test -f "$OMARCHY_QEMU_GPU_STATE_ROOT/updates/current/rollback/rootfs.ext4"

# A retained rollback generation does not block normal use of the committed
# target. Selection also reaps an interrupted atomic state-file write, exposes
# the pending cleanup state, and does not discard the rollback generation.
printf 'committed\n' >"$OMARCHY_QEMU_GPU_STATE_ROOT/updates/current/.state.ABCDEF"
chmod 600 "$OMARCHY_QEMU_GPU_STATE_ROOT/updates/current/.state.ABCDEF"
qemu_persistent_storage_select \
  persistent "$identity_b" "$source_disk_b" "$source_sha_b" "$source_bytes_b" '' \
  "$generation_target_bytes"
assert_eq "$QEMU_SELECTED_DISK" "$generation_committed_disk"
assert_eq "$QEMU_PERSISTENT_STORAGE_UPDATE_STATE" committed
assert test ! -e "$OMARCHY_QEMU_GPU_STATE_ROOT/updates/current/.state.ABCDEF"
assert test -f "$OMARCHY_QEMU_GPU_STATE_ROOT/updates/current/rollback/rootfs.ext4"
qemu_persistent_storage_release_lock

qemu_persistent_storage_rollback_update
generation_restored_disk="$OMARCHY_QEMU_GPU_STATE_ROOT/disks/current/rootfs.ext4"
assert_eq \
  "$(dd if="$generation_restored_disk" bs=1 skip=$((source_bytes + 512)) count=20 2>/dev/null)" \
  generation-user-data
assert_eq \
  "$(dd if="$generation_restored_disk" bs=1 skip=$((source_bytes + 4096)) count=18 2>/dev/null | tr -d '\000')" \
  ''
assert test ! -e "$OMARCHY_QEMU_GPU_STATE_ROOT/updates/current"
qemu_persistent_storage_assess_update \
  "$identity_b" "$source_sha_b" "$source_bytes_b" "$generation_target_bytes"
assert_eq "$QEMU_PERSISTENT_STORAGE_UPDATE_STATE" required

# Future launches can proactively persist the current generation's genuine boot
# assets. Once present, prepare reuses that pair and exposes it as active.
qemu_persistent_storage_stage_boot_kit \
  "$identity_a" "$active_kernel" "$active_initramfs"

# Once a boot kit is staged it is reused. Simulate interruption after the
# health-token gate changed the journal to `committing` and detached the old
# active workspace; the next normal launch completes it deterministically.
qemu_persistent_storage_prepare_update \
  "$identity_b" "$source_sha_b" "$source_bytes_b" "$generation_target_bytes" \
  "$target_kernel" "$target_initramfs"
assert_eq \
  "$QEMU_PERSISTENT_STORAGE_ACTIVE_KERNEL" \
  "$OMARCHY_QEMU_GPU_STATE_ROOT/boot/$identity_a/kernel"
assert grep -Fq \
  '"fromBootKitAvailable":true' \
  "$OMARCHY_QEMU_GPU_STATE_ROOT/updates/current/transaction.json"
generation_candidate_disk=$QEMU_PERSISTENT_STORAGE_CANDIDATE_DISK
printf 'recovered-candidate' | dd \
  of="$generation_candidate_disk" bs=1 seek=$((source_bytes + 4096)) conv=notrunc \
  >/dev/null 2>&1
generation_transaction="$OMARCHY_QEMU_GPU_STATE_ROOT/updates/current"
_qps_write_update_state "$generation_transaction" committing
/bin/mv \
  "$OMARCHY_QEMU_GPU_STATE_ROOT/disks/current" \
  "$generation_transaction/rollback"
_qps_fsync "$OMARCHY_QEMU_GPU_STATE_ROOT/disks"
qemu_persistent_storage_release_lock

# Normal selection, not only the assessment API, must finish a journaled
# activation after a launcher crash and expose the retained rollback state.
qemu_persistent_storage_select \
  persistent "$identity_b" "$source_disk_b" "$source_sha_b" "$source_bytes_b" '' \
  "$generation_target_bytes"
assert_eq "$QEMU_PERSISTENT_STORAGE_UPDATE_STATE" committed
assert_eq \
  "$QEMU_SELECTED_DISK" \
  "$OMARCHY_QEMU_GPU_STATE_ROOT/disks/current/rootfs.ext4"
assert_eq \
  "$(dd if="$OMARCHY_QEMU_GPU_STATE_ROOT/disks/current/rootfs.ext4" \
      bs=1 skip=$((source_bytes + 4096)) count=19 2>/dev/null)" \
  recovered-candidate

# Finalization prunes only caches made obsolete by this exact transaction. The
# active target factory image and unrelated release caches remain available.
generation_images="$OMARCHY_QEMU_GPU_STATE_ROOT/images"
/bin/cp "$source_disk" "$generation_images/$identity_a.ext4"
/bin/cp "$source_disk" "$generation_images/$identity_a.update.ext4"
/bin/cp "$source_disk_b" "$generation_images/$identity_b.ext4"
/bin/cp "$source_disk_b" "$generation_images/$identity_b.update.ext4"
/bin/cp "$source_disk" "$generation_images/$identity_c.ext4"
chmod 600 "$generation_images"/*.ext4
qemu_persistent_storage_finalize_update
assert test ! -e "$OMARCHY_QEMU_GPU_STATE_ROOT/updates/current"
assert test -f "$OMARCHY_QEMU_GPU_STATE_ROOT/disks/current/rootfs.ext4"
assert test ! -e "$generation_images/$identity_a.ext4"
assert test ! -e "$generation_images/$identity_a.update.ext4"
assert test ! -e "$generation_images/$identity_b.update.ext4"
assert test ! -e "$OMARCHY_QEMU_GPU_STATE_ROOT/boot/$identity_a"
assert test -f "$generation_images/$identity_b.ext4"
assert test -f "$generation_images/$identity_c.ext4"
assert test -f "$OMARCHY_QEMU_GPU_STATE_ROOT/boot/$identity_b/kernel"
qemu_persistent_storage_assess_update \
  "$identity_b" "$source_sha_b" "$source_bytes_b" "$generation_target_bytes"
assert_eq "$QEMU_PERSISTENT_STORAGE_UPDATE_STATE" none

# A retained rollback from one healthy update must not wedge the next app
# release when the first normal session ended non-zero. The next prepare keeps
# the committed active VM, retires only its older predecessor, and clones that
# active state into the new candidate.
/bin/cp "$source_disk_b" "$generation_images/$identity_c.update.ext4"
chmod 600 "$generation_images/$identity_c.update.ext4"
qemu_persistent_storage_prepare_update \
  "$identity_c" "$source_sha_b" "$source_bytes_b" "$generation_target_bytes" \
  "$target_kernel" "$target_initramfs"
assert_eq "$QEMU_PERSISTENT_STORAGE_UPDATE_STATE" candidate
qemu_persistent_storage_release_lock

# A prepared candidate belongs only to its release. A newer release can cancel
# it without touching the still-active VM, instead of becoming permanently
# wedged behind the stale transaction.
qemu_persistent_storage_assess_update \
  "$identity_d" "$source_sha_b" "$source_bytes_b" "$generation_target_bytes"
assert_eq "$QEMU_PERSISTENT_STORAGE_UPDATE_STATE" required
qemu_persistent_storage_prepare_update \
  "$identity_d" "$source_sha_b" "$source_bytes_b" "$generation_target_bytes" \
  "$active_kernel" "$active_initramfs"
assert_eq "$QEMU_PERSISTENT_STORAGE_UPDATE_STATE" candidate
assert_eq "$QEMU_PERSISTENT_STORAGE_ACTIVE_IDENTITY" "$identity_b"
assert_eq "$QEMU_PERSISTENT_STORAGE_CANDIDATE_IDENTITY" "$identity_d"
assert test ! -e "$generation_images/$identity_c.update.ext4"
assert test ! -e "$OMARCHY_QEMU_GPU_STATE_ROOT/boot/$identity_c"
qemu_persistent_storage_rollback_update
assert test ! -e "$OMARCHY_QEMU_GPU_STATE_ROOT/updates/current"

qemu_persistent_storage_prepare_update \
  "$identity_c" "$source_sha_b" "$source_bytes_b" "$generation_target_bytes" \
  "$target_kernel" "$target_initramfs"
chain_c_candidate=$QEMU_PERSISTENT_STORAGE_CANDIDATE_DISK
printf 'chain-c-user-data' | dd \
  of="$chain_c_candidate" bs=1 seek=$((source_bytes + 6144)) conv=notrunc \
  >/dev/null 2>&1
chain_c_token=$QEMU_PERSISTENT_STORAGE_UPDATE_HEALTH_TOKEN
qemu_persistent_storage_commit_update "$chain_c_token"
assert_eq "$QEMU_PERSISTENT_STORAGE_UPDATE_STATE" committed
assert test -f "$OMARCHY_QEMU_GPU_STATE_ROOT/updates/current/rollback/rootfs.ext4"

qemu_persistent_storage_assess_update \
  "$identity_d" "$source_sha_b" "$source_bytes_b" "$generation_target_bytes"
assert_eq "$QEMU_PERSISTENT_STORAGE_UPDATE_STATE" required
assert_eq "$QEMU_PERSISTENT_STORAGE_ACTIVE_IDENTITY" "$identity_c"

# A failure while validating the next release must leave both the active VM
# and its retained predecessor untouched. Supersession happens only after the
# replacement candidate has been cloned and flushed successfully.
assert_fails qemu_persistent_storage_prepare_update \
  "$identity_d" "$source_sha_b" "$source_bytes_b" "$generation_target_bytes" \
  "$test_root/missing-next-kernel" "$active_initramfs"
qemu_persistent_storage_assess_update \
  "$identity_c" "$source_sha_b" "$source_bytes_b" "$generation_target_bytes"
assert_eq "$QEMU_PERSISTENT_STORAGE_UPDATE_STATE" committed
assert test -f "$OMARCHY_QEMU_GPU_STATE_ROOT/updates/current/rollback/rootfs.ext4"

qemu_persistent_storage_prepare_update \
  "$identity_d" "$source_sha_b" "$source_bytes_b" "$generation_target_bytes" \
  "$active_kernel" "$active_initramfs"
assert_eq "$QEMU_PERSISTENT_STORAGE_UPDATE_STATE" candidate
assert_eq "$QEMU_PERSISTENT_STORAGE_ACTIVE_IDENTITY" "$identity_c"
assert_eq "$QEMU_PERSISTENT_STORAGE_CANDIDATE_IDENTITY" "$identity_d"
assert grep -Fq "\"fromBundleIdentity\":\"$identity_c\"" \
  "$OMARCHY_QEMU_GPU_STATE_ROOT/updates/current/transaction.json"
assert grep -Fq "\"targetBundleIdentity\":\"$identity_d\"" \
  "$OMARCHY_QEMU_GPU_STATE_ROOT/updates/current/transaction.json"
assert_eq \
  "$(dd if="$QEMU_PERSISTENT_STORAGE_CANDIDATE_DISK" \
      bs=1 skip=$((source_bytes + 6144)) count=17 2>/dev/null)" \
  chain-c-user-data
qemu_persistent_storage_rollback_update
assert test ! -e "$OMARCHY_QEMU_GPU_STATE_ROOT/updates/current"
assert_eq \
  "$(dd if="$OMARCHY_QEMU_GPU_STATE_ROOT/disks/current/rootfs.ext4" \
      bs=1 skip=$((source_bytes + 6144)) count=17 2>/dev/null)" \
  chain-c-user-data
qemu_persistent_storage_assess_update \
  "$identity_c" "$source_sha_b" "$source_bytes_b" "$generation_target_bytes"
assert_eq "$QEMU_PERSISTENT_STORAGE_UPDATE_STATE" none

# A compatible current workspace must not hide another recognized legacy VM.
# Launch requires confirmation; reset removes both and restores one current VM.
export OMARCHY_QEMU_GPU_STATE_ROOT="$test_root/current-plus-legacy-state"
export OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK=0
qemu_persistent_storage_select \
  persistent "$identity_a" "$source_disk" "$source_sha" "$source_bytes" ''
current_plus_legacy_current=$QEMU_SELECTED_DISK
printf 'current-user-data' | dd of="$current_plus_legacy_current" bs=1 seek=704 conv=notrunc >/dev/null 2>&1
qemu_persistent_storage_release_lock

export OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK=1
qemu_persistent_storage_select \
  persistent "$identity_b" "$source_disk" "$source_sha" "$source_bytes" ''
current_plus_legacy_legacy=$QEMU_SELECTED_DISK
printf 'legacy-user-data' | dd of="$current_plus_legacy_legacy" bs=1 seek=704 conv=notrunc >/dev/null 2>&1
qemu_persistent_storage_release_lock

export OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK=0
assert_status "$QEMU_PERSISTENT_STORAGE_INCOMPATIBLE_STATUS" \
  qemu_persistent_storage_select \
    persistent "$identity_a" "$source_disk" "$source_sha" "$source_bytes" ''
assert test -f "$current_plus_legacy_current"
assert test -f "$current_plus_legacy_legacy"
assert_eq \
  "$(dd if="$current_plus_legacy_current" bs=1 skip=704 count=17 2>/dev/null)" \
  current-user-data
assert_eq \
  "$(dd if="$current_plus_legacy_legacy" bs=1 skip=704 count=16 2>/dev/null)" \
  legacy-user-data

qemu_persistent_storage_select \
  reset "$identity_a" "$source_disk" "$source_sha" "$source_bytes" ''
assert_eq "$QEMU_SELECTED_DISK" "$OMARCHY_QEMU_GPU_STATE_ROOT/disks/current/rootfs.ext4"
assert cmp -s "$QEMU_SELECTED_DISK" "$source_disk"
assert test ! -e "$current_plus_legacy_legacy"
assert_eq \
  "$(find "$OMARCHY_QEMU_GPU_STATE_ROOT/disks" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')" \
  1
qemu_persistent_storage_release_lock

# An unsafe current directory remains an ordinary storage error even if a
# separate legacy VM is recognized. Reset must never be offered for data that
# its destructive validator will intentionally refuse to remove.
export OMARCHY_QEMU_GPU_STATE_ROOT="$test_root/invalid-current-plus-legacy-state"
export OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK=0
qemu_persistent_storage_select \
  persistent "$identity_a" "$source_disk" "$source_sha" "$source_bytes" ''
invalid_current_disk=$QEMU_SELECTED_DISK
qemu_persistent_storage_release_lock

export OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK=1
qemu_persistent_storage_select \
  persistent "$identity_b" "$source_disk" "$source_sha" "$source_bytes" ''
invalid_current_legacy_disk=$QEMU_SELECTED_DISK
qemu_persistent_storage_release_lock
printf 'preserve-unknown\n' >"${invalid_current_disk%/*}/unknown.txt"
chmod 600 "${invalid_current_disk%/*}/unknown.txt"

export OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK=0
assert_status 1 \
  qemu_persistent_storage_select \
    persistent "$identity_a" "$source_disk" "$source_sha" "$source_bytes" ''
assert test -f "$invalid_current_disk"
assert test -f "$invalid_current_legacy_disk"
assert test -f "${invalid_current_disk%/*}/unknown.txt"

# Several recognized legacy disks require the confirmed reset flow even when
# one exactly matches the current build. Normal launch preserves them all;
# reset removes both and publishes one fresh current workspace.
export OMARCHY_QEMU_GPU_STATE_ROOT="$test_root/multi-exact-state"
export OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK=1
qemu_persistent_storage_select \
  persistent "$identity_a" "$source_disk" "$source_sha" "$source_bytes" ''
legacy_exact_a=$QEMU_SELECTED_DISK
printf 'exact-a-user-data' | dd of="$legacy_exact_a" bs=1 seek=640 conv=notrunc >/dev/null 2>&1
qemu_persistent_storage_release_lock
qemu_persistent_storage_select \
  persistent "$identity_b" "$source_disk" "$source_sha" "$source_bytes" ''
legacy_exact_b=$QEMU_SELECTED_DISK
printf 'newer-b-user-data' | dd of="$legacy_exact_b" bs=1 seek=640 conv=notrunc >/dev/null 2>&1
qemu_persistent_storage_release_lock
/usr/bin/touch -t 202601010101 "$legacy_exact_a"
/usr/bin/touch -t 202601020101 "$legacy_exact_b"

export OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK=0
assert_status "$QEMU_PERSISTENT_STORAGE_INCOMPATIBLE_STATUS" \
  qemu_persistent_storage_select \
    persistent "$identity_a" "$source_disk" "$source_sha" "$source_bytes" ''
assert test -f "$legacy_exact_a"
assert test -f "$legacy_exact_b"
assert test ! -e "$OMARCHY_QEMU_GPU_STATE_ROOT/disks/current"

qemu_persistent_storage_select \
  reset "$identity_a" "$source_disk" "$source_sha" "$source_bytes" ''
multi_exact_disk=$QEMU_SELECTED_DISK
assert_eq "$multi_exact_disk" "$OMARCHY_QEMU_GPU_STATE_ROOT/disks/current/rootfs.ext4"
assert cmp -s "$multi_exact_disk" "$source_disk"
assert test ! -e "$legacy_exact_a"
assert test ! -e "$legacy_exact_b"
qemu_persistent_storage_release_lock

# If the current build has no exact legacy disk, normal launch preserves all
# workspaces and asks for reset. A confirmed reset targets the most recently
# written valid workspace with a deterministic path tie-break.
export OMARCHY_QEMU_GPU_STATE_ROOT="$test_root/multi-newest-state"
export OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK=1
qemu_persistent_storage_select \
  persistent "$identity_a" "$source_disk" "$source_sha" "$source_bytes" ''
legacy_newest_a=$QEMU_SELECTED_DISK
printf 'older-a-user-data' | dd of="$legacy_newest_a" bs=1 seek=768 conv=notrunc >/dev/null 2>&1
qemu_persistent_storage_release_lock
qemu_persistent_storage_select \
  persistent "$identity_b" "$source_disk" "$source_sha" "$source_bytes" ''
legacy_newest_b=$QEMU_SELECTED_DISK
printf 'newest-b-user-data' | dd of="$legacy_newest_b" bs=1 seek=768 conv=notrunc >/dev/null 2>&1
qemu_persistent_storage_release_lock
/usr/bin/touch -t 202601010101 "$legacy_newest_a"
/usr/bin/touch -t 202601020101 "$legacy_newest_b"
invalid_legacy="$OMARCHY_QEMU_GPU_STATE_ROOT/disks/$identity_bad"
mkdir "$invalid_legacy"
chmod 700 "$invalid_legacy"
printf 'must-survive\n' >"$invalid_legacy/unrecognized.txt"
chmod 600 "$invalid_legacy/unrecognized.txt"

export OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK=0
assert_status "$QEMU_PERSISTENT_STORAGE_INCOMPATIBLE_STATUS" \
  qemu_persistent_storage_select \
    persistent "$identity_c" "$source_disk" "$source_sha" "$source_bytes" ''
assert test -f "$legacy_newest_a"
assert test -f "$legacy_newest_b"
assert test -f "$invalid_legacy/unrecognized.txt"
assert test ! -e "$OMARCHY_QEMU_GPU_STATE_ROOT/disks/current"

qemu_persistent_storage_select \
  reset "$identity_c" "$source_disk" "$source_sha" "$source_bytes" ''
multi_newest_disk=$QEMU_SELECTED_DISK
assert_eq "$multi_newest_disk" "$OMARCHY_QEMU_GPU_STATE_ROOT/disks/current/rootfs.ext4"
assert cmp -s "$multi_newest_disk" "$source_disk"
assert test ! -e "$legacy_newest_a"
assert test ! -e "$legacy_newest_b"
assert test -f "$invalid_legacy/unrecognized.txt"
assert grep -Fq "\"bundleIdentity\":\"$identity_c\"" "${multi_newest_disk%/*}/metadata.json"
qemu_persistent_storage_release_lock

export OMARCHY_QEMU_GPU_STATE_ROOT="$test_root/state"
export OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK=1

# QEMU normally closes unrelated inherited descriptors. `-add-fd` explicitly
# retains the lock in a QEMU fdset, so killing only the launcher cannot permit a
# second writer. QMP proves that the real staged QEMU owns the registered fd.
qemu_bin="$native_dir/.build/qemu-gpu-runtime/bin/qemu-system-aarch64"
if [[ ! -x $qemu_bin ]]; then
  printf 'qemu-persistent-storage.test: SKIP staged-QEMU lock inheritance (binary absent)\n' >&2
else
  qemu_version=$($qemu_bin --version | sed -n '1p')
  [[ $qemu_version == 'QEMU emulator version 10.2.50' ]] || {
    fail "staged QEMU version is not 10.2.50: $qemu_version"
  }
  holder_pid_file="$test_root/qemu-launcher.pid"
  qemu_pid_file="$test_root/qemu.pid"
  qmp_socket="$test_root/qmp.sock"
  qemu_log="$test_root/qemu.log"
  /bin/bash -c '
    set -euo pipefail
    source "$1"
    qemu_persistent_storage_select persistent "$2" "$3" "$4" "$5" ""
    "$6" \
      -machine none \
      -nodefaults \
      -display none \
      -S \
      -qmp "unix:$7,server=on,wait=off" \
      -add-fd "$QEMU_PERSISTENT_STORAGE_QEMU_ADD_FD" \
      >"${10}" 2>&1 &
    printf "%s\n" "$!" >"$9"
    printf "%s\n" "$$" >"$8"
    wait "$!"
  ' qps-qemu-holder "$native_dir/qemu-persistent-storage.sh" \
    "$identity_a" "$source_disk" "$source_sha" "$source_bytes" \
    "$qemu_bin" "$qmp_socket" "$holder_pid_file" "$qemu_pid_file" "$qemu_log" \
    9>&- &
  holder_job=$!
  wait_for_file "$holder_pid_file"
  wait_for_file "$qemu_pid_file"
  holder_pid=$(<"$holder_pid_file")
  qemu_pid=$(<"$qemu_pid_file")
  qmp_request "$qmp_socket" assert-lock-fdset || {
    sed -n '1,160p' "$qemu_log" >&2
    fail 'staged QEMU did not publish its persistent-lock fdset'
  }
  kill -KILL "$holder_pid"
  wait "$holder_job" 2>/dev/null || true
  holder_pid=''
  assert kill -0 "$qemu_pid"
  qmp_request "$qmp_socket" assert-lock-fdset
  assert_fails /bin/bash -c \
    'source "$1"; qemu_persistent_storage_select persistent "$2" "$3" "$4" "$5" ""' \
    qps-qemu-inherited-lock-test "$native_dir/qemu-persistent-storage.sh" \
    "$identity_a" "$source_disk" "$source_sha" "$source_bytes" 9>&-
  qmp_request "$qmp_socket" quit
  for ((attempt = 0; attempt < 250; attempt++)); do
    kill -0 "$qemu_pid" 2>/dev/null || break
    sleep 0.02
  done
  if kill -0 "$qemu_pid" 2>/dev/null; then
    fail "staged QEMU did not terminate after QMP quit"
  fi
  qemu_pid=''

  qemu_persistent_storage_select \
    persistent "$identity_a" "$source_disk" "$source_sha" "$source_bytes" ''
  qemu_persistent_storage_release_lock
  printf 'qemu-persistent-storage.test: staged-QEMU crash lock: PASS\n'
fi

# Reset is deliberately identity-scoped and rebuilds from the immutable base.
qemu_persistent_storage_select \
  reset "$identity_a" "$source_disk" "$source_sha" "$source_bytes" ''
assert cmp -s "$QEMU_SELECTED_DISK" "$source_disk"
qemu_persistent_storage_release_lock

# Ephemeral selection never changes or locks the saved workspace.
ephemeral_dir="$test_root/ephemeral"
mkdir "$ephemeral_dir"
chmod 700 "$ephemeral_dir"
qemu_persistent_storage_select \
  ephemeral "$identity_a" "$source_disk" "$source_sha" "$source_bytes" "$ephemeral_dir"
assert_eq "$QEMU_SELECTED_STORAGE_MODE" ephemeral
assert cmp -s "$QEMU_SELECTED_DISK" "$source_disk"
printf 'temporary-only' | dd of="$QEMU_SELECTED_DISK" bs=1 seek=256 conv=notrunc >/dev/null 2>&1
assert cmp -s "$persistent_a" "$source_disk"

# Exact metadata and an allowlisted directory are required even for explicit
# reset; unknown host files are never recursively deleted.
qemu_persistent_storage_select \
  persistent "$identity_bad" "$source_disk" "$source_sha" "$source_bytes" ''
bad_directory=$QEMU_PERSISTENT_STORAGE_DIRECTORY
qemu_persistent_storage_release_lock
printf 'must-survive\n' >"$bad_directory/unknown.txt"
chmod 600 "$bad_directory/unknown.txt"
assert_fails qemu_persistent_storage_select \
  reset "$identity_bad" "$source_disk" "$source_sha" "$source_bytes" ''
assert test -f "$bad_directory/unknown.txt"
qemu_persistent_storage_release_lock

# A symlink can never be accepted as a persistent disk, even if the metadata
# and target bytes otherwise match the selected bundle.
/bin/rm -f "$bad_directory/unknown.txt" "$bad_directory/rootfs.ext4"
ln -s "$source_disk" "$bad_directory/rootfs.ext4"
assert_fails qemu_persistent_storage_select \
  persistent "$identity_bad" "$source_disk" "$source_sha" "$source_bytes" ''
assert test -L "$bad_directory/rootfs.ext4"
qemu_persistent_storage_release_lock

# A recognized interrupted transaction is reclaimed; an unmarked directory is
# deliberately left untouched.
recognized_stage="$OMARCHY_QEMU_GPU_STATE_ROOT/disks/.${identity_a}.initializing.ABCDEF"
mkdir "$recognized_stage"
chmod 700 "$recognized_stage"
_qps_write_metadata \
  "$recognized_stage/metadata.json" "$identity_a" "$source_sha" "$source_bytes"
unknown_stage="$OMARCHY_QEMU_GPU_STATE_ROOT/disks/.${identity_a}.initializing.FEDCBA"
mkdir "$unknown_stage"
chmod 700 "$unknown_stage"

# This exact shape bypassed the old newline-serialized allowlist: valid
# metadata, no real rootfs.ext4, and one unknown basename ending in a newline.
# An exact os.listdir set check must leave the directory and hostile file alone.
newline_stage="$OMARCHY_QEMU_GPU_STATE_ROOT/disks/.${identity_a}.initializing.NLTEST"
mkdir "$newline_stage"
chmod 700 "$newline_stage"
_qps_write_metadata \
  "$newline_stage/metadata.json" "$identity_a" "$source_sha" "$source_bytes"
newline_entry=$'rootfs.ext4\n'
printf 'must-survive\n' >"$newline_stage/$newline_entry"
chmod 600 "$newline_stage/$newline_entry"

qemu_persistent_storage_select \
  persistent "$identity_a" "$source_disk" "$source_sha" "$source_bytes" ''
assert test ! -e "$recognized_stage"
assert test -d "$unknown_stage"
assert test -d "$newline_stage"
assert test -f "$newline_stage/$newline_entry"
qemu_persistent_storage_release_lock

# The production default is branded for Try Omarchy and never recreates the
# former Omarchy-only Application Support path.
saved_state_root=$OMARCHY_QEMU_GPU_STATE_ROOT
saved_home=$HOME
saved_multi_disk=$OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK
default_home="$test_root/default-home"
mkdir "$default_home"
chmod 700 "$default_home"
old_branded_root="$default_home/Library/Application Support/Try Omarchy/QEMU/v1"
mkdir -p "$old_branded_root"
chmod 700 \
  "$default_home/Library" \
  "$default_home/Library/Application Support" \
  "$default_home/Library/Application Support/Try Omarchy" \
  "$default_home/Library/Application Support/Try Omarchy/QEMU" \
  "$old_branded_root"
printf 'leave old storage untouched\n' >"$old_branded_root/sentinel"
chmod 600 "$old_branded_root/sentinel"
unset OMARCHY_QEMU_GPU_STATE_ROOT
export HOME=$default_home
export OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK=0
qemu_persistent_storage_select \
  persistent "$identity_a" "$source_disk" "$source_sha" "$source_bytes" ''
assert_eq \
  "$QEMU_SELECTED_DISK" \
  "$default_home/Library/Application Support/Try Omarchy/VM/v1/disks/current/rootfs.ext4"
assert test -f "$old_branded_root/sentinel"
assert test ! -e "$default_home/Library/Application Support/Omarchy"
qemu_persistent_storage_release_lock
export HOME=$saved_home
export OMARCHY_QEMU_GPU_STATE_ROOT=$saved_state_root
export OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK=$saved_multi_disk

# A broad override is rejected before any mutation.
export OMARCHY_QEMU_GPU_STATE_ROOT=/
assert_fails qemu_persistent_storage_select \
  persistent "$identity_a" "$source_disk" "$source_sha" "$source_bytes" ''
export OMARCHY_QEMU_GPU_STATE_ROOT=$saved_state_root

printf 'qemu-persistent-storage.test: PASS\n'
