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
systemctl enable omarchy-provision-owner.service
systemctl enable sddm.service
systemctl enable omarchy-native-mac-share.service

# The app expands only the writable APFS clone to 24 GiB. Grow ext4 online so
# Omarchy's update-safety check sees that working capacity.
[[ -f /usr/lib/systemd/system/systemd-growfs-root.service ]] || { echo "Missing systemd root grow service" >&2; exit 1; }
mkdir -p /etc/systemd/system/local-fs.target.wants
ln -sfn /usr/lib/systemd/system/systemd-growfs-root.service \
  /etc/systemd/system/local-fs.target.wants/systemd-growfs-root.service

fc-cache -f
update-desktop-database /usr/share/applications || true

# Never let the container host's hardware autodetection remove the virtual
# devices required by QEMU on the Mac.
case ${TRY_OMARCHY_DEFER_INITRAMFS:-0} in
  0) mkinitcpio -P ;;
  1) ;;
  *) echo "TRY_OMARCHY_DEFER_INITRAMFS must be 0 or 1" >&2; exit 1 ;;
esac
echo "Finalized unprovisioned Omarchy factory guest"
