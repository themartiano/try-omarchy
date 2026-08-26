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
fingerprint of what it last wrote for a couple of seconds so the immediate
echo is dropped while a later genuine repeat of the same content still flows.

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
  and host audio-device routing.
- The pinned Omarchy runtime trees are copied from upstream. Guest overlays add
  the QEMU and ARM64 integration around them.

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
required QEMU features. Updates to a pinned dependency should update its digest,
contract tests, notices, and review evidence together.
