#!/bin/bash

# Copy the saved Omarchy VM into an empty APFS folder.
#
# The copy is a valid workspace: the start menu can open it via VM Location.
# Factory images are not copied; the matching Try Omarchy build rematerializes
# them. Quit Try Omarchy first so the workspace lock is free.

set -euo pipefail

usage() {
  echo "Usage: macos/backup-qemu-storage.sh DEST" >&2
  echo "DEST must be an empty folder on a local APFS volume, or a path that can be created as one." >&2
  exit 64
}

fail() {
  echo "backup-qemu-storage: $*" >&2
  exit 1
}

(( $# == 1 )) || usage
dest=$1
[[ $dest != *$'\n'* && $dest != *$'\r'* && -n $dest ]] || {
  fail 'destination must be a single-line path'
}
if [[ $dest != /* ]]; then
  dest="$PWD/$dest"
fi

script_dir=$(cd "$(dirname "$0")" && pwd -P)
storage_library="$script_dir/qemu-persistent-storage.sh"
[[ -f $storage_library && ! -L $storage_library ]] || {
  fail "persistent-storage library is missing or unsafe: $storage_library"
}

if [[ ! -e $dest && ! -L $dest ]]; then
  mkdir -p "$dest" || fail "cannot create backup destination: $dest"
  chmod 700 "$dest" || fail "cannot protect backup destination: $dest"
fi

# shellcheck source=qemu-persistent-storage.sh
source "$storage_library"
qemu_persistent_storage_backup "$dest"
echo "Backup complete: $QEMU_PERSISTENT_STORAGE_BACKUP_ROOT"
