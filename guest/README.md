# ARM64 guest image

This directory builds the single guest supported by Try Omarchy: our own
unprovisioned ARM64 Arch Linux factory image containing pinned upstream Omarchy
source. It is not a prebuilt image published by Basecamp.

From the repository root:

```sh
make guest
```

The privileged ARM64 Docker build writes verified artifacts to `dist/guest/`.
Its persistent package/source cache lives in a project-scoped Docker volume, so
repeat builds do not start from zero.

Useful lower-level commands:

```sh
guest/build-container.sh --dry-run
guest/build-container.sh --output dist/guest
guest/build-container.sh --refresh-package-lock /tmp/packages.lock.json
guest/test
```

`spec.json` is the authoritative image and runtime contract. `packages.txt` is
the requested transaction and `packages.lock.json` pins the full resolved ARM64
package set. Source repositories, commits, downloads, versions, and hashes are
reviewed inputs rather than floating build dependencies.

Hyprland is the one source-patched guest package. It is rebuilt from verified
upstream source with the rounded-border VM-graphics compatibility patch declared
under `supplyChain.hyprland` in `spec.json`, then held in the image's local
repository. `scripts/register-patched-hyprland.sh` owns the reproducible package
build, and `tests/test_rounded_border_coverage.py` owns its focused regression
model.

When updating Hyprland, first test the unpatched package through the same
Virtio/VirGL guest path. Remove the local patch and package hold if upstream is
clean; otherwise rebase the patch and update every source, patch, toolchain,
binary, package, and launcher identity together. In either case, run the full
tests and verify the newly built factory artifact. Installing a new app does
not rewrite existing persistent VMs, so they are not evidence that the new
factory contents are correct.

The output includes the kernel, initramfs, raw and compressed ext4 image,
provenance, package inventory, licenses, manifest, and SHA-256 sums. Generated
output belongs under the repository's ignored `dist/` directory and must not be
committed.

The factory is a seed, not an update payload. A new or reset persistent VM and
every ephemeral VM use the current output. An existing persistent VM keeps its
writable disk and a validated copy of the kernel and initramfs originally paired
with that disk, so a later app release does not replace its guest files. VMs
from before paired boot kits are migrated once by a recovery initramfs that
reads their `/boot` directory with the root disk mounted read-only.

Omarchy's built-in updater remains available for updates supported by this ARM
guest, but it is not equivalent to installing a new Try Omarchy factory. The
direct-boot kernel and matching headers are held, while the packaged
`try-omarchy-runtime` and reviewed backports resolve from the immutable local
repository. A separate migration channel is required before those
Try-Omarchy-specific revisions can advance on an existing disk without reset.

OpenSSH is an explicit factory package. A systemd generator requests the vendor
`sshd.service` only for a boot carrying the exact
`tryomarchy.ssh_access=1` kernel token, which the Mac launcher derives from a
validated generic TCP mapping to guest port 22. The generator writes only to
systemd's runtime generator directory; it does not enable sshd persistently or
change authentication policy under `/etc`.

The vendor service generates missing host keys on the writable guest disk. A
persistent VM therefore keeps its identity across restarts and app updates,
while a Factory Reset or a fresh ephemeral VM gets a new identity. The factory
image must never contain shared SSH host private keys.
