# Architecture

Try Omarchy packages three pieces into one macOS app:

1. A small Swift/AppKit launcher for the macOS side.
2. A patched QEMU runtime that creates and runs the virtual machine.
3. An ARM64 Arch Linux image containing pinned upstream Omarchy source.

```text
Try Omarchy.app
└── Swift/AppKit launcher
    └── QEMU + Apple Hypervisor Framework
        └── project-built ARM64 Linux image
            └── Omarchy desktop
```

## What happens when the app opens

The Swift launcher presents a start menu on every app open. It reports optional
macOS Accessibility, Microphone, and Camera permission state, handles confirmed factory
resets, startup, shutdown, and host audio devices. It prepares a writable copy
of the Linux disk and starts QEMU. QEMU's Cocoa input layer uses the shared
Accessibility grant to capture system-wide Command chords and deliver Command
as guest Super. Swift does not replace QEMU or run the Omarchy desktop itself.

QEMU presents the hardware that Linux expects: CPUs, memory, storage, networking,
graphics, audio, keyboard, and pointer devices. Because both the Mac and the
guest are ARM64, Apple Hypervisor Framework runs the guest CPU instructions on
the Apple Silicon processor. QEMU provides the virtual devices around that CPU.

Linux then boots normally from the bundled kernel and disk, and Omarchy runs
inside Linux. Graphics travel from Linux through virtio-gpu and VirGL to the
native Cocoa window. Storage, networking, audio, and input use their matching
QEMU virtual devices and host backends.

One small host-integration channel sits beside those devices. A virtio-serial
port (`dev.tryomarchy.clipboard`) carries newline-delimited JSON between a
Swift bridge on the Mac, which watches the `NSPasteboard` change count, and a
Python agent in the Omarchy session, which uses wl-clipboard's data-control
protocol. Text and PNG payloads flow both ways; each side remembers the
fingerprint of what it last wrote so the immediate echo is dropped. The marker
is cleared as soon as the other side moves on to new content, and expires after
a couple of seconds regardless, so a genuine repeat of the same content still flows.

A separate virtio-serial port (`dev.tryomarchy.camera`) carries fixed-size
1280×720 NV12 frames from an AVFoundation bridge in the signed Mac helper. The
guest feeds those frames into an exclusive-capabilities `v4l2loopback` device,
`/dev/video42`, labeled **Mac Camera**. The guest subscribes to the loopback
driver's client-usage events and requests capture only while a Linux application
is reading the camera. Camera permission, capture failure, or device removal is
non-fatal to the VM; the launcher can restart the optional bridge without
restarting Omarchy.

When a folder is chosen on the start menu, QEMU exports it over virtio-9p with
`security_model=none`, so every host file operation runs as the Mac user and
the Mac keeps real modes and ownership. A small QEMU patch adds
`guest_owner_uid`/`guest_owner_gid` fsdev options that report the Mac user's
files as the first Omarchy account (uid/gid 1000), which makes the guest
kernel's permission checks agree with what the host will actually allow. The
guest mounts the tag at `/mnt/mac` before the display manager starts, and a
user unit links `~/<folder name>` to it at login; the name travels on the
kernel command line as `omarchy.shared_folder_name=<base64url>`.

Optional port mappings are stored as a versioned launcher preference, validated
again at every Swift-to-shell boundary, and translated into QEMU user-network
`hostfwd` rules. The host side is always bound explicitly to `127.0.0.1`; the
launcher never creates wildcard or LAN-facing listeners. TCP and UDP occupy
separate host-port namespaces, matching QEMU's socket behavior.

## The ARM64 image

The guest image is built by this project; it is not an official prebuilt image
from Basecamp. The `guest/` builder starts with pinned Arch Linux ARM packages,
installs a pinned upstream Omarchy source tree, applies any explicitly declared
and checksummed backports to the staged copy, and adds the small configuration
and compatibility layer needed for ARM64 and QEMU. The verified upstream Git
checkout itself stays untouched.

The result is upstream Omarchy running in a project-built ARM64 Linux image. The
image has no preconfigured user, so Omarchy's upstream owner-provisioning flow
creates the account on first boot.

## What this project changes

- The Swift code is a separate macOS launcher and helper.
- A few QEMU C and Objective-C files are patched before QEMU is compiled. These
  patches cover the Cocoa app identity, display behavior, graphics integration,
  host audio-device routing, and shared-folder ownership mapping.
- The pinned Omarchy runtime trees are copied from upstream. Reviewed temporary
  backports are applied strictly against declared file hashes and recorded in
  artifact provenance. Guest overlays add the QEMU and ARM64 integration around
  them, including narrowly audited command replacements for host-backed audio
  selection and VM-aware cursor restoration after the screensaver exits.
- The guest normally consumes upstream Arch Linux ARM packages. Hyprland is the
  documented exception: an upstream package is reproducibly rebuilt with a
  guarded rounded-border coverage patch for the VM graphics path, then held in
  the guest's immutable local repository.
- The final Arch Linux ARM pacman files live under `/usr/share/try-omarchy/`.
  An Omarchy-supported `pre-refresh-pacman` hook restores them after a channel
  refresh writes its x86_64 templates to `/etc`; the upstream templates remain
  unchanged.

Nothing is overwritten while the app runs. The app bundle and packaged factory
disk remain unchanged. Normal user launches use one private writable disk under
`~/Library/Application Support/Try Omarchy/VM/v1`. Its factory-image identity is immutable:
the launcher never pairs a saved root filesystem with a different bundled kernel
or initramfs. When a guest build changes, the start menu asks for an explicitly
confirmed factory reset before creating the replacement disk. A compatible
legacy identity-keyed disk can be migrated into the single workspace without
discarding its contents. If several recognized legacy disks exist, normal launch
stops at the start menu; confirmed reset safely removes them before publishing
one fresh workspace. Unrecognized host files are always left untouched.
Ephemeral mode uses a disposable disk.

The workspace does not have to live in Application Support. The start menu can
put it in any folder the user picks, including one on an external drive, and the
launcher receives that choice as `OMARCHY_QEMU_GPU_STATE_ROOT`. The chosen
folder is used as-is: it is never restructured with a folder created inside
it, so it must already be empty (or already be a workspace Omarchy has used)
— a populated folder or a drive's top level is refused with an explanation
instead. The volume must
be APFS: the storage library clones the factory image with `cp -c` and expands
the working disk sparsely, and it serializes launches with a `lockf` advisory
lock. On exFAT the same expansion allocates the full working size immediately,
and on a network share the lock is unreliable. Both layers check independently, the app
when the folder is chosen and the shell library again at launch, because the
volume can change in between. A location change never moves the existing VM;
unrecognized host files stay untouched, as everywhere else here.

## Build layout

- `guest/` reproducibly assembles the unprovisioned ARM64 image in a privileged
  ARM64 Docker container. Inputs are commit-, version-, and checksum-pinned.
- `macos/` builds the Swift launcher and a patched QEMU runtime. The runtime is
  isolated, relocated, and signed before it enters the app bundle.
- `dist/` is the only public output directory. It is generated and ignored by
  Git.

## Trust model

The app validates the exact guest file set, JSON schemas, hashes, sizes, pinned
upstream identity, runtime contract, kernel command line, architecture, and
factory profile before QEMU starts. Guest provenance separates verbatim runtime
trees from backported trees and records each reviewed patch with its input and
output hashes. The app also verifies the app signature and required QEMU
features. Updates to a pinned dependency should update its digest, contract
tests, notices, and review evidence together.
