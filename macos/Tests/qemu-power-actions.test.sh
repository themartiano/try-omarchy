#!/bin/bash

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd -P)
launcher=$(cd "$test_dir/.." && pwd -P)/run-qemu-gpu.sh

fail() {
  printf 'qemu-power-actions.test: %s\n' "$*" >&2
  exit 1
}

qemu_arguments=$(sed -n '/^qemu_args=(/,/^)/p' "$launcher")
[[ -n $qemu_arguments ]] || fail 'could not find the QEMU argument list'

action_count=$(printf '%s\n' "$qemu_arguments" | grep -Ec -- \
  "^[[:space:]]+-action 'reboot=reset,shutdown=poweroff'[[:space:]]*$" || true)
[[ $action_count == 1 ]] || {
  fail 'QEMU must reset on guest reboot and power off on guest shutdown'
}
[[ $qemu_arguments != *-no-reboot* ]] || {
  fail 'QEMU must not turn a guest reboot into a process exit'
}
[[ $qemu_arguments != *-no-shutdown* ]] || {
  fail 'QEMU must not remain open after a guest shutdown'
}

qmp_argument_count=$(printf '%s\n' "$qemu_arguments" | grep -Fxc -- \
  '  -qmp "unix:$qmp_socket,server=on,wait=off"' || true)
[[ $qmp_argument_count == 1 ]] || {
  fail 'QEMU must expose its private machine-protocol control socket exactly once'
}

monitor_argument_count=$(printf '%s\n' "$qemu_arguments" | grep -Ec -- \
  '^[[:space:]]+-mon(itor)?[[:space:]]' || true)
monitor_none_count=$(printf '%s\n' "$qemu_arguments" | grep -Fxc -- \
  '  -monitor none' || true)
[[ $monitor_argument_count == 1 && $monitor_none_count == 1 ]] || {
  fail 'QMP must be the only QEMU monitor that can pause the VM'
}

gdb_argument_count=$(printf '%s\n' "$qemu_arguments" | grep -Ec -- \
  '^[[:space:]]+(-gdb|-s)([[:space:]]|$)' || true)
[[ $gdb_argument_count == 0 ]] || {
  fail 'the production VM must not expose a second debugger pause controller'
}

qmp_assignment_count=$(grep -Fxc -- \
  'qmp_socket="/tmp/${work_dir##*/}/qmp.sock"' "$launcher" || true)
[[ $qmp_assignment_count == 1 ]] || {
  fail 'the QMP socket pathname must match the validated launcher contract'
}

mktemp_template_count=$(grep -Fxc -- \
  "work_dir=\$(mktemp -d '/private/tmp/omarchy-qemu-gpu.XXXXXX') || {" \
  "$launcher" || true)
[[ $mktemp_template_count == 1 ]] || {
  fail 'the private runtime directory must retain its six-character token'
}

ready_control_count=$(grep -Fxc -- \
  'echo "[qemu-gpu] Ready. QMP: $qmp_socket" >&2' "$launcher" || true)
[[ $ready_control_count == 1 ]] || {
  fail 'the Ready event must advertise the same private QMP socket used by QEMU'
}

ready_emission_count=$(grep -Ec -- \
  '^[[:space:]]*echo .*\[qemu-gpu\] Ready\.' "$launcher" || true)
[[ $ready_emission_count == 1 ]] || {
  fail 'the launcher must emit exactly one Ready event'
}

qmp_check_line=$(grep -nF -- \
  '[[ -S $qmp_socket ]] || fail "QEMU did not create its private QMP socket"' \
  "$launcher" | cut -d: -f1)
ready_line=$(grep -nF -- \
  'echo "[qemu-gpu] Ready. QMP: $qmp_socket" >&2' "$launcher" | cut -d: -f1)
[[ -n $qmp_check_line && -n $ready_line && $qmp_check_line -lt $ready_line ]] || {
  fail 'the Ready event must follow QMP socket validation'
}

printf 'qemu-power-actions.test: reboot/shutdown and host-sleep control policy: PASS\n'
