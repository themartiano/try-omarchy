#!/bin/sh

# Schema 0 predates the installed ownership manifest. The signed initramfs
# helper performs the same exact convergence used by every later release.

set -eu

[ "$#" -eq 3 ] || exit 64
owned_payload_runner=${TRY_OMARCHY_OWNED_PAYLOAD_RUNNER:-/try-omarchy-update/owned-payload}
[ -f "$owned_payload_runner" ] && [ ! -L "$owned_payload_runner" ] \
  && [ -x "$owned_payload_runner" ] || exit 1
exec "$owned_payload_runner" "$@"
