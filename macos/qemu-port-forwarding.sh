#!/bin/bash

# Strict port-forwarding configuration for run-qemu-gpu.sh.
#
# The launcher passes the complete value of OMARCHY_QEMU_GPU_PORT_FORWARDS to
# qemu_port_forwarding_configure. On success, the exported values below are
# safe to pass to QEMU as one -netdev argument and to include in launch logs.
# No partially parsed configuration is exposed when validation fails.

QEMU_PORT_FORWARDING_MAX_RULES=32
QEMU_PORT_FORWARDING_MAX_INPUT_BYTES=4096

QEMU_PORT_FORWARDING_NETDEV='user,id=omarchy-net'
QEMU_PORT_FORWARDING_CANONICAL=''
QEMU_PORT_FORWARDING_SUMMARY='disabled'
QEMU_PORT_FORWARDING_RULE_COUNT=0
QEMU_PORT_FORWARDING_ENABLES_SSH=0
QEMU_PORT_FORWARDING_ERROR=''

_qpf_fail() {
  QEMU_PORT_FORWARDING_ERROR=$1
  return 1
}

qemu_port_forwarding_configure() {
  local qpf_input=${1-}
  local LC_ALL=C
  local qpf_remaining=''
  local qpf_rule=''
  local qpf_protocol=''
  local qpf_host_text=''
  local qpf_guest_text=''
  local qpf_host_port=0
  local qpf_guest_port=0
  local qpf_rule_count=0
  local qpf_final_rule=0
  local qpf_key=''
  local qpf_seen='|'
  local qpf_netdev='user,id=omarchy-net'
  local qpf_canonical=''
  local qpf_summary=''
  local qpf_enables_ssh=0

  QEMU_PORT_FORWARDING_NETDEV='user,id=omarchy-net'
  QEMU_PORT_FORWARDING_CANONICAL=''
  QEMU_PORT_FORWARDING_SUMMARY='disabled'
  QEMU_PORT_FORWARDING_RULE_COUNT=0
  QEMU_PORT_FORWARDING_ENABLES_SSH=0
  QEMU_PORT_FORWARDING_ERROR=''

  if ((${#qpf_input} > QEMU_PORT_FORWARDING_MAX_INPUT_BYTES)); then
    _qpf_fail \
      "port-forwarding configuration exceeds $QEMU_PORT_FORWARDING_MAX_INPUT_BYTES bytes"
    return 1
  fi
  [[ -n $qpf_input ]] || return 0

  qpf_remaining=$qpf_input
  while :; do
    qpf_rule_count=$((qpf_rule_count + 1))
    if ((qpf_rule_count > QEMU_PORT_FORWARDING_MAX_RULES)); then
      _qpf_fail \
        "port-forwarding configuration has more than $QEMU_PORT_FORWARDING_MAX_RULES rules"
      return 1
    fi

    if [[ $qpf_remaining == *';'* ]]; then
      qpf_rule=${qpf_remaining%%;*}
      qpf_remaining=${qpf_remaining#*;}
      qpf_final_rule=0
    else
      qpf_rule=$qpf_remaining
      qpf_remaining=''
      qpf_final_rule=1
    fi

    if [[ -z $qpf_rule ]]; then
      _qpf_fail "port-forwarding rule $qpf_rule_count is empty"
      return 1
    fi
    if [[ ! $qpf_rule =~ ^(tcp|udp):([0-9]+):([0-9]+)$ ]]; then
      _qpf_fail \
        "port-forwarding rule $qpf_rule_count must use protocol:host-port:guest-port"
      return 1
    fi

    qpf_protocol=${BASH_REMATCH[1]}
    qpf_host_text=${BASH_REMATCH[2]}
    qpf_guest_text=${BASH_REMATCH[3]}
    if [[ $qpf_host_text == 0?* || $qpf_guest_text == 0?* ]]; then
      _qpf_fail \
        "port-forwarding rule $qpf_rule_count ports must use canonical decimal without leading zeroes"
      return 1
    fi
    if ((${#qpf_host_text} > 5)); then
      _qpf_fail "port-forwarding rule $qpf_rule_count host port must be 1...65535"
      return 1
    fi
    if ((${#qpf_guest_text} > 5)); then
      _qpf_fail "port-forwarding rule $qpf_rule_count guest port must be 1...65535"
      return 1
    fi
    qpf_host_port=$((10#$qpf_host_text))
    qpf_guest_port=$((10#$qpf_guest_text))
    if ((qpf_host_port < 1 || qpf_host_port > 65535)); then
      _qpf_fail "port-forwarding rule $qpf_rule_count host port must be 1...65535"
      return 1
    fi
    if ((qpf_guest_port < 1 || qpf_guest_port > 65535)); then
      _qpf_fail "port-forwarding rule $qpf_rule_count guest port must be 1...65535"
      return 1
    fi

    qpf_key="$qpf_protocol:$qpf_host_port"
    case "$qpf_seen" in
      *"|$qpf_key|"*)
        _qpf_fail \
          "port-forwarding rule $qpf_rule_count duplicates $qpf_protocol host port $qpf_host_port"
        return 1
        ;;
    esac
    qpf_seen="${qpf_seen}${qpf_key}|"

    if [[ $qpf_protocol == tcp && $qpf_guest_port == 22 ]]; then
      qpf_enables_ssh=1
    fi

    qpf_netdev="$qpf_netdev,hostfwd=$qpf_protocol:127.0.0.1:$qpf_host_port-:$qpf_guest_port"
    if [[ -n $qpf_canonical ]]; then
      qpf_canonical="$qpf_canonical;"
      qpf_summary="$qpf_summary; "
    fi
    qpf_canonical="$qpf_canonical$qpf_protocol:$qpf_host_port:$qpf_guest_port"
    qpf_summary="$qpf_summary$qpf_protocol 127.0.0.1:$qpf_host_port -> guest:$qpf_guest_port"

    ((qpf_final_rule)) && break
  done

  QEMU_PORT_FORWARDING_NETDEV=$qpf_netdev
  QEMU_PORT_FORWARDING_CANONICAL=$qpf_canonical
  QEMU_PORT_FORWARDING_SUMMARY=$qpf_summary
  QEMU_PORT_FORWARDING_RULE_COUNT=$qpf_rule_count
  QEMU_PORT_FORWARDING_ENABLES_SSH=$qpf_enables_ssh
}
