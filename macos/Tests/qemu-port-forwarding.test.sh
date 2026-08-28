#!/bin/bash

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd -P)
native_dir=$(cd "$test_dir/.." && pwd -P)
# shellcheck source=../qemu-port-forwarding.sh
source "$native_dir/qemu-port-forwarding.sh"

fail() {
  printf 'qemu-port-forwarding.test: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  [[ $1 == "$2" ]] || fail "expected [$2], got [$1]"
}

assert_contains() {
  [[ $1 == *"$2"* ]] || fail "expected [$1] to contain [$2]"
}

assert_rejected() {
  local input=$1
  local expected_error=${2:-}

  if qemu_port_forwarding_configure "$input"; then
    fail "configuration unexpectedly succeeded: [$input]"
  fi
  [[ -n $QEMU_PORT_FORWARDING_ERROR ]] || fail "rejection did not explain the error"
  if [[ -n $expected_error ]]; then
    assert_contains "$QEMU_PORT_FORWARDING_ERROR" "$expected_error"
  fi
  assert_eq "$QEMU_PORT_FORWARDING_NETDEV" 'user,id=omarchy-net'
  assert_eq "$QEMU_PORT_FORWARDING_CANONICAL" ''
  assert_eq "$QEMU_PORT_FORWARDING_SUMMARY" disabled
  assert_eq "$QEMU_PORT_FORWARDING_RULE_COUNT" 0
}

qemu_port_forwarding_configure ''
assert_eq "$QEMU_PORT_FORWARDING_NETDEV" 'user,id=omarchy-net'
assert_eq "$QEMU_PORT_FORWARDING_CANONICAL" ''
assert_eq "$QEMU_PORT_FORWARDING_SUMMARY" disabled
assert_eq "$QEMU_PORT_FORWARDING_RULE_COUNT" 0
assert_eq "$QEMU_PORT_FORWARDING_ERROR" ''

qemu_port_forwarding_configure 'tcp:8080:3000'
assert_eq \
  "$QEMU_PORT_FORWARDING_NETDEV" \
  'user,id=omarchy-net,hostfwd=tcp:127.0.0.1:8080-:3000'
assert_eq "$QEMU_PORT_FORWARDING_CANONICAL" 'tcp:8080:3000'
assert_eq \
  "$QEMU_PORT_FORWARDING_SUMMARY" \
  'tcp 127.0.0.1:8080 -> guest:3000'
assert_eq "$QEMU_PORT_FORWARDING_RULE_COUNT" 1

qemu_port_forwarding_configure 'udp:5353:5353;tcp:2222:22;udp:2222:22'
assert_eq \
  "$QEMU_PORT_FORWARDING_NETDEV" \
  'user,id=omarchy-net,hostfwd=udp:127.0.0.1:5353-:5353,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=udp:127.0.0.1:2222-:22'
assert_eq \
  "$QEMU_PORT_FORWARDING_CANONICAL" \
  'udp:5353:5353;tcp:2222:22;udp:2222:22'
assert_eq "$QEMU_PORT_FORWARDING_RULE_COUNT" 3

qemu_port_forwarding_configure 'tcp:1:65535;udp:65535:1'
assert_eq "$QEMU_PORT_FORWARDING_CANONICAL" 'tcp:1:65535;udp:65535:1'

for invalid in \
  'TCP:80:80' \
  'sctp:80:80' \
  'tcp:0:80' \
  'tcp:80:0' \
  'tcp:65536:80' \
  'tcp:80:65536' \
  'tcp:-1:80' \
  'tcp:+1:80' \
  'tcp:01:80' \
  'tcp:80:01' \
  'tcp:000001:80' \
  'tcp: 80:80' \
  'tcp:80 :80' \
  'tcp:80:80 ' \
  'tcp:x80:80' \
  'tcp:80:80x' \
  'tcp:80' \
  'tcp:80:80:90'; do
  assert_rejected "$invalid" 'rule 1'
done

assert_rejected ';tcp:80:80' 'rule 1 is empty'
assert_rejected 'tcp:80:80;' 'rule 2 is empty'
assert_rejected 'tcp:80:80;;udp:53:53' 'rule 2 is empty'
assert_rejected 'tcp:80:80;tcp:80:81' 'duplicates tcp host port 80'

rules=''
for ((port = 1; port <= QEMU_PORT_FORWARDING_MAX_RULES; port++)); do
  [[ -z $rules ]] || rules="$rules;"
  rules="${rules}tcp:$port:$port"
done
qemu_port_forwarding_configure "$rules"
assert_eq "$QEMU_PORT_FORWARDING_RULE_COUNT" "$QEMU_PORT_FORWARDING_MAX_RULES"
assert_contains \
  "$QEMU_PORT_FORWARDING_NETDEV" \
  "hostfwd=tcp:127.0.0.1:$QEMU_PORT_FORWARDING_MAX_RULES-:$QEMU_PORT_FORWARDING_MAX_RULES"
assert_rejected "${rules};tcp:33:33" "more than $QEMU_PORT_FORWARDING_MAX_RULES rules"

oversized=''
for ((index = 0; index <= QEMU_PORT_FORWARDING_MAX_INPUT_BYTES; index++)); do
  oversized="${oversized}x"
done
assert_rejected "$oversized" "exceeds $QEMU_PORT_FORWARDING_MAX_INPUT_BYTES bytes"

# A valid call after failures must replace the reset failure state completely.
qemu_port_forwarding_configure 'udp:53:53'
assert_eq \
  "$QEMU_PORT_FORWARDING_NETDEV" \
  'user,id=omarchy-net,hostfwd=udp:127.0.0.1:53-:53'
assert_eq "$QEMU_PORT_FORWARDING_ERROR" ''

printf 'qemu-port-forwarding.test: PASS\n'
