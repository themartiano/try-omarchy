# Try Omarchy

Run the upstream [Omarchy](https://github.com/basecamp/omarchy) desktop as a native, hardware-accelerated app on an Apple Silicon Mac.

Try Omarchy packages a project-built ARM64 Arch Linux image configured with Omarchy Quattro, a QEMU runtime using Apple Hypervisor Framework, and a small Swift/AppKit launcher into one macOS app. The image is built from pinned Arch Linux ARM packages and a pinned revision of the upstream Omarchy source. Temporary fixes carried ahead of the next upstream release are enumerated with strict hashes in the guest build spec and artifact provenance.

<img width="800" src="https://github.com/user-attachments/assets/1368a8f5-5099-43e4-8d3b-3d7d7fba0326" />

Try Omarchy is not official or affiliated with Omarchy.

## Highlights

- Hardware-accelerated ARM64 virtualization and VirGL graphics
- Resizable native window with automatic guest resolution and HiDPI scale updates
- Mac audio input/output selection inside Omarchy, with live routing and system-default fallback
- FaceTime HD and other Mac cameras exposed to Omarchy as an on-demand 720p webcam
- Two-way clipboard sharing for text and PNG images between macOS and Omarchy
- One optional shared Mac folder, available inside Omarchy under the same name (`~/Work` stays `~/Work`)
- Loopback-only TCP and UDP port forwarding from the Mac into Omarchy

> **Current limitation:** Video decoding is CPU-only, so playback can be slow, especially at high resolutions. An improved video path is in development.

## Changes in this fork

This fork moves the runtime to QEMU 11.1.1 to pick up Apple's in-hypervisor
GIC, and fixes two audio problems found along the way.

### Component versions

| Component | Upstream | This fork | Reason |
| --- | --- | --- | --- |
| QEMU | `cf3e71d8` — 10.2.50, 2026-01-13 | `c3d48b7d` — 11.1.1, 2026-08-26 | First release carrying `hw/intc/arm_gicv3_hvf.c` |
| ARM GIC | GICv2, emulated in QEMU userspace | GICv3 via Hypervisor.framework | Removes the interrupt path from the big QEMU lock |
| Render patch | startergo mega-patch, 29 files | Vendored and trimmed to 18, forward-ported | Upstream is unmaintained since 2026-01-14 and QEMU's display API moved |
| Python build deps | Host interpreter | Pinned `setuptools`, `wheel`, `pip` wheels | QEMU 11.1 builds `qemu.qmp`, and Python 3.12+ dropped `setuptools` |
| Render patch source | Downloaded from the startergo tarball | Vendored in `macos/patches/` | That tree is unmaintained since 2026-01-14; the archive is no longer fetched at all |
| Cocoa keyboard capture | Capture follows the mouse grab | Capture follows the key window | An absolute-pointing guest drops the grab as soon as virtio-tablet binds, leaking host Command chords mid-session |

### What it fixes

**Idle CPU.** QEMU emulated GICv2 in userspace under the big QEMU lock, so
every guest interrupt cost about four lock acquisitions and every IPI about
five across two vCPU threads. The cost scaled with vCPU count and was
independent of what the guest was doing.

| Measured at idle | Before | After |
| --- | --- | --- |
| QEMU | ~65% of a core | ~15% |
| `coreaudiod` attributable to the VM | 6.4% | 0.3% |
| Total | ~71% | ~15% |

The QEMU figure moved twice: the GIC work took it to ~22%, and clearing the
Cocoa GL dirty flag (below) took it to ~15%. The second measurement was taken
on a freshly booted desktop rather than the same session, so treat the split
between the two as approximate.

Under HVF, QEMU 11.1.1 also rejects GICv2 outright, so this is now the only
supported configuration rather than an optimisation.

**A host audio device held open forever.** `sdl_enable_out` only paused the
device, and QEMU links sdl2-compat over SDL3 where pausing a logical device
leaves the physical one running. The device being held was not even from
playback — `sdl_init_out` opens one at startup purely to negotiate a format,
and nothing released it. The host resampled silence for the life of the VM.
Microphone capture is stricter: its initial device open is deferred until an
Omarchy application actually records, and the device is closed again when the
guest capture stream stops. The first recording may therefore take one device
open longer to begin, but merely launching Try Omarchy does not activate the
Mac microphone.

**An unconditional re-render every refresh tick.** The vendored
GPU-resolution patch cleared `gl_dirty` inside an `if (cocoa_gl_trace_enabled())`
block, so in a normal build the flag was never cleared: it latched true on the
first damage and `cocoa_gl_refresh` then blitted the scanout on every tick for
the life of the VM, whether or not anything had changed. The clear now sits at
function scope, where its own comment says it belongs.

**Audio dropouts.** PipeWire reported continuous xruns on a ring 682 ms deep,
with the guest driver using 17 us against a 42 ms deadline. QEMU advances the
emulated Intel HDA DMA position from a 100 Hz timer, so the counter moves in
coarse jumps and ALSA concludes it has missed. Raising the guest's quantum
gives the emulated counter fewer and larger checks to satisfy. A deeper SDL
buffer made this worse, and raising the QEMU main loop to
`QOS_CLASS_USER_INTERACTIVE` changed nothing, which rules out both buffer
depth and priority inversion.

### Graphics chain

Rendering reaches the GPU through Metal, but nothing in QEMU speaks Metal.
virglrenderer replays the guest's commands as OpenGL ES, and ANGLE translates
those into Metal, which is why the display is started with `gl=es`.

```
Hyprland / Omarchy
  |  OpenGL
  v
Mesa virgl driver                       guest
  |  command stream
  v
virtio-gpu-gl-pci  ─────────────────────────── VM boundary
  |
  v
virglrenderer                           host, replays as OpenGL ES
  |
  v
ANGLE  (libGLESv2.dylib, libEGL.dylib)  translates GL ES -> Metal
  |
  v
Metal.framework                         Apple silicon GPU
```

Two things this makes explicit. The guest sees a plain virtio GPU and needs no
Apple-specific driver. And the acceleration is real rather than a software
rasteriser: `libGLESv2.dylib` and `libEGL.dylib` link `Metal.framework`
directly, and the guest reports the renderer as
`ANGLE (Apple, ANGLE Metal Renderer: <chip>)`.

This chain is unchanged by the QEMU 11.1.1 move. That work touched the
interrupt controller and the GL scanout plumbing — how a rendered texture is
handed to the Cocoa window — not the rendering backend.

Note that the upstream tap this builds from is named
`homebrew-qemu-virgl-kosmickrisp`, but KosmicKrisp, Mesa's Vulkan-to-Metal
driver, is not part of this path.

### Not yet verified

Window resize across a HiDPI boundary, Mac output-device switching mid-session,
the shared folder, and clipboard sharing have not been exercised since the
port. The `dtc` mirror should be reverted once kernel.org returns.

## Quick start

1. Open [Releases](https://github.com/themartiano/try-omarchy/releases) and download the latest signed and notarized `.dmg`.
2. Open the DMG and drag **Try Omarchy** to **Applications**.
3. Launch **Try Omarchy** from Applications.

Every launch begins at the start menu. **Immersive** is on by default and controls only the Full Screen presentation. Turn it off to keep Omarchy full screen while letting the Mac menu bar and Dock appear at the screen edges. Whenever the Omarchy window is focused, Command belongs to the guest as Super in either mode; Accessibility permission lets system shortcuts such as Command-Space reach it before macOS. Microphone and camera access are optional. The first launch takes longer while the app prepares Linux and starts Omarchy's account provisioning.

Restarting from inside Omarchy reboots the guest in the same Try Omarchy app.
Shutting down Omarchy closes the app and leaves it closed.

## 1Password

Install 1Password from the Omarchy menu. On ARM64 guests, Try Omarchy downloads
the current official 1Password application, verifies its signature against the
pinned 1Password signing key, and installs the ARM64 CLI package. Its launcher
uses software rendering to avoid the virtual GPU incompatibility affecting the
Electron interface.

After signing in, use these global shortcuts:

- `Ctrl + Shift + Space` — open 1Password Quick Access
- `Super + Shift + /` — open the full 1Password app

## Camera sharing

Choose **Allow…** next to **Camera access** on the start menu to make the Mac's
FaceTime HD camera available in Omarchy as **Mac Camera**. The bridge publishes a
standard Linux V4L2 camera at `/dev/video42`, so browser calls and Linux camera
apps can use it without special configuration. Capture is on demand: the Mac
camera and its indicator turn on only while an Omarchy app is actively using
the virtual camera. Denying camera permission does not prevent Omarchy from
launching.

## Clipboard sharing

Copy and paste work in both directions as soon as you sign in to Omarchy: text
and PNG images copied on the Mac appear in the Omarchy clipboard, and content
copied in Omarchy lands on the Mac pasteboard. Nothing is transferred until
something is copied.

## Sharing a folder with the Mac

Folder sharing is off until you pick a folder. Use **Choose…** next to
**Shared folder** on the start menu to select one Mac folder; Omarchy links it
into its home under the same name (`~/Work` on the Mac becomes `~/Work` in
Omarchy) with full read and write access, so choose a folder you intend Linux
software to modify. The whole home folder, `~/Library`, and system directories
cannot be shared. **Turn Off** keeps the choice but stops exporting it on the
next launch; Omarchy then removes the link and gives back any standard folder
such as `~/Documents` that the link had taken over. The share belongs to the
first Omarchy account created during
provisioning. Additional guest accounts can reach the same share, with each
entry's normal Unix permission bits deciding whether they can modify it.

## Forwarding ports to Omarchy

Use **Configure…** next to **Port forwarding** on the start menu to map a Mac
localhost port to a service port in Omarchy. Each mapping can use TCP or UDP;
the same Mac port may be used once for each protocol. Forwarded ports bind only
to `127.0.0.1`, so other devices on the network cannot connect to them. The
service inside Omarchy must listen on `0.0.0.0` or the guest network interface,
not only on the guest's own localhost.

The reverse direction does not need a mapping. From Omarchy, connect to
`10.0.2.2:<Mac port>` to reach a service running on the Mac.

### SSH access

After completing Omarchy's first-boot account setup, open **Port forwarding**,
choose **Add SSH**, and save the prefilled TCP mapping from Mac port `2222` to
Omarchy port `22`. Try Omarchy then requests `sshd` for boots that contain a TCP
mapping to guest port 22. It does not change guest accounts, `sshd_config`,
password policy, or authorized keys.

Connect with the username and password created inside Omarchy (the Mac username
is not assumed):

```sh
ssh -p 2222 <guest-user>@127.0.0.1
```

Once the initial password login works, install a key if desired:

```sh
ssh-copy-id -p 2222 <guest-user>@127.0.0.1
```

For a shorter command, add this to `~/.ssh/config` on the Mac:

```sshconfig
Host omarchy
  HostName 127.0.0.1
  Port 2222
  User <guest-user>
```

You can then use `ssh omarchy`, and the same alias works with `scp`, `rsync`,
Git, and VS Code Remote SSH. If you edit the preset's Mac port, substitute that
port in every command.

Factory Reset creates a new guest host key, and every ephemeral VM has its own
disposable host key. If OpenSSH reports that the key for the reused endpoint
changed, remove only that endpoint's old entry and reconnect to verify the new
fingerprint:

```sh
ssh-keygen -R '[127.0.0.1]:2222'
```

Loopback binding prevents devices on Wi-Fi, Ethernet, or the wider LAN from
connecting. It does not isolate the listener from other users or processes on
the same Mac; guest SSH authentication is still required.

## Requirements

- Apple Silicon Mac (`arm64`)
- macOS 15 or newer
- At least 8 GB free initially

## Data and updates

Normal launches keep one persistent VM under `~/Library/Application Support/Try Omarchy/VM/v1`. Removing the app does not remove this data. The start menu can reset it, and requires confirmation before replacing a disk that is incompatible with a new factory guest build.

### Choosing where the VM lives

**Change…** on the start menu's **VM Location** row moves the VM to any folder
you pick, including one on an external drive. Omarchy uses exactly the folder
you choose — it never creates a folder inside it on your behalf.

- The folder must be **empty**, or one Omarchy has already used. A folder with
  other files in it, or a drive's top level, is turned away with an
  explanation instead of being restructured; create or pick an empty folder
  (for example, one named "Try Omarchy") to use instead.
- The drive must be **APFS**. The VM disk grows as you use it, which only APFS
  supports here: on exFAT, FAT, or NTFS the same disk would claim its full size
  the moment it was created. Network volumes are refused because the VM's disk
  lock is unreliable on them. Anything else is turned away when you pick it, with
  the actual format named.
- You need roughly 7 GB free to create the VM, and up to 30 GB as it fills. The
  disk is sparse, so it only ever occupies what the guest has actually written.
- **Changing the location does not move your existing VM.** It stays where it
  is, and switching back reaches it again.
- Do not disconnect the drive while Omarchy is running. macOS refuses a normal
  eject while the VM holds the disk, but pulling the cable can damage it. If the
  volume does disappear, Omarchy shuts the VM down instead of writing on.
- **If the drive is not connected, Omarchy will not quietly use the default VM
  instead.** Launching offers to switch back to the default folder; resetting
  refuses outright, so a reset can never erase a workspace other than the one
  you confirmed. Opening the folder from the start menu will not recreate it on
  your startup disk either.

## Development requirements

- Xcode command-line tools with Swift 6
- Python 3
- `pkg-config` (Homebrew is the simplest way to install it)
- A running Docker-compatible engine that supports privileged `linux/arm64`
  containers
- Roughly 20 GB free for guest, runtime, caches, and assembled output

Install the one Homebrew build tool with:

```sh
brew install pkg-config
```

`make doctor` performs the basic preflight. `make runtime` downloads a
checksum-pinned `arm64_sequoia` dependency set, builds QEMU for macOS 15.0,
and rejects any runtime image that raises that minimum or strongly imports an
API unavailable on the declared platform. Installed Homebrew library versions
are never copied into the app.

## Build and run

For a first full build and launch:

```sh
make build run
```

The first build downloads pinned sources, assembles a multi-gigabyte guest, and
compiles QEMU, so it can take a while. `make build` includes the basic toolchain
check. Later builds hash the effective inputs and validate the existing outputs,
then rebuild only the guest, runtime, or app components that changed. To bypass
that cache deliberately, run `make build FORCE=1` (or add `FORCE=1` to an
individual component command).

Artifacts created before their `.build/state/` record exists are rebuilt once;
the cache never adopts an output whose successful inputs it did not observe.

Launching also ensures that the guest, runtime, and native app are current, so
the normal follow-up command is:

```sh
make run
```

Run the complete contract and native test suite with:

```sh
make test
```

Run `make help` for component builds, persistent-storage reset, ephemeral mode, and cleanup commands.

To reclaim development build space, run:

```sh
make clean
```

This removes all repository build output, the native and guest build caches,
and Try Omarchy's project-scoped Docker builder image and work volumes. It does
not touch a developer's persistent VM.

For a complete local reset, first quit Try Omarchy and then run:

```sh
make clean-all
```

The deep cleanup also permanently deletes the current user's Try Omarchy VM
disks and app state, plus stale Try Omarchy build and test directories in the
macOS temporary directories. It only selects Docker resources and temporary
paths owned by this project; it does not run a global Docker or system prune.
To prevent accidental data loss, the command requires an interactive terminal
and only proceeds after the developer types `clean-all` at the confirmation
prompt.

## Packaging and releases

All generated output has one predictable home:

```text
dist/
├── Try Omarchy.app
├── TryOmarchy.dmg        # after make package or make release
└── guest/                # verified guest build artifacts
```

Both DMG targets create distributable artifacts:

- `make package` rebuilds the app, Developer ID-signs the app and DMG,
  notarizes the DMG with Apple, and staples the notarization tickets. It uses
  `PACKAGE_SIGN_IDENTITY` and `PACKAGE_NOTARY_PROFILE`, which default to the
  configured release credentials, and fails instead of producing an
  unnotarized fallback.
- `make release` performs the same signing and notarization workflow with the
  release-specific credential variables.

Maintainers should follow [`docs/releasing.md`](docs/releasing.md) for the full build, test, signing, license, corresponding-source, and verification checklist.

## Repository layout

```text
.
├── Makefile                 public build interface
├── macos/                   Swift launcher and QEMU/HVF runtime builder
├── guest/                   reproducible ARM64 factory-image builder
├── docs/                    architecture and release documentation
├── dist/                    generated output (ignored)
├── CONTRIBUTING.md
├── SECURITY.md
├── THIRD_PARTY_NOTICES.md
└── LICENSE
```

The architecture and trust boundaries are documented in [`docs/architecture.md`](docs/architecture.md). Contributors should start with [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Project status and support

Try Omarchy is pre-1.0 and under active development. It is an independent open-source project and is not affiliated with or endorsed by Basecamp. Omarchy and bundled dependencies retain their own licenses; see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

Report ordinary bugs through [GitHub Issues](https://github.com/themartiano/try-omarchy/issues). Report suspected vulnerabilities using the private process in [`SECURITY.md`](SECURITY.md), not a public issue.

Try Omarchy's original code is licensed under the [MIT License](LICENSE).

by [@martiano](https://x.com/martiano)
