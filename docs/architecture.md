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
macOS Accessibility and Microphone permission state, handles confirmed factory
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

When a folder is chosen on the start menu, QEMU exports it over virtio-9p with
`security_model=none`, so every host file operation runs as the Mac user and
the Mac keeps real modes and ownership. A small QEMU patch adds
`guest_owner_uid`/`guest_owner_gid` fsdev options that report the Mac user's
files as the first Omarchy account (uid/gid 1000), which makes the guest
kernel's permission checks agree with what the host will actually allow. The
guest mounts the tag at `/mnt/mac` before the display manager starts, and a
user unit links `~/<folder name>` to it at login; the name travels on the
kernel command line as `omarchy.shared_folder_name=<base64url>`.

## The ARM64 image

The guest image is built by this project; it is not an official prebuilt image
from Basecamp. The `guest/` builder starts with pinned Arch Linux ARM packages,
installs a pinned upstream Omarchy source tree, and adds the small configuration
and compatibility layer needed for ARM64 and QEMU.

The result is upstream Omarchy running in a project-built ARM64 Linux image. The
image has no preconfigured user, so Omarchy's upstream owner-provisioning flow
creates the account on first boot.

## What this project changes

- The Swift code is a separate macOS launcher and helper.
- A few QEMU C and Objective-C files are patched before QEMU is compiled. These
  patches cover the Cocoa app identity, display behavior, graphics integration,
  host audio-device routing, and shared-folder ownership mapping.
- The pinned Omarchy runtime trees are copied from upstream. Guest overlays add
  the QEMU and ARM64 integration around them.

Nothing is overwritten in place. The app bundle and packaged factory disk remain
unchanged, and normal launches use one private writable disk under
`~/Library/Application Support/Try Omarchy/VM/v1`. Each saved generation is
paired with its exact kernel/initramfs identity.

When the bundled guest identity changes, the start menu offers a non-destructive
update. The host APFS-clones the active disk (falling back to a full copy),
attaches the signed update filesystem read-only as `/dev/vdb`, and boots the
candidate headlessly with the target kernel and initramfs. The initramfs applies
the pinned offline package transaction and the unique chain of guest migrations.
A private virtio-serial channel must deliver both a nonce-bound update completion
and a post-switch-root health report, and QEMU must then exit cleanly. Only after
all three conditions does the journal atomically promote the candidate. A crash
or failure before that point preserves the active disk; journal recovery makes
prepare, commit, and rollback restartable.

The predecessor remains as a rollback generation through the first normal
launch. That graphical launch gets its own non-transactional health channel;
the multi-user reporter waits for a per-boot marker from a UWSM user service
that has verified both the Wayland socket and a successful Hyprland monitor
query. The predecessor is removed only after this explicit graphical health
report and a clean QEMU exit.
A compatible legacy identity-keyed disk can first be relocated into the single
workspace without discarding its contents. Ambiguous, malformed, oversized, or
otherwise unsafe storage still requires the separately confirmed factory-reset
path. Unrecognized host files are always left untouched. Ephemeral mode uses a
disposable disk and never participates in persistent updates.

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
factory profile before QEMU starts. It also verifies the app signature and
required QEMU features. The update disk has its own signed raw/compressed digest
contract; its internal manifest is also pinned into the signed initramfs. Guest
status is treated only as a report from a user-controlled VM, while host paths,
transaction identity, and activation remain host-controlled. Updates to a pinned
dependency should update its digest, migration generation, contract tests,
notices, and review evidence together.
