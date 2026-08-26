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

`make package` creates an ad-hoc local build. `make release` uses the maintainer's
Developer ID Application identity and the `try-omarchy` notarytool keychain
profile to sign, notarize, and staple the app and DMG. Both commands first
ensure the content-hashed guest and runtime artifacts are current; packaging
and signing themselves always run freshly. Another maintainer can override both
defaults:

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
   read and written from both sides, persistence, update, reset, and ephemeral
   mode.
4. Verify the app and DMG signatures with Apple's tools and confirm notarization.
5. Audit `THIRD_PARTY_NOTICES.md`, the bundle's license material, the guest
   package lock, and QEMU corresponding-source obligations.
6. Record SHA-256 digests for the final app archive/DMG and publish them with the
   release notes.

## Persistent guest update checklist

Every published guest release must be forward-migratable from every supported
older `guestStateSchema`:

1. Advance `runtime.update.guestStateSchema`; do not publish changed guest
   contents under an existing generation.
2. Never decrease `runtime.storage.expandedSizeMiB`, and keep it at least as
   large as the target factory image. Persistent ext4 disks are grow-only;
   shrinking this value would make existing VMs intentionally incompatible.
3. Keep the complete migration chain under `guest/migrations/`. Each step must
   be deterministic, idempotent, and implement both `apply` and `verify`.
4. Refresh the pinned package closure and rebuild the update filesystem. It must
   contain the target package repository, Try Omarchy-owned files, target state,
   and migration catalog—no network access is allowed during a user update.
5. Run `make test`, then test upgrades from the immediately previous release and
   the oldest supported release. Verify user files, accounts, settings, and
   user-installed packages before and after.
6. Inject failures during package installation, migration, health reporting,
   candidate shutdown, commit, and app termination. Each pre-commit failure must
   leave the predecessor byte-for-byte available, and a retry must converge.
7. Confirm **Update Omarchy** transitions through **Updating Omarchy…** and
   **Launching Omarchy…**, automatically opens the updated VM, and never offers
   reset for an ordinary version upgrade.

The detailed artifact and migration contract is in
[`guest-updates.md`](guest-updates.md).

Never publish generated artifacts from an unreviewed or locally modified build
input.
