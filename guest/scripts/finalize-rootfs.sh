#!/bin/bash

# Runs inside the ARM64 Arch root after packages and files are staged.
set -euo pipefail

spec=/usr/share/try-omarchy/build-spec.json
[[ -f $spec ]] || { echo "Missing $spec" >&2; exit 1; }

read_spec() {
  python3 -c "import json; print(json.load(open('$spec'))$1)"
}

[[ $(read_spec '["image"]["architecture"]') == aarch64 ]] || {
  echo "Factory guest must be ARM64" >&2
  exit 1
}
[[ $(read_spec '["guest"].get("profile")') == factory ]] || {
  echo "Factory guest profile is required" >&2
  exit 1
}

locale-gen
passwd --lock root >/dev/null
systemctl enable NetworkManager.service
systemctl enable systemd-resolved.service

# Avoid a systemctl introspection path that crashes under some ARM container
# runtimes after it has already written the link.
ln -sfn /usr/lib/systemd/system/graphical.target /etc/systemd/system/default.target

# Account, password, theme, and per-user state belong to Omarchy's real owner
# provisioning flow on first boot.
[[ -x /usr/bin/omarchy-provision-owner ]] || { echo "Missing upstream owner provisioner" >&2; exit 1; }
[[ -f /var/lib/omarchy/provisioning/pending ]] || { echo "Factory provisioning is not armed" >&2; exit 1; }
expected_mise=$(read_spec '["supplyChain"]["mise"]["reportedVersion"]')
[[ -x /usr/bin/mise ]] || { echo "Missing pinned ARM64 mise" >&2; exit 1; }
[[ $(/usr/bin/mise --version) == "$expected_mise" ]] || { echo "Pinned mise identity mismatch" >&2; exit 1; }
expected_ttfx=$(read_spec '["supplyChain"]["ttfx"]["reportedVersion"]')
[[ -x /usr/bin/ttfx ]] || { echo "Missing pinned ARM64 ttfx" >&2; exit 1; }
[[ $(/usr/bin/ttfx --version) == "$expected_ttfx" ]] || { echo "Pinned ttfx identity mismatch" >&2; exit 1; }
expected_hyprland="$(read_spec '["supplyChain"]["hyprland"]["version"]')-$(read_spec '["supplyChain"]["hyprland"]["pkgrel"]')"
[[ $(pacman -Q hyprland) == "hyprland $expected_hyprland" ]] || {
  echo "Rounded-border Hyprland backport is missing" >&2
  exit 1
}
expected_hyprland_sha256=$(read_spec '["supplyChain"]["hyprland"]["binarySha256"]')
printf '%s  %s\n' "$expected_hyprland_sha256" /usr/bin/Hyprland | sha256sum -c - >/dev/null || {
  echo "Rounded-border Hyprland binary digest mismatch" >&2
  exit 1
}
[[ $(pacman -Qoq /usr/local/bin/omarchy-native-cursor-restore) == try-omarchy-runtime ]] || {
  echo "Screensaver cursor helper is not owned by the Omarchy runtime package" >&2
  exit 1
}
if pacman -Qq vivaldi >/dev/null 2>&1; then
  echo "Vivaldi must remain a user-initiated post-build install" >&2
  exit 1
fi
vivaldi_installer=/usr/local/lib/try-omarchy/install-vivaldi-arm64
vivaldi_key=/usr/local/share/try-omarchy/vivaldi/linux_signing_key.pub
[[ -x $vivaldi_installer && ! -L $vivaldi_installer ]] || {
  echo "Vivaldi ARM64 installer is missing or unsafe" >&2
  exit 1
}
[[ -f $vivaldi_key && ! -L $vivaldi_key ]] || {
  echo "Vivaldi package key is missing or unsafe" >&2
  exit 1
}
[[ $(pacman -Qoq "$vivaldi_installer") == try-omarchy-runtime ]] || {
  echo "Vivaldi ARM64 installer is not owned by the Omarchy runtime package" >&2
  exit 1
}
[[ $(pacman -Qoq "$vivaldi_key") == try-omarchy-runtime ]] || {
  echo "Vivaldi package key is not owned by the Omarchy runtime package" >&2
  exit 1
}
expected_vivaldi_key_sha256=$(read_spec '["supplyChain"]["vivaldi"]["signingKeySha256"]')
printf '%s  %s\n' "$expected_vivaldi_key_sha256" "$vivaldi_key" | sha256sum -c - >/dev/null || {
  echo "Vivaldi package key digest mismatch" >&2
  exit 1
}
[[ ! -e /usr/local/bin/ttfx && ! -L /usr/local/bin/ttfx ]] || {
  echo "Obsolete ttfx compatibility command shadows the packaged binary" >&2
  exit 1
}
systemctl enable omarchy-provision-owner.service
systemctl enable sddm.service
systemctl enable omarchy-native-mac-share.service

# The app expands only the writable APFS clone to the configured capacity.
# Grow ext4 online so Omarchy's update-safety check sees that working capacity.
[[ -f /usr/lib/systemd/system/systemd-growfs-root.service ]] || { echo "Missing systemd root grow service" >&2; exit 1; }
mkdir -p /etc/systemd/system/local-fs.target.wants
ln -sfn /usr/lib/systemd/system/systemd-growfs-root.service \
  /etc/systemd/system/local-fs.target.wants/systemd-growfs-root.service

fc-cache -f
update-desktop-database /usr/share/applications || true

# Never let the container host's hardware autodetection remove the virtual
# devices required by QEMU on the Mac.
mkinitcpio -P
echo "Finalized unprovisioned Omarchy factory guest"
