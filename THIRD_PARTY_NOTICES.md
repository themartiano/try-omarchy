# Third-party notices

Try Omarchy builds and redistributes third-party components under their own
licenses. The repository's MIT license applies only to this project's original
code.

- **Omarchy** — pinned from `basecamp/omarchy`; MIT. Its license is copied into
  every guest artifact as `LICENSE.omarchy`.
- **QEMU** — GPL-2.0 and other component licenses. Release maintainers must
  provide the corresponding source and notices required by the exact bundled
  build.
- **Arch Linux ARM packages** — each package retains its own license. The
  generated package transaction is recorded in `packages.lock.txt`.
- **Hyprland** — BSD-3-Clause; the reviewed v0.56.1 source and rounded-border
  coverage backport are pinned in `guest/spec.json`. The guest package retains
  Hyprland's upstream license and dependency metadata.
- **Glaze** — MIT; the pinned v7.2.0 headers are used by the Hyprland build, and
  their verified upstream license is retained in the rebuilt guest package.
- **ANGLE, VirGLRenderer, libepoxy, SDL, libslirp, GLib, Pixman, and other QEMU
  dependencies** — retain their respective upstream licenses.
- **mise** — MIT; the reviewed ARM64 release is pinned in `guest/spec.json`.
- **ttfx** — MIT; the reviewed source release and locked Rust dependencies are
  pinned in `guest/spec.json` and built natively for ARM64. Its packaged
  `LICENSE` and `NOTICE` retain attribution to TerminalTextEffects and
  ChrisBuilds.
- **yay** — GPL-3.0-or-later; the official ARM64 release and its versioned
  license are pinned in `guest/spec.json` and packaged into the guest's local
  repository.

See `guest/spec.json`, `guest/packages.lock.json`, and
`macos/build-qemu-gpu-runtime.sh` for exact source identities and checksums.
Before distributing a release, follow `docs/releasing.md` and audit the assembled
bundle's notices and corresponding-source obligations.
