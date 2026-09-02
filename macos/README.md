# Native macOS app

This directory contains the Apple Silicon application layer:

- a Swift/AppKit lifecycle and permission helper;
- a pinned, patched QEMU ARM64 runtime using HVF and Cocoa/VirGL;
- persistent-disk, input, audio-device, camera, clipboard, shared-folder, signing, and DMG tooling.

Use the root Makefile for normal development:

```sh
make runtime   # macos/.build/qemu-gpu-runtime
make app       # dist/Try Omarchy.app
make run
make package   # signed and notarized dist/TryOmarchy.dmg
make release   # signed and notarized dist/TryOmarchy.dmg
make test
```

`make app` requires an existing `dist/guest/` and staged QEMU runtime. A full
`make build` creates both first.

The staged runtime is a complete, checksum-pinned Apple Silicon closure built
for macOS 15.0. Runtime and app assembly do not resolve libraries or `zstd`
from the host Homebrew prefix, so building on a newer macOS release cannot
silently raise the app's deployment target.

`make release` defaults to the maintainer's Developer ID Application identity
and `try-omarchy` notarytool profile. The app builder is also directly usable
for release signing and notarization:

```sh
macos/build-app.sh \
  --dmg \
  --guest-dir dist/guest \
  --sign-identity "Developer ID Application: Example (TEAMID)" \
  --notarize-profile try-omarchy
```

Local app builds are ad-hoc signed by default. To keep Accessibility and other
macOS privacy grants across rebuilds, use a stable Apple Development identity:

```sh
make run DEVELOPMENT_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
```

`make package` uses `PACKAGE_SIGN_IDENTITY` and `PACKAGE_NOTARY_PROFILE`, which
default to the configured release credentials. It fails instead of producing
an unnotarized fallback.
Runtime caches are private to `macos/.build/`; user-facing output always goes
to `dist/`.

Normal app launches maintain one stable user VM disk under
`~/Library/Application Support/Try Omarchy/VM/v1`. Storage integration tests
and specialized development runs can opt into identity-keyed parallel disks by
setting `OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK=1`; release behavior leaves it
unset. Each persistent disk keeps the identity of the factory that created it
and is paired with a private, validated boot kit containing that factory's
kernel, initramfs, and base command line. App updates reuse the disk and its
boot kit; the current bundled factory is selected only for a new, reset, or
ephemeral VM. This keeps an older root filesystem on its matching kernel-module
ABI and lets an existing VM launch without first materializing the new factory
disk.

Schema-2 disks created before boot kits use a one-time preserving migration.
The first launcher pass reports that consent is required and exits before QEMU
starts. The start menu then explains that the disk and data stay intact, the
new factory is ignored for this VM, and the operation neither resets nor
upgrades Omarchy. **Cancel** returns to the menu; **Continue** authorizes only
that retry. The recovery-capable initramfs then attaches the old disk read-only,
exports its installed `/boot/Image`, `/boot/initramfs-linux.img`, and recorded
base command line over a private 9p share, and powers off without entering the
old userspace. The launcher validates and atomically stages that boot kit before
the normal launch. Unsupported storage or boot ABIs, and ambiguous multiple
legacy disks, still use the user-facing, confirmed Reset Omarchy flow.
That destructive flow keeps **Reset** disabled until the user types
`Try Omarchy` exactly in a native sheet. Cancelling or dismissing the sheet
returns control without invoking the storage reset.

The start menu can move that workspace to any APFS folder the user picks; the
folder is used exactly as chosen, never with a folder created inside it — a
folder with other files already in it, or a drive's top level, is refused
instead of restructured. The choice is stored in `UserDefaults` and published
to the launcher as `OMARCHY_QEMU_GPU_STATE_ROOT`. An inherited value of that
variable still wins, so the development and test override keeps working
unchanged. Reset composes its environment exactly as a launch does, so it
always erases the workspace the user is actually running.

Port forwarding is one versioned generic mapping list. The editor's **Add SSH**
action only inserts the ordinary TCP `2222 → 22` preset; users may edit it like
any other mapping. The signed shell parser remains the sole QEMU `hostfwd`
builder and derives boot-scoped sshd intent only from a fully valid TCP mapping
to guest port 22. No SSH-specific preference, port probe, status code, or
parallel forwarding path exists.

Ad-hoc signing identifies one exact build, so macOS intentionally invalidates
its privacy grants when that build is replaced. The app's **Open Settings**
action repairs a stale Accessibility entry and registers the installed build,
but a stable Apple Development or Developer ID signature is required for the
grant to survive future updates.

See the root `README.md`, `docs/architecture.md`, and `docs/releasing.md` for the
supported platform, runtime boundaries, and distribution checklist.
