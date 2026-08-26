# Guest updates without losing VM state

Try Omarchy updates an existing VM as a cloned candidate. It never replaces the
user's working disk in place. The candidate retains `/home`, machine identity,
application data, and every other guest file while a signed, offline release
payload updates the OS and Try Omarchy-owned integration files. The launcher
promotes that candidate only after the updated guest reports healthy.

## Version contract

`guest/spec.json` owns the update ABI:

```json
{
  "bootABI": "arm64-qemu-direct-v1",
  "compressedImage": "update.ext4.zst",
  "controlPort": "dev.tryomarchy.control",
  "guestStateSchema": 1,
  "image": "update.ext4",
  "protocolVersion": 1
}
```

Every factory disk and successfully updated disk has a canonical state marker
at `/var/lib/try-omarchy/state.json`. It records `guestStateSchema`, `bootABI`,
`protocolVersion`, and a 64-character `releaseId`. The release ID is a
deterministic SHA-256 over the canonical spec, resolved package lock and exact
package archives, normalized upstream tree identity, migrations, and
Try Omarchy-owned payload. It therefore changes when any offline target input
changes without depending on the generated disk or manifest.

Increment `guestStateSchema` for **every release that may update an existing
VM**, even when the migration only updates packages. A candidate already at the
target schema is accepted as a crash-resume only when its release ID, boot ABI,
and protocol version also match the target. The same schema with a different
release ID fails with `release-schema-not-advanced`; this turns a forgotten
schema increment into a safe release failure instead of silently skipping work.

Change `bootABI` only when the launcher's direct-boot kernel/device contract is
incompatible. Change `protocolVersion` only for an incompatible control-message
change. The launcher must reject unsupported values before starting an update.

## Release artifact

The guest builder emits `update.ext4` and `update.ext4.zst` alongside the normal
kernel, initramfs, and factory root disk. The guest manifest identifies them as
`guest-update-disk` and `guest-update-disk-compressed` and includes their byte
counts and SHA-256 digests.

The read-only ext4 update disk contains:

- an offline pacman repository containing the exact target factory package
  closure, the matching `linux-aarch64`, and Try Omarchy's local packages;
- a pacman configuration that can see only that repository;
- a strictly versioned migration catalog and checksummed migration scripts;
- a generated, checksummed ownership manifest covering the complete Omarchy
  runtime and commands, `/etc/skel`, every factory/native overlay, mapped
  system integrations, local repository, and release metadata;
- the canonical target state marker and update metadata; and
- `SHA256SUMS` covering every payload file.

The SHA-256 of the internal `SHA256SUMS` is embedded in the release initramfs.
This binds the updater running outside the mutable candidate root to one exact
update disk. The host must also verify the release manifest before materializing
or attaching either artifact.

## Transaction and recovery

The launcher performs these steps:

1. Stop the VM cleanly and APFS-clone (or copy) the current working disk to a
   candidate. Keep the original working disk untouched.
2. Materialize and verify `update.ext4.zst`, attach the raw image read-only as
   the second virtio block disk (`/dev/vdb`), and attach the root-owned
   `dev.tryomarchy.control` virtio port.
3. Direct-boot the candidate headlessly with the target kernel/initramfs and
   append:

   ```text
   tryomarchy.update=1 tryomarchy.transaction=<64-lowercase-hex> systemd.unit=multi-user.target
   ```

4. The initramfs mounts `/dev/vdb` read-only, bind-mounts `/home` and `/root`
   read-only, verifies its complete payload, reinstalls the exact offline pacman
   target (including same-version content rebuilds), removes only obsolete
   packages managed by the old factory when dependency checks permit it,
   restores the target explicit/dependency reasons, applies and verifies each
   schema migration, regenerates its initramfs, and atomically publishes the
   target state marker last. Foreign packages installed by the user are not an
   old-factory removal candidate.
5. After switch-root, `try-omarchy-health.service` validates the installed
   release identity, kernel modules, and core host integrations at
   `multi-user.target`. It reports `readiness: "system"` with the same
   transaction nonce and powers off. No graphical session or owner login is
   required.
6. Only after both matching `update/complete` and `health/ready` messages does
   the launcher atomically promote the candidate. It retains a rollback copy
   until a subsequent normal boot reaches UWSM's graphical session, proves a
   live Wayland socket and responsive Hyprland monitor, sends a nonce-free
   `health/ready` report with `readiness: "graphical"`, and QEMU exits cleanly.

An update error, unexpected power loss, timeout, stale nonce, malformed
message, or failed health check leaves the candidate uncommitted. The original
disk remains bootable. Retrying from a candidate whose target marker was
published is idempotent: the updater verifies the exact release, rechecks the
payload and boot artifacts, reports completion, and proceeds to health.

The owned-path manifest deliberately never admits `/home` or `/root`. Broad
release-owned trees (`/usr/share/omarchy`, its license, `/etc/skel`, and the
immutable local package repository) converge exactly, including removal of
obsolete leaves. Before replacing or removing an old byte, the migration moves
it to `/var/lib/try-omarchy/preserved/<releaseId>/...`; this provides an
in-guest recovery copy for local edits in a path the release must own. Machine
identity, existing users' homes, provisioning state, host keys, and general
application state are not factory-reset. `/etc/skel` changes affect only users
created later and are never copied over an existing home. A complete
`original-etc` snapshot is also retained under that release recovery tree
before pacman runs, covering configuration owned by ordinary OS packages.

Update success is one canonical JSON line:

```json
{"bootABI":"arm64-qemu-direct-v1","fromGuestStateSchema":0,"guestStateSchema":1,"protocolVersion":1,"status":"complete","transaction":"<64hex>","type":"update"}
```

Failure uses `"status":"failed"` and adds a stable kebab-case `errorCode`.
Trial-boot health is:

```json
{"bootABI":"arm64-qemu-direct-v1","guestStateSchema":1,"protocolVersion":1,"readiness":"system","status":"ready","transaction":"<64hex>","type":"health"}
```

The transaction nonce is mandatory during an update and lets the host reject
late messages from an earlier QEMU process. Normal-boot health omits it and must
instead declare `readiness: "graphical"`; the host rejects either readiness
class in the wrong boot mode.

## Adding a migration

Add a POSIX shell script under `guest/migrations/` named
`NNNN-MMMM-description.sh`, where `NNNN` is the source schema and `MMMM` is the
target schema. The catalog must provide exactly one forward path from every
supported installed schema to the release schema. A script receives:

```text
migration.sh verify CANDIDATE_ROOT UPDATE_MOUNT
migration.sh apply  CANDIDATE_ROOT UPDATE_MOUNT
```

`verify` must return success only when the intended postcondition already
holds. `apply` must be safe to repeat after interruption, use atomic replacement
for individual files, preserve user-owned data by default, and never publish
the global state marker. The runner calls `verify`, then `apply` only if needed,
then `verify` again. It publishes the marker after the entire package and
migration transaction succeeds.

OS and kernel changes belong in the target package lock. Try Omarchy-owned
integration and template changes must appear in the generated owned payload or
a local package. The build intentionally snapshots the ownership manifest only
after rootfs finalization; it then writes the final release environment and
regenerates the external direct-boot initramfs. Changes to user configuration
must be explicit, versioned transformations that preserve local edits; upstream
`omarchy-migrate` remains a per-user graphical-session operation and is not
falsely treated as an offline system migration.

Run the host-independent contract suite with:

```sh
guest/test
```

The full ARM64 container build is the integration test that constructs and
checks the ext4 update artifact:

```sh
guest/build-container.sh --output dist/guest
```
