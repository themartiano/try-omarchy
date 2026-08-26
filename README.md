# Try Omarchy

Run the upstream [Omarchy](https://github.com/basecamp/omarchy) desktop as a native, hardware-accelerated app on an Apple Silicon Mac.

Try Omarchy packages a project-built ARM64 Arch Linux image configured with Omarchy Quattro, a QEMU runtime using Apple Hypervisor Framework, and a small Swift/AppKit launcher into one macOS app. The image is built from pinned Arch Linux ARM packages and a pinned revision of the upstream Omarchy source.

<img width="800" src="https://github.com/user-attachments/assets/1368a8f5-5099-43e4-8d3b-3d7d7fba0326" />

Try Omarchy is not official or affiliated with Omarchy.

## Highlights

- Hardware-accelerated ARM64 virtualization and VirGL graphics
- Resizable native window with automatic guest resolution and HiDPI scale updates
- Mac audio input/output selection inside Omarchy, with live routing and system-default fallback
- Two-way clipboard sharing for text and PNG images between macOS and Omarchy

> **Current limitation:** Video decoding is CPU-only, so playback can be slow, especially at high resolutions. An improved video path is in development.

## Quick start

1. Open [Releases](https://github.com/themartiano/try-omarchy/releases) and download the latest signed and notarized `.dmg`.
2. Open the DMG and drag **Try Omarchy** to **Applications**.
3. Launch **Try Omarchy** from Applications.

Every launch begins at the start menu. Accessibility enables Mac Command-to-guest-Super shortcuts; microphone access is optional. The first launch takes longer while the app prepares Linux and starts Omarchy's account provisioning.

## Clipboard sharing

Copy and paste work in both directions as soon as you sign in to Omarchy: text
and PNG images copied on the Mac appear in the Omarchy clipboard, and content
copied in Omarchy lands on the Mac pasteboard. Nothing is transferred until
something is copied.

## Requirements

- Apple Silicon Mac (`arm64`)
- macOS 15 or newer
- At least 8 GB free initially

## Data and updates

Normal launches keep one persistent VM under `~/Library/Application Support/Try Omarchy/VM/v1`. Removing or replacing the app does not remove this data.

When a newer release can migrate that VM, the start-menu button changes from **Launch Omarchy** to **Update Omarchy**. Updating runs against a protected clone, verifies the signed offline package and migration payload, boots the candidate through a health check, and only then activates it. The app launches Omarchy automatically afterward. An interrupted or failed update leaves the previous VM intact and can be retried.

Factory reset remains a separate, confirmed action for malformed, ambiguous, or genuinely incompatible storage. It is not the normal release-upgrade path.

## Development requirements

- Xcode command-line tools with Swift 6
- Homebrew
- Python 3
- A running Docker-compatible engine that supports privileged `linux/arm64`
  containers
- `zstd`, `pkg-config`, GLib, Pixman, libslirp 4.9.3, and SDL2 2.32.70
- Roughly 20 GB free for guest, runtime, caches, and assembled output

Install the Homebrew dependencies with:

```sh
brew install zstd pkg-config glib pixman libslirp sdl2
```

`make doctor` performs the basic preflight. `make runtime` checks the exact libslirp and SDL2 versions against the pinned runtime contract.

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
├── Try Omarchy.dmg       # after make package or make release
└── guest/                # verified guest build artifacts
```

The two DMG targets have intentionally different purposes:

- `make package` creates an ad-hoc DMG for local testing. Do not publish it.
- `make release` rebuilds the app, Developer ID-signs the app and DMG, notarizes the DMG with Apple, and staples the notarization tickets. It assumes the guest and QEMU runtime already exist and does not run tests or rebuild those inputs.

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
