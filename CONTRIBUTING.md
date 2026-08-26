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

By contributing, you agree that your contribution is licensed under the MIT
License in this repository.
