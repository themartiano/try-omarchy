#!/bin/sh

# The package transaction runs before schema migrations and installs these
# files from the signed offline repository. This migration records and verifies
# the package-only state change; there is no additional mutable state to apply.

set -eu

[ "$#" -eq 3 ] || exit 64
mode=$1
candidate_root=$2

verify_yay() {
  [ -x "$candidate_root/usr/bin/yay" ] \
    && [ -x "$candidate_root/usr/bin/fakeroot" ] \
    && [ -f "$candidate_root/usr/share/licenses/try-omarchy-yay/LICENSE" ] \
    && [ ! -L "$candidate_root/usr/bin/yay" ] \
    && [ ! -L "$candidate_root/usr/share/licenses/try-omarchy-yay/LICENSE" ]
}

case "$mode" in
  verify)
    verify_yay
    ;;
  apply)
    # Pacman owns the payload. The following verify pass will fail closed if
    # the preceding package transaction did not install the expected files.
    :
    ;;
  *)
    exit 64
    ;;
esac
