#!/bin/sh

# Schema 0 predates the installed ownership manifest. The signed initramfs
# helper performs the same exact convergence used by every later release.

set -eu

[ "$#" -eq 3 ] || exit 64
mode=$1
candidate_root=$2
update_mount=$3
owned_payload_runner=${TRY_OMARCHY_OWNED_PAYLOAD_RUNNER:-/try-omarchy-update/owned-payload}
[ -f "$owned_payload_runner" ] && [ ! -L "$owned_payload_runner" ] \
  && [ -x "$owned_payload_runner" ] || exit 1

release_id=$(sed -n \
  's/^.*"releaseId":"\([0-9a-f][0-9a-f]*\)".*$/\1/p' \
  "$update_mount/target-state.json")
case "$release_id" in *[!0-9a-f]*|'') exit 1 ;; esac
[ "${#release_id}" -eq 64 ] || exit 1

# SDDM's package transaction can remove the owner provisioner's generated
# autologin file. It is mutable machine state, so it intentionally is not in
# the release-owned payload. Restore only the exact safe form emitted by the
# provisioner from the pre-transaction /etc snapshot.
autologin_source="$candidate_root/var/lib/try-omarchy/preserved/$release_id/original-etc/sddm.conf.d/autologin.conf"
autologin_destination="$candidate_root/etc/sddm.conf.d/autologin.conf"
autologin_cleanup_unit="$candidate_root/etc/systemd/system/omarchy-provision-autologin-once.service"
autologin_cleanup_link="$candidate_root/etc/systemd/system/graphical.target.wants/omarchy-provision-autologin-once.service"

validate_autologin_source() {
  [ -e "$autologin_source" ] || [ -L "$autologin_source" ] || return 2
  [ -f "$autologin_source" ] && [ ! -L "$autologin_source" ] || return 1
  [ "$(wc -c <"$autologin_source")" -le 1024 ] || return 1
  autologin_user=$(sed -n 's/^User=\([a-z_][a-z0-9_-]*\)$/\1/p' \
    "$autologin_source")
  case "$autologin_user" in ''|*[!a-z0-9_-]*) return 1 ;; esac
  [ "$(cat "$autologin_source")" = "[Autologin]
User=$autologin_user
Session=omarchy.desktop" ]
}

verify_autologin() {
  if validate_autologin_source; then
    [ -f "$autologin_destination" ] \
      && [ ! -L "$autologin_destination" ] \
      && cmp -s "$autologin_source" "$autologin_destination" \
      && [ ! -e "$autologin_cleanup_unit" ] \
      && [ ! -L "$autologin_cleanup_unit" ] \
      && [ ! -e "$autologin_cleanup_link" ] \
      && [ ! -L "$autologin_cleanup_link" ]
  else
    source_status=$?
    [ "$source_status" -eq 2 ]
  fi
}

restore_autologin() {
  if validate_autologin_source; then
    [ -d "$candidate_root/etc/sddm.conf.d" ] \
      && [ ! -L "$candidate_root/etc/sddm.conf.d" ] || return 1
    if [ -e "$autologin_destination" ] || [ -L "$autologin_destination" ]; then
      [ -f "$autologin_destination" ] \
        && [ ! -L "$autologin_destination" ] || return 1
    fi
    autologin_temporary="$candidate_root/etc/sddm.conf.d/.autologin.conf.try-omarchy-update.$$"
    [ ! -e "$autologin_temporary" ] && [ ! -L "$autologin_temporary" ] \
      || return 1
    cp -p "$autologin_source" "$autologin_temporary" || return 1
    chmod 0644 "$autologin_temporary" || return 1
    mv -f "$autologin_temporary" "$autologin_destination" || return 1
    # A native VM has no LUKS prompt, but its host account already guards the
    # disk. Avoid exposing SDDM's unusable X11 greeter on the VirGL display by
    # keeping the provisioner's direct Omarchy login for native launches.
    rm -f "$autologin_cleanup_link" "$autologin_cleanup_unit"
  else
    source_status=$?
    [ "$source_status" -eq 2 ]
  fi
}

case "$mode" in
  verify)
    "$owned_payload_runner" verify "$candidate_root" "$update_mount" \
      && verify_autologin
    ;;
  apply)
    "$owned_payload_runner" apply "$candidate_root" "$update_mount" \
      && restore_autologin
    ;;
  *) exit 64 ;;
esac
