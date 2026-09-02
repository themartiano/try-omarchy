#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: configure-rootfs.sh --root ROOT [--guest-dir GUEST_DIR] [--spec SPEC]"
}

fail() {
  echo "configure-rootfs: $*" >&2
  exit 1
}

script_dir=$(cd "$(dirname "$0")" && pwd)
guest_dir=$(cd "$script_dir/.." && pwd)
root=""
spec=""

while (($#)); do
  case "$1" in
    --root)
      root=${2:-}
      shift 2
      ;;
    --guest-dir)
      guest_dir=${2:-}
      shift 2
      ;;
    --spec)
      spec=${2:-}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

[[ -n $root ]] || fail "--root is required"
[[ $root == /* ]] || fail "--root must be an absolute path"
case "$root" in
  /|/bin|/boot|/etc|/home|/opt|/root|/usr|/var)
    fail "refusing unsafe root: $root"
    ;;
esac
[[ -d $root/usr/share/omarchy ]] || fail "materialize Omarchy before configuring the rootfs"
[[ -n $spec ]] || spec="$guest_dir/spec.json"
[[ -f $spec ]] || fail "guest spec not found: $spec"

architecture=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["image"]["architecture"])' "$spec")
profile=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["guest"].get("profile"))' "$spec")
[[ $architecture == aarch64 ]] || fail "native guest architecture must be aarch64"
[[ $profile == factory ]] || fail "native guest profile must be factory"

mkdir -p "$root/etc" "$root/etc/skel" "$root/usr/share/try-omarchy"
cp -a "$guest_dir/factory-overlay/." "$root/"

# Session-config customizations are additive, so each fragment remains
# independently auditable against Basecamp's pinned config. The native overlay
# also carries three deliberate command replacements: safe PipeWire input
# switching, VM-aware cursor restoration after the screensaver exits, and
# user-first ordering in the background picker. The display fragment selects
# Cocoa's host-composited cursor path and keeps the guest mode synchronized when
# QEMU changes the virtual EDID.
# The clipboard bridge mirrors the Mac pasteboard into the Wayland session,
# and the Mac folder mount completes the host integration.
cp -a "$guest_dir/native-overlay/." "$root/"
chmod 0755 \
  "$root/usr/bin/omarchy-audio-input-set-default" \
  "$root/usr/bin/omarchy-screensaver" \
  "$root/usr/bin/omarchy-theme-bg-switcher" \
  "$root/usr/local/bin/omarchy-native-audio-bridge" \
  "$root/usr/local/bin/omarchy-native-camera-bridge" \
  "$root/usr/local/bin/omarchy-native-clipboard-bridge" \
  "$root/usr/local/bin/omarchy-native-cursor-restore" \
  "$root/usr/local/bin/omarchy-native-display-sync" \
  "$root/usr/local/bin/omarchy-native-mac-share" \
  "$root/usr/lib/systemd/system-generators/try-omarchy-ssh-access"
for native_command in \
  omarchy-audio-input-set-default \
  omarchy-screensaver \
  omarchy-theme-bg-switcher; do
  source_digest=$(sha256sum "$guest_dir/native-overlay/usr/bin/$native_command")
  source_digest=${source_digest%% *}
  installed_digest=$(sha256sum "$root/usr/bin/$native_command")
  installed_digest=${installed_digest%% *}
  [[ $installed_digest == "$source_digest" ]] || \
    fail "native $native_command did not replace the upstream command"
done
mkdir -p "$root/etc/systemd/user/default.target.wants" \
  "$root/etc/systemd/user/graphical-session.target.wants"
ln -sfn /usr/lib/systemd/user/omarchy-native-audio-bridge.service \
  "$root/etc/systemd/user/default.target.wants/omarchy-native-audio-bridge.service"
ln -sfn /usr/lib/systemd/user/omarchy-native-camera-bridge.service \
  "$root/etc/systemd/user/default.target.wants/omarchy-native-camera-bridge.service"
# The clipboard agent needs the Wayland socket, so it follows the uwsm-managed
# graphical session rather than the plain user manager.
ln -sfn /usr/lib/systemd/user/omarchy-native-clipboard-bridge.service \
  "$root/etc/systemd/user/graphical-session.target.wants/omarchy-native-clipboard-bridge.service"

# The shared Mac folder mounts system-wide at the spec's mount point; at login
# each account links ~/<Mac folder name> to it. QEMU maps the Mac user's files
# to the Omarchy owner account (uid 1000, the first provisioned user).
shared_folder_mount_point=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runtime"]["sharedFolder"]["guestMountPoint"])' "$spec")
[[ $shared_folder_mount_point == /mnt/mac ]] || fail "shared folder mount point must match the link unit"
ln -sfn /usr/lib/systemd/user/omarchy-native-mac-share-link.service \
  "$root/etc/systemd/user/default.target.wants/omarchy-native-mac-share-link.service"
cat "$guest_dir/fragments/hypr-monitors-arm-qemu.append.lua" >>"$root/etc/skel/.config/hypr/monitors.lua"

hostname=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["guest"]["hostname"])' "$spec")
printf '%s\n' "$hostname" >"$root/etc/hostname"
cat >"$root/etc/hosts" <<EOF
127.0.0.1 localhost
::1 localhost
127.0.1.1 $hostname
EOF
printf 'en_US.UTF-8 UTF-8\n' >"$root/etc/locale.gen"
printf 'LANG=en_US.UTF-8\n' >"$root/etc/locale.conf"
printf 'KEYMAP=us\n' >"$root/etc/vconsole.conf"
# An unprovisioned machine receives a new identity from systemd on first boot.
: >"$root/etc/machine-id"
ln -sfn /usr/share/zoneinfo/UTC "$root/etc/localtime"

# Keep the reviewed Arch Linux ARM package and mirror configuration.
pacman_input=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["inputs"].get("pacmanConfig", ""))' "$spec")
[[ -n $pacman_input ]] || fail "native guest spec must provide pacmanConfig"
arm_mirrorlist="$guest_dir/mirrorlist.aarch64"
[[ -f $arm_mirrorlist ]] || fail "ARM mirrorlist not found: $arm_mirrorlist"
install -m 0644 "$guest_dir/$pacman_input" "$root/etc/pacman.conf"
install -m 0644 "$arm_mirrorlist" "$root/etc/pacman.d/mirrorlist"

# Omarchy's channel templates stay authentic. Its supported hook restores the
# final Try Omarchy-owned ARM configuration after a template is copied to /etc
# and before pacman refreshes its databases.
refresh_hook="$guest_dir/fragments/pre-refresh-pacman-restore-arm.sh"
[[ -f $refresh_hook ]] || fail "ARM pacman refresh hook not found: $refresh_hook"
install -d -m 0755 "$root/etc/skel/.config/omarchy/hooks/pre-refresh-pacman.d"
install -m 0755 "$refresh_hook" \
  "$root/etc/skel/.config/omarchy/hooks/pre-refresh-pacman.d/restore-arm-pacman"

provision_unit="$root/usr/share/omarchy/install/provisioning/omarchy-provision-owner.service"
[[ -f $provision_unit ]] || fail "pinned upstream owner-provisioning service is missing"
mkdir -p "$root/etc/systemd/system" "$root/var/lib/omarchy/provisioning"
install -m 0644 "$provision_unit" "$root/etc/systemd/system/omarchy-provision-owner.service"
: >"$root/var/lib/omarchy/provisioning/pending"
printf '%s\n' audio input users video >"$root/var/lib/omarchy/provisioning/groups"

# No persistent logs, random seed, or package cache should ship in the factory image.
rm -rf "$root/var/log/journal" "$root/var/lib/systemd/random-seed"
mkdir -p "$root/var/log" "$root/var/cache/pacman/pkg"
find "$root/var/cache/pacman/pkg" -mindepth 1 -maxdepth 1 -type f -delete 2>/dev/null || true

mkdir -p "$root/usr/local/lib/try-omarchy"
install -m 0755 "$guest_dir/scripts/finalize-rootfs.sh" "$root/usr/local/lib/try-omarchy/finalize-rootfs"
install -m 0644 "$spec" "$root/usr/share/try-omarchy/build-spec.json"

# Record content digests before the user overlay is copied into $HOME. This is
# the machine-readable proof that the compositor/shell runtime came from the
# pinned Omarchy tree rather than a frontend reproduction.
python3 "$guest_dir/scripts/write-provenance.py" \
  --root "$root" \
  --spec "$spec" \
  --output "$root/usr/share/try-omarchy/provenance.json"

echo "Configured Omarchy $profile profile in $root"
