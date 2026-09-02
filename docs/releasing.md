# Releasing

Releases are Apple Silicon-only and require macOS 15 or newer.

## Build and verify

```sh
make doctor
make test
make build
make release
```

When the release updates Omarchy itself, first run:

```sh
make update-omarchy OMARCHY_RELEASE=x.y.z
```

Review both the upstream source change and the regenerated ARM64 package lock
before continuing with the normal build and verification sequence.

Outputs are written to:

- `dist/Try Omarchy.app`
- `dist/TryOmarchy.dmg`
- `dist/guest/`

`make package` and `make release` both create distributable builds: they sign
the app and DMG with Developer ID, submit the DMG to Apple's notarization
service, and staple the resulting tickets. Neither command falls back to an
unnotarized build. Both commands first ensure the content-hashed guest and
runtime artifacts are current; packaging and signing themselves always run
freshly. Another maintainer can override the release defaults:

```sh
make release \
  RELEASE_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
  RELEASE_NOTARY_PROFILE=example-profile
```

## Release checklist

1. Confirm `main` is clean and all pinned inputs have reviewable provenance.
2. Run all tests and perform a first-boot provisioning test on a clean Mac user.
3. Verify networking, display scaling, keyboard/mouse, microphone and camera permission,
   on-demand FaceTime HD capture, audio-device changes, clipboard sharing in both
   directions, a shared folder read and written from both sides, persistence,
   reset, and ephemeral mode. Exercise the SSH preset with a provisioned guest:
   confirm the listener is bound only to `127.0.0.1`, normal and ephemeral TCP
   mappings to guest port 22 work, UDP port 22 does not request sshd, a normal
   restart preserves the persistent VM, and the documented endpoint-specific
   host-key recovery works after Reset/ephemeral replacement. Inspect the
   factory image to confirm it contains no SSH host private keys.
4. Install the release over a provisioned VM created by a different guest
   build. Confirm launch preserves its disk and user data, selects the saved
   boot kit instead of the release's bundled kernel/initramfs, and does not
   materialize or charge free space for the new factory disk. For a schema-2 VM
   without a boot kit, confirm the one-time read-only `/boot` export completes,
   but only after the pre-launch dialog appears. Confirm **Cancel** starts no
   QEMU process and changes no disk contents; confirm **Continue** performs the
   recovery, the environment powers off without entering the old userspace,
   and later launches do not repeat it. Separately confirm that new, reset, and
   ephemeral VMs use the current factory.
5. Verify the app and DMG signatures with Apple's tools and confirm notarization.
6. Audit `THIRD_PARTY_NOTICES.md`, the bundle's license material, the guest
   package lock, and QEMU corresponding-source obligations.
7. State in release notes that installing the app preserves existing VM
   contents. Do not claim that the built-in updater reproduces factory changes:
   the direct-boot kernel and headers, `try-omarchy-runtime`, and reviewed
   backports remain pinned until an explicit in-guest migration channel exists.
8. Record SHA-256 digests for the final app archive/DMG and publish them with the
   release notes.

Never publish generated artifacts from an unreviewed or locally modified build
input.

The saved boot-kit ABI is a compatibility boundary. Do not change it or remove
support for an existing value without a reviewed preserving migration or an
explicitly confirmed reset path.
