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
tests and verify a fresh factory image rather than updating a persistent VM in
place.

The output includes the kernel, initramfs, raw and compressed ext4 image,
provenance, package inventory, licenses, manifest, and SHA-256 sums. Generated
output belongs under the repository's ignored `dist/` directory and must not be
committed.

OpenSSH is an explicit factory package. A systemd generator requests the vendor
`sshd.service` only for a boot carrying the exact
`tryomarchy.ssh_access=1` kernel token, which the Mac launcher derives from a
validated generic TCP mapping to guest port 22. The generator writes only to
systemd's runtime generator directory; it does not enable sshd persistently or
change authentication policy under `/etc`.

The vendor service generates missing host keys on the writable guest disk. A
compatible persistent VM therefore keeps its identity across restarts, while a
Factory Reset or a fresh ephemeral VM gets a new identity. The factory image
must never contain shared SSH host private keys.
