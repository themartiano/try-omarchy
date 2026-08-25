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
mkdir -p "$root/usr/local/bin"
install -m 0755 "$guest_dir/compat/ttfx-arm64" "$root/usr/local/bin/ttfx"

# Session-config customizations are additive, so each fragment remains
# independently auditable against Basecamp's pinned config. The native overlay
# also carries one deliberate command replacement for safe PipeWire input
# switching. The display fragment selects Cocoa's host-composited cursor path
# and keeps the guest mode synchronized when QEMU changes the virtual EDID.
cp -a "$guest_dir/native-overlay/." "$root/"
chmod 0755 \
  "$root/usr/bin/omarchy-audio-input-set-default" \
  "$root/usr/local/bin/omarchy-native-audio-bridge" \
  "$root/usr/local/bin/omarchy-native-display-sync"
audio_helper_source_digest=$(sha256sum \
  "$guest_dir/native-overlay/usr/bin/omarchy-audio-input-set-default")
audio_helper_source_digest=${audio_helper_source_digest%% *}
audio_helper_installed_digest=$(sha256sum \
  "$root/usr/bin/omarchy-audio-input-set-default")
audio_helper_installed_digest=${audio_helper_installed_digest%% *}
[[ $audio_helper_installed_digest == "$audio_helper_source_digest" ]] || \
  fail "native audio input helper did not replace the upstream command"
mkdir -p "$root/etc/systemd/user/default.target.wants"
ln -sfn /usr/lib/systemd/user/omarchy-native-audio-bridge.service \
  "$root/etc/systemd/user/default.target.wants/omarchy-native-audio-bridge.service"
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

# omarchy-refresh-pacman copies these templates over /etc. Keep them ARM so an
# update cannot point pacman at x86_64 Omarchy mirrors or drop the local repo.
pacman_templates="$root/usr/share/omarchy/default/pacman"
[[ -d $pacman_templates ]] || fail "Omarchy pacman templates are missing"
{
  cat "$guest_dir/$pacman_input"
  cat <<'EOF'

# Immutable packages assembled from the checksummed Try Omarchy build spec.
[try-omarchy]
SigLevel = Optional TrustAll
Server = file:///usr/share/try-omarchy/repo
EOF
} >"$root/usr/share/try-omarchy/pacman.conf"
install -m 0644 "$arm_mirrorlist" "$root/usr/share/try-omarchy/mirrorlist"
for channel in stable rc edge; do
  install -m 0644 "$root/usr/share/try-omarchy/pacman.conf" "$pacman_templates/pacman-$channel.conf"
  install -m 0644 "$arm_mirrorlist" "$pacman_templates/mirrorlist-$channel"
done
grep -q '^\[multilib\]$' "$root/usr/share/try-omarchy/pacman.conf" &&
  fail "ARM pacman templates must not include multilib"
grep -q '^Server = https://stable-mirror.omarchy.org' "$root/usr/share/try-omarchy/pacman.conf" \
  "$pacman_templates/mirrorlist-stable" &&
  fail "ARM pacman templates must not use Omarchy x86_64 mirrors"
grep -q '^\[try-omarchy\]$' "$root/usr/share/try-omarchy/pacman.conf" ||
  fail "ARM pacman refresh template must keep the local try-omarchy repository"

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
