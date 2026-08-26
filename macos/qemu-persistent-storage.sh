#!/bin/bash

# Persistent-disk lifecycle for run-qemu-gpu.sh.
#
# This file is intentionally a library, not a subprocess. The caller must
# source it so file descriptor 9, and therefore its BSD advisory lock, remains
# open for the complete QEMU lifetime. The caller must pass
# `-add-fd "$QEMU_PERSISTENT_STORAGE_QEMU_ADD_FD"` to QEMU; QEMU otherwise
# closes unrelated inherited descriptors. The fdset keeps the lock alive if
# the launcher is killed while QEMU is still writing the disk.

QEMU_PERSISTENT_STORAGE_SCHEMA=2
QEMU_PERSISTENT_STORAGE_KIND='omarchy-qemu-persistent-disk'
QEMU_PERSISTENT_STORAGE_ROOT_MARKER='omarchy-qemu-storage-root-v1'
QEMU_PERSISTENT_STORAGE_LOCK_FD=9
QEMU_PERSISTENT_STORAGE_QEMU_ADD_FD='fd=9,set=77,opaque=omarchy-persistent-lock'
QEMU_PERSISTENT_STORAGE_INCOMPATIBLE_STATUS=78
QEMU_PERSISTENT_STORAGE_UPDATE_REQUIRED_STATUS=79
QEMU_PERSISTENT_STORAGE_BOOT_KIT_KIND='omarchy-qemu-boot-kit'
QEMU_PERSISTENT_STORAGE_UPDATE_KIND='omarchy-qemu-generational-update'

QEMU_SELECTED_DISK=''
QEMU_SELECTED_STORAGE_MODE=''
QEMU_PERSISTENT_STORAGE_DIRECTORY=''
QEMU_PERSISTENT_STORAGE_IDENTITY=''
QEMU_PERSISTENT_STORAGE_LOCK_PATH=''
QEMU_PERSISTENT_STORAGE_WORKING_BYTES=''
QEMU_IMMUTABLE_SOURCE_DISK=''
QEMU_PERSISTENT_STORAGE_UPDATE_IMAGE=''
QEMU_PERSISTENT_STORAGE_UPDATE_STATE=''
QEMU_PERSISTENT_STORAGE_UPDATE_HEALTH_TOKEN=''
QEMU_PERSISTENT_STORAGE_ACTIVE_IDENTITY=''
QEMU_PERSISTENT_STORAGE_ACTIVE_DISK=''
QEMU_PERSISTENT_STORAGE_ACTIVE_BOOT_DIRECTORY=''
QEMU_PERSISTENT_STORAGE_ACTIVE_KERNEL=''
QEMU_PERSISTENT_STORAGE_ACTIVE_INITRAMFS=''
QEMU_PERSISTENT_STORAGE_CANDIDATE_IDENTITY=''
QEMU_PERSISTENT_STORAGE_CANDIDATE_DISK=''
QEMU_PERSISTENT_STORAGE_CANDIDATE_BOOT_DIRECTORY=''
QEMU_PERSISTENT_STORAGE_CANDIDATE_KERNEL=''
QEMU_PERSISTENT_STORAGE_CANDIDATE_INITRAMFS=''
QPS_LEGACY_LOCK_PATH=''
QPS_METADATA_SCHEMA=''
QPS_METADATA_IDENTITY=''
QPS_METADATA_SOURCE_SHA=''
QPS_METADATA_SOURCE_BYTES=''
QPS_RECORDED_EXISTING_BYTES=''
QPS_BOOT_IDENTITY=''
QPS_BOOT_KERNEL_BYTES=''
QPS_BOOT_KERNEL_SHA=''
QPS_BOOT_INITRAMFS_BYTES=''
QPS_BOOT_INITRAMFS_SHA=''
QPS_UPDATE_FROM_IDENTITY=''
QPS_UPDATE_FROM_BOOT_AVAILABLE=''
QPS_UPDATE_FROM_SOURCE_BYTES=''
QPS_UPDATE_FROM_SOURCE_SHA=''
QPS_UPDATE_FROM_WORKING_BYTES=''
QPS_UPDATE_FROM_KERNEL_BYTES=''
QPS_UPDATE_FROM_KERNEL_SHA=''
QPS_UPDATE_FROM_INITRAMFS_BYTES=''
QPS_UPDATE_FROM_INITRAMFS_SHA=''
QPS_UPDATE_TARGET_IDENTITY=''
QPS_UPDATE_TARGET_SOURCE_BYTES=''
QPS_UPDATE_TARGET_SOURCE_SHA=''
QPS_UPDATE_TARGET_WORKING_BYTES=''
QPS_UPDATE_TARGET_KERNEL_BYTES=''
QPS_UPDATE_TARGET_KERNEL_SHA=''
QPS_UPDATE_TARGET_INITRAMFS_BYTES=''
QPS_UPDATE_TARGET_INITRAMFS_SHA=''
QPS_UPDATE_HEALTH_TOKEN=''

_qps_error() {
  printf 'qemu-persistent-storage: %s\n' "$*" >&2
}

_qps_fail() {
  _qps_error "$*"
  return 1
}

_qps_incompatible() {
  _qps_error "$*"
  return "$QEMU_PERSISTENT_STORAGE_INCOMPATIBLE_STATUS"
}

_qps_update_required() {
  _qps_error "$*"
  return "$QEMU_PERSISTENT_STORAGE_UPDATE_REQUIRED_STATUS"
}

_qps_reset_update_outputs() {
  QEMU_PERSISTENT_STORAGE_UPDATE_STATE=''
  QEMU_PERSISTENT_STORAGE_UPDATE_HEALTH_TOKEN=''
  QEMU_PERSISTENT_STORAGE_ACTIVE_IDENTITY=''
  QEMU_PERSISTENT_STORAGE_ACTIVE_DISK=''
  QEMU_PERSISTENT_STORAGE_ACTIVE_BOOT_DIRECTORY=''
  QEMU_PERSISTENT_STORAGE_ACTIVE_KERNEL=''
  QEMU_PERSISTENT_STORAGE_ACTIVE_INITRAMFS=''
  QEMU_PERSISTENT_STORAGE_CANDIDATE_IDENTITY=''
  QEMU_PERSISTENT_STORAGE_CANDIDATE_DISK=''
  QEMU_PERSISTENT_STORAGE_CANDIDATE_BOOT_DIRECTORY=''
  QEMU_PERSISTENT_STORAGE_CANDIDATE_KERNEL=''
  QEMU_PERSISTENT_STORAGE_CANDIDATE_INITRAMFS=''
}

_qps_is_identity() {
  [[ ${1:-} =~ ^[0-9a-f]{64}$ ]]
}

_qps_is_positive_integer() {
  [[ ${1:-} =~ ^[1-9][0-9]*$ ]]
}

_qps_lstat_kind() {
  stat -f '%HT' "$1" 2>/dev/null
}

_qps_owner() {
  stat -f '%u' "$1" 2>/dev/null
}

_qps_permissions() {
  stat -f '%Lp' "$1" 2>/dev/null
}

_qps_size() {
  stat -f '%z' "$1" 2>/dev/null
}

_qps_sha256() {
  /usr/bin/shasum -a 256 "$1" 2>/dev/null | awk '{ print $1 }'
}

_qps_file_identity() {
  stat -f '%d:%i' "$1" 2>/dev/null
}

_qps_assert_private_directory() {
  local qps_directory=$1
  local qps_label=$2

  [[ -d $qps_directory && ! -L $qps_directory ]] || {
    _qps_fail "$qps_label is not a direct directory: $qps_directory"
    return 1
  }
  [[ $(_qps_lstat_kind "$qps_directory") == Directory ]] || {
    _qps_fail "$qps_label has an unsafe file type: $qps_directory"
    return 1
  }
  [[ $(_qps_owner "$qps_directory") == $(id -u) ]] || {
    _qps_fail "$qps_label is not owned by the current user: $qps_directory"
    return 1
  }
  [[ $(_qps_permissions "$qps_directory") == 700 ]] || {
    _qps_fail "$qps_label must have mode 0700: $qps_directory"
    return 1
  }
}

_qps_assert_private_regular_file() {
  local qps_file=$1
  local qps_label=$2

  [[ -f $qps_file && ! -L $qps_file ]] || {
    _qps_fail "$qps_label is not a direct regular file: $qps_file"
    return 1
  }
  [[ $(_qps_lstat_kind "$qps_file") == 'Regular File' ]] || {
    _qps_fail "$qps_label has an unsafe file type: $qps_file"
    return 1
  }
  [[ $(_qps_owner "$qps_file") == $(id -u) ]] || {
    _qps_fail "$qps_label is not owned by the current user: $qps_file"
    return 1
  }
  [[ $(_qps_permissions "$qps_file") == 600 ]] || {
    _qps_fail "$qps_label must have mode 0600: $qps_file"
    return 1
  }
}

_qps_assert_source_disk() {
  local qps_source=$1
  local qps_expected_bytes=$2

  [[ -f $qps_source && ! -L $qps_source ]] || {
    _qps_fail "source root disk is not a direct regular file: $qps_source"
    return 1
  }
  [[ $(_qps_lstat_kind "$qps_source") == 'Regular File' ]] || {
    _qps_fail "source root disk has an unsafe file type: $qps_source"
    return 1
  }
  [[ $(_qps_size "$qps_source") == "$qps_expected_bytes" ]] || {
    _qps_fail "source root disk does not have the manifest size"
    return 1
  }
}

_qps_assert_safe_root_path() {
  local qps_root=$1

  [[ $qps_root == /* && $qps_root != *$'\n'* && $qps_root != *$'\r'* ]] || {
    _qps_fail "state root must be an absolute single-line path"
    return 1
  }
  case "$qps_root" in
    /|/Users|/private|/private/tmp|/tmp)
      _qps_fail "refusing unsafe broad state root: $qps_root"
      return 1
      ;;
  esac
}

_qps_write_root_marker() {
  local qps_marker=$1

  (umask 077; set -o noclobber; printf '%s\n' "$QEMU_PERSISTENT_STORAGE_ROOT_MARKER" >"$qps_marker") \
    2>/dev/null
}

_qps_validate_root_marker() {
  local qps_marker=$1

  _qps_assert_private_regular_file "$qps_marker" 'state-root marker' || return 1
  [[ $(<"$qps_marker") == "$QEMU_PERSISTENT_STORAGE_ROOT_MARKER" ]] || {
    _qps_fail "state-root marker is invalid: $qps_marker"
    return 1
  }
}

_qps_prepare_state_root() {
  local qps_configured_root=''
  local qps_root=''
  local qps_marker=''
  local qps_marker_status=0
  local qps_child=''

  if [[ -n ${OMARCHY_QEMU_GPU_STATE_ROOT:-} ]]; then
    qps_configured_root=$OMARCHY_QEMU_GPU_STATE_ROOT
  else
    [[ -n ${HOME:-} ]] || {
      _qps_fail 'HOME is unavailable; cannot locate Application Support'
      return 1
    }
    qps_configured_root="$HOME/Library/Application Support/Try Omarchy/VM/v1"
  fi
  _qps_assert_safe_root_path "$qps_configured_root" || return 1

  umask 077
  mkdir -p "$qps_configured_root" || {
    _qps_fail "cannot create state root: $qps_configured_root"
    return 1
  }
  _qps_assert_private_directory "$qps_configured_root" 'state root' || return 1
  qps_root=$(cd "$qps_configured_root" && pwd -P) || {
    _qps_fail "cannot resolve state root: $qps_configured_root"
    return 1
  }
  _qps_assert_safe_root_path "$qps_root" || return 1

  qps_marker="$qps_root/.omarchy-qemu-storage"
  if [[ ! -e $qps_marker && ! -L $qps_marker ]]; then
    if _qps_write_root_marker "$qps_marker"; then
      :
    else
      qps_marker_status=$?
      [[ -e $qps_marker || -L $qps_marker ]] || {
        _qps_fail "cannot initialize state-root marker: $qps_marker"
        return 1
      }
    fi
  fi
  _qps_validate_root_marker "$qps_marker" || return 1

  for qps_child in boot disks images locks updates; do
    if [[ ! -e $qps_root/$qps_child && ! -L $qps_root/$qps_child ]]; then
      if mkdir "$qps_root/$qps_child" 2>/dev/null; then
        chmod 700 "$qps_root/$qps_child" || return 1
      elif [[ ! -d $qps_root/$qps_child || -L $qps_root/$qps_child ]]; then
        _qps_fail "cannot create state $qps_child directory"
        return 1
      fi
    fi
    _qps_assert_private_directory "$qps_root/$qps_child" "state $qps_child directory" || return 1
  done

  QEMU_PERSISTENT_STORAGE_ROOT=$qps_root
  QEMU_PERSISTENT_STORAGE_BOOT_ROOT="$qps_root/boot"
  QEMU_PERSISTENT_STORAGE_DISKS_ROOT="$qps_root/disks"
  QEMU_PERSISTENT_STORAGE_IMAGES_ROOT="$qps_root/images"
  QEMU_PERSISTENT_STORAGE_LOCKS_ROOT="$qps_root/locks"
  QEMU_PERSISTENT_STORAGE_UPDATES_ROOT="$qps_root/updates"
}

_qps_lock_fd_is_open() {
  { true >&9; } 2>/dev/null
}

_qps_fd_matches_path() {
  local qps_fd=$1
  local qps_path=$2
  [[ $(stat -f '%HT:%u:%i' "/dev/fd/$qps_fd" 2>/dev/null) == \
     "Regular File:$(id -u):$(_qps_file_identity "$qps_path" | sed 's/^.*://')" ]]
}

_qps_lock_fd_matches_path() {
  _qps_fd_matches_path 9 "$1"
}

_qps_acquire_lock() {
  local qps_identity=$1
  local qps_lock_path="$QEMU_PERSISTENT_STORAGE_LOCKS_ROOT/$qps_identity.lock"

  if _qps_lock_fd_is_open; then
    _qps_fail "file descriptor $QEMU_PERSISTENT_STORAGE_LOCK_FD is already in use"
    return 1
  fi
  [[ -x /usr/bin/lockf ]] || {
    _qps_fail '/usr/bin/lockf is required for persistent workspace locking'
    return 1
  }
  if [[ -e $qps_lock_path || -L $qps_lock_path ]]; then
    _qps_assert_private_regular_file "$qps_lock_path" 'workspace lock' || return 1
  fi

  exec 9>>"$qps_lock_path" || {
    _qps_fail "cannot open workspace lock: $qps_lock_path"
    return 1
  }
  chmod 600 "$qps_lock_path" || {
    exec 9>&-
    _qps_fail "cannot protect workspace lock: $qps_lock_path"
    return 1
  }
  _qps_assert_private_regular_file "$qps_lock_path" 'workspace lock' || {
    exec 9>&-
    return 1
  }
  _qps_lock_fd_matches_path "$qps_lock_path" || {
    exec 9>&-
    _qps_fail "workspace lock changed while it was opened"
    return 1
  }
  if ! /usr/bin/lockf -s -t 0 9; then
    exec 9>&-
    _qps_fail "workspace $qps_identity is already open"
    return 1
  fi

  QEMU_PERSISTENT_STORAGE_LOCK_PATH=$qps_lock_path
}

qemu_persistent_storage_release_lock() {
  if [[ -n $QPS_LEGACY_LOCK_PATH ]] && { true >&7; } 2>/dev/null; then
    exec 7>&-
  fi
  QPS_LEGACY_LOCK_PATH=''
  if _qps_lock_fd_is_open; then
    exec 9>&-
  fi
  QEMU_PERSISTENT_STORAGE_LOCK_PATH=''
}

_qps_acquire_legacy_lock() {
  local qps_identity=$1
  local qps_lock_path="$QEMU_PERSISTENT_STORAGE_LOCKS_ROOT/$qps_identity.lock"

  if { true >&7; } 2>/dev/null; then
    _qps_fail 'file descriptor 7 is already in use'
    return 1
  fi
  if [[ -e $qps_lock_path || -L $qps_lock_path ]]; then
    _qps_assert_private_regular_file "$qps_lock_path" 'legacy workspace lock' || return 1
  fi
  exec 7>>"$qps_lock_path" || {
    _qps_fail "cannot open legacy workspace lock: $qps_lock_path"
    return 1
  }
  chmod 600 "$qps_lock_path" || {
    exec 7>&-
    return 1
  }
  _qps_assert_private_regular_file "$qps_lock_path" 'legacy workspace lock' || {
    exec 7>&-
    return 1
  }
  _qps_fd_matches_path 7 "$qps_lock_path" || {
    exec 7>&-
    _qps_fail 'legacy workspace lock changed while it was opened'
    return 1
  }
  if ! /usr/bin/lockf -s -t 0 7; then
    exec 7>&-
    _qps_fail "legacy workspace $qps_identity is already open"
    return 1
  fi
  QPS_LEGACY_LOCK_PATH=$qps_lock_path
}

_qps_release_legacy_lock() {
  if [[ -n $QPS_LEGACY_LOCK_PATH ]] && { true >&7; } 2>/dev/null; then
    exec 7>&-
  fi
  QPS_LEGACY_LOCK_PATH=''
}

_qps_write_metadata() {
  local qps_path=$1
  local qps_identity=$2
  local qps_source_sha=$3
  local qps_source_bytes=$4

  (umask 077; set -o noclobber; printf \
    '{"bundleIdentity":"%s","kind":"%s","schemaVersion":%s,"sourceRootfs":{"bytes":%s,"sha256":"%s"}}\n' \
    "$qps_identity" \
    "$QEMU_PERSISTENT_STORAGE_KIND" \
    "$QEMU_PERSISTENT_STORAGE_SCHEMA" \
    "$qps_source_bytes" \
    "$qps_source_sha" >"$qps_path") 2>/dev/null
}

_qps_validate_metadata() {
  local qps_path=$1
  local qps_identity=$2
  local qps_source_sha=$3
  local qps_source_bytes=$4
  local qps_schema=${5:-$QEMU_PERSISTENT_STORAGE_SCHEMA}

  local qps_expected=''
  _qps_assert_private_regular_file "$qps_path" 'persistent-disk metadata' || return 1
  [[ $(_qps_size "$qps_path") -le 16384 ]] || return 1
  printf -v qps_expected \
    '{"bundleIdentity":"%s","kind":"%s","schemaVersion":%s,"sourceRootfs":{"bytes":%s,"sha256":"%s"}}' \
    "$qps_identity" \
    "$QEMU_PERSISTENT_STORAGE_KIND" \
    "$qps_schema" \
    "$qps_source_bytes" \
    "$qps_source_sha"
  [[ $(<"$qps_path") == "$qps_expected" ]] || {
    _qps_fail 'metadata does not match the selected guest bundle'
    return 1
  }
}

_qps_read_metadata_fields() {
  local qps_path=$1
  local qps_content=''
  local qps_pattern='^\{"bundleIdentity":"([0-9a-f]{64})","kind":"omarchy-qemu-persistent-disk","schemaVersion":([12]),"sourceRootfs":\{"bytes":([1-9][0-9]*),"sha256":"([0-9a-f]{64})"\}\}$'

  _qps_assert_private_regular_file "$qps_path" 'persistent-disk metadata' || return 1
  [[ $(_qps_size "$qps_path") -le 16384 ]] || {
    _qps_fail 'persistent-disk metadata is too large'
    return 1
  }
  qps_content=$(<"$qps_path")
  [[ $qps_content =~ $qps_pattern ]] || {
    _qps_fail 'persistent-disk metadata has an unknown format'
    return 1
  }
  QPS_METADATA_IDENTITY=${BASH_REMATCH[1]}
  QPS_METADATA_SCHEMA=${BASH_REMATCH[2]}
  QPS_METADATA_SOURCE_BYTES=${BASH_REMATCH[3]}
  QPS_METADATA_SOURCE_SHA=${BASH_REMATCH[4]}
}

_qps_has_only_store_contents() (
  local qps_directory=$1
  local qps_allow_missing_disk=$2

  local qps_entry=''
  local qps_has_metadata=0
  local qps_has_disk=0
  local qps_count=0

  shopt -s nullglob dotglob
  for qps_entry in "$qps_directory"/*; do
    ((qps_count += 1))
    case ${qps_entry##*/} in
      metadata.json) qps_has_metadata=1 ;;
      rootfs.ext4) qps_has_disk=1 ;;
      *) return 1 ;;
    esac
  done
  shopt -u nullglob dotglob
  ((qps_has_metadata == 1)) || return 1
  if [[ $qps_allow_missing_disk == 1 ]]; then
    ((qps_count == 1 || (qps_count == 2 && qps_has_disk == 1)))
  else
    ((qps_count == 2 && qps_has_disk == 1))
  fi
)

_qps_validate_store_directory() {
  local qps_directory=$1
  local qps_identity=$2
  local qps_source_sha=$3
  local qps_source_bytes=$4
  local qps_working_bytes=$5
  local qps_allow_missing_disk=${6:-0}
  local qps_schema=${7:-$QEMU_PERSISTENT_STORAGE_SCHEMA}
  local qps_disk="$qps_directory/rootfs.ext4"

  _qps_assert_private_directory "$qps_directory" 'persistent-disk directory' || return 1
  _qps_has_only_store_contents "$qps_directory" "$qps_allow_missing_disk" || {
    _qps_fail "persistent-disk directory contains unexpected files: $qps_directory"
    return 1
  }
  _qps_validate_metadata \
    "$qps_directory/metadata.json" \
    "$qps_identity" \
    "$qps_source_sha" \
    "$qps_source_bytes" \
    "$qps_schema" || return 1

  if [[ -e $qps_disk || -L $qps_disk ]]; then
    _qps_assert_private_regular_file "$qps_disk" 'persistent root disk' || return 1
    [[ $(_qps_size "$qps_disk") == "$qps_working_bytes" ]] || {
      _qps_fail "persistent root disk has the wrong size: $qps_disk"
      return 1
    }
  elif [[ $qps_allow_missing_disk != 1 ]]; then
    _qps_fail "persistent root disk is missing: $qps_disk"
    return 1
  fi
}

_qps_fsync() {
  /bin/sync
}

_qps_clone_disk() {
  local qps_source=$1
  local qps_destination=$2
  local qps_expected_bytes=$3

  if /bin/cp -c "$qps_source" "$qps_destination" 2>/dev/null; then
    _qps_error "APFS-cloned the immutable root disk"
  else
    [[ ! -e $qps_destination && ! -L $qps_destination ]] || /bin/rm -f "$qps_destination"
    _qps_error "APFS clone unavailable; copying the immutable root disk"
    /bin/cp "$qps_source" "$qps_destination" || {
      _qps_fail "cannot copy the immutable root disk"
      return 1
    }
  fi
  chmod 600 "$qps_destination" || return 1
  _qps_assert_private_regular_file "$qps_destination" 'working root disk' || return 1
  [[ $(_qps_size "$qps_destination") == "$qps_expected_bytes" ]] || {
    _qps_fail "working root disk has the wrong size"
    return 1
  }
  [[ $(_qps_file_identity "$qps_destination") != $(_qps_file_identity "$qps_source") ]] || {
    _qps_fail "working root disk did not receive a distinct inode"
    return 1
  }
  _qps_fsync "$qps_destination" || {
    _qps_fail "cannot flush the initialized root disk"
    return 1
  }
}

_qps_assert_boot_source_file() {
  local qps_path=$1
  local qps_label=$2
  local qps_bytes=''

  [[ -f $qps_path && ! -L $qps_path ]] || {
    _qps_fail "$qps_label is missing or unsafe: $qps_path"
    return 1
  }
  [[ $(_qps_lstat_kind "$qps_path") == 'Regular File' ]] || {
    _qps_fail "$qps_label is not a regular file: $qps_path"
    return 1
  }
  qps_bytes=$(_qps_size "$qps_path")
  _qps_is_positive_integer "$qps_bytes" || {
    _qps_fail "$qps_label is empty or has an invalid size: $qps_path"
    return 1
  }
}

_qps_copy_private_file() {
  local qps_source=$1
  local qps_destination=$2
  local qps_label=$3
  local qps_expected_bytes=$4
  local qps_expected_sha=$5

  [[ ! -e $qps_destination && ! -L $qps_destination ]] || {
    _qps_fail "$qps_label destination already exists: $qps_destination"
    return 1
  }
  if /bin/cp -c "$qps_source" "$qps_destination" 2>/dev/null; then
    :
  else
    [[ ! -e $qps_destination && ! -L $qps_destination ]] || /bin/rm -f "$qps_destination"
    /bin/cp "$qps_source" "$qps_destination" || {
      _qps_fail "cannot copy $qps_label"
      return 1
    }
  fi
  chmod 600 "$qps_destination" || return 1
  _qps_assert_private_regular_file "$qps_destination" "$qps_label" || return 1
  [[ $(_qps_size "$qps_destination") == "$qps_expected_bytes" ]] || {
    _qps_fail "$qps_label copy has the wrong size"
    return 1
  }
  [[ $(_qps_sha256 "$qps_destination") == "$qps_expected_sha" ]] || {
    _qps_fail "$qps_label copy has the wrong digest"
    return 1
  }
  [[ $(_qps_file_identity "$qps_destination") != $(_qps_file_identity "$qps_source") ]] || {
    _qps_fail "$qps_label copy aliases its source inode"
    return 1
  }
}

_qps_write_boot_metadata() {
  local qps_path=$1
  local qps_identity=$2
  local qps_kernel_bytes=$3
  local qps_kernel_sha=$4
  local qps_initramfs_bytes=$5
  local qps_initramfs_sha=$6

  (umask 077; set -o noclobber; printf \
    '{"bundleIdentity":"%s","initramfs":{"bytes":%s,"sha256":"%s"},"kernel":{"bytes":%s,"sha256":"%s"},"kind":"%s","schemaVersion":1}\n' \
    "$qps_identity" \
    "$qps_initramfs_bytes" \
    "$qps_initramfs_sha" \
    "$qps_kernel_bytes" \
    "$qps_kernel_sha" \
    "$QEMU_PERSISTENT_STORAGE_BOOT_KIT_KIND" >"$qps_path") 2>/dev/null
}

_qps_read_boot_metadata() {
  local qps_path=$1
  local qps_content=''
  local qps_pattern='^\{"bundleIdentity":"([0-9a-f]{64})","initramfs":\{"bytes":([1-9][0-9]*),"sha256":"([0-9a-f]{64})"\},"kernel":\{"bytes":([1-9][0-9]*),"sha256":"([0-9a-f]{64})"\},"kind":"omarchy-qemu-boot-kit","schemaVersion":1\}$'

  _qps_assert_private_regular_file "$qps_path" 'boot-kit metadata' || return 1
  [[ $(_qps_size "$qps_path") -le 16384 ]] || {
    _qps_fail 'boot-kit metadata is too large'
    return 1
  }
  qps_content=$(<"$qps_path")
  [[ $qps_content =~ $qps_pattern ]] || {
    _qps_fail 'boot-kit metadata has an unknown format'
    return 1
  }
  QPS_BOOT_IDENTITY=${BASH_REMATCH[1]}
  QPS_BOOT_INITRAMFS_BYTES=${BASH_REMATCH[2]}
  QPS_BOOT_INITRAMFS_SHA=${BASH_REMATCH[3]}
  QPS_BOOT_KERNEL_BYTES=${BASH_REMATCH[4]}
  QPS_BOOT_KERNEL_SHA=${BASH_REMATCH[5]}
}

_qps_has_only_boot_contents() (
  local qps_directory=$1
  local qps_entry=''
  local qps_has_initramfs=0
  local qps_has_kernel=0
  local qps_has_metadata=0
  local qps_count=0

  shopt -s nullglob dotglob
  for qps_entry in "$qps_directory"/*; do
    ((qps_count += 1))
    case ${qps_entry##*/} in
      initramfs) qps_has_initramfs=1 ;;
      kernel) qps_has_kernel=1 ;;
      metadata.json) qps_has_metadata=1 ;;
      *) return 1 ;;
    esac
  done
  shopt -u nullglob dotglob
  (( qps_count == 3 && qps_has_initramfs == 1 && \
     qps_has_kernel == 1 && qps_has_metadata == 1 ))
)

_qps_validate_boot_kit_directory() {
  local qps_directory=$1
  local qps_expected_identity=${2:-}

  _qps_assert_private_directory "$qps_directory" 'boot-kit directory' || return 1
  _qps_has_only_boot_contents "$qps_directory" || {
    _qps_fail "boot-kit directory contains unexpected files: $qps_directory"
    return 1
  }
  _qps_read_boot_metadata "$qps_directory/metadata.json" || return 1
  [[ -z $qps_expected_identity || $QPS_BOOT_IDENTITY == "$qps_expected_identity" ]] || {
    _qps_fail 'boot-kit identity does not match the selected generation'
    return 1
  }
  case ${qps_directory##*/} in
    "$QPS_BOOT_IDENTITY"|."$QPS_BOOT_IDENTITY".initializing.??????) ;;
    *)
      _qps_fail 'boot-kit directory name does not match its metadata'
      return 1
      ;;
  esac
  _qps_assert_private_regular_file "$qps_directory/kernel" 'boot-kit kernel' || return 1
  _qps_assert_private_regular_file "$qps_directory/initramfs" 'boot-kit initramfs' || return 1
  [[ $(_qps_size "$qps_directory/kernel") == "$QPS_BOOT_KERNEL_BYTES" && \
     $(_qps_sha256 "$qps_directory/kernel") == "$QPS_BOOT_KERNEL_SHA" ]] || {
    _qps_fail 'boot-kit kernel does not match its metadata'
    return 1
  }
  [[ $(_qps_size "$qps_directory/initramfs") == "$QPS_BOOT_INITRAMFS_BYTES" && \
     $(_qps_sha256 "$qps_directory/initramfs") == "$QPS_BOOT_INITRAMFS_SHA" ]] || {
    _qps_fail 'boot-kit initramfs does not match its metadata'
    return 1
  }
}

_qps_validate_interrupted_boot_staging() (
  local qps_staging=$1
  local qps_identity=$2
  local qps_kernel_bytes=$3
  local qps_kernel_sha=$4
  local qps_initramfs_bytes=$5
  local qps_initramfs_sha=$6
  local qps_entry=''
  local qps_has_kernel=0
  local qps_has_initramfs=0
  local qps_has_metadata=0
  local qps_count=0

  case "$qps_staging" in
    "$QEMU_PERSISTENT_STORAGE_BOOT_ROOT/.${qps_identity}.initializing."??????) ;;
    *) return 1 ;;
  esac
  _qps_assert_private_directory "$qps_staging" 'interrupted boot-kit staging directory' || return 1
  shopt -s nullglob dotglob
  for qps_entry in "$qps_staging"/*; do
    ((qps_count += 1))
    case ${qps_entry##*/} in
      kernel) qps_has_kernel=1 ;;
      initramfs) qps_has_initramfs=1 ;;
      metadata.json) qps_has_metadata=1 ;;
      *) return 1 ;;
    esac
  done
  shopt -u nullglob dotglob

  # Copy order is kernel, initramfs, then metadata. Empty directories and
  # impossible orderings are tiny but not sufficiently attributable to us.
  (( qps_has_kernel == 1 && qps_count >= 1 && qps_count <= 3 )) || return 1
  (( qps_has_metadata == 0 || qps_has_initramfs == 1 )) || return 1
  _qps_assert_private_regular_file "$qps_staging/kernel" 'interrupted boot-kit kernel' || return 1
  [[ $(_qps_size "$qps_staging/kernel") == "$qps_kernel_bytes" && \
     $(_qps_sha256 "$qps_staging/kernel") == "$qps_kernel_sha" ]] || return 1
  if (( qps_has_initramfs == 1 )); then
    _qps_assert_private_regular_file \
      "$qps_staging/initramfs" 'interrupted boot-kit initramfs' || return 1
    [[ $(_qps_size "$qps_staging/initramfs") == "$qps_initramfs_bytes" && \
       $(_qps_sha256 "$qps_staging/initramfs") == "$qps_initramfs_sha" ]] || return 1
  fi
  if (( qps_has_metadata == 1 )); then
    _qps_validate_boot_kit_directory "$qps_staging" "$qps_identity" || return 1
    [[ $QPS_BOOT_KERNEL_BYTES == "$qps_kernel_bytes" && \
       $QPS_BOOT_KERNEL_SHA == "$qps_kernel_sha" && \
       $QPS_BOOT_INITRAMFS_BYTES == "$qps_initramfs_bytes" && \
       $QPS_BOOT_INITRAMFS_SHA == "$qps_initramfs_sha" ]] || return 1
  fi
)

_qps_reap_interrupted_boot_staging() {
  local qps_identity=$1
  local qps_kernel_bytes=$2
  local qps_kernel_sha=$3
  local qps_initramfs_bytes=$4
  local qps_initramfs_sha=$5
  local qps_staging=''

  for qps_staging in \
    "$QEMU_PERSISTENT_STORAGE_BOOT_ROOT"/."$qps_identity".initializing.??????; do
    [[ -e $qps_staging || -L $qps_staging ]] || continue
    if _qps_validate_interrupted_boot_staging \
      "$qps_staging" "$qps_identity" \
      "$qps_kernel_bytes" "$qps_kernel_sha" \
      "$qps_initramfs_bytes" "$qps_initramfs_sha"; then
      if /bin/rm -rf "$qps_staging"; then
        _qps_fsync "$QEMU_PERSISTENT_STORAGE_BOOT_ROOT" || true
        _qps_error "removed recognized interrupted boot-kit staging ${qps_staging##*/}"
      else
        _qps_error "could not remove recognized interrupted boot-kit staging: $qps_staging"
      fi
    else
      _qps_error "left unrecognized interrupted boot-kit staging untouched: $qps_staging"
    fi
  done
  return 0
}

_qps_stage_boot_kit_locked() {
  local qps_identity=$1
  local qps_kernel=$2
  local qps_initramfs=$3
  local qps_final="$QEMU_PERSISTENT_STORAGE_BOOT_ROOT/$qps_identity"
  local qps_staging=''
  local qps_kernel_bytes=''
  local qps_kernel_sha=''
  local qps_initramfs_bytes=''
  local qps_initramfs_sha=''

  _qps_is_identity "$qps_identity" || {
    _qps_fail 'boot-kit identity must be exactly 64 lowercase hexadecimal characters'
    return 1
  }
  _qps_assert_boot_source_file "$qps_kernel" 'source boot-kit kernel' || return 1
  _qps_assert_boot_source_file "$qps_initramfs" 'source boot-kit initramfs' || return 1
  qps_kernel_bytes=$(_qps_size "$qps_kernel")
  qps_kernel_sha=$(_qps_sha256 "$qps_kernel")
  qps_initramfs_bytes=$(_qps_size "$qps_initramfs")
  qps_initramfs_sha=$(_qps_sha256 "$qps_initramfs")
  _qps_is_identity "$qps_kernel_sha" || return 1
  _qps_is_identity "$qps_initramfs_sha" || return 1
  _qps_reap_interrupted_boot_staging \
    "$qps_identity" "$qps_kernel_bytes" "$qps_kernel_sha" \
    "$qps_initramfs_bytes" "$qps_initramfs_sha" || true

  if [[ -e $qps_final || -L $qps_final ]]; then
    _qps_validate_boot_kit_directory "$qps_final" "$qps_identity" || return 1
    [[ $QPS_BOOT_KERNEL_BYTES == "$qps_kernel_bytes" && \
       $QPS_BOOT_KERNEL_SHA == "$qps_kernel_sha" && \
       $QPS_BOOT_INITRAMFS_BYTES == "$qps_initramfs_bytes" && \
       $QPS_BOOT_INITRAMFS_SHA == "$qps_initramfs_sha" ]] || {
      _qps_fail 'a different boot kit is already paired with this generation'
      return 1
    }
    return 0
  fi

  qps_staging=$(mktemp -d "$QEMU_PERSISTENT_STORAGE_BOOT_ROOT/.${qps_identity}.initializing.XXXXXX") || {
    _qps_fail 'cannot create boot-kit staging directory'
    return 1
  }
  chmod 700 "$qps_staging" || return 1
  if ! _qps_copy_private_file \
    "$qps_kernel" "$qps_staging/kernel" 'staged boot-kit kernel' \
    "$qps_kernel_bytes" "$qps_kernel_sha" || \
    ! _qps_copy_private_file \
    "$qps_initramfs" "$qps_staging/initramfs" 'staged boot-kit initramfs' \
    "$qps_initramfs_bytes" "$qps_initramfs_sha" || \
    ! _qps_write_boot_metadata \
    "$qps_staging/metadata.json" "$qps_identity" \
    "$qps_kernel_bytes" "$qps_kernel_sha" \
    "$qps_initramfs_bytes" "$qps_initramfs_sha" || \
    ! _qps_validate_boot_kit_directory "$qps_staging" "$qps_identity"; then
    case "$qps_staging" in
      "$QEMU_PERSISTENT_STORAGE_BOOT_ROOT/.${qps_identity}.initializing."??????)
        /bin/rm -rf "$qps_staging"
        ;;
    esac
    return 1
  fi
  _qps_fsync "$qps_staging" || return 1
  [[ ! -e $qps_final && ! -L $qps_final ]] || return 1
  /bin/mv "$qps_staging" "$qps_final" || return 1
  _qps_fsync "$QEMU_PERSISTENT_STORAGE_BOOT_ROOT" || return 1
  _qps_error "staged boot kit ${qps_identity:0:12}"
}

qemu_persistent_storage_stage_boot_kit() {
  local qps_identity=${1:-}
  local qps_kernel=${2:-}
  local qps_initramfs=${3:-}
  local qps_status=0

  _qps_prepare_state_root || return 1
  _qps_acquire_lock current || return 1
  if _qps_stage_boot_kit_locked "$qps_identity" "$qps_kernel" "$qps_initramfs"; then
    :
  else
    qps_status=$?
  fi
  qemu_persistent_storage_release_lock
  return "$qps_status"
}

_qps_set_active_boot_globals() {
  local qps_identity=$1
  local qps_directory="$QEMU_PERSISTENT_STORAGE_BOOT_ROOT/$qps_identity"

  QEMU_PERSISTENT_STORAGE_ACTIVE_BOOT_DIRECTORY=''
  QEMU_PERSISTENT_STORAGE_ACTIVE_KERNEL=''
  QEMU_PERSISTENT_STORAGE_ACTIVE_INITRAMFS=''
  [[ -e $qps_directory || -L $qps_directory ]] || return 0
  _qps_validate_boot_kit_directory "$qps_directory" "$qps_identity" || return 1
  QEMU_PERSISTENT_STORAGE_ACTIVE_BOOT_DIRECTORY=$qps_directory
  QEMU_PERSISTENT_STORAGE_ACTIVE_KERNEL="$qps_directory/kernel"
  QEMU_PERSISTENT_STORAGE_ACTIVE_INITRAMFS="$qps_directory/initramfs"
}

_qps_set_candidate_boot_globals() {
  local qps_identity=$1
  local qps_directory="$QEMU_PERSISTENT_STORAGE_BOOT_ROOT/$qps_identity"

  _qps_validate_boot_kit_directory "$qps_directory" "$qps_identity" || return 1
  QEMU_PERSISTENT_STORAGE_CANDIDATE_BOOT_DIRECTORY=$qps_directory
  QEMU_PERSISTENT_STORAGE_CANDIDATE_KERNEL="$qps_directory/kernel"
  QEMU_PERSISTENT_STORAGE_CANDIDATE_INITRAMFS="$qps_directory/initramfs"
}

_qps_expand_disk() {
  local qps_disk=$1
  local qps_source_bytes=$2
  local qps_working_bytes=$3

  [[ $qps_working_bytes == "$qps_source_bytes" ]] && return 0
  [[ $qps_working_bytes -gt $qps_source_bytes ]] || {
    _qps_fail 'working root disk cannot be smaller than its immutable source'
    return 1
  }
  /usr/bin/truncate -s "$qps_working_bytes" "$qps_disk" || {
    _qps_fail 'cannot sparsely expand the working root disk'
    return 1
  }
  [[ $(_qps_size "$qps_disk") == "$qps_working_bytes" ]] || {
    _qps_fail 'expanded working root disk has the wrong size'
    return 1
  }
  _qps_error "expanded the sparse working disk to $((qps_working_bytes / 1024 / 1024)) MiB"
}

_qps_validate_immutable_source() {
  local qps_source=$1
  local qps_expected_bytes=$2
  local qps_magic=''

  _qps_assert_private_regular_file "$qps_source" 'materialized immutable root disk' || return 1
  [[ $(_qps_size "$qps_source") == "$qps_expected_bytes" ]] || {
    _qps_fail 'materialized immutable root disk has the wrong size'
    return 1
  }
  qps_magic=$(/usr/bin/od -An -tx1 -j 1080 -N 2 "$qps_source" | tr -d '[:space:]') || {
    _qps_fail 'cannot inspect the materialized ext4 superblock'
    return 1
  }
  [[ $qps_magic == 53ef ]] || {
    _qps_fail 'materialized immutable root disk has no ext4 superblock'
    return 1
  }
}

# Expand a signed, manifest-verified Zstandard artifact into an identity-keyed
# immutable APFS source exactly once. The persistent workspace is then cloned
# from this source, so the 6 GiB base blocks are not physically duplicated.
qemu_persistent_storage_materialize_source() {
  local qps_identity=${1:-}
  local qps_compressed=${2:-}
  local qps_compressed_bytes=${3:-}
  local qps_source_sha=${4:-}
  local qps_source_bytes=${5:-}
  local qps_zstd=${6:-}
  local qps_final=''
  local qps_staging=''
  local qps_actual_sha=''
  local qps_lock_path=''

  QEMU_IMMUTABLE_SOURCE_DISK=''
  _qps_is_identity "$qps_identity" || {
    _qps_fail 'bundle identity must be exactly 64 lowercase hexadecimal characters'
    return 1
  }
  _qps_is_identity "$qps_source_sha" || {
    _qps_fail 'source rootfs digest must be exactly 64 lowercase hexadecimal characters'
    return 1
  }
  _qps_is_positive_integer "$qps_compressed_bytes" || return 1
  _qps_is_positive_integer "$qps_source_bytes" || return 1
  [[ -f $qps_compressed && ! -L $qps_compressed ]] || {
    _qps_fail 'compressed root disk is missing or unsafe'
    return 1
  }
  [[ $(_qps_size "$qps_compressed") == "$qps_compressed_bytes" ]] || {
    _qps_fail 'compressed root disk has the wrong size'
    return 1
  }
  [[ -f $qps_zstd && ! -L $qps_zstd && -x $qps_zstd ]] || {
    _qps_fail 'bundled Zstandard decoder is missing or unsafe'
    return 1
  }

  _qps_prepare_state_root || return 1
  qps_final="$QEMU_PERSISTENT_STORAGE_IMAGES_ROOT/$qps_identity.ext4"
  qps_lock_path="$QEMU_PERSISTENT_STORAGE_LOCKS_ROOT/$qps_identity.image.lock"
  exec 8>>"$qps_lock_path" || return 1
  chmod 600 "$qps_lock_path" || { exec 8>&-; return 1; }
  _qps_assert_private_regular_file "$qps_lock_path" 'base-image lock' || {
    exec 8>&-
    return 1
  }
  if ! /usr/bin/lockf -s 8; then
    exec 8>&-
    _qps_fail 'cannot lock base-image materialization'
    return 1
  fi

  for qps_staging in \
    "$QEMU_PERSISTENT_STORAGE_IMAGES_ROOT"/."$qps_identity".initializing.??????; do
    [[ -f $qps_staging && ! -L $qps_staging ]] || continue
    [[ $(_qps_owner "$qps_staging") == $(id -u) ]] || continue
    case "$qps_staging" in
      "$QEMU_PERSISTENT_STORAGE_IMAGES_ROOT/.${qps_identity}.initializing."??????)
        /bin/rm -f -- "$qps_staging" || {
          exec 8>&-
          _qps_fail 'cannot reclaim an interrupted base-image expansion'
          return 1
        }
        ;;
    esac
  done

  if [[ -e $qps_final || -L $qps_final ]]; then
    if ! _qps_validate_immutable_source "$qps_final" "$qps_source_bytes"; then
      exec 8>&-
      return 1
    fi
    QEMU_IMMUTABLE_SOURCE_DISK=$qps_final
    exec 8>&-
    return 0
  fi

  qps_staging=$(mktemp "$QEMU_PERSISTENT_STORAGE_IMAGES_ROOT/.${qps_identity}.initializing.XXXXXX") || {
    exec 8>&-
    return 1
  }
  chmod 600 "$qps_staging" || return 1
  if ! "$qps_zstd" -d -f "$qps_compressed" -o "$qps_staging" >&2; then
    /bin/rm -f -- "$qps_staging"
    exec 8>&-
    _qps_fail 'cannot expand the bundled root disk'
    return 1
  fi
  chmod 600 "$qps_staging" || {
    /bin/rm -f -- "$qps_staging"
    exec 8>&-
    return 1
  }
  if ! _qps_validate_immutable_source "$qps_staging" "$qps_source_bytes"; then
    /bin/rm -f -- "$qps_staging"
    exec 8>&-
    return 1
  fi
  qps_actual_sha=$(/usr/bin/shasum -a 256 "$qps_staging" | awk '{ print $1 }') || {
    /bin/rm -f -- "$qps_staging"
    exec 8>&-
    return 1
  }
  if [[ $qps_actual_sha != "$qps_source_sha" ]]; then
    /bin/rm -f -- "$qps_staging"
    exec 8>&-
    _qps_fail 'expanded root disk does not match its signed manifest digest'
    return 1
  fi
  _qps_fsync "$qps_staging" || return 1
  /bin/mv "$qps_staging" "$qps_final" || return 1
  _qps_fsync "$QEMU_PERSISTENT_STORAGE_IMAGES_ROOT" || return 1
  QEMU_IMMUTABLE_SOURCE_DISK=$qps_final
  exec 8>&-
  _qps_error "materialized immutable base image ${qps_identity:0:12}"
}

# Expand a signed update payload into a cache that is deliberately distinct
# from the same generation's factory rootfs. The result is suitable for a
# read-only secondary QEMU drive and is never used as disks/current directly.
qemu_persistent_storage_materialize_update_image() {
  local qps_identity=${1:-}
  local qps_compressed=${2:-}
  local qps_compressed_bytes=${3:-}
  local qps_raw_sha=${4:-}
  local qps_raw_bytes=${5:-}
  local qps_zstd=${6:-}
  local qps_final=''
  local qps_staging=''
  local qps_actual_sha=''
  local qps_lock_path=''

  QEMU_PERSISTENT_STORAGE_UPDATE_IMAGE=''
  _qps_is_identity "$qps_identity" || {
    _qps_fail 'update-image identity must be exactly 64 lowercase hexadecimal characters'
    return 1
  }
  _qps_is_identity "$qps_raw_sha" || {
    _qps_fail 'update-image digest must be exactly 64 lowercase hexadecimal characters'
    return 1
  }
  _qps_is_positive_integer "$qps_compressed_bytes" || {
    _qps_fail 'compressed update-image size must be a positive integer'
    return 1
  }
  _qps_is_positive_integer "$qps_raw_bytes" || {
    _qps_fail 'expanded update-image size must be a positive integer'
    return 1
  }
  [[ -f $qps_compressed && ! -L $qps_compressed ]] || {
    _qps_fail 'compressed update image is missing or unsafe'
    return 1
  }
  [[ $(_qps_lstat_kind "$qps_compressed") == 'Regular File' && \
     $(_qps_size "$qps_compressed") == "$qps_compressed_bytes" ]] || {
    _qps_fail 'compressed update image has the wrong type or size'
    return 1
  }
  [[ -f $qps_zstd && ! -L $qps_zstd && -x $qps_zstd ]] || {
    _qps_fail 'bundled Zstandard decoder is missing or unsafe'
    return 1
  }

  _qps_prepare_state_root || return 1
  qps_final="$QEMU_PERSISTENT_STORAGE_IMAGES_ROOT/$qps_identity.update.ext4"
  qps_lock_path="$QEMU_PERSISTENT_STORAGE_LOCKS_ROOT/$qps_identity.update-image.lock"
  exec 8>>"$qps_lock_path" || return 1
  chmod 600 "$qps_lock_path" || { exec 8>&-; return 1; }
  _qps_assert_private_regular_file "$qps_lock_path" 'update-image lock' || {
    exec 8>&-
    return 1
  }
  if ! /usr/bin/lockf -s 8; then
    exec 8>&-
    _qps_fail 'cannot lock update-image materialization'
    return 1
  fi

  for qps_staging in \
    "$QEMU_PERSISTENT_STORAGE_IMAGES_ROOT"/."$qps_identity".update.initializing.??????; do
    [[ -f $qps_staging && ! -L $qps_staging ]] || continue
    [[ $(_qps_owner "$qps_staging") == $(id -u) ]] || continue
    case "$qps_staging" in
      "$QEMU_PERSISTENT_STORAGE_IMAGES_ROOT/.${qps_identity}.update.initializing."??????)
        /bin/rm -f -- "$qps_staging" || {
          exec 8>&-
          _qps_fail 'cannot reclaim an interrupted update-image expansion'
          return 1
        }
        ;;
    esac
  done

  if [[ -e $qps_final || -L $qps_final ]]; then
    if ! _qps_validate_immutable_source "$qps_final" "$qps_raw_bytes"; then
      exec 8>&-
      return 1
    fi
    qps_actual_sha=$(_qps_sha256 "$qps_final") || {
      exec 8>&-
      return 1
    }
    if [[ $qps_actual_sha != "$qps_raw_sha" ]]; then
      exec 8>&-
      _qps_fail 'cached update image does not match its signed digest'
      return 1
    fi
    QEMU_PERSISTENT_STORAGE_UPDATE_IMAGE=$qps_final
    exec 8>&-
    return 0
  fi

  qps_staging=$(mktemp \
    "$QEMU_PERSISTENT_STORAGE_IMAGES_ROOT/.${qps_identity}.update.initializing.XXXXXX") || {
    exec 8>&-
    return 1
  }
  chmod 600 "$qps_staging" || { exec 8>&-; return 1; }
  if ! "$qps_zstd" -d -f "$qps_compressed" -o "$qps_staging" >&2; then
    /bin/rm -f -- "$qps_staging"
    exec 8>&-
    _qps_fail 'cannot expand the bundled update image'
    return 1
  fi
  chmod 600 "$qps_staging" || {
    /bin/rm -f -- "$qps_staging"
    exec 8>&-
    return 1
  }
  if ! _qps_validate_immutable_source "$qps_staging" "$qps_raw_bytes"; then
    /bin/rm -f -- "$qps_staging"
    exec 8>&-
    return 1
  fi
  qps_actual_sha=$(_qps_sha256 "$qps_staging") || {
    /bin/rm -f -- "$qps_staging"
    exec 8>&-
    return 1
  }
  if [[ $qps_actual_sha != "$qps_raw_sha" ]]; then
    /bin/rm -f -- "$qps_staging"
    exec 8>&-
    _qps_fail 'expanded update image does not match its signed digest'
    return 1
  fi
  _qps_fsync "$qps_staging" || { exec 8>&-; return 1; }
  /bin/mv "$qps_staging" "$qps_final" || { exec 8>&-; return 1; }
  _qps_fsync "$QEMU_PERSISTENT_STORAGE_IMAGES_ROOT" || { exec 8>&-; return 1; }
  QEMU_PERSISTENT_STORAGE_UPDATE_IMAGE=$qps_final
  exec 8>&-
  _qps_error "materialized immutable update image ${qps_identity:0:12}"
}

_qps_remove_recognized_directory() {
  local qps_directory=$1
  local qps_identity=$2
  local qps_source_sha=$3
  local qps_source_bytes=$4
  local qps_working_bytes=$5
  local qps_allow_missing_disk=${6:-0}
  local qps_schema=${7:-$QEMU_PERSISTENT_STORAGE_SCHEMA}

  case "$qps_directory" in
    "$QEMU_PERSISTENT_STORAGE_DISKS_ROOT/$qps_identity"|\
    "$QEMU_PERSISTENT_STORAGE_DISKS_ROOT/current"|\
    "$QEMU_PERSISTENT_STORAGE_DISKS_ROOT/.${qps_identity}.initializing."??????|\
    "$QEMU_PERSISTENT_STORAGE_DISKS_ROOT/.${qps_identity}.discarded."*|\
    "$QEMU_PERSISTENT_STORAGE_DISKS_ROOT/.current.initializing."??????|\
    "$QEMU_PERSISTENT_STORAGE_DISKS_ROOT/.current.discarded."*) ;;
    *)
      _qps_fail "refusing to remove a path outside the identity-scoped storage contract: $qps_directory"
      return 1
      ;;
  esac

  _qps_validate_store_directory \
    "$qps_directory" \
    "$qps_identity" \
    "$qps_source_sha" \
    "$qps_source_bytes" \
    "$qps_working_bytes" \
    "$qps_allow_missing_disk" \
    "$qps_schema" || return 1
  /bin/rm -rf "$qps_directory" || {
    _qps_fail "cannot remove recognized persistent-disk directory: $qps_directory"
    return 1
  }
}

_qps_remove_recorded_directory() {
  local qps_directory=$1
  local qps_allow_missing_disk=${2:-0}
  local qps_existing_bytes=''
  local qps_existing_identity=''
  local qps_existing_schema=''
  local qps_existing_source_sha=''
  local qps_existing_source_bytes=''

  _qps_read_metadata_fields "$qps_directory/metadata.json" || return 1
  qps_existing_identity=$QPS_METADATA_IDENTITY
  qps_existing_schema=$QPS_METADATA_SCHEMA
  qps_existing_source_sha=$QPS_METADATA_SOURCE_SHA
  qps_existing_source_bytes=$QPS_METADATA_SOURCE_BYTES

  if [[ -e $qps_directory/rootfs.ext4 || -L $qps_directory/rootfs.ext4 ]]; then
    qps_existing_bytes=$(_qps_size "$qps_directory/rootfs.ext4")
    _qps_is_positive_integer "$qps_existing_bytes" || return 1
    (( qps_existing_bytes >= qps_existing_source_bytes )) || return 1
  else
    [[ $qps_allow_missing_disk == 1 ]] || return 1
    qps_existing_bytes=$qps_existing_source_bytes
  fi

  _qps_remove_recognized_directory \
    "$qps_directory" "$qps_existing_identity" "$qps_existing_source_sha" \
    "$qps_existing_source_bytes" "$qps_existing_bytes" \
    "$qps_allow_missing_disk" "$qps_existing_schema"
}

_qps_reap_interrupted_work() {
  local qps_storage_key=$1
  local qps_candidate=''
  local qps_name=''

  for qps_candidate in \
    "$QEMU_PERSISTENT_STORAGE_DISKS_ROOT"/."$qps_storage_key".initializing.?????? \
    "$QEMU_PERSISTENT_STORAGE_DISKS_ROOT"/."$qps_storage_key".discarded.*; do
    [[ -d $qps_candidate && ! -L $qps_candidate ]] || continue
    qps_name=${qps_candidate##*/}
    case "$qps_name" in
      ."$qps_storage_key".initializing.??????|."$qps_storage_key".discarded.*) ;;
      *) continue ;;
    esac
    if _qps_remove_recorded_directory "$qps_candidate" 1; then
      _qps_error "removed interrupted storage transaction $qps_name"
    else
      _qps_error "left unrecognized interrupted storage path untouched: $qps_candidate"
    fi
  done
}

_qps_initialize_persistent_disk() {
  local qps_identity=$1
  local qps_storage_key=$2
  local qps_source=$3
  local qps_source_sha=$4
  local qps_source_bytes=$5
  local qps_working_bytes=$6
  local qps_final="$QEMU_PERSISTENT_STORAGE_DISKS_ROOT/$qps_storage_key"
  local qps_staging=''

  qps_staging=$(mktemp -d \
    "$QEMU_PERSISTENT_STORAGE_DISKS_ROOT/.${qps_storage_key}.initializing.XXXXXX") || {
    _qps_fail 'cannot create persistent-disk staging directory'
    return 1
  }
  chmod 700 "$qps_staging" || return 1
  _qps_assert_private_directory "$qps_staging" 'persistent-disk staging directory' || return 1

  if ! _qps_write_metadata \
    "$qps_staging/metadata.json" \
    "$qps_identity" \
    "$qps_source_sha" \
    "$qps_source_bytes"; then
    _qps_fail 'cannot write persistent-disk metadata'
    return 1
  fi
  if ! _qps_clone_disk "$qps_source" "$qps_staging/rootfs.ext4" "$qps_source_bytes"; then
    _qps_remove_recognized_directory \
      "$qps_staging" "$qps_identity" "$qps_source_sha" "$qps_source_bytes" \
      "$qps_working_bytes" 1 || true
    return 1
  fi
  if ! _qps_expand_disk "$qps_staging/rootfs.ext4" "$qps_source_bytes" "$qps_working_bytes"; then
    _qps_remove_recognized_directory \
      "$qps_staging" "$qps_identity" "$qps_source_sha" "$qps_source_bytes" \
      "$qps_working_bytes" 1 || true
    return 1
  fi
  _qps_validate_store_directory \
    "$qps_staging" "$qps_identity" "$qps_source_sha" "$qps_source_bytes" \
    "$qps_working_bytes" || return 1
  _qps_fsync "$qps_staging" || {
    _qps_fail 'cannot flush persistent-disk staging directory'
    return 1
  }

  [[ ! -e $qps_final && ! -L $qps_final ]] || {
    _qps_fail "persistent-disk directory appeared during initialization: $qps_final"
    return 1
  }
  /bin/mv "$qps_staging" "$qps_final" || {
    _qps_fail 'cannot publish initialized persistent disk'
    return 1
  }
  _qps_fsync "$QEMU_PERSISTENT_STORAGE_DISKS_ROOT" || {
    _qps_fail 'cannot flush persistent-disk parent directory'
    return 1
  }
  _qps_error "initialized persistent workspace ${qps_identity:0:12}"
}

_qps_reset_persistent_disk() {
  local qps_storage_key=$1
  local qps_final="$QEMU_PERSISTENT_STORAGE_DISKS_ROOT/$qps_storage_key"
  local qps_discarded=''
  local qps_existing_bytes=''
  local qps_existing_identity=''
  local qps_existing_schema=''
  local qps_existing_source_sha=''
  local qps_existing_source_bytes=''

  [[ -e $qps_final || -L $qps_final ]] || return 0
  _qps_validate_recorded_workspace "$qps_final" || return 1
  qps_existing_bytes=$QPS_RECORDED_EXISTING_BYTES
  qps_existing_identity=$QPS_METADATA_IDENTITY
  qps_existing_schema=$QPS_METADATA_SCHEMA
  qps_existing_source_sha=$QPS_METADATA_SOURCE_SHA
  qps_existing_source_bytes=$QPS_METADATA_SOURCE_BYTES

  qps_discarded="$QEMU_PERSISTENT_STORAGE_DISKS_ROOT/.${qps_storage_key}.discarded.$$.$RANDOM$RANDOM"
  [[ ! -e $qps_discarded && ! -L $qps_discarded ]] || {
    _qps_fail 'cannot allocate reset transaction name'
    return 1
  }
  /bin/mv "$qps_final" "$qps_discarded" || {
    _qps_fail 'cannot detach persistent disk for reset'
    return 1
  }
  _qps_fsync "$QEMU_PERSISTENT_STORAGE_DISKS_ROOT" || return 1
  _qps_remove_recognized_directory \
    "$qps_discarded" "$qps_existing_identity" "$qps_existing_source_sha" \
    "$qps_existing_source_bytes" "$qps_existing_bytes" 0 \
    "$qps_existing_schema" || return 1
  _qps_error "reset persistent workspace ${qps_existing_identity:0:12}"
}

_qps_validate_recorded_workspace() {
  local qps_directory=$1
  local qps_existing_bytes=''

  QPS_RECORDED_EXISTING_BYTES=''
  _qps_read_metadata_fields "$qps_directory/metadata.json" || return 1
  qps_existing_bytes=$(_qps_size "$qps_directory/rootfs.ext4")
  _qps_is_positive_integer "$qps_existing_bytes" || {
    _qps_fail 'existing single workspace has an invalid disk size'
    return 1
  }
  (( qps_existing_bytes >= QPS_METADATA_SOURCE_BYTES )) || {
    _qps_fail 'existing single workspace is smaller than its recorded factory image'
    return 1
  }
  _qps_validate_store_directory \
    "$qps_directory" \
    "$QPS_METADATA_IDENTITY" \
    "$QPS_METADATA_SOURCE_SHA" \
    "$QPS_METADATA_SOURCE_BYTES" \
    "$qps_existing_bytes" \
    0 \
    "$QPS_METADATA_SCHEMA" || return 1
  QPS_RECORDED_EXISTING_BYTES=$qps_existing_bytes
}

_qps_require_compatible_workspace() {
  local qps_directory=$1
  local qps_identity=$2
  local qps_source_sha=$3
  local qps_source_bytes=$4
  local qps_working_bytes=$5
  local qps_existing_bytes=''

  _qps_validate_recorded_workspace "$qps_directory" || return 1
  qps_existing_bytes=$QPS_RECORDED_EXISTING_BYTES

  if [[ $QPS_METADATA_SCHEMA != "$QEMU_PERSISTENT_STORAGE_SCHEMA" || \
        $QPS_METADATA_IDENTITY != "$qps_identity" || \
        $QPS_METADATA_SOURCE_SHA != "$qps_source_sha" || \
        $QPS_METADATA_SOURCE_BYTES != "$qps_source_bytes" ]]; then
    _qps_update_required \
      'the saved VM requires a generational update before this Try Omarchy build can start'
    return $?
  fi

  (( qps_existing_bytes <= qps_working_bytes )) || {
    _qps_incompatible \
      'the existing Omarchy disk is larger than this app supports; refusing to shrink it'
    return $?
  }
  if (( qps_existing_bytes < qps_working_bytes )); then
    _qps_expand_disk "$qps_directory/rootfs.ext4" "$qps_existing_bytes" "$qps_working_bytes" || return 1
    _qps_fsync "$qps_directory/rootfs.ext4" || return 1
  fi

  return 0
}

_qps_new_health_token() {
  local qps_uuid=''
  local qps_token=''

  [[ -x /usr/bin/uuidgen ]] || {
    _qps_fail '/usr/bin/uuidgen is required for update health tokens'
    return 1
  }
  qps_uuid=$(/usr/bin/uuidgen 2>/dev/null) || return 1
  qps_token=$(printf '%s:%s:%s\n' "$qps_uuid" "$$" "$RANDOM" | /usr/bin/shasum -a 256 | awk '{ print $1 }') || return 1
  _qps_is_identity "$qps_token" || return 1
  printf '%s\n' "$qps_token"
}

_qps_clone_candidate_disk() {
  local qps_source=$1
  local qps_destination=$2
  local qps_expected_bytes=$3

  if /bin/cp -c "$qps_source" "$qps_destination" 2>/dev/null; then
    _qps_error 'APFS-cloned the active disk into an update candidate'
  else
    [[ ! -e $qps_destination && ! -L $qps_destination ]] || /bin/rm -f "$qps_destination"
    _qps_error 'APFS clone unavailable; copying the active disk into an update candidate'
    /bin/cp "$qps_source" "$qps_destination" || {
      _qps_fail 'cannot copy the active disk into an update candidate'
      return 1
    }
  fi
  chmod 600 "$qps_destination" || return 1
  _qps_assert_private_regular_file "$qps_destination" 'candidate root disk' || return 1
  [[ $(_qps_size "$qps_destination") == "$qps_expected_bytes" ]] || {
    _qps_fail 'candidate root disk has the wrong size after cloning'
    return 1
  }
  [[ $(_qps_file_identity "$qps_destination") != $(_qps_file_identity "$qps_source") ]] || {
    _qps_fail 'candidate root disk aliases the active root disk'
    return 1
  }
  _qps_fsync "$qps_destination" || return 1
}

_qps_write_update_metadata() {
  local qps_path=$1
  local qps_from_identity=$2
  local qps_from_source_bytes=$3
  local qps_from_source_sha=$4
  local qps_from_working_bytes=$5
  local qps_from_kernel_bytes=$6
  local qps_from_kernel_sha=$7
  local qps_from_initramfs_bytes=$8
  local qps_from_initramfs_sha=$9
  shift 9
  local qps_target_identity=$1
  local qps_target_source_bytes=$2
  local qps_target_source_sha=$3
  local qps_target_working_bytes=$4
  local qps_target_kernel_bytes=$5
  local qps_target_kernel_sha=$6
  local qps_target_initramfs_bytes=$7
  local qps_target_initramfs_sha=$8
  local qps_health_token=$9
  local qps_from_boot_available=true

  if [[ $qps_from_kernel_bytes == 0 && $qps_from_initramfs_bytes == 0 ]]; then
    qps_from_boot_available=false
  fi

  (umask 077; set -o noclobber; printf \
    '{"fromBootKitAvailable":%s,"fromBundleIdentity":"%s","fromInitramfsBytes":%s,"fromInitramfsSHA256":"%s","fromKernelBytes":%s,"fromKernelSHA256":"%s","fromSourceBytes":%s,"fromSourceSHA256":"%s","fromWorkingBytes":%s,"healthToken":"%s","kind":"%s","schemaVersion":1,"targetBundleIdentity":"%s","targetInitramfsBytes":%s,"targetInitramfsSHA256":"%s","targetKernelBytes":%s,"targetKernelSHA256":"%s","targetSourceBytes":%s,"targetSourceSHA256":"%s","targetWorkingBytes":%s}\n' \
    "$qps_from_boot_available" \
    "$qps_from_identity" \
    "$qps_from_initramfs_bytes" \
    "$qps_from_initramfs_sha" \
    "$qps_from_kernel_bytes" \
    "$qps_from_kernel_sha" \
    "$qps_from_source_bytes" \
    "$qps_from_source_sha" \
    "$qps_from_working_bytes" \
    "$qps_health_token" \
    "$QEMU_PERSISTENT_STORAGE_UPDATE_KIND" \
    "$qps_target_identity" \
    "$qps_target_initramfs_bytes" \
    "$qps_target_initramfs_sha" \
    "$qps_target_kernel_bytes" \
    "$qps_target_kernel_sha" \
    "$qps_target_source_bytes" \
    "$qps_target_source_sha" \
    "$qps_target_working_bytes" >"$qps_path") 2>/dev/null
}

_qps_read_update_metadata() {
  local qps_path=$1
  local qps_content=''
  local qps_pattern='^\{"fromBootKitAvailable":(true|false),"fromBundleIdentity":"([0-9a-f]{64})","fromInitramfsBytes":([0-9]+),"fromInitramfsSHA256":"([0-9a-f]{64})","fromKernelBytes":([0-9]+),"fromKernelSHA256":"([0-9a-f]{64})","fromSourceBytes":([1-9][0-9]*),"fromSourceSHA256":"([0-9a-f]{64})","fromWorkingBytes":([1-9][0-9]*),"healthToken":"([0-9a-f]{64})","kind":"omarchy-qemu-generational-update","schemaVersion":1,"targetBundleIdentity":"([0-9a-f]{64})","targetInitramfsBytes":([1-9][0-9]*),"targetInitramfsSHA256":"([0-9a-f]{64})","targetKernelBytes":([1-9][0-9]*),"targetKernelSHA256":"([0-9a-f]{64})","targetSourceBytes":([1-9][0-9]*),"targetSourceSHA256":"([0-9a-f]{64})","targetWorkingBytes":([1-9][0-9]*)\}$'

  _qps_assert_private_regular_file "$qps_path" 'update transaction metadata' || return 1
  [[ $(_qps_size "$qps_path") -le 32768 ]] || {
    _qps_fail 'update transaction metadata is too large'
    return 1
  }
  qps_content=$(<"$qps_path")
  [[ $qps_content =~ $qps_pattern ]] || {
    _qps_fail 'update transaction metadata has an unknown format'
    return 1
  }
  QPS_UPDATE_FROM_BOOT_AVAILABLE=${BASH_REMATCH[1]}
  QPS_UPDATE_FROM_IDENTITY=${BASH_REMATCH[2]}
  QPS_UPDATE_FROM_INITRAMFS_BYTES=${BASH_REMATCH[3]}
  QPS_UPDATE_FROM_INITRAMFS_SHA=${BASH_REMATCH[4]}
  QPS_UPDATE_FROM_KERNEL_BYTES=${BASH_REMATCH[5]}
  QPS_UPDATE_FROM_KERNEL_SHA=${BASH_REMATCH[6]}
  QPS_UPDATE_FROM_SOURCE_BYTES=${BASH_REMATCH[7]}
  QPS_UPDATE_FROM_SOURCE_SHA=${BASH_REMATCH[8]}
  QPS_UPDATE_FROM_WORKING_BYTES=${BASH_REMATCH[9]}
  QPS_UPDATE_HEALTH_TOKEN=${BASH_REMATCH[10]}
  QPS_UPDATE_TARGET_IDENTITY=${BASH_REMATCH[11]}
  QPS_UPDATE_TARGET_INITRAMFS_BYTES=${BASH_REMATCH[12]}
  QPS_UPDATE_TARGET_INITRAMFS_SHA=${BASH_REMATCH[13]}
  QPS_UPDATE_TARGET_KERNEL_BYTES=${BASH_REMATCH[14]}
  QPS_UPDATE_TARGET_KERNEL_SHA=${BASH_REMATCH[15]}
  QPS_UPDATE_TARGET_SOURCE_BYTES=${BASH_REMATCH[16]}
  QPS_UPDATE_TARGET_SOURCE_SHA=${BASH_REMATCH[17]}
  QPS_UPDATE_TARGET_WORKING_BYTES=${BASH_REMATCH[18]}
}

_qps_read_update_state() {
  local qps_transaction=$1
  local qps_state_file="$qps_transaction/state"
  local qps_state=''

  _qps_assert_private_regular_file "$qps_state_file" 'update transaction state' || return 1
  [[ $(_qps_size "$qps_state_file") -le 64 ]] || return 1
  qps_state=$(<"$qps_state_file")
  case "$qps_state" in
    prepared|committing|committed|rolling-back) ;;
    *)
      _qps_fail "update transaction has an unknown state: $qps_state"
      return 1
      ;;
  esac
  QPS_UPDATE_STATE=$qps_state
}

_qps_initialize_update_state() {
  local qps_transaction=$1
  local qps_state=$2

  (umask 077; set -o noclobber; printf '%s\n' "$qps_state" >"$qps_transaction/state") 2>/dev/null
}

_qps_write_update_state() {
  local qps_transaction=$1
  local qps_state=$2
  local qps_staging=''

  case "$qps_state" in
    prepared|committing|committed|rolling-back) ;;
    *) return 1 ;;
  esac
  qps_staging=$(mktemp "$qps_transaction/.state.XXXXXX") || return 1
  chmod 600 "$qps_staging" || return 1
  printf '%s\n' "$qps_state" >"$qps_staging" || return 1
  _qps_fsync "$qps_staging" || return 1
  /bin/mv -f "$qps_staging" "$qps_transaction/state" || return 1
  _qps_fsync "$qps_transaction" || return 1
}

_qps_reap_update_state_staging() {
  local qps_transaction=$1
  local qps_staging=''

  [[ $qps_transaction == "$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT/current" ]] || return 1
  _qps_assert_private_directory "$qps_transaction" 'update transaction directory' || return 1
  for qps_staging in "$qps_transaction"/.state.??????; do
    [[ -e $qps_staging || -L $qps_staging ]] || continue
    case "$qps_staging" in
      "$qps_transaction/.state."??????) ;;
      *) return 1 ;;
    esac
    if ! _qps_assert_private_regular_file "$qps_staging" 'interrupted update-state staging file'; then
      _qps_fail 'an unsafe interrupted update-state file was left untouched'
      return 1
    fi
    /bin/rm -f -- "$qps_staging" || return 1
    _qps_error 'removed an interrupted update-state staging file'
  done
}

_qps_validate_update_boot_kits() {
  local qps_from_directory="$QEMU_PERSISTENT_STORAGE_BOOT_ROOT/$QPS_UPDATE_FROM_IDENTITY"
  local qps_target_directory="$QEMU_PERSISTENT_STORAGE_BOOT_ROOT/$QPS_UPDATE_TARGET_IDENTITY"
  local qps_zero_sha='0000000000000000000000000000000000000000000000000000000000000000'

  if [[ $QPS_UPDATE_FROM_BOOT_AVAILABLE == true ]]; then
    _qps_validate_boot_kit_directory \
      "$qps_from_directory" "$QPS_UPDATE_FROM_IDENTITY" || return 1
    [[ $QPS_BOOT_KERNEL_BYTES == "$QPS_UPDATE_FROM_KERNEL_BYTES" && \
       $QPS_BOOT_KERNEL_SHA == "$QPS_UPDATE_FROM_KERNEL_SHA" && \
       $QPS_BOOT_INITRAMFS_BYTES == "$QPS_UPDATE_FROM_INITRAMFS_BYTES" && \
       $QPS_BOOT_INITRAMFS_SHA == "$QPS_UPDATE_FROM_INITRAMFS_SHA" ]] || {
      _qps_fail 'active-generation boot kit does not match the update transaction'
      return 1
    }
  else
    [[ $QPS_UPDATE_FROM_KERNEL_BYTES == 0 && \
       $QPS_UPDATE_FROM_KERNEL_SHA == "$qps_zero_sha" && \
       $QPS_UPDATE_FROM_INITRAMFS_BYTES == 0 && \
       $QPS_UPDATE_FROM_INITRAMFS_SHA == "$qps_zero_sha" ]] || {
      _qps_fail 'unpaired predecessor boot-kit metadata is not canonical'
      return 1
    }
  fi
  _qps_validate_boot_kit_directory \
    "$qps_target_directory" "$QPS_UPDATE_TARGET_IDENTITY" || return 1
  [[ $QPS_BOOT_KERNEL_BYTES == "$QPS_UPDATE_TARGET_KERNEL_BYTES" && \
     $QPS_BOOT_KERNEL_SHA == "$QPS_UPDATE_TARGET_KERNEL_SHA" && \
     $QPS_BOOT_INITRAMFS_BYTES == "$QPS_UPDATE_TARGET_INITRAMFS_BYTES" && \
     $QPS_BOOT_INITRAMFS_SHA == "$QPS_UPDATE_TARGET_INITRAMFS_SHA" ]] || {
    _qps_fail 'target-generation boot kit does not match the update transaction'
    return 1
  }
}

_qps_validate_update_workspace() {
  local qps_directory=$1
  local qps_identity=$2
  local qps_source_sha=$3
  local qps_source_bytes=$4
  local qps_working_bytes=$5

  _qps_validate_store_directory \
    "$qps_directory" "$qps_identity" "$qps_source_sha" \
    "$qps_source_bytes" "$qps_working_bytes"
}

_qps_has_only_update_contents() (
  local qps_directory=$1
  local qps_expected=$2
  local qps_entry=''
  local qps_workspace=''
  local qps_has_state=0
  local qps_has_transaction=0
  local qps_has_workspace=0
  local qps_count=0

  case "$qps_expected" in
    $'candidate\nstate\ntransaction.json\n') qps_workspace=candidate ;;
    $'rollback\nstate\ntransaction.json\n') qps_workspace=rollback ;;
    *) return 1 ;;
  esac

  shopt -s nullglob dotglob
  for qps_entry in "$qps_directory"/*; do
    ((qps_count += 1))
    case ${qps_entry##*/} in
      state) qps_has_state=1 ;;
      transaction.json) qps_has_transaction=1 ;;
      "$qps_workspace") qps_has_workspace=1 ;;
      *) return 1 ;;
    esac
  done
  shopt -u nullglob dotglob
  (( qps_count == 3 && qps_has_state == 1 && \
     qps_has_transaction == 1 && qps_has_workspace == 1 ))
)

_qps_has_only_interrupted_candidate_contents() (
  local qps_directory=$1
  local qps_entry=''
  local qps_has_metadata=0
  local qps_has_disk=0
  local qps_count=0

  _qps_assert_private_directory \
    "$qps_directory" 'interrupted update candidate directory' || return 1
  shopt -s nullglob dotglob
  for qps_entry in "$qps_directory"/*; do
    ((qps_count += 1))
    case ${qps_entry##*/} in
      metadata.json) qps_has_metadata=1 ;;
      rootfs.ext4) qps_has_disk=1 ;;
      *) return 1 ;;
    esac
  done
  shopt -u nullglob dotglob
  (( qps_has_metadata == 1 && qps_count >= 1 && qps_count <= 2 ))
)

_qps_validate_interrupted_update_staging() {
  local qps_staging=$1
  local qps_current="$QEMU_PERSISTENT_STORAGE_DISKS_ROOT/current"
  local qps_candidate="$qps_staging/candidate"
  local qps_candidate_bytes=''

  case "$qps_staging" in
    "$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT/.current.initializing."??????) ;;
    *) return 1 ;;
  esac
  _qps_assert_private_directory \
    "$qps_staging" 'interrupted update staging directory' || return 1
  _qps_has_only_update_contents \
    "$qps_staging" $'candidate\nstate\ntransaction.json\n' || return 1
  _qps_read_update_metadata "$qps_staging/transaction.json" || return 1
  _qps_read_update_state "$qps_staging" || return 1
  [[ $QPS_UPDATE_STATE == prepared ]] || return 1
  (( QPS_UPDATE_FROM_WORKING_BYTES >= QPS_UPDATE_FROM_SOURCE_BYTES )) || return 1
  (( QPS_UPDATE_TARGET_WORKING_BYTES >= QPS_UPDATE_TARGET_SOURCE_BYTES )) || return 1
  (( QPS_UPDATE_FROM_WORKING_BYTES <= QPS_UPDATE_TARGET_WORKING_BYTES )) || return 1
  _qps_validate_update_boot_kits || return 1
  _qps_validate_update_workspace \
    "$qps_current" "$QPS_UPDATE_FROM_IDENTITY" \
    "$QPS_UPDATE_FROM_SOURCE_SHA" "$QPS_UPDATE_FROM_SOURCE_BYTES" \
    "$QPS_UPDATE_FROM_WORKING_BYTES" || return 1
  _qps_has_only_interrupted_candidate_contents "$qps_candidate" || return 1
  _qps_validate_metadata \
    "$qps_candidate/metadata.json" "$QPS_UPDATE_TARGET_IDENTITY" \
    "$QPS_UPDATE_TARGET_SOURCE_SHA" "$QPS_UPDATE_TARGET_SOURCE_BYTES" || return 1

  if [[ -e $qps_candidate/rootfs.ext4 || -L $qps_candidate/rootfs.ext4 ]]; then
    _qps_assert_private_regular_file \
      "$qps_candidate/rootfs.ext4" 'interrupted candidate root disk' || return 1
    qps_candidate_bytes=$(_qps_size "$qps_candidate/rootfs.ext4")
    [[ $qps_candidate_bytes =~ ^[0-9]+$ ]] || return 1
    (( qps_candidate_bytes <= QPS_UPDATE_TARGET_WORKING_BYTES )) || return 1
    [[ $(_qps_file_identity "$qps_candidate/rootfs.ext4") != \
       $(_qps_file_identity "$qps_current/rootfs.ext4") ]] || return 1
  fi
}

_qps_reap_interrupted_update_staging() {
  local qps_staging=''

  for qps_staging in \
    "$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT"/.current.initializing.??????; do
    [[ -e $qps_staging || -L $qps_staging ]] || continue
    if _qps_validate_interrupted_update_staging "$qps_staging"; then
      if /bin/rm -rf "$qps_staging"; then
        _qps_fsync "$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT" || true
        _qps_error "removed recognized interrupted update staging ${qps_staging##*/}"
      else
        _qps_error "could not remove recognized interrupted update staging: $qps_staging"
      fi
    else
      _qps_error "left unrecognized interrupted update staging untouched: $qps_staging"
    fi
  done
  return 0
}

_qps_validate_detached_update_tombstone() (
  local qps_tombstone=$1
  local qps_current="$QEMU_PERSISTENT_STORAGE_DISKS_ROOT/current"
  local qps_name=${qps_tombstone##*/}
  local qps_name_pattern='^\.current\.(rolled-back|replaced|cancelled|superseded|finalized)\.([1-9][0-9]*)\.([0-9]{2,10})$'
  local qps_reason=''
  local qps_workspace=''
  local qps_workspace_identity=''
  local qps_workspace_source_sha=''
  local qps_workspace_source_bytes=''
  local qps_workspace_working_bytes=''
  local qps_current_identity=''
  local qps_current_source_sha=''
  local qps_current_source_bytes=''
  local qps_current_working_bytes=''
  local qps_expected_contents=''
  local qps_expected_state=''

  case "$qps_tombstone" in
    "$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT"/.current.*) ;;
    *) return 1 ;;
  esac
  [[ $qps_name =~ $qps_name_pattern ]] || return 1
  qps_reason=${BASH_REMATCH[1]}
  _qps_assert_private_directory \
    "$qps_tombstone" 'detached update tombstone' || return 1
  _qps_read_update_metadata "$qps_tombstone/transaction.json" || return 1
  _qps_read_update_state "$qps_tombstone" || return 1
  (( QPS_UPDATE_FROM_WORKING_BYTES >= QPS_UPDATE_FROM_SOURCE_BYTES )) || return 1
  (( QPS_UPDATE_TARGET_WORKING_BYTES >= QPS_UPDATE_TARGET_SOURCE_BYTES )) || return 1
  (( QPS_UPDATE_FROM_WORKING_BYTES <= QPS_UPDATE_TARGET_WORKING_BYTES )) || return 1
  case "$QPS_UPDATE_FROM_BOOT_AVAILABLE" in
    true|false) ;;
    *) return 1 ;;
  esac
  _qps_validate_update_boot_kits || return 1

  case "$qps_reason" in
    cancelled|replaced)
      qps_expected_state=prepared
      qps_workspace=candidate
      qps_workspace_identity=$QPS_UPDATE_TARGET_IDENTITY
      qps_workspace_source_sha=$QPS_UPDATE_TARGET_SOURCE_SHA
      qps_workspace_source_bytes=$QPS_UPDATE_TARGET_SOURCE_BYTES
      qps_workspace_working_bytes=$QPS_UPDATE_TARGET_WORKING_BYTES
      qps_current_identity=$QPS_UPDATE_FROM_IDENTITY
      qps_current_source_sha=$QPS_UPDATE_FROM_SOURCE_SHA
      qps_current_source_bytes=$QPS_UPDATE_FROM_SOURCE_BYTES
      qps_current_working_bytes=$QPS_UPDATE_FROM_WORKING_BYTES
      qps_expected_contents=$'candidate\nstate\ntransaction.json\n'
      ;;
    rolled-back)
      qps_expected_state=rolling-back
      qps_workspace=candidate
      qps_workspace_identity=$QPS_UPDATE_TARGET_IDENTITY
      qps_workspace_source_sha=$QPS_UPDATE_TARGET_SOURCE_SHA
      qps_workspace_source_bytes=$QPS_UPDATE_TARGET_SOURCE_BYTES
      qps_workspace_working_bytes=$QPS_UPDATE_TARGET_WORKING_BYTES
      qps_current_identity=$QPS_UPDATE_FROM_IDENTITY
      qps_current_source_sha=$QPS_UPDATE_FROM_SOURCE_SHA
      qps_current_source_bytes=$QPS_UPDATE_FROM_SOURCE_BYTES
      qps_current_working_bytes=$QPS_UPDATE_FROM_WORKING_BYTES
      qps_expected_contents=$'candidate\nstate\ntransaction.json\n'
      ;;
    finalized|superseded)
      qps_expected_state=committed
      qps_workspace=rollback
      qps_workspace_identity=$QPS_UPDATE_FROM_IDENTITY
      qps_workspace_source_sha=$QPS_UPDATE_FROM_SOURCE_SHA
      qps_workspace_source_bytes=$QPS_UPDATE_FROM_SOURCE_BYTES
      qps_workspace_working_bytes=$QPS_UPDATE_FROM_WORKING_BYTES
      qps_current_identity=$QPS_UPDATE_TARGET_IDENTITY
      qps_current_source_sha=$QPS_UPDATE_TARGET_SOURCE_SHA
      qps_current_source_bytes=$QPS_UPDATE_TARGET_SOURCE_BYTES
      qps_current_working_bytes=$QPS_UPDATE_TARGET_WORKING_BYTES
      qps_expected_contents=$'rollback\nstate\ntransaction.json\n'
      ;;
    *) return 1 ;;
  esac

  [[ $QPS_UPDATE_STATE == "$qps_expected_state" ]] || return 1
  _qps_has_only_update_contents \
    "$qps_tombstone" "$qps_expected_contents" || return 1
  _qps_validate_update_workspace \
    "$qps_tombstone/$qps_workspace" "$qps_workspace_identity" \
    "$qps_workspace_source_sha" "$qps_workspace_source_bytes" \
    "$qps_workspace_working_bytes" || return 1
  _qps_validate_update_workspace \
    "$qps_current" "$qps_current_identity" \
    "$qps_current_source_sha" "$qps_current_source_bytes" \
    "$qps_current_working_bytes" || return 1
  [[ $(_qps_file_identity "$qps_tombstone/$qps_workspace/rootfs.ext4") != \
     $(_qps_file_identity "$qps_current/rootfs.ext4") ]] || return 1
)

_qps_reap_detached_update_tombstones() {
  local qps_tombstone=''

  for qps_tombstone in \
    "$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT"/.current.rolled-back.* \
    "$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT"/.current.replaced.* \
    "$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT"/.current.cancelled.* \
    "$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT"/.current.superseded.* \
    "$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT"/.current.finalized.*; do
    [[ -e $qps_tombstone || -L $qps_tombstone ]] || continue
    if _qps_validate_detached_update_tombstone "$qps_tombstone"; then
      if /bin/rm -rf "$qps_tombstone"; then
        _qps_fsync "$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT" || true
        _qps_error "removed recognized detached update tombstone ${qps_tombstone##*/}"
      else
        _qps_error "could not remove recognized detached update tombstone: $qps_tombstone"
      fi
    else
      _qps_error "left unrecognized detached update tombstone untouched: $qps_tombstone"
    fi
  done
  return 0
}

_qps_validate_update_transaction_header() {
  local qps_transaction=$1

  [[ $qps_transaction == "$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT/current" ]] || {
    _qps_fail 'update transaction is outside the supported current workspace'
    return 1
  }
  _qps_assert_private_directory "$qps_transaction" 'update transaction directory' || return 1
  _qps_read_update_metadata "$qps_transaction/transaction.json" || return 1
  _qps_read_update_state "$qps_transaction" || return 1
  (( QPS_UPDATE_FROM_WORKING_BYTES >= QPS_UPDATE_FROM_SOURCE_BYTES )) || return 1
  (( QPS_UPDATE_TARGET_WORKING_BYTES >= QPS_UPDATE_TARGET_SOURCE_BYTES )) || return 1
  case "$QPS_UPDATE_FROM_BOOT_AVAILABLE" in
    true|false) ;;
    *) return 1 ;;
  esac
  (( QPS_UPDATE_FROM_WORKING_BYTES <= QPS_UPDATE_TARGET_WORKING_BYTES )) || {
    _qps_fail 'update transaction would shrink the active disk'
    return 1
  }
  _qps_validate_update_boot_kits || return 1
}

_qps_validate_stable_update_transaction() {
  local qps_transaction=$1
  local qps_current="$QEMU_PERSISTENT_STORAGE_DISKS_ROOT/current"

  _qps_validate_update_transaction_header "$qps_transaction" || return 1
  case "$QPS_UPDATE_STATE" in
    prepared)
      _qps_has_only_update_contents \
        "$qps_transaction" $'candidate\nstate\ntransaction.json\n' || {
        _qps_fail 'prepared update transaction contains unexpected files'
        return 1
      }
      _qps_validate_update_workspace \
        "$qps_current" "$QPS_UPDATE_FROM_IDENTITY" \
        "$QPS_UPDATE_FROM_SOURCE_SHA" "$QPS_UPDATE_FROM_SOURCE_BYTES" \
        "$QPS_UPDATE_FROM_WORKING_BYTES" || return 1
      _qps_validate_update_workspace \
        "$qps_transaction/candidate" "$QPS_UPDATE_TARGET_IDENTITY" \
        "$QPS_UPDATE_TARGET_SOURCE_SHA" "$QPS_UPDATE_TARGET_SOURCE_BYTES" \
        "$QPS_UPDATE_TARGET_WORKING_BYTES" || return 1
      [[ $(_qps_file_identity "$qps_current/rootfs.ext4") != \
         $(_qps_file_identity "$qps_transaction/candidate/rootfs.ext4") ]] || {
        _qps_fail 'update candidate aliases the active root disk'
        return 1
      }
      ;;
    committed)
      _qps_has_only_update_contents \
        "$qps_transaction" $'rollback\nstate\ntransaction.json\n' || {
        _qps_fail 'committed update transaction contains unexpected files'
        return 1
      }
      _qps_validate_update_workspace \
        "$qps_current" "$QPS_UPDATE_TARGET_IDENTITY" \
        "$QPS_UPDATE_TARGET_SOURCE_SHA" "$QPS_UPDATE_TARGET_SOURCE_BYTES" \
        "$QPS_UPDATE_TARGET_WORKING_BYTES" || return 1
      _qps_validate_update_workspace \
        "$qps_transaction/rollback" "$QPS_UPDATE_FROM_IDENTITY" \
        "$QPS_UPDATE_FROM_SOURCE_SHA" "$QPS_UPDATE_FROM_SOURCE_BYTES" \
        "$QPS_UPDATE_FROM_WORKING_BYTES" || return 1
      [[ $(_qps_file_identity "$qps_current/rootfs.ext4") != \
         $(_qps_file_identity "$qps_transaction/rollback/rootfs.ext4") ]] || {
        _qps_fail 'rollback workspace aliases the committed root disk'
        return 1
      }
      ;;
    *)
      _qps_fail "update transaction is not in a stable state: $QPS_UPDATE_STATE"
      return 1
      ;;
  esac
}

_qps_discard_update_transaction() {
  local qps_transaction=$1
  local qps_reason=$2
  local qps_discarded=''

  [[ $qps_transaction == "$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT/current" ]] || return 1
  case "$qps_reason" in
    rolled-back|replaced|cancelled|superseded|finalized) ;;
    *) return 1 ;;
  esac
  qps_discarded="$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT/.current.${qps_reason}.$$.$RANDOM$RANDOM"
  [[ ! -e $qps_discarded && ! -L $qps_discarded ]] || return 1
  /bin/mv "$qps_transaction" "$qps_discarded" || return 1
  _qps_fsync "$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT" || return 1
  _qps_assert_private_directory "$qps_discarded" 'detached update transaction' || return 1
  case "$qps_discarded" in
    "$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT/.current.${qps_reason}."*) ;;
    *) return 1 ;;
  esac
  /bin/rm -rf "$qps_discarded" || return 1
  _qps_fsync "$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT" || return 1
}

_qps_finish_rolling_back_update() {
  local qps_transaction=$1
  local qps_current="$QEMU_PERSISTENT_STORAGE_DISKS_ROOT/current"

  _qps_validate_update_transaction_header "$qps_transaction" || return 1
  [[ $QPS_UPDATE_STATE == rolling-back ]] || return 1

  if [[ -e $qps_current || -L $qps_current ]]; then
    if [[ -e $qps_transaction/rollback || -L $qps_transaction/rollback ]]; then
      [[ ! -e $qps_transaction/candidate && ! -L $qps_transaction/candidate ]] || {
        _qps_fail 'rolling-back transaction has both active and detached candidates'
        return 1
      }
      _qps_validate_update_workspace \
        "$qps_current" "$QPS_UPDATE_TARGET_IDENTITY" \
        "$QPS_UPDATE_TARGET_SOURCE_SHA" "$QPS_UPDATE_TARGET_SOURCE_BYTES" \
        "$QPS_UPDATE_TARGET_WORKING_BYTES" || return 1
      /bin/mv "$qps_current" "$qps_transaction/candidate" || return 1
      _qps_fsync "$QEMU_PERSISTENT_STORAGE_DISKS_ROOT" || return 1
    else
      _qps_validate_update_workspace \
        "$qps_current" "$QPS_UPDATE_FROM_IDENTITY" \
        "$QPS_UPDATE_FROM_SOURCE_SHA" "$QPS_UPDATE_FROM_SOURCE_BYTES" \
        "$QPS_UPDATE_FROM_WORKING_BYTES" || return 1
    fi
  fi

  if [[ ! -e $qps_current && ! -L $qps_current ]]; then
    _qps_validate_update_workspace \
      "$qps_transaction/rollback" "$QPS_UPDATE_FROM_IDENTITY" \
      "$QPS_UPDATE_FROM_SOURCE_SHA" "$QPS_UPDATE_FROM_SOURCE_BYTES" \
      "$QPS_UPDATE_FROM_WORKING_BYTES" || return 1
    /bin/mv "$qps_transaction/rollback" "$qps_current" || return 1
    _qps_fsync "$QEMU_PERSISTENT_STORAGE_DISKS_ROOT" || return 1
  fi

  _qps_validate_update_workspace \
    "$qps_current" "$QPS_UPDATE_FROM_IDENTITY" \
    "$QPS_UPDATE_FROM_SOURCE_SHA" "$QPS_UPDATE_FROM_SOURCE_BYTES" \
    "$QPS_UPDATE_FROM_WORKING_BYTES" || return 1
  _qps_validate_update_workspace \
    "$qps_transaction/candidate" "$QPS_UPDATE_TARGET_IDENTITY" \
    "$QPS_UPDATE_TARGET_SOURCE_SHA" "$QPS_UPDATE_TARGET_SOURCE_BYTES" \
    "$QPS_UPDATE_TARGET_WORKING_BYTES" || return 1
  _qps_has_only_update_contents \
    "$qps_transaction" $'candidate\nstate\ntransaction.json\n' || {
    _qps_fail 'rolled-back update transaction contains unexpected files'
    return 1
  }
  _qps_discard_update_transaction "$qps_transaction" rolled-back || return 1
  _qps_error "rolled back generational update to ${QPS_UPDATE_FROM_IDENTITY:0:12}"
}

_qps_recover_update_transaction() {
  local qps_transaction="$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT/current"
  local qps_current="$QEMU_PERSISTENT_STORAGE_DISKS_ROOT/current"

  _qps_reap_interrupted_update_staging || true
  _qps_reap_detached_update_tombstones || true
  [[ -e $qps_transaction || -L $qps_transaction ]] || return 0
  _qps_reap_update_state_staging "$qps_transaction" || return 1
  _qps_validate_update_transaction_header "$qps_transaction" || return 1
  case "$QPS_UPDATE_STATE" in
    prepared|committed)
      _qps_validate_stable_update_transaction "$qps_transaction"
      ;;
    committing)
      if [[ -e $qps_current || -L $qps_current ]]; then
        if [[ -e $qps_transaction/candidate || -L $qps_transaction/candidate ]]; then
          [[ ! -e $qps_transaction/rollback && ! -L $qps_transaction/rollback ]] || {
            _qps_fail 'committing update has an ambiguous workspace layout'
            return 1
          }
          _qps_validate_update_workspace \
            "$qps_current" "$QPS_UPDATE_FROM_IDENTITY" \
            "$QPS_UPDATE_FROM_SOURCE_SHA" "$QPS_UPDATE_FROM_SOURCE_BYTES" \
            "$QPS_UPDATE_FROM_WORKING_BYTES" || return 1
          /bin/mv "$qps_current" "$qps_transaction/rollback" || return 1
          _qps_fsync "$QEMU_PERSISTENT_STORAGE_DISKS_ROOT" || return 1
        else
          _qps_validate_update_workspace \
            "$qps_current" "$QPS_UPDATE_TARGET_IDENTITY" \
            "$QPS_UPDATE_TARGET_SOURCE_SHA" "$QPS_UPDATE_TARGET_SOURCE_BYTES" \
            "$QPS_UPDATE_TARGET_WORKING_BYTES" || return 1
        fi
      fi
      if [[ ! -e $qps_current && ! -L $qps_current ]]; then
        _qps_validate_update_workspace \
          "$qps_transaction/rollback" "$QPS_UPDATE_FROM_IDENTITY" \
          "$QPS_UPDATE_FROM_SOURCE_SHA" "$QPS_UPDATE_FROM_SOURCE_BYTES" \
          "$QPS_UPDATE_FROM_WORKING_BYTES" || return 1
        _qps_validate_update_workspace \
          "$qps_transaction/candidate" "$QPS_UPDATE_TARGET_IDENTITY" \
          "$QPS_UPDATE_TARGET_SOURCE_SHA" "$QPS_UPDATE_TARGET_SOURCE_BYTES" \
          "$QPS_UPDATE_TARGET_WORKING_BYTES" || return 1
        /bin/mv "$qps_transaction/candidate" "$qps_current" || return 1
        _qps_fsync "$QEMU_PERSISTENT_STORAGE_DISKS_ROOT" || return 1
      fi
      _qps_write_update_state "$qps_transaction" committed || return 1
      _qps_validate_stable_update_transaction "$qps_transaction" || return 1
      _qps_error "recovered committed generational update ${QPS_UPDATE_TARGET_IDENTITY:0:12}"
      ;;
    rolling-back)
      _qps_finish_rolling_back_update "$qps_transaction"
      ;;
  esac
}

_qps_load_update_outputs() {
  local qps_transaction="$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT/current"
  local qps_current="$QEMU_PERSISTENT_STORAGE_DISKS_ROOT/current"

  _qps_reset_update_outputs
  if [[ ! -e $qps_transaction && ! -L $qps_transaction ]]; then
    QEMU_PERSISTENT_STORAGE_UPDATE_STATE=none
    if [[ -e $qps_current || -L $qps_current ]]; then
      _qps_validate_recorded_workspace "$qps_current" || return 1
      QEMU_PERSISTENT_STORAGE_ACTIVE_IDENTITY=$QPS_METADATA_IDENTITY
      QEMU_PERSISTENT_STORAGE_ACTIVE_DISK="$qps_current/rootfs.ext4"
      _qps_set_active_boot_globals "$QPS_METADATA_IDENTITY" || return 1
    fi
    return 0
  fi

  _qps_validate_stable_update_transaction "$qps_transaction" || return 1
  QEMU_PERSISTENT_STORAGE_UPDATE_HEALTH_TOKEN=$QPS_UPDATE_HEALTH_TOKEN
  case "$QPS_UPDATE_STATE" in
    prepared)
      QEMU_PERSISTENT_STORAGE_UPDATE_STATE=candidate
      QEMU_PERSISTENT_STORAGE_ACTIVE_IDENTITY=$QPS_UPDATE_FROM_IDENTITY
      QEMU_PERSISTENT_STORAGE_ACTIVE_DISK="$qps_current/rootfs.ext4"
      if [[ $QPS_UPDATE_FROM_BOOT_AVAILABLE == true ]]; then
        _qps_set_active_boot_globals "$QPS_UPDATE_FROM_IDENTITY" || return 1
      fi
      QEMU_PERSISTENT_STORAGE_CANDIDATE_IDENTITY=$QPS_UPDATE_TARGET_IDENTITY
      QEMU_PERSISTENT_STORAGE_CANDIDATE_DISK="$qps_transaction/candidate/rootfs.ext4"
      _qps_set_candidate_boot_globals "$QPS_UPDATE_TARGET_IDENTITY" || return 1
      ;;
    committed)
      QEMU_PERSISTENT_STORAGE_UPDATE_STATE=committed
      QEMU_PERSISTENT_STORAGE_ACTIVE_IDENTITY=$QPS_UPDATE_TARGET_IDENTITY
      QEMU_PERSISTENT_STORAGE_ACTIVE_DISK="$qps_current/rootfs.ext4"
      _qps_set_active_boot_globals "$QPS_UPDATE_TARGET_IDENTITY" || return 1
      ;;
  esac
}

_qps_validate_update_target_arguments() {
  local qps_target_identity=$1
  local qps_target_source_sha=$2
  local qps_target_source_bytes=$3
  local qps_target_working_bytes=$4

  _qps_is_identity "$qps_target_identity" || {
    _qps_fail 'update target identity must be exactly 64 lowercase hexadecimal characters'
    return 1
  }
  _qps_is_identity "$qps_target_source_sha" || {
    _qps_fail 'update target rootfs digest must be exactly 64 lowercase hexadecimal characters'
    return 1
  }
  _qps_is_positive_integer "$qps_target_source_bytes" || {
    _qps_fail 'update target rootfs size must be a positive integer'
    return 1
  }
  _qps_is_positive_integer "$qps_target_working_bytes" || {
    _qps_fail 'update target working size must be a positive integer'
    return 1
  }
  (( qps_target_working_bytes >= qps_target_source_bytes )) || {
    _qps_fail 'update target working disk cannot be smaller than its factory source'
    return 1
  }
}

_qps_update_matches_target() {
  local qps_target_identity=$1
  local qps_target_source_sha=$2
  local qps_target_source_bytes=$3
  local qps_target_working_bytes=$4

  [[ $QPS_UPDATE_TARGET_IDENTITY == "$qps_target_identity" && \
     $QPS_UPDATE_TARGET_SOURCE_SHA == "$qps_target_source_sha" && \
     $QPS_UPDATE_TARGET_SOURCE_BYTES == "$qps_target_source_bytes" && \
     $QPS_UPDATE_TARGET_WORKING_BYTES == "$qps_target_working_bytes" ]]
}

# Assess the single persistent workspace without changing disk contents.
#
# Arguments are the validated target bundle identity, target factory-rootfs
# digest and byte count, and target working-disk byte count. On success,
# QEMU_PERSISTENT_STORAGE_UPDATE_STATE is one of none, required, candidate, or
# committed. Active/candidate disk and paired boot-kit globals are populated
# when those objects exist. This call does not retain the workspace lock.
qemu_persistent_storage_assess_update() {
  local qps_target_identity=${1:-}
  local qps_target_source_sha=${2:-}
  local qps_target_source_bytes=${3:-}
  local qps_target_working_bytes=${4:-}
  local qps_transaction=''
  local qps_current=''
  local qps_existing_bytes=''
  local qps_status=0

  _qps_reset_update_outputs
  _qps_validate_update_target_arguments \
    "$qps_target_identity" "$qps_target_source_sha" \
    "$qps_target_source_bytes" "$qps_target_working_bytes" || return 1
  _qps_prepare_state_root || return 1
  _qps_acquire_lock current || return 1
  qps_transaction="$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT/current"
  qps_current="$QEMU_PERSISTENT_STORAGE_DISKS_ROOT/current"

  if _qps_recover_update_transaction; then
    :
  else
    qps_status=$?
  fi
  if (( qps_status == 0 )); then
    if _qps_load_update_outputs; then
      :
    else
      qps_status=$?
    fi
  fi
  if (( qps_status == 0 )) && [[ -e $qps_transaction || -L $qps_transaction ]]; then
    _qps_read_update_metadata "$qps_transaction/transaction.json" || qps_status=$?
    if (( qps_status == 0 )) && ! _qps_update_matches_target \
      "$qps_target_identity" "$qps_target_source_sha" \
      "$qps_target_source_bytes" "$qps_target_working_bytes"; then
      # A stale prepared candidate is disposable, and a committed target is
      # still the active VM. prepare_update can safely replace either one with
      # a candidate for this newer release.
      QEMU_PERSISTENT_STORAGE_UPDATE_STATE=required
    fi
  elif (( qps_status == 0 )) && [[ ! -e $qps_current && ! -L $qps_current ]]; then
    QEMU_PERSISTENT_STORAGE_UPDATE_STATE=none
  elif (( qps_status == 0 )); then
    _qps_validate_recorded_workspace "$qps_current" || qps_status=$?
    if (( qps_status == 0 )); then
      qps_existing_bytes=$QPS_RECORDED_EXISTING_BYTES
      if (( qps_existing_bytes > qps_target_working_bytes )); then
        if _qps_incompatible \
          'the saved VM is larger than the target release supports; refusing to shrink it'; then
          :
        else
          qps_status=$?
        fi
      elif [[ $QPS_METADATA_SCHEMA == "$QEMU_PERSISTENT_STORAGE_SCHEMA" && \
              $QPS_METADATA_IDENTITY == "$qps_target_identity" && \
              $QPS_METADATA_SOURCE_SHA == "$qps_target_source_sha" && \
              $QPS_METADATA_SOURCE_BYTES == "$qps_target_source_bytes" ]]; then
        QEMU_PERSISTENT_STORAGE_UPDATE_STATE=none
      else
        QEMU_PERSISTENT_STORAGE_UPDATE_STATE=required
      fi
    fi
  fi
  qemu_persistent_storage_release_lock
  return "$qps_status"
}

_qps_remove_owned_update_staging() {
  local qps_staging=$1

  case "$qps_staging" in
    "$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT/.current.initializing."??????)
      [[ -d $qps_staging && ! -L $qps_staging ]] || return 0
      [[ $(_qps_owner "$qps_staging") == $(id -u) ]] || return 1
      /bin/rm -rf "$qps_staging"
      ;;
    *) return 1 ;;
  esac
}

_qps_prepare_update_locked() {
  local qps_target_identity=$1
  local qps_target_source_sha=$2
  local qps_target_source_bytes=$3
  local qps_target_working_bytes=$4
  local qps_target_kernel=$5
  local qps_target_initramfs=$6
  local qps_active_kernel=${7:-}
  local qps_active_initramfs=${8:-}
  local qps_transaction="$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT/current"
  local qps_current="$QEMU_PERSISTENT_STORAGE_DISKS_ROOT/current"
  local qps_staging=''
  local qps_candidate=''
  local qps_health_token=''
  local qps_from_identity=''
  local qps_from_source_sha=''
  local qps_from_source_bytes=''
  local qps_from_working_bytes=''
  local qps_from_kernel_bytes=''
  local qps_from_kernel_sha=''
  local qps_from_initramfs_bytes=''
  local qps_from_initramfs_sha=''
  local qps_target_kernel_bytes=''
  local qps_target_kernel_sha=''
  local qps_target_initramfs_bytes=''
  local qps_target_initramfs_sha=''
  local qps_zero_sha='0000000000000000000000000000000000000000000000000000000000000000'
  local qps_supersede_committed=0

  _qps_recover_update_transaction || return 1
  if [[ -e $qps_transaction || -L $qps_transaction ]]; then
    _qps_validate_stable_update_transaction "$qps_transaction" || return 1
    if _qps_update_matches_target \
      "$qps_target_identity" "$qps_target_source_sha" \
      "$qps_target_source_bytes" "$qps_target_working_bytes"; then
      _qps_load_update_outputs
      return $?
    fi
    case "$QPS_UPDATE_STATE" in
      prepared)
        _qps_discard_update_transaction "$qps_transaction" replaced || return 1
        _qps_error 'cancelled a stale candidate for a different app release'
        _qps_prune_replaced_candidate_caches_best_effort || true
        ;;
      committed)
        # Keep the previous rollback until every fallible part of preparing
        # the next candidate (target validation, boot staging, clone, growth,
        # and journal flush) has succeeded.
        qps_supersede_committed=1
        ;;
      *) return 1 ;;
    esac
  fi

  [[ -e $qps_current && ! -L $qps_current ]] || {
    _qps_fail 'there is no active persistent workspace to update'
    return 1
  }
  _qps_validate_recorded_workspace "$qps_current" || return 1
  qps_from_identity=$QPS_METADATA_IDENTITY
  qps_from_source_sha=$QPS_METADATA_SOURCE_SHA
  qps_from_source_bytes=$QPS_METADATA_SOURCE_BYTES
  qps_from_working_bytes=$QPS_RECORDED_EXISTING_BYTES
  if (( qps_from_working_bytes > qps_target_working_bytes )); then
    _qps_incompatible 'the generational update would shrink the active disk'
    return $?
  fi
  if [[ $QPS_METADATA_SCHEMA == "$QEMU_PERSISTENT_STORAGE_SCHEMA" && \
        $qps_from_identity == "$qps_target_identity" && \
        $qps_from_source_sha == "$qps_target_source_sha" && \
        $qps_from_source_bytes == "$qps_target_source_bytes" ]]; then
    _qps_load_update_outputs || return 1
    QEMU_PERSISTENT_STORAGE_UPDATE_STATE=none
    return 0
  fi

  if [[ ! -e $QEMU_PERSISTENT_STORAGE_BOOT_ROOT/$qps_from_identity && \
        ! -L $QEMU_PERSISTENT_STORAGE_BOOT_ROOT/$qps_from_identity ]]; then
    if [[ -n $qps_active_kernel || -n $qps_active_initramfs ]]; then
      [[ -n $qps_active_kernel && -n $qps_active_initramfs ]] || {
        _qps_fail 'both active kernel and initramfs must be supplied together'
        return 1
      }
      _qps_stage_boot_kit_locked \
        "$qps_from_identity" "$qps_active_kernel" "$qps_active_initramfs" || return 1
    fi
  elif [[ -n $qps_active_kernel || -n $qps_active_initramfs ]]; then
    [[ -n $qps_active_kernel && -n $qps_active_initramfs ]] || {
      _qps_fail 'both active kernel and initramfs must be supplied together'
      return 1
    }
    _qps_stage_boot_kit_locked \
      "$qps_from_identity" "$qps_active_kernel" "$qps_active_initramfs" || return 1
  fi
  if [[ -e $QEMU_PERSISTENT_STORAGE_BOOT_ROOT/$qps_from_identity || \
        -L $QEMU_PERSISTENT_STORAGE_BOOT_ROOT/$qps_from_identity ]]; then
    _qps_validate_boot_kit_directory \
      "$QEMU_PERSISTENT_STORAGE_BOOT_ROOT/$qps_from_identity" "$qps_from_identity" || return 1
    qps_from_kernel_bytes=$QPS_BOOT_KERNEL_BYTES
    qps_from_kernel_sha=$QPS_BOOT_KERNEL_SHA
    qps_from_initramfs_bytes=$QPS_BOOT_INITRAMFS_BYTES
    qps_from_initramfs_sha=$QPS_BOOT_INITRAMFS_SHA
  else
    qps_from_kernel_bytes=0
    qps_from_kernel_sha=$qps_zero_sha
    qps_from_initramfs_bytes=0
    qps_from_initramfs_sha=$qps_zero_sha
  fi

  _qps_stage_boot_kit_locked \
    "$qps_target_identity" "$qps_target_kernel" "$qps_target_initramfs" || return 1
  _qps_validate_boot_kit_directory \
    "$QEMU_PERSISTENT_STORAGE_BOOT_ROOT/$qps_target_identity" "$qps_target_identity" || return 1
  qps_target_kernel_bytes=$QPS_BOOT_KERNEL_BYTES
  qps_target_kernel_sha=$QPS_BOOT_KERNEL_SHA
  qps_target_initramfs_bytes=$QPS_BOOT_INITRAMFS_BYTES
  qps_target_initramfs_sha=$QPS_BOOT_INITRAMFS_SHA

  qps_health_token=$(_qps_new_health_token) || return 1
  qps_staging=$(mktemp -d \
    "$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT/.current.initializing.XXXXXX") || {
    _qps_fail 'cannot create generational-update staging directory'
    return 1
  }
  chmod 700 "$qps_staging" || return 1
  qps_candidate="$qps_staging/candidate"
  mkdir "$qps_candidate" || return 1
  chmod 700 "$qps_candidate" || return 1

  if ! _qps_write_update_metadata \
      "$qps_staging/transaction.json" \
      "$qps_from_identity" "$qps_from_source_bytes" "$qps_from_source_sha" \
      "$qps_from_working_bytes" \
      "$qps_from_kernel_bytes" "$qps_from_kernel_sha" \
      "$qps_from_initramfs_bytes" "$qps_from_initramfs_sha" \
      "$qps_target_identity" "$qps_target_source_bytes" "$qps_target_source_sha" \
      "$qps_target_working_bytes" \
      "$qps_target_kernel_bytes" "$qps_target_kernel_sha" \
      "$qps_target_initramfs_bytes" "$qps_target_initramfs_sha" \
      "$qps_health_token" || \
    ! _qps_initialize_update_state "$qps_staging" prepared || \
    ! _qps_write_metadata \
      "$qps_candidate/metadata.json" "$qps_target_identity" \
      "$qps_target_source_sha" "$qps_target_source_bytes" || \
    ! _qps_clone_candidate_disk \
      "$qps_current/rootfs.ext4" "$qps_candidate/rootfs.ext4" \
      "$qps_from_working_bytes" || \
    ! _qps_expand_disk \
      "$qps_candidate/rootfs.ext4" "$qps_from_working_bytes" \
      "$qps_target_working_bytes" || \
    ! _qps_validate_update_workspace \
      "$qps_candidate" "$qps_target_identity" "$qps_target_source_sha" \
      "$qps_target_source_bytes" "$qps_target_working_bytes" || \
    ! _qps_has_only_update_contents \
      "$qps_staging" $'candidate\nstate\ntransaction.json\n' || \
    ! _qps_fsync "$qps_candidate" || \
    ! _qps_fsync "$qps_staging"; then
    _qps_remove_owned_update_staging "$qps_staging" || true
    return 1
  fi

  if (( qps_supersede_committed )); then
    if ! _qps_finalize_committed_update_locked "$qps_transaction" superseded; then
      _qps_remove_owned_update_staging "$qps_staging" || true
      return 1
    fi
  fi
  [[ ! -e $qps_transaction && ! -L $qps_transaction ]] || {
    _qps_remove_owned_update_staging "$qps_staging" || true
    _qps_fail 'an update transaction appeared during candidate preparation'
    return 1
  }
  /bin/mv "$qps_staging" "$qps_transaction" || {
    _qps_remove_owned_update_staging "$qps_staging" || true
    return 1
  }
  _qps_fsync "$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT" || return 1
  _qps_validate_stable_update_transaction "$qps_transaction" || return 1
  _qps_load_update_outputs || return 1
  _qps_error \
    "prepared generational update ${qps_from_identity:0:12} -> ${qps_target_identity:0:12}"
}

# Clone the active workspace into a target-generation candidate and pair both
# generations with immutable boot kits. Optional arguments 7 and 8 provide the
# predecessor kernel/initramfs when that kit has not already been staged.
# Success with state=candidate retains FD 9 so the caller can pass it to QEMU.
qemu_persistent_storage_prepare_update() {
  local qps_target_identity=${1:-}
  local qps_target_source_sha=${2:-}
  local qps_target_source_bytes=${3:-}
  local qps_target_working_bytes=${4:-}
  local qps_target_kernel=${5:-}
  local qps_target_initramfs=${6:-}
  local qps_active_kernel=${7:-}
  local qps_active_initramfs=${8:-}
  local qps_status=0

  _qps_reset_update_outputs
  _qps_validate_update_target_arguments \
    "$qps_target_identity" "$qps_target_source_sha" \
    "$qps_target_source_bytes" "$qps_target_working_bytes" || return 1
  _qps_prepare_state_root || return 1
  _qps_acquire_lock current || return 1
  if _qps_prepare_update_locked \
    "$qps_target_identity" "$qps_target_source_sha" \
    "$qps_target_source_bytes" "$qps_target_working_bytes" \
    "$qps_target_kernel" "$qps_target_initramfs" \
    "$qps_active_kernel" "$qps_active_initramfs"; then
    :
  else
    qps_status=$?
  fi
  if (( qps_status != 0 )) || \
     [[ $QEMU_PERSISTENT_STORAGE_UPDATE_STATE != candidate ]]; then
    qemu_persistent_storage_release_lock
  else
    QEMU_SELECTED_DISK=$QEMU_PERSISTENT_STORAGE_CANDIDATE_DISK
    QEMU_SELECTED_STORAGE_MODE=persistent
    QEMU_PERSISTENT_STORAGE_DIRECTORY=${QEMU_PERSISTENT_STORAGE_CANDIDATE_DISK%/*}
    QEMU_PERSISTENT_STORAGE_IDENTITY=$QEMU_PERSISTENT_STORAGE_CANDIDATE_IDENTITY
  fi
  return "$qps_status"
}

_qps_ensure_current_lock() {
  local qps_expected="$QEMU_PERSISTENT_STORAGE_LOCKS_ROOT/current.lock"

  if _qps_lock_fd_is_open; then
    [[ $QEMU_PERSISTENT_STORAGE_LOCK_PATH == "$qps_expected" ]] || {
      _qps_fail 'a different persistent workspace lock is already held'
      return 1
    }
    _qps_lock_fd_matches_path "$qps_expected" || {
      _qps_fail 'the held persistent workspace lock is no longer valid'
      return 1
    }
    return 0
  fi
  _qps_acquire_lock current
}

# Publish a prepared candidate only after the caller proves guest health by
# returning the exact private token exposed by prepare_update.
qemu_persistent_storage_commit_update() {
  local qps_health_token=${1:-}
  local qps_transaction=''
  local qps_current=''
  local qps_status=0

  _qps_is_identity "$qps_health_token" || {
    _qps_fail 'update commit requires the exact 64-character health token'
    return 1
  }
  _qps_prepare_state_root || return 1
  _qps_ensure_current_lock || return 1
  qps_transaction="$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT/current"
  qps_current="$QEMU_PERSISTENT_STORAGE_DISKS_ROOT/current"

  if _qps_recover_update_transaction; then
    :
  else
    qps_status=$?
  fi
  if (( qps_status != 0 )); then
    :
  elif [[ ! -e $qps_transaction || -L $qps_transaction ]]; then
    _qps_fail 'there is no prepared generational update to commit'
    qps_status=1
  elif _qps_validate_stable_update_transaction "$qps_transaction"; then
    if [[ $QPS_UPDATE_STATE == committed ]]; then
      [[ $QPS_UPDATE_HEALTH_TOKEN == "$qps_health_token" ]] || {
        _qps_fail 'update health token does not match the committed transaction'
        qps_status=1
      }
    elif [[ $QPS_UPDATE_HEALTH_TOKEN != "$qps_health_token" ]]; then
      _qps_fail 'update health token does not match the prepared candidate'
      qps_status=1
    elif _qps_write_update_state "$qps_transaction" committing; then
      if _qps_recover_update_transaction; then
        :
      else
        qps_status=$?
      fi
    else
      qps_status=$?
    fi
  else
    qps_status=$?
  fi
  if (( qps_status == 0 )); then
    _qps_load_update_outputs || qps_status=$?
  fi
  qemu_persistent_storage_release_lock
  return "$qps_status"
}

# Cancel an uncommitted candidate, or restore the retained predecessor after a
# commit. The active disk is never deleted; the failed target is detached only
# after the predecessor is back at disks/current.
qemu_persistent_storage_rollback_update() {
  local qps_transaction=''
  local qps_status=0

  _qps_prepare_state_root || return 1
  _qps_ensure_current_lock || return 1
  qps_transaction="$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT/current"
  if _qps_recover_update_transaction; then
    :
  else
    qps_status=$?
  fi
  if (( qps_status != 0 )); then
    :
  elif [[ ! -e $qps_transaction && ! -L $qps_transaction ]]; then
    _qps_fail 'there is no generational update to roll back'
    qps_status=1
  elif _qps_validate_stable_update_transaction "$qps_transaction"; then
    if [[ $QPS_UPDATE_STATE == prepared ]]; then
      if _qps_discard_update_transaction "$qps_transaction" cancelled; then
        _qps_error 'cancelled the prepared generational update; active disk was unchanged'
      else
        qps_status=$?
      fi
    elif _qps_write_update_state "$qps_transaction" rolling-back; then
      if _qps_finish_rolling_back_update "$qps_transaction"; then
        :
      else
        qps_status=$?
      fi
    else
      qps_status=$?
    fi
  else
    qps_status=$?
  fi
  if (( qps_status == 0 )); then
    _qps_load_update_outputs || qps_status=$?
  fi
  qemu_persistent_storage_release_lock
  return "$qps_status"
}

_qps_validate_prunable_cache_file() {
  local qps_path=$1
  local qps_label=$2
  local qps_expected_bytes=${3:-}
  local qps_magic=''

  _qps_assert_private_regular_file "$qps_path" "$qps_label" || return 1
  if [[ -n $qps_expected_bytes && $(_qps_size "$qps_path") != "$qps_expected_bytes" ]]; then
    _qps_fail "$qps_label has an unexpected size; leaving it untouched"
    return 1
  fi
  qps_magic=$(/usr/bin/od -An -tx1 -j 1080 -N 2 "$qps_path" | tr -d '[:space:]') || return 1
  [[ $qps_magic == 53ef ]] || {
    _qps_fail "$qps_label is not a recognized ext4 cache; leaving it untouched"
    return 1
  }
}

# Immutable factory and update images are disposable caches, but another app
# process may still be materializing one before it takes the workspace lock.
# Take the matching cache lock without waiting, validate the exact private file,
# and treat every cleanup failure as non-fatal to the already-committed VM.
_qps_prune_image_cache_best_effort() {
  local qps_identity=$1
  local qps_cache_kind=$2
  local qps_expected_bytes=${3:-}
  local qps_path=''
  local qps_lock_path=''
  local qps_label=''

  _qps_is_identity "$qps_identity" || return 0
  case "$qps_cache_kind" in
    factory)
      qps_path="$QEMU_PERSISTENT_STORAGE_IMAGES_ROOT/$qps_identity.ext4"
      qps_lock_path="$QEMU_PERSISTENT_STORAGE_LOCKS_ROOT/$qps_identity.image.lock"
      qps_label='obsolete factory-image cache'
      ;;
    update)
      qps_path="$QEMU_PERSISTENT_STORAGE_IMAGES_ROOT/$qps_identity.update.ext4"
      qps_lock_path="$QEMU_PERSISTENT_STORAGE_LOCKS_ROOT/$qps_identity.update-image.lock"
      qps_label='obsolete update-image cache'
      ;;
    *) return 0 ;;
  esac

  [[ -e $qps_path || -L $qps_path ]] || return 0
  if { true >&8; } 2>/dev/null; then
    _qps_error "left $qps_label untouched because file descriptor 8 is in use"
    return 0
  fi
  if [[ -e $qps_lock_path || -L $qps_lock_path ]]; then
    _qps_assert_private_regular_file "$qps_lock_path" 'cache cleanup lock' || return 0
  fi
  if exec 8>>"$qps_lock_path"; then
    :
  else
    _qps_error "could not open cache cleanup lock; left $qps_path untouched"
    return 0
  fi
  if ! chmod 600 "$qps_lock_path" || \
     ! _qps_assert_private_regular_file "$qps_lock_path" 'cache cleanup lock' || \
     ! /usr/bin/lockf -s -t 0 8; then
    exec 8>&-
    _qps_error "cache is busy or unsafe; left $qps_path untouched"
    return 0
  fi

  if ! _qps_validate_prunable_cache_file \
      "$qps_path" "$qps_label" "$qps_expected_bytes"; then
    exec 8>&-
    return 0
  fi
  if /bin/rm -f -- "$qps_path"; then
    _qps_fsync "$QEMU_PERSISTENT_STORAGE_IMAGES_ROOT" || true
    _qps_error "pruned $qps_label ${qps_identity:0:12}"
  else
    _qps_error "could not prune $qps_label; the committed VM remains healthy"
  fi
  exec 8>&-
  return 0
}

_qps_prune_boot_kit_best_effort() {
  local qps_identity=$1
  local qps_kernel_bytes=$2
  local qps_kernel_sha=$3
  local qps_initramfs_bytes=$4
  local qps_initramfs_sha=$5
  local qps_label=$6
  local qps_directory="$QEMU_PERSISTENT_STORAGE_BOOT_ROOT/$qps_identity"

  _qps_is_identity "$qps_identity" || return 0
  [[ -e $qps_directory || -L $qps_directory ]] || return 0
  if ! _qps_validate_boot_kit_directory \
      "$qps_directory" "$qps_identity" || \
     [[ $QPS_BOOT_KERNEL_BYTES != "$qps_kernel_bytes" || \
        $QPS_BOOT_KERNEL_SHA != "$qps_kernel_sha" || \
        $QPS_BOOT_INITRAMFS_BYTES != "$qps_initramfs_bytes" || \
        $QPS_BOOT_INITRAMFS_SHA != "$qps_initramfs_sha" ]]; then
    _qps_error "left the $qps_label boot kit untouched because it was not recognized"
    return 0
  fi
  if /bin/rm -rf "$qps_directory"; then
    _qps_fsync "$QEMU_PERSISTENT_STORAGE_BOOT_ROOT" || true
    _qps_error "pruned $qps_label boot kit ${qps_identity:0:12}"
  else
    _qps_error "could not prune the $qps_label boot kit; the active VM remains healthy"
  fi
  return 0
}

_qps_prune_predecessor_boot_kit_best_effort() {
  [[ $QPS_UPDATE_FROM_BOOT_AVAILABLE == true ]] || return 0
  [[ $QPS_UPDATE_FROM_IDENTITY != "$QPS_UPDATE_TARGET_IDENTITY" ]] || return 0
  _qps_prune_boot_kit_best_effort \
    "$QPS_UPDATE_FROM_IDENTITY" \
    "$QPS_UPDATE_FROM_KERNEL_BYTES" "$QPS_UPDATE_FROM_KERNEL_SHA" \
    "$QPS_UPDATE_FROM_INITRAMFS_BYTES" "$QPS_UPDATE_FROM_INITRAMFS_SHA" \
    predecessor
}

_qps_prune_replaced_candidate_caches_best_effort() {
  local qps_from_identity=$QPS_UPDATE_FROM_IDENTITY
  local qps_target_identity=$QPS_UPDATE_TARGET_IDENTITY
  local qps_target_kernel_bytes=$QPS_UPDATE_TARGET_KERNEL_BYTES
  local qps_target_kernel_sha=$QPS_UPDATE_TARGET_KERNEL_SHA
  local qps_target_initramfs_bytes=$QPS_UPDATE_TARGET_INITRAMFS_BYTES
  local qps_target_initramfs_sha=$QPS_UPDATE_TARGET_INITRAMFS_SHA

  _qps_prune_image_cache_best_effort "$qps_target_identity" update
  if [[ $qps_target_identity != "$qps_from_identity" ]]; then
    _qps_prune_boot_kit_best_effort \
      "$qps_target_identity" \
      "$qps_target_kernel_bytes" "$qps_target_kernel_sha" \
      "$qps_target_initramfs_bytes" "$qps_target_initramfs_sha" \
      replaced-candidate
  fi
  return 0
}

_qps_prune_finalized_update_caches_best_effort() {
  # Never remove the active target's factory source. If an unusual update keeps
  # the same identity, that rule also protects the shared predecessor path.
  if [[ $QPS_UPDATE_FROM_IDENTITY != "$QPS_UPDATE_TARGET_IDENTITY" ]]; then
    _qps_prune_image_cache_best_effort \
      "$QPS_UPDATE_FROM_IDENTITY" factory "$QPS_UPDATE_FROM_SOURCE_BYTES"
    _qps_prune_image_cache_best_effort "$QPS_UPDATE_FROM_IDENTITY" update
    _qps_prune_predecessor_boot_kit_best_effort
  fi
  # The target update payload has already been applied and health-checked. Its
  # factory image, if materialized, remains available for explicit reset.
  _qps_prune_image_cache_best_effort "$QPS_UPDATE_TARGET_IDENTITY" update
  return 0
}

_qps_finalize_committed_update_locked() {
  local qps_transaction=$1
  local qps_reason=$2
  local qps_target_identity=''

  _qps_validate_stable_update_transaction "$qps_transaction" || return 1
  [[ $QPS_UPDATE_STATE == committed ]] || {
    _qps_fail 'an uncommitted update cannot be finalized'
    return 1
  }
  qps_target_identity=$QPS_UPDATE_TARGET_IDENTITY
  _qps_discard_update_transaction "$qps_transaction" "$qps_reason" || return 1
  if [[ $qps_reason == superseded ]]; then
    _qps_error \
      "retired the previous rollback before updating ${qps_target_identity:0:12} again"
  else
    _qps_error "finalized generational update ${qps_target_identity:0:12}"
  fi
  _qps_prune_finalized_update_caches_best_effort || true
  _qps_load_update_outputs || return 1
  QEMU_PERSISTENT_STORAGE_UPDATE_STATE=none
}

# Remove the retained predecessor only after a committed generation has passed
# any desired post-boot soak period. This operation never removes disks/current.
qemu_persistent_storage_finalize_update() {
  local qps_transaction=''
  local qps_status=0

  _qps_prepare_state_root || return 1
  _qps_ensure_current_lock || return 1
  qps_transaction="$QEMU_PERSISTENT_STORAGE_UPDATES_ROOT/current"
  if _qps_recover_update_transaction; then
    :
  else
    qps_status=$?
  fi
  if (( qps_status != 0 )); then
    :
  elif [[ ! -e $qps_transaction || -L $qps_transaction ]]; then
    _qps_fail 'there is no committed generational update to finalize'
    qps_status=1
  elif _qps_finalize_committed_update_locked "$qps_transaction" finalized; then
    :
  else
    qps_status=$?
  fi
  qemu_persistent_storage_release_lock
  return "$qps_status"
}

_qps_reset_remaining_legacy_workspaces() {
  local qps_candidate=''
  local qps_candidate_name=''
  local qps_discarded=''
  local qps_removed_count=0

  for qps_candidate in "$QEMU_PERSISTENT_STORAGE_DISKS_ROOT"/*; do
    [[ -d $qps_candidate && ! -L $qps_candidate ]] || continue
    qps_candidate_name=${qps_candidate##*/}
    [[ $qps_candidate_name =~ ^[0-9a-f]{64}$ ]] || continue
    if ! _qps_validate_recorded_workspace "$qps_candidate" || \
      [[ $QPS_METADATA_IDENTITY != "$qps_candidate_name" ]]; then
      _qps_error "leaving unrecognized legacy workspace untouched during reset: $qps_candidate_name"
      continue
    fi

    _qps_acquire_legacy_lock "$qps_candidate_name" || return 1
    if ! _qps_validate_recorded_workspace "$qps_candidate" || \
      [[ $QPS_METADATA_IDENTITY != "$qps_candidate_name" ]]; then
      _qps_release_legacy_lock
      _qps_fail 'a legacy workspace changed before it could be reset'
      return 1
    fi

    qps_discarded="$QEMU_PERSISTENT_STORAGE_DISKS_ROOT/.current.discarded.legacy.${qps_candidate_name}.$$.$RANDOM$RANDOM"
    [[ ! -e $qps_discarded && ! -L $qps_discarded ]] || {
      _qps_release_legacy_lock
      _qps_fail 'cannot allocate legacy reset transaction name'
      return 1
    }
    if ! /bin/mv "$qps_candidate" "$qps_discarded" || \
      ! _qps_fsync "$QEMU_PERSISTENT_STORAGE_DISKS_ROOT" || \
      ! _qps_remove_recorded_directory "$qps_discarded"; then
      _qps_release_legacy_lock
      _qps_fail "cannot reset legacy workspace $qps_candidate_name"
      return 1
    fi
    _qps_release_legacy_lock
    ((qps_removed_count += 1))
  done

  if (( qps_removed_count > 0 )); then
    _qps_error "reset $qps_removed_count additional legacy workspace(s)"
  fi
}

_qps_has_recognized_legacy_workspace() {
  local qps_candidate=''
  local qps_candidate_name=''

  for qps_candidate in "$QEMU_PERSISTENT_STORAGE_DISKS_ROOT"/*; do
    [[ -d $qps_candidate && ! -L $qps_candidate ]] || continue
    qps_candidate_name=${qps_candidate##*/}
    [[ $qps_candidate_name =~ ^[0-9a-f]{64}$ ]] || continue
    if _qps_validate_recorded_workspace "$qps_candidate" && \
      [[ $QPS_METADATA_IDENTITY == "$qps_candidate_name" ]]; then
      return 0
    fi
  done
  return 1
}

_qps_migrate_legacy_single_workspace() {
  local qps_mode=$1
  local qps_identity=$2
  local qps_source_sha=$3
  local qps_source_bytes=$4
  local qps_working_bytes=$5
  local qps_final="$QEMU_PERSISTENT_STORAGE_DISKS_ROOT/current"
  local qps_candidate=''
  local qps_candidate_mtime=''
  local qps_candidate_name=''
  local qps_selected=''
  local qps_selected_name=''
  local qps_selected_is_exact=0
  local qps_selected_mtime=-1
  local qps_count=0
  local qps_valid_count=0
  local qps_exact_invalid=0

  if [[ -e $qps_final || -L $qps_final ]]; then
    _qps_validate_recorded_workspace "$qps_final" || return 1
    if [[ $qps_mode == persistent ]] && \
      _qps_has_recognized_legacy_workspace; then
      _qps_incompatible \
        'multiple saved VMs were found; use Reset Omarchy to return to one supported disk'
      return $?
    fi
    return 0
  fi
  for qps_candidate in "$QEMU_PERSISTENT_STORAGE_DISKS_ROOT"/*; do
    [[ -d $qps_candidate && ! -L $qps_candidate ]] || continue
    qps_candidate_name=${qps_candidate##*/}
    [[ $qps_candidate_name =~ ^[0-9a-f]{64}$ ]] || continue
    ((qps_count += 1))
    if ! _qps_validate_recorded_workspace "$qps_candidate"; then
      [[ $qps_candidate_name != "$qps_identity" ]] || qps_exact_invalid=1
      _qps_error "leaving invalid legacy workspace $qps_candidate_name untouched"
      continue
    fi
    if [[ $QPS_METADATA_IDENTITY != "$qps_candidate_name" ]]; then
      [[ $qps_candidate_name != "$qps_identity" ]] || qps_exact_invalid=1
      _qps_error "leaving legacy workspace with mismatched metadata untouched: $qps_candidate_name"
      continue
    fi
    ((qps_valid_count += 1))
    if (( QPS_RECORDED_EXISTING_BYTES > qps_working_bytes )); then
      [[ $qps_candidate_name != "$qps_identity" ]] || qps_exact_invalid=1
      _qps_error "leaving oversized legacy workspace untouched: $qps_candidate_name"
      continue
    fi
    qps_candidate_mtime=$(stat -f '%m' "$qps_candidate/rootfs.ext4" 2>/dev/null)
    [[ $qps_candidate_mtime =~ ^[0-9]+$ ]] || {
      [[ $qps_candidate_name != "$qps_identity" ]] || qps_exact_invalid=1
      _qps_error "leaving legacy workspace with an unreadable modification time untouched: $qps_candidate_name"
      continue
    }
    if [[ $qps_mode == persistent ]]; then
      if [[ $qps_candidate_name == "$qps_identity" && \
            $QPS_METADATA_SCHEMA == "$QEMU_PERSISTENT_STORAGE_SCHEMA" && \
            $QPS_METADATA_SOURCE_SHA == "$qps_source_sha" && \
            $QPS_METADATA_SOURCE_BYTES == "$qps_source_bytes" ]]; then
        qps_selected=$qps_candidate
        qps_selected_mtime=$qps_candidate_mtime
        qps_selected_is_exact=1
      elif (( qps_selected_is_exact == 0 )) && \
        { (( qps_candidate_mtime > qps_selected_mtime )) || \
          { (( qps_candidate_mtime == qps_selected_mtime )) && \
            [[ -z $qps_selected || $qps_candidate < $qps_selected ]]; }; }; then
        # A sole valid older workspace is safe to relocate into `current` even
        # though it still requires a generational content update. Several valid
        # workspaces remain ambiguous and are rejected below.
        qps_selected=$qps_candidate
        qps_selected_mtime=$qps_candidate_mtime
      fi
    elif [[ $qps_candidate_name == "$qps_identity" ]]; then
      qps_selected=$qps_candidate
      qps_selected_mtime=$qps_candidate_mtime
      qps_selected_is_exact=1
    elif (( qps_selected_is_exact == 0 )) && \
      { (( qps_candidate_mtime > qps_selected_mtime )) || \
        { (( qps_candidate_mtime == qps_selected_mtime )) && \
          [[ -z $qps_selected || $qps_candidate < $qps_selected ]]; }; }; then
      qps_selected=$qps_candidate
      qps_selected_mtime=$qps_candidate_mtime
    fi
  done
  ((qps_count > 0)) || return 0
  ((qps_exact_invalid == 0)) || {
    _qps_fail 'the legacy workspace for this app build is not safe to migrate'
    return 1
  }
  if [[ $qps_mode == persistent && $qps_valid_count -gt 1 ]]; then
    _qps_incompatible \
      'multiple saved VMs were found; use Reset Omarchy to return to one supported disk'
    return $?
  fi
  [[ -n $qps_selected ]] || {
    _qps_fail 'legacy Omarchy disks were found, but none are safe to migrate or reset'
    return 1
  }

  qps_selected_name=${qps_selected##*/}
  _qps_acquire_legacy_lock "$qps_selected_name" || return 1
  if ! _qps_validate_recorded_workspace "$qps_selected" || \
    [[ $QPS_METADATA_IDENTITY != "$qps_selected_name" ]] || \
    (( QPS_RECORDED_EXISTING_BYTES > qps_working_bytes )) || \
    { [[ $qps_mode == persistent && $qps_selected_is_exact == 1 ]] && \
      { [[ $QPS_METADATA_SCHEMA != "$QEMU_PERSISTENT_STORAGE_SCHEMA" ]] || \
        [[ $QPS_METADATA_IDENTITY != "$qps_identity" ]] || \
        [[ $QPS_METADATA_SOURCE_SHA != "$qps_source_sha" ]] || \
        [[ $QPS_METADATA_SOURCE_BYTES != "$qps_source_bytes" ]]; }; }; then
    _qps_release_legacy_lock
    _qps_fail 'the selected legacy workspace changed before it could be migrated'
    return 1
  fi
  /bin/mv "$qps_selected" "$qps_final" || {
    _qps_release_legacy_lock
    _qps_fail 'cannot migrate the existing VM disk into the single user workspace'
    return 1
  }
  if ! _qps_fsync "$QEMU_PERSISTENT_STORAGE_DISKS_ROOT"; then
    _qps_release_legacy_lock
    return 1
  fi
  _qps_release_legacy_lock
  if (( qps_count > 1 )); then
    _qps_error "migrated legacy workspace $qps_selected_name and preserved $((qps_count - 1)) other workspace(s)"
  else
    _qps_error 'migrated the existing VM disk into the single user workspace'
  fi
}

_qps_select_persistent_disk() {
  local qps_mode=$1
  local qps_identity=$2
  local qps_source=$3
  local qps_source_sha=$4
  local qps_source_bytes=$5
  local qps_working_bytes=$6
  local qps_final=''
  local qps_status=0
  local qps_storage_key='current'

  _qps_prepare_state_root || return 1
  case "${OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK:-0}" in
    0) ;;
    1) qps_storage_key=$qps_identity ;;
    *)
      _qps_fail 'OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK must be 0 or 1'
      return 1
      ;;
  esac
  _qps_acquire_lock "$qps_storage_key" || return 1
  QEMU_PERSISTENT_STORAGE_IDENTITY=$qps_identity
  qps_final="$QEMU_PERSISTENT_STORAGE_DISKS_ROOT/$qps_storage_key"

  if [[ $qps_storage_key == current ]]; then
    if ! _qps_recover_update_transaction; then
      qemu_persistent_storage_release_lock
      return 1
    fi
    if [[ $qps_mode == reset && \
          ( -e $QEMU_PERSISTENT_STORAGE_UPDATES_ROOT/current || \
            -L $QEMU_PERSISTENT_STORAGE_UPDATES_ROOT/current ) ]]; then
      qemu_persistent_storage_release_lock
      _qps_fail 'roll back or finalize the generational update before resetting storage'
      return 1
    fi
    if _qps_migrate_legacy_single_workspace \
      "$qps_mode" "$qps_identity" "$qps_source_sha" "$qps_source_bytes" \
      "$qps_working_bytes"; then
      :
    else
      qps_status=$?
      qemu_persistent_storage_release_lock
      return "$qps_status"
    fi
  fi

  _qps_reap_interrupted_work "$qps_storage_key"
  if [[ $qps_mode == reset ]]; then
    if ! _qps_reset_persistent_disk "$qps_storage_key"; then
      qemu_persistent_storage_release_lock
      return 1
    fi
    if [[ $qps_storage_key == current ]] && \
      ! _qps_reset_remaining_legacy_workspaces; then
      qemu_persistent_storage_release_lock
      return 1
    fi
  elif [[ -e $qps_final || -L $qps_final ]]; then
    if _qps_require_compatible_workspace \
      "$qps_final" "$qps_identity" "$qps_source_sha" "$qps_source_bytes" \
      "$qps_working_bytes"; then
      :
    else
      qps_status=$?
      qemu_persistent_storage_release_lock
      return "$qps_status"
    fi
  fi
  if [[ ! -e $qps_final && ! -L $qps_final ]]; then
    if ! _qps_initialize_persistent_disk \
      "$qps_identity" "$qps_storage_key" "$qps_source" "$qps_source_sha" \
      "$qps_source_bytes" "$qps_working_bytes"; then
      qemu_persistent_storage_release_lock
      return 1
    fi
  fi
  if ! _qps_validate_store_directory \
    "$qps_final" "$qps_identity" "$qps_source_sha" "$qps_source_bytes" \
    "$qps_working_bytes"; then
    qemu_persistent_storage_release_lock
    return 1
  fi
  [[ $(_qps_file_identity "$qps_final/rootfs.ext4") != $(_qps_file_identity "$qps_source") ]] || {
    qemu_persistent_storage_release_lock
    _qps_fail 'persistent root disk aliases the immutable source disk'
    return 1
  }

  QEMU_SELECTED_DISK="$qps_final/rootfs.ext4"
  QEMU_SELECTED_STORAGE_MODE=persistent
  QEMU_PERSISTENT_STORAGE_DIRECTORY=$qps_final
  if [[ $qps_storage_key == current ]]; then
    _qps_load_update_outputs || {
      qemu_persistent_storage_release_lock
      return 1
    }
  fi
}

_qps_select_ephemeral_disk() {
  local qps_source=$1
  local qps_source_bytes=$2
  local qps_work_directory=$3
  local qps_working_bytes=${4:-$qps_source_bytes}
  local qps_final="$qps_work_directory/rootfs.ext4"
  local qps_staging="$qps_work_directory/.rootfs.ext4.initializing.$$.$RANDOM$RANDOM"

  _qps_assert_private_directory "$qps_work_directory" 'ephemeral work directory' || return 1
  [[ ! -e $qps_final && ! -L $qps_final ]] || {
    _qps_fail "ephemeral root disk already exists: $qps_final"
    return 1
  }
  if ! _qps_clone_disk "$qps_source" "$qps_staging" "$qps_source_bytes"; then
    [[ ! -e $qps_staging && ! -L $qps_staging ]] || /bin/rm -f "$qps_staging"
    return 1
  fi
  if ! _qps_expand_disk "$qps_staging" "$qps_source_bytes" "$qps_working_bytes"; then
    [[ ! -e $qps_staging && ! -L $qps_staging ]] || /bin/rm -f "$qps_staging"
    return 1
  fi
  /bin/mv "$qps_staging" "$qps_final" || {
    _qps_fail 'cannot publish ephemeral root disk'
    return 1
  }
  _qps_fsync "$qps_work_directory" || return 1

  QEMU_SELECTED_DISK=$qps_final
  QEMU_SELECTED_STORAGE_MODE=ephemeral
  QEMU_PERSISTENT_STORAGE_DIRECTORY=''
  QEMU_PERSISTENT_STORAGE_IDENTITY=''
}

# Select and prepare a QEMU root disk.
#
# Arguments:
#   1. mode: persistent (default lifecycle), reset, or ephemeral
#   2. exact 64-character lowercase guest-manifest SHA-256
#   3. validated immutable source rootfs path
#   4. validated source-rootfs SHA-256 from the manifest
#   5. source-rootfs byte count from the manifest
#   6. private run directory (required only for ephemeral mode)
#   7. working rootfs byte count (optional; defaults to source size)
#
# On success, QEMU_SELECTED_DISK and QEMU_SELECTED_STORAGE_MODE are populated.
# Persistent/reset mode also holds FD 9 until the caller exits or explicitly
# calls qemu_persistent_storage_release_lock.
qemu_persistent_storage_select() {
  local qps_mode=${1:-}
  local qps_identity=${2:-}
  local qps_source=${3:-}
  local qps_source_sha=${4:-}
  local qps_source_bytes=${5:-}
  local qps_work_directory=${6:-}
  local qps_working_bytes=${7:-$qps_source_bytes}

  QEMU_SELECTED_DISK=''
  QEMU_SELECTED_STORAGE_MODE=''
  QEMU_PERSISTENT_STORAGE_DIRECTORY=''
  QEMU_PERSISTENT_STORAGE_IDENTITY=''
  QEMU_PERSISTENT_STORAGE_LOCK_PATH=''
  QEMU_PERSISTENT_STORAGE_WORKING_BYTES=''
  _qps_reset_update_outputs

  case "$qps_mode" in
    persistent|reset|ephemeral) ;;
    *)
      _qps_fail "storage mode must be persistent, reset, or ephemeral"
      return 1
      ;;
  esac
  _qps_is_identity "$qps_identity" || {
    _qps_fail 'bundle identity must be exactly 64 lowercase hexadecimal characters'
    return 1
  }
  _qps_is_identity "$qps_source_sha" || {
    _qps_fail 'source rootfs digest must be exactly 64 lowercase hexadecimal characters'
    return 1
  }
  _qps_is_positive_integer "$qps_source_bytes" || {
    _qps_fail 'source rootfs byte count must be a positive integer'
    return 1
  }
  _qps_is_positive_integer "$qps_working_bytes" || {
    _qps_fail 'working rootfs byte count must be a positive integer'
    return 1
  }
  (( qps_working_bytes >= qps_source_bytes )) || {
    _qps_fail 'working rootfs byte count cannot be smaller than the source'
    return 1
  }
  _qps_assert_source_disk "$qps_source" "$qps_source_bytes" || return 1
  QEMU_PERSISTENT_STORAGE_WORKING_BYTES=$qps_working_bytes

  if [[ $qps_mode == ephemeral ]]; then
    _qps_select_ephemeral_disk \
      "$qps_source" "$qps_source_bytes" "$qps_work_directory" "$qps_working_bytes"
  else
    _qps_select_persistent_disk \
      "$qps_mode" "$qps_identity" "$qps_source" "$qps_source_sha" \
      "$qps_source_bytes" "$qps_working_bytes"
  fi
}
