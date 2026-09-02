#!/bin/bash

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd -P)
macos_dir=$(cd "$test_dir/.." && pwd -P)

fail() {
  printf 'qemu-memory-contract.test: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  [[ $1 == *"$2"* ]] || fail "expected output to contain [$2], got [$1]"
}

assert_line_pair() {
  local file=$1
  local first=$2
  local second=$3
  awk -v first="$first" -v second="$second" \
    'previous == first && $0 == second { found = 1 } { previous = $0 } END { exit !found }' \
    "$file" || fail "expected adjacent lines [$first] and [$second] in $file"
}

test_root=$(mktemp -d '/private/tmp/omarchy-qemu-memory-contract.XXXXXX')
case "$test_root" in
  /private/tmp/omarchy-qemu-memory-contract.??????) ;;
  *) fail "unexpected test root: $test_root" ;;
esac
trap '/bin/rm -rf "$test_root"' EXIT HUP INT TERM

app="$test_root/Try Omarchy.app"
contents="$app/Contents"
resources="$contents/Resources"
shim_dir="$test_root/bin"
mkdir -p \
  "$contents/MacOS" \
  "$resources/guest" \
  "$resources/runtime/bin" \
  "$resources/scripts" \
  "$shim_dir"

/bin/cp "$macos_dir/run-qemu-gpu.sh" "$resources/scripts/run-qemu-gpu.sh"
/bin/cp "$macos_dir/qemu-port-forwarding.sh" "$resources/scripts/qemu-port-forwarding.sh"
chmod 755 "$resources/scripts/run-qemu-gpu.sh"
chmod 644 "$resources/scripts/qemu-port-forwarding.sh"

cat >"$contents/MacOS/omarchy-vm-helper" <<'SH'
#!/bin/bash
set -euo pipefail
if [[ ${1:-} == --bridge-native-audio \
   || ${1:-} == --bridge-native-clipboard \
   || ${1:-} == --bridge-native-camera ]]; then
  while kill -0 "$2" 2>/dev/null; do
    sleep 0.02
  done
fi
exit 0
SH
chmod 755 "$contents/MacOS/omarchy-vm-helper"

cat >"$resources/runtime/bin/Try Omarchy" <<'SH'
#!/bin/bash
# Identity markers validated by the production launcher:
# TryOmarchy.icns
# OMARCHY_SDL_AUDIO_CONTROL_DIRECTORY
# OMARCHY_SDL_INPUT_DEVICE_NAME
# OMARCHY_SDL_OUTPUT_DEVICE_NAME
# guest_owner_uid guest_owner_gid
case " $* " in
  *' -accel help '*) printf '%s\n' hvf ;;
  *' -machine help '*) printf '%s\n' 'virt                 ARM Virtual Machine' ;;
  *' -cpu help '*) printf '%s\n' '  host' ;;
  *' -display help '*) printf '%s\n' cocoa ;;
  *' -device help '*)
    for device in \
      hda-micro intel-hda virtconsole virtserialport virtio-balloon-pci \
      virtio-9p-pci virtio-blk-pci virtio-gpu-gl-pci virtio-keyboard-pci \
      virtio-net-pci virtio-rng-pci virtio-serial-pci virtio-tablet-pci; do
      printf 'name "%s"\n' "$device"
    done
    ;;
  *' -help '*)
    printf '%s\n' \
      '-add-fd fd=fd,set=set[,opaque=opaque]' \
      '-action reboot=reset|shutdown' \
      '-action shutdown=poweroff|pause' \
      'full-grab=on|off' \
      'immersive=on|off'
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
Path(os.environ["FAKE_QEMU_LOG"]).write_text("\n".join(arguments) + "\n")
socket_paths = []
for argument in arguments:
    if argument.startswith("unix:"):
        socket_paths.append(argument[5:].split(",", 1)[0])
    elif argument.startswith("socket,"):
        for field in argument.split(","):
            if field.startswith("path="):
                socket_paths.append(field[5:])

servers = []
if os.environ.get("FAKE_QEMU_SKIP_SOCKETS") != "1":
    for path in socket_paths:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        server = socket.socket(socket.AF_UNIX)
        server.bind(path)
        server.listen(1)
        servers.append(server)

time.sleep(float(os.environ.get("FAKE_QEMU_LIFETIME", "0.20")))
for server in servers:
    server.close()
raise SystemExit(int(os.environ.get("FAKE_QEMU_STATUS", "0")))
PY
    ;;
esac
SH
chmod 755 "$resources/runtime/bin/Try Omarchy"

cat >"$resources/scripts/qemu-persistent-storage.sh" <<'SH'
#!/bin/bash
QEMU_PERSISTENT_STORAGE_INCOMPATIBLE_STATUS=78
QEMU_PERSISTENT_STORAGE_QEMU_ADD_FD='fd=9,set=77,opaque=omarchy-persistent-lock'
QEMU_SELECTED_DISK=''
QEMU_SELECTED_STORAGE_MODE=''
QEMU_PERSISTENT_STORAGE_DIRECTORY=''
_qps_owner() { /usr/bin/stat -f '%u' "$1"; }
_qps_permissions() { /usr/bin/stat -f '%Lp' "$1"; }
qemu_persistent_storage_release_lock() { :; }
qemu_persistent_storage_materialize_source() { return 1; }
qemu_persistent_storage_select() {
  mkdir -p "$FAKE_PERSISTENT_ROOT"
  QEMU_SELECTED_DISK="$FAKE_PERSISTENT_ROOT/rootfs.ext4"
  if [[ ! -f $QEMU_SELECTED_DISK ]]; then
    printf 'factory\n' >"$QEMU_SELECTED_DISK"
  fi
  chmod 600 "$QEMU_SELECTED_DISK"
  QEMU_SELECTED_STORAGE_MODE=$([[ $1 == ephemeral ]] && printf ephemeral || printf persistent)
  QEMU_PERSISTENT_STORAGE_DIRECTORY=$FAKE_PERSISTENT_ROOT
}
SH
chmod 644 "$resources/scripts/qemu-persistent-storage.sh"

cat >"$shim_dir/codesign" <<'SH'
#!/bin/bash
for argument in "$@"; do
  if [[ $argument == -d ]]; then
    printf '%s\n' '<key>com.apple.security.hypervisor</key>' >&2
  fi
done
exit 0
SH
cat >"$shim_dir/file" <<'SH'
#!/bin/bash
printf '%s: Mach-O 64-bit executable arm64\n' "$1"
SH
cat >"$shim_dir/sysctl" <<'SH'
#!/bin/bash
if [[ $# == 2 && $1 == -n && ($2 == hw.logicalcpu || $2 == hw.ncpu) ]]; then
  printf '8\n'
  exit 0
fi
if [[ $# == 2 && $1 == -n && $2 == hw.memsize ]]; then
  # 16 GiB unless a scenario shrinks the host.
  printf '%s\n' "${FAKE_HOST_MEMSIZE:-17179869184}"
  exit 0
fi
exec /usr/sbin/sysctl "$@"
SH
chmod 755 "$shim_dir"/*

guest="$resources/guest"
printf 'kernel\n' >"$guest/vmlinuz-linux"
printf 'initramfs\n' >"$guest/initramfs-linux.img"
printf 'factory\n' >"$guest/rootfs.ext4"
/usr/bin/plutil -create xml1 "$guest/launch.plist"
/usr/bin/plutil -insert bundleIdentity -string "$(printf 'a%.0s' {1..64})" "$guest/launch.plist"
/usr/bin/plutil -insert sourceDiskSHA256 -string "$(printf 'b%.0s' {1..64})" "$guest/launch.plist"
/usr/bin/plutil -insert sourceDiskBytes -integer 8 "$guest/launch.plist"
/usr/bin/plutil -insert compressedDiskBytes -integer 4 "$guest/launch.plist"
/usr/bin/plutil -insert workingDiskBytes -integer 16 "$guest/launch.plist"
/usr/bin/plutil -insert kernelCommandLine -string \
  'root=/dev/vda rw rootwait console=tty0 console=hvc0 loglevel=4 systemd.show_status=false rd.systemd.show_status=false mitigations=off nowatchdog' \
  "$guest/launch.plist"

launcher="$resources/scripts/run-qemu-gpu.sh"
persistent_root="$test_root/persistent"

run_scenario() {
  local scenario=$1
  local expected_status=$2
  shift 2
  local scenario_dir="$test_root/$scenario"
  local actual_status=0
  mkdir -p "$scenario_dir"
  if env \
    PATH="$shim_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
    FAKE_PERSISTENT_ROOT="$persistent_root" \
    FAKE_QEMU_LOG="$scenario_dir/qemu.log" \
    "$@" \
    "$launcher" \
    >"$scenario_dir/stdout" 2>"$scenario_dir/stderr"; then
    actual_status=0
  else
    actual_status=$?
  fi
  if [[ $actual_status != "$expected_status" ]]; then
    /bin/cat "$scenario_dir/stderr" >&2 || true
    fail "$scenario expected status $expected_status, got $actual_status"
  fi
}

# The default allocation matches the guest manifest's recommendedMemoryMiB.
run_scenario default 0
assert_line_pair "$test_root/default/qemu.log" -m 4096M
assert_contains "$(<"$test_root/default/stderr")" '4 GiB RAM'

# A whole-GiB choice reaches QEMU verbatim and reads as GiB in the log.
run_scenario six-gib 0 OMARCHY_QEMU_GPU_MEMORY_MIB=6144
assert_line_pair "$test_root/six-gib/qemu.log" -m 6144M
assert_contains "$(<"$test_root/six-gib/stderr")" '6 GiB RAM'

# A fractional-GiB value is legal for the environment and logs in MiB.
run_scenario odd-mib 0 OMARCHY_QEMU_GPU_MEMORY_MIB=2560
assert_line_pair "$test_root/odd-mib/qemu.log" -m 2560M
assert_contains "$(<"$test_root/odd-mib/stderr")" '2560 MiB RAM'

# Malformed values fail loudly instead of booting a mis-sized guest.
run_scenario malformed 1 OMARCHY_QEMU_GPU_MEMORY_MIB=6g
assert_contains "$(<"$test_root/malformed/stderr")" 'whole number of MiB'

# A leading zero must not be read as octal (bash) while QEMU reads decimal:
# the value is normalized to base 10 before any check or use.
run_scenario leading-zero 0 OMARCHY_QEMU_GPU_MEMORY_MIB=08192
assert_line_pair "$test_root/leading-zero/qemu.log" -m 8192M

# A value past 64-bit range must hit the launcher's own error, not wrap
# silently through bash arithmetic into a bogus small number.
run_scenario wraparound 1 OMARCHY_QEMU_GPU_MEMORY_MIB=18446744073709555712
assert_contains "$(<"$test_root/wraparound/stderr")" 'whole number of MiB'

# The guest manifest's minimumMemoryMiB is a hard floor.
run_scenario too-small 1 OMARCHY_QEMU_GPU_MEMORY_MIB=1024
assert_contains "$(<"$test_root/too-small/stderr")" 'at least 2048 MiB'

# The host must keep enough memory to stay responsive: on an 8 GiB host an
# 8 GiB guest is refused.
run_scenario starved-host 1 \
  FAKE_HOST_MEMSIZE=8589934592 OMARCHY_QEMU_GPU_MEMORY_MIB=8192
assert_contains "$(<"$test_root/starved-host/stderr")" 'leave the host at least 4096 MiB'

# The default must boot unconditionally, even on hosts too small to satisfy
# the cap (CI runners have 7 GiB): 4096 + 4096 > 7168, so this scenario fails
# if the host cap is ever applied to the default.
run_scenario small-host-default 0 FAKE_HOST_MEMSIZE=7516192768
assert_line_pair "$test_root/small-host-default/qemu.log" -m 4096M

printf 'qemu-memory-contract.test: PASS\n'
