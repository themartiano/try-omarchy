# Contributing

Thanks for helping improve Try Omarchy. The project has one product target: a
native Apple Silicon macOS app that runs pinned upstream Omarchy in a
project-built ARM64 virtual machine image.

## Before opening a pull request

1. Open an issue for large behavioral or architecture changes.
2. Keep changes within the current Apple Silicon, QEMU/HVF, and ARM64 guest
   architecture unless an architecture change has been discussed first.
3. Run `make test`.
4. If build inputs changed, run the relevant component build and explain how
   its pinned versions or checksums were reviewed.
5. Update documentation when commands, requirements, output paths, or security
   boundaries change.

The guest and QEMU supply chains are deliberately pinned. Do not update a URL,
commit, package lock, archive, or checksum independently of its associated
validation code.

Generated files in `dist/` and build caches in `macos/.build/` and
`guest/.work/` are not committed. Use `make clean` to remove project build
artifacts and caches. `make clean-all` additionally destroys persistent local
VM data and should only be used when a complete reset is intended.

Component builds use content-hashed state under `.build/state/`. A state file is
published only after the build succeeds and its output passes validation. Use
`FORCE=1` when reviewing reproducibility or when an intentionally unchanged
input must be rebuilt; do not work around the cache by editing generated state.

## Updating Omarchy

Pin an official upstream release, refresh the complete ARM64 transaction lock,
and verify the source contract with one command:

```sh
make update-omarchy OMARCHY_RELEASE=4.0.1
```

The command keeps a complete shallow source checkout under `.build/upstream/`,
verifies that its clean `HEAD` is the requested release tag, and derives the
commit, Git tree, normalized source digest, source timestamp, source-reported
version, and official release version. It then refreshes the package lock and
runs the guest contract against that exact checkout.

Before committing an update, review the upstream diff—especially changes to
`install/omarchy-base.packages`—against the intentionally trimmed
`guest/packages.txt`. Add runtime dependencies the native guest now needs, then
review every entry in `authenticity.backports`: drop a backport that the new
release contains, or refresh its strict preimage and postimage hashes after
review. Run `make guest` and `make test`. The upstream source can report a development
version even for an official tag, so never hand-edit the `version` or `release`
fields to make them agree; they record different upstream identities.

## Tests

Tests should describe a user-visible behavior, policy, data contract, or
process boundary. Keep presentation and edit rules in deterministic models that
can be exercised without opening AppKit windows. Do not make CI depend on pixel
coordinates, font metrics, display size, global window lookup, fixed run-loop
delays, or an assumed free network port.

Platform integration tests are appropriate when the operating-system boundary
is itself the contract. Use isolated temporary state, inject controllable
probes where the real resource is incidental, and use bounded readiness checks
instead of fixed settling delays.

By contributing, you agree that your contribution is licensed under the MIT
License in this repository.
