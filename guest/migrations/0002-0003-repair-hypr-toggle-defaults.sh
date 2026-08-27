#!/bin/sh

# Existing homes are intentionally read-only during offline updates. Converge
# the signed system-owned repair service now; it safely transforms each user's
# affected Hyprland state at their next login.

set -eu

[ "$#" -eq 3 ] || exit 64
mode=$1
candidate_root=$2
update_mount=$3
owned_payload_runner=${TRY_OMARCHY_OWNED_PAYLOAD_RUNNER:-/try-omarchy-update/owned-payload}
[ -f "$owned_payload_runner" ] && [ ! -L "$owned_payload_runner" ] \
  && [ -x "$owned_payload_runner" ] || exit 1

verify_repair_support() {
  [ -x "$candidate_root/usr/local/lib/try-omarchy/user-migrate" ] \
    && [ -f "$candidate_root/usr/share/try-omarchy/user-migrations/0003-hypr-toggle-defaults.tsv" ] \
    && [ ! -L "$candidate_root/usr/share/try-omarchy/user-migrations/0003-hypr-toggle-defaults.tsv" ] \
    && [ -f "$candidate_root/usr/lib/systemd/user/try-omarchy-user-migrate.service" ] \
    && [ ! -L "$candidate_root/usr/lib/systemd/user/try-omarchy-user-migrate.service" ] \
    && [ -L "$candidate_root/etc/systemd/user/default.target.wants/try-omarchy-user-migrate.service" ] \
    && [ "$(readlink "$candidate_root/etc/systemd/user/default.target.wants/try-omarchy-user-migrate.service")" \
      = /usr/lib/systemd/user/try-omarchy-user-migrate.service ]
}

case "$mode" in
  verify)
    "$owned_payload_runner" verify "$candidate_root" "$update_mount" \
      && verify_repair_support
    ;;
  apply)
    "$owned_payload_runner" apply "$candidate_root" "$update_mount"
    ;;
  *)
    exit 64
    ;;
esac
