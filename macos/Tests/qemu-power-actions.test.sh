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

printf 'qemu-power-actions.test: reboot/shutdown policy: PASS\n'
