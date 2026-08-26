# Native macOS app

This directory contains the Apple Silicon application layer:

- a Swift/AppKit lifecycle and permission helper;
- a pinned, patched QEMU ARM64 runtime using HVF and Cocoa/VirGL;
- persistent-disk, input, audio-device, clipboard, shared-folder, signing, and DMG tooling.

Use the root Makefile for normal development:

```sh
make runtime   # macos/.build/qemu-gpu-runtime
make app       # dist/Try Omarchy.app
make run
make package   # ad-hoc dist/Try Omarchy.dmg for local testing
make release   # signed and notarized dist/Try Omarchy.dmg
make test
```

`make app` requires an existing `dist/guest/` and staged QEMU runtime. A full
`make build` creates both first.

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

Local app builds are ad-hoc signed. Runtime caches are private to
`macos/.build/`; user-facing output always goes to `dist/`.

Normal app launches maintain one stable user VM disk under
`~/Library/Application Support/Try Omarchy/VM/v1`. Storage integration tests
and specialized development runs can opt into identity-keyed parallel disks by
setting `OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK=1`; release behavior leaves it
unset. A changed guest build uses the **Update Omarchy** flow: the launcher
updates and health-checks a cloned candidate, atomically activates it, then
launches normally. The prior generation is retained through that first normal
launch and is removed only after the normal guest reports healthy and QEMU exits
cleanly. Normal health is accepted only after the UWSM session has proved a live
Wayland socket and responsive Hyprland monitor. Confirmed **Reset Omarchy**
remains separate and is reserved for
storage that cannot be safely recognized or migrated.

Ad-hoc local builds use one stable designated requirement for the app and its
input-capturing processes, so rebuilding does not invalidate their Accessibility
grant. Builds made before this requirement was introduced used a changing
code-hash identity: remove any such stale Try Omarchy entry from Privacy &
Security > Accessibility once, then use the current build's **Open Settings**
action and enable it again. Developer ID-signed release builds keep their stable
identity through the signing certificate.

See the root `README.md`, `docs/architecture.md`, and `docs/releasing.md` for the
supported platform, runtime boundaries, and distribution checklist.
