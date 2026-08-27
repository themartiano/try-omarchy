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
- `dist/Try Omarchy.dmg`
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
3. Verify networking, display scaling, keyboard/mouse, microphone permission,
   audio-device changes, clipboard sharing in both directions, a shared folder
   read and written from both sides, persistence, reset, and ephemeral mode.
4. Verify the app and DMG signatures with Apple's tools and confirm notarization.
5. Audit `THIRD_PARTY_NOTICES.md`, the bundle's license material, the guest
   package lock, and QEMU corresponding-source obligations.
6. Record SHA-256 digests for the final app archive/DMG and publish them with the
   release notes.

Never publish generated artifacts from an unreviewed or locally modified build
input.
