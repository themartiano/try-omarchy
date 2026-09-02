#!/bin/bash

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd -P)
macos_dir=$(cd "$test_dir/.." && pwd -P)

fail() {
  printf 'run-qemu-ssh-contract.test: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  [[ $1 == *"$2"* ]] || fail "expected output to contain [$2], got [$1]"
}

assert_not_contains() {
  [[ $1 != *"$2"* ]] || fail "expected output not to contain [$2], got [$1]"
}

assert_line_pair() {
  local file=$1
  local first=$2
  local second=$3
  awk -v first="$first" -v second="$second" \
    'previous == first && $0 == second { found = 1 } { previous = $0 } END { exit !found }' \
    "$file" || fail "expected adjacent lines [$first] and [$second] in $file"
}

test_root=$(mktemp -d '/private/tmp/omarchy-qemu-ssh-contract.XXXXXX')
case "$test_root" in
  /private/tmp/omarchy-qemu-ssh-contract.??????) ;;
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
is_recovery = "Try Omarchy Boot Recovery" in arguments
log_variable = "FAKE_QEMU_RECOVERY_LOG" if is_recovery else "FAKE_QEMU_LOG"
Path(os.environ[log_variable]).write_text("\n".join(arguments) + "\n")

if is_recovery:
    export_path = None
    for argument in arguments:
        if argument.startswith("local,id=omarchy-boot-export,"):
            for field in argument.split(","):
                if field.startswith("path="):
                    export_path = Path(field[5:])
    if export_path is None:
        raise SystemExit("recovery invocation has no boot-export path")
    export_path.joinpath("kernel").write_text("recovered-kernel\n")
    export_path.joinpath("initramfs").write_text("recovered-initramfs\n")
    export_path.joinpath("build-spec.json").write_text(
        '{"runtime":{"kernelCommandLine":"root=/dev/vda rw rootwait '
        'console=tty0 console=hvc0 loglevel=3"}}\n'
    )
    export_path.joinpath("complete").write_text("try-omarchy-boot-export-v1\n")
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
QEMU_PERSISTENT_STORAGE_MISSING_STATUS=79
QEMU_PERSISTENT_STORAGE_QEMU_ADD_FD='fd=9,set=77,opaque=omarchy-persistent-lock'
QEMU_SELECTED_DISK=''
QEMU_SELECTED_STORAGE_MODE=''
QEMU_PERSISTENT_STORAGE_DIRECTORY=''
QEMU_PERSISTENT_STORAGE_IDENTITY=''
QEMU_SELECTED_KERNEL=''
QEMU_SELECTED_INITRAMFS=''
QEMU_SELECTED_KERNEL_COMMAND_LINE=''
QEMU_PERSISTENT_STORAGE_NEEDS_BOOT_RECOVERY=0
_qps_owner() { /usr/bin/stat -f '%u' "$1"; }
_qps_permissions() { /usr/bin/stat -f '%Lp' "$1"; }
_qps_lstat_kind() { /usr/bin/stat -f '%HT' "$1"; }
_qps_size() { /usr/bin/stat -f '%z' "$1"; }
qemu_persistent_storage_release_lock() { :; }
qemu_persistent_storage_materialize_source() {
  printf 'materialize\n' >>"$FAKE_STORAGE_LOG"
  return 1
}
qemu_persistent_storage_select_existing() {
  printf 'select-existing\n' >>"$FAKE_STORAGE_LOG"
  QEMU_SELECTED_DISK="$FAKE_PERSISTENT_ROOT/rootfs.ext4"
  if [[ ! -f $QEMU_SELECTED_DISK ]]; then
    QEMU_SELECTED_DISK=''
    return "$QEMU_PERSISTENT_STORAGE_MISSING_STATUS"
  fi
  printf 'reuse\n' >>"$FAKE_STORAGE_LOG"
  QEMU_SELECTED_STORAGE_MODE=persistent
  QEMU_PERSISTENT_STORAGE_DIRECTORY=$FAKE_PERSISTENT_ROOT
  QEMU_PERSISTENT_STORAGE_IDENTITY=${FAKE_SAVED_IDENTITY:-saved-vm}
  if [[ -f $FAKE_PERSISTENT_ROOT/boot/kernel && \
        -f $FAKE_PERSISTENT_ROOT/boot/initramfs && \
        -f $FAKE_PERSISTENT_ROOT/boot/command-line ]]; then
    QEMU_SELECTED_KERNEL="$FAKE_PERSISTENT_ROOT/boot/kernel"
    QEMU_SELECTED_INITRAMFS="$FAKE_PERSISTENT_ROOT/boot/initramfs"
    QEMU_SELECTED_KERNEL_COMMAND_LINE=$(<"$FAKE_PERSISTENT_ROOT/boot/command-line")
    QEMU_PERSISTENT_STORAGE_NEEDS_BOOT_RECOVERY=0
  else
    QEMU_SELECTED_KERNEL=''
    QEMU_SELECTED_INITRAMFS=''
    QEMU_SELECTED_KERNEL_COMMAND_LINE=''
    QEMU_PERSISTENT_STORAGE_NEEDS_BOOT_RECOVERY=1
  fi
}
qemu_persistent_storage_stage_selected_boot_kit() {
  printf 'stage-recovered-boot\n' >>"$FAKE_STORAGE_LOG"
  mkdir -p "$FAKE_PERSISTENT_ROOT/boot"
  /bin/cp "$1" "$FAKE_PERSISTENT_ROOT/boot/kernel"
  /bin/cp "$2" "$FAKE_PERSISTENT_ROOT/boot/initramfs"
  printf '%s\n' "$3" >"$FAKE_PERSISTENT_ROOT/boot/command-line"
  QEMU_SELECTED_KERNEL="$FAKE_PERSISTENT_ROOT/boot/kernel"
  QEMU_SELECTED_INITRAMFS="$FAKE_PERSISTENT_ROOT/boot/initramfs"
  QEMU_SELECTED_KERNEL_COMMAND_LINE=$3
  QEMU_PERSISTENT_STORAGE_NEEDS_BOOT_RECOVERY=0
}
qemu_persistent_storage_select() {
  printf 'select %s\n' "$1" >>"$FAKE_STORAGE_LOG"
  if [[ $1 == ephemeral ]]; then
    mkdir -p "$6"
    QEMU_SELECTED_DISK="$6/rootfs.ext4"
    /bin/cp "$3" "$QEMU_SELECTED_DISK"
    chmod 600 "$QEMU_SELECTED_DISK"
    QEMU_SELECTED_STORAGE_MODE=ephemeral
    QEMU_PERSISTENT_STORAGE_DIRECTORY=''
    QEMU_PERSISTENT_STORAGE_IDENTITY=''
    QEMU_SELECTED_KERNEL=$8
    QEMU_SELECTED_INITRAMFS=$9
    QEMU_SELECTED_KERNEL_COMMAND_LINE=${10}
    QEMU_PERSISTENT_STORAGE_NEEDS_BOOT_RECOVERY=0
    return 0
  fi
  mkdir -p "$FAKE_PERSISTENT_ROOT"
  QEMU_SELECTED_DISK="$FAKE_PERSISTENT_ROOT/rootfs.ext4"
  if [[ $1 != reset && -f $QEMU_SELECTED_DISK ]]; then
    printf 'reuse\n' >>"$FAKE_STORAGE_LOG"
  else
    printf 'factory\n' >"$QEMU_SELECTED_DISK"
    printf 'create\n' >>"$FAKE_STORAGE_LOG"
  fi
  chmod 600 "$QEMU_SELECTED_DISK"
  mkdir -p "$FAKE_PERSISTENT_ROOT/boot"
  /bin/cp "$8" "$FAKE_PERSISTENT_ROOT/boot/kernel"
  /bin/cp "$9" "$FAKE_PERSISTENT_ROOT/boot/initramfs"
  printf '%s\n' "${10}" >"$FAKE_PERSISTENT_ROOT/boot/command-line"
  QEMU_SELECTED_STORAGE_MODE=persistent
  QEMU_PERSISTENT_STORAGE_DIRECTORY=$FAKE_PERSISTENT_ROOT
  QEMU_PERSISTENT_STORAGE_IDENTITY=${FAKE_SAVED_IDENTITY:-saved-vm}
  QEMU_SELECTED_KERNEL="$FAKE_PERSISTENT_ROOT/boot/kernel"
  QEMU_SELECTED_INITRAMFS="$FAKE_PERSISTENT_ROOT/boot/initramfs"
  QEMU_SELECTED_KERNEL_COMMAND_LINE=${10}
  QEMU_PERSISTENT_STORAGE_NEEDS_BOOT_RECOVERY=0
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
  local launcher_argument=$3
  shift 3
  local scenario_dir="$test_root/$scenario"
  local actual_status=0
  mkdir -p "$scenario_dir"
  : >"$scenario_dir/storage.log"
  if env \
    PATH="$shim_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
    FAKE_STORAGE_LOG="$scenario_dir/storage.log" \
    FAKE_PERSISTENT_ROOT="$persistent_root" \
    FAKE_QEMU_LOG="$scenario_dir/qemu.log" \
    "$@" \
    "$launcher" ${launcher_argument:+"$launcher_argument"} \
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

run_scenario disabled 0 ''
disabled_qemu=$(<"$test_root/disabled/qemu.log")
assert_line_pair "$test_root/disabled/qemu.log" -machine \
  'virt,accel=hvf,gic-version=3'
assert_not_contains "$disabled_qemu" gic-version=2
assert_line_pair "$test_root/disabled/qemu.log" -netdev 'user,id=omarchy-net'
assert_line_pair "$test_root/disabled/qemu.log" -kernel "$persistent_root/boot/kernel"
assert_line_pair "$test_root/disabled/qemu.log" -initrd "$persistent_root/boot/initramfs"
assert_not_contains "$disabled_qemu" hostfwd
assert_not_contains "$disabled_qemu" tryomarchy.ssh_access
assert_contains "$disabled_qemu" \
  'cocoa,gl=es,show-cursor=on,zoom-to-fit=on,full-screen=on,full-grab=on,immersive=on,swap-opt-cmd=off'
assert_contains "$(<"$test_root/disabled/storage.log")" select-existing
assert_contains "$(<"$test_root/disabled/storage.log")" create

run_scenario non-immersive 0 '' OMARCHY_QEMU_GPU_IMMERSIVE=0
non_immersive_qemu=$(<"$test_root/non-immersive/qemu.log")
assert_contains "$non_immersive_qemu" \
  'cocoa,gl=es,show-cursor=on,zoom-to-fit=on,full-screen=on,full-grab=on,immersive=off,swap-opt-cmd=off'

# Simulate installing a newer app build after the first VM was created. The
# saved VM must be selected before the launcher even considers the absent new
# factory image, and it must boot with the kernel, initramfs, and base command
# line that were paired with its disk.
/bin/rm -f "$guest/rootfs.ext4"
printf 'new-kernel\n' >"$guest/vmlinuz-linux"
printf 'new-initramfs\n' >"$guest/initramfs-linux.img"
/usr/bin/plutil -replace kernelCommandLine -string \
  'root=/dev/vda rw rootwait console=tty0 console=hvc0 loglevel=5 systemd.show_status=false rd.systemd.show_status=false mitigations=off nowatchdog' \
  "$guest/launch.plist"
run_scenario enabled 0 '' OMARCHY_QEMU_GPU_PORT_FORWARDS=tcp:2223:22
enabled_qemu=$(<"$test_root/enabled/qemu.log")
assert_line_pair "$test_root/enabled/qemu.log" -netdev \
  'user,id=omarchy-net,hostfwd=tcp:127.0.0.1:2223-:22'
assert_line_pair "$test_root/enabled/qemu.log" -kernel "$persistent_root/boot/kernel"
assert_line_pair "$test_root/enabled/qemu.log" -initrd "$persistent_root/boot/initramfs"
assert_contains "$enabled_qemu" tryomarchy.ssh_access=1
assert_contains "$enabled_qemu" loglevel=4
assert_not_contains "$enabled_qemu" loglevel=5
assert_not_contains "$enabled_qemu" 0.0.0.0
assert_contains "$(<"$test_root/enabled/storage.log")" reuse
assert_not_contains "$(<"$test_root/enabled/storage.log")" materialize
assert_not_contains "$(<"$test_root/enabled/storage.log")" 'select persistent'
assert_contains "$(<"$persistent_root/boot/kernel")" kernel
assert_not_contains "$(<"$persistent_root/boot/kernel")" new-kernel
printf 'factory\n' >"$guest/rootfs.ext4"

# Older schema-2 disks have no host-side boot kit. Merely selecting one asks
# the app for explicit consent (status 80) and does not start either recovery
# or the normal VM.
recovery_root="$test_root/recovery-persistent"
mkdir -p "$recovery_root"
printf 'legacy-user-disk\n' >"$recovery_root/rootfs.ext4"
chmod 600 "$recovery_root/rootfs.ext4"
run_scenario recovery-consent-required 80 '' \
  "FAKE_PERSISTENT_ROOT=$recovery_root" \
  "FAKE_QEMU_RECOVERY_LOG=$test_root/recovery-consent-required/recovery.log"
assert_contains "$(<"$test_root/recovery-consent-required/storage.log")" reuse
assert_not_contains "$(<"$test_root/recovery-consent-required/storage.log")" stage-recovered-boot
assert_contains "$(<"$test_root/recovery-consent-required/stderr")" \
  'needs consent for one-time read-only boot pairing'
[[ ! -e $test_root/recovery-consent-required/qemu.log ]] || \
  fail 'recovery consent request started the normal VM'
[[ ! -e $test_root/recovery-consent-required/recovery.log ]] || \
  fail 'recovery consent request started recovery QEMU'
[[ ! -e $recovery_root/boot ]] || fail 'recovery consent request staged boot files'

# A recovery-specific failure keeps its own status so the app can explain that
# the saved VM remains intact and offer another attempt instead of blaming the
# installed app generally.
recovery_failure_root="$test_root/recovery-failure-persistent"
mkdir -p "$recovery_failure_root"
printf 'legacy-user-disk\n' >"$recovery_failure_root/rootfs.ext4"
chmod 600 "$recovery_failure_root/rootfs.ext4"
run_scenario recovery-failed 81 '' \
  "FAKE_PERSISTENT_ROOT=$recovery_failure_root" \
  "FAKE_QEMU_RECOVERY_LOG=$test_root/recovery-failed/recovery.log" \
  OMARCHY_QEMU_GPU_ALLOW_BOOT_RECOVERY=1 \
  FAKE_QEMU_STATUS=17
assert_contains "$(<"$test_root/recovery-failed/stderr")" \
  'the one-time boot recovery exited with status 17'
[[ ! -e $test_root/recovery-failed/qemu.log ]] || \
  fail 'failed recovery started the normal VM'
[[ ! -e $recovery_failure_root/boot ]] || \
  fail 'failed recovery staged a boot kit'
assert_contains "$(<"$recovery_failure_root/rootfs.ext4")" legacy-user-disk

# With consent, the recovery boot exposes the disk read-only and exports only
# its matching boot pair. The subsequent normal boot consumes the newly staged
# files and the recovered base command line.
run_scenario recovery-allowed 0 '' \
  "FAKE_PERSISTENT_ROOT=$recovery_root" \
  "FAKE_QEMU_RECOVERY_LOG=$test_root/recovery-allowed/recovery.log" \
  OMARCHY_QEMU_GPU_ALLOW_BOOT_RECOVERY=1
recovery_qemu=$(<"$test_root/recovery-allowed/recovery.log")
assert_line_pair "$test_root/recovery-allowed/recovery.log" -machine \
  'virt,accel=hvf,gic-version=3'
assert_not_contains "$recovery_qemu" gic-version=2
assert_line_pair "$test_root/recovery-allowed/recovery.log" -drive \
  "if=none,id=omarchy-recovery-root,file=$recovery_root/rootfs.ext4,format=raw,media=disk,cache=none,readonly=on"
assert_line_pair "$test_root/recovery-allowed/recovery.log" -device \
  'virtio-9p-pci,fsdev=omarchy-boot-export,mount_tag=try-omarchy-boot-export,romfile='
assert_contains "$recovery_qemu" 'root=/dev/vda ro rootwait'
assert_contains "$recovery_qemu" 'rootflags=noload fsck.mode=skip tryomarchy.export_boot=1'
assert_not_contains "$recovery_qemu" 'root=/dev/vda rw rootwait'
[[ $(grep -o 'rootflags=noload' \
  "$test_root/recovery-allowed/recovery.log" | wc -l | tr -d ' ') == 1 ]] || \
  fail 'recovery must force exactly one read-only no-journal mount option'
[[ $(grep -o 'tryomarchy.export_boot=1' \
  "$test_root/recovery-allowed/recovery.log" | wc -l | tr -d ' ') == 1 ]] || \
  fail 'recovery must append exactly one boot-export activation token'
assert_contains "$(<"$test_root/recovery-allowed/storage.log")" stage-recovered-boot
assert_line_pair "$test_root/recovery-allowed/qemu.log" -kernel "$recovery_root/boot/kernel"
assert_line_pair "$test_root/recovery-allowed/qemu.log" -initrd "$recovery_root/boot/initramfs"
assert_contains "$(<"$test_root/recovery-allowed/qemu.log")" loglevel=3
assert_not_contains "$(<"$test_root/recovery-allowed/qemu.log")" loglevel=5
assert_contains "$(<"$recovery_root/boot/kernel")" recovered-kernel
assert_contains "$(<"$recovery_root/boot/initramfs")" recovered-initramfs
assert_contains "$(<"$recovery_root/boot/command-line")" loglevel=3
assert_contains "$(<"$recovery_root/rootfs.ext4")" legacy-user-disk

# Once paired, the same VM launches without consent and without another
# recovery invocation.
run_scenario recovery-relaunch 0 '' \
  "FAKE_PERSISTENT_ROOT=$recovery_root" \
  "FAKE_QEMU_RECOVERY_LOG=$test_root/recovery-relaunch/recovery.log"
assert_contains "$(<"$test_root/recovery-relaunch/storage.log")" reuse
assert_not_contains "$(<"$test_root/recovery-relaunch/storage.log")" stage-recovered-boot
assert_not_contains "$(<"$test_root/recovery-relaunch/stderr")" 'needs consent'
[[ ! -e $test_root/recovery-relaunch/recovery.log ]] || \
  fail 'a paired VM unnecessarily ran boot recovery again'
assert_line_pair "$test_root/recovery-relaunch/qemu.log" -kernel "$recovery_root/boot/kernel"
assert_line_pair "$test_root/recovery-relaunch/qemu.log" -initrd "$recovery_root/boot/initramfs"
assert_contains "$(<"$test_root/recovery-relaunch/qemu.log")" loglevel=3
assert_contains "$(<"$recovery_root/rootfs.ext4")" legacy-user-disk

run_scenario preset 0 '' OMARCHY_QEMU_GPU_PORT_FORWARDS=tcp:2222:22
assert_line_pair "$test_root/preset/qemu.log" -netdev \
  'user,id=omarchy-net,hostfwd=tcp:127.0.0.1:2222-:22'
[[ $(grep -o 'tryomarchy.ssh_access=1' "$test_root/preset/qemu.log" | wc -l | tr -d ' ') == 1 ]] || \
  fail 'preset must append exactly one SSH activation token'

run_scenario udp-22 0 '' OMARCHY_QEMU_GPU_PORT_FORWARDS=udp:2224:22
udp_qemu=$(<"$test_root/udp-22/qemu.log")
assert_contains "$udp_qemu" 'hostfwd=udp:127.0.0.1:2224-:22'
assert_not_contains "$udp_qemu" tryomarchy.ssh_access

run_scenario unrelated 0 '' OMARCHY_QEMU_GPU_PORT_FORWARDS=tcp:8080:3000
unrelated_qemu=$(<"$test_root/unrelated/qemu.log")
assert_contains "$unrelated_qemu" 'hostfwd=tcp:127.0.0.1:8080-:3000'
assert_not_contains "$unrelated_qemu" tryomarchy.ssh_access

run_scenario mixed 0 '' \
  'OMARCHY_QEMU_GPU_PORT_FORWARDS=udp:5353:5353;tcp:22022:22;udp:2222:22'
mixed_qemu=$(<"$test_root/mixed/qemu.log")
assert_contains "$mixed_qemu" 'hostfwd=tcp:127.0.0.1:22022-:22'
assert_contains "$mixed_qemu" 'hostfwd=udp:127.0.0.1:2222-:22'
[[ $(grep -o 'tryomarchy.ssh_access=1' "$test_root/mixed/qemu.log" | wc -l | tr -d ' ') == 1 ]] || \
  fail 'mixed forwarding must append exactly one SSH activation token'

run_scenario ephemeral 0 --ephemeral OMARCHY_QEMU_GPU_PORT_FORWARDS=tcp:2224:22
assert_contains "$(<"$test_root/ephemeral/qemu.log")" \
  'user,id=omarchy-net,hostfwd=tcp:127.0.0.1:2224-:22'
assert_contains "$(<"$test_root/ephemeral/qemu.log")" tryomarchy.ssh_access=1
assert_contains "$(<"$test_root/ephemeral/storage.log")" 'select ephemeral'
assert_line_pair "$test_root/ephemeral/qemu.log" -kernel "$guest/vmlinuz-linux"
assert_line_pair "$test_root/ephemeral/qemu.log" -initrd "$guest/initramfs-linux.img"
assert_contains "$(<"$test_root/ephemeral/qemu.log")" loglevel=5

run_scenario malformed 1 '' OMARCHY_QEMU_GPU_PORT_FORWARDS=tcp:02222:22
[[ ! -s $test_root/malformed/storage.log ]] || fail 'malformed mapping touched storage'
assert_contains "$(<"$test_root/malformed/stderr")" 'canonical decimal'

run_scenario reset-only 0 --reset-storage-only \
  OMARCHY_QEMU_GPU_PORT_FORWARDS=tcp:2225:22
assert_contains "$(<"$test_root/reset-only/storage.log")" 'select reset'
[[ ! -e $test_root/reset-only/qemu.log ]] || fail 'reset-only launch started QEMU'
assert_not_contains "$(<"$test_root/reset-only/stderr")" tryomarchy.ssh_access
assert_contains "$(<"$persistent_root/boot/kernel")" new-kernel
assert_contains "$(<"$persistent_root/boot/initramfs")" new-initramfs
assert_contains "$(<"$persistent_root/boot/command-line")" loglevel=5

/usr/bin/plutil -replace kernelCommandLine -string \
  'root=/dev/vda rw rootwait console=tty0 console=hvc0 tryomarchy.ssh_access=0' \
  "$guest/launch.plist"
run_scenario prebaked-token 1 '' OMARCHY_QEMU_GPU_PORT_FORWARDS=tcp:2222:22
[[ ! -s $test_root/prebaked-token/storage.log ]] || fail 'prebaked token touched storage'
assert_contains "$(<"$test_root/prebaked-token/stderr")" 'launcher-owned SSH activation argument'

printf 'run-qemu-ssh-contract.test: PASS\n'
