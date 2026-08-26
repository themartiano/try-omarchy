#!/usr/bin/env python3
"""Fast, host-independent checks for the native ARM64 guest build contract."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import py_compile
import stat
import subprocess
import tempfile
from pathlib import Path


GUEST = Path(__file__).resolve().parents[1]
REPO = GUEST.parent


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)
    print(f"ok - {message}")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def json_file(path: Path) -> dict:
    value = json.loads(read(path))
    check(isinstance(value, dict), f"{path.name} contains a JSON object")
    return value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, help="optional pinned Omarchy checkout")
    args = parser.parse_args()

    spec = json_file(GUEST / "spec.json")
    check(spec.get("schemaVersion") == 1, "guest spec schema is supported")
    check(spec["image"]["architecture"] == "aarch64", "guest is ARM64-only")
    check(spec["guest"].get("profile") == "factory", "guest is an unprovisioned factory image")
    check(spec["guest"].get("username") is None, "factory image has no baked-in user")
    check(spec["runtime"]["virtualMachineMonitor"] == "qemu-system-aarch64", "runtime uses native ARM QEMU")
    check(spec["runtime"]["hypervisor"] == "hvf", "runtime uses Apple Hypervisor.framework")
    check(spec["runtime"]["storage"]["expandedSizeMiB"] == 24576, "working disk expands to 24 GiB")
    update = spec["runtime"]["update"]
    check(
        set(update)
        == {
            "bootABI",
            "compressedImage",
            "controlPort",
            "guestStateSchema",
            "image",
            "protocolVersion",
        }
        and update["bootABI"] == "arm64-qemu-direct-v1"
        and update["controlPort"] == "dev.tryomarchy.control"
        and isinstance(update["guestStateSchema"], int)
        and update["guestStateSchema"] > 0
        and isinstance(update["protocolVersion"], int)
        and update["protocolVersion"] > 0,
        "offline update protocol is explicit and versioned",
    )
    check(set(spec["inputs"]) == {"packages", "packageLock", "pacmanConfig"}, "spec has a minimal input set")
    for path in spec["inputs"].values():
        check((GUEST / path).is_file(), f"spec input exists: {path}")

    package_text = (GUEST / spec["inputs"]["packages"]).read_bytes()
    package_lock = json_file(GUEST / spec["inputs"]["packageLock"])
    check(package_lock.get("architecture") == "aarch64", "package lock is ARM64")
    check(
        package_lock.get("requestedFileSha256") == hashlib.sha256(package_text).hexdigest(),
        "package lock matches packages.txt",
    )
    packages = package_lock.get("packages")
    check(isinstance(packages, dict) and len(packages) > 100, "package transaction is fully locked")

    container = read(GUEST / "build-container.sh")
    check("linux/arm64" in container and '"$guest_dir/Containerfile"' in container, "container builder targets ARM64")
    check('output="$repo_dir/dist/guest"' in container, "guest output defaults to dist/guest")
    check("try-omarchy-guest-work" in container, "guest cache has a project-scoped Docker volume")

    materialize = read(GUEST / "scripts/materialize-omarchy.sh")
    check(
        'mkdir -p "$root/etc/skel/.local/state/omarchy/toggles/hypr"' in materialize
        and 'copy_contents "$source_dir/default/hypr/toggles"' not in materialize
        and 'toggles/flags.lua' in materialize,
        "skel hypr toggles seed only flags.lua, not the catalog",
    )

    configure = read(GUEST / "scripts/configure-rootfs.sh")
    check("factory-overlay" in configure and "native-overlay" in configure, "rootfs receives only native factory overlays")
    check("omarchy-provision-owner.service" in configure, "first boot uses upstream owner provisioning")
    check("omarchy-native-audio-bridge" in configure, "guest installs native host-audio integration")
    check(
        "graphical-session.target.wants/omarchy-native-clipboard-bridge.service" in configure,
        "guest starts clipboard sharing with the graphical session",
    )
    check(
        "graphical-session.target.wants/try-omarchy-graphical-health.service" in configure,
        "guest gates normal health on the graphical session",
    )
    check(
        spec["runtime"]["clipboard"]["port"] == "dev.tryomarchy.clipboard",
        "clipboard contract names the virtio port",
    )
    zram_override = read(
        GUEST
        / "factory-overlay/etc/systemd/zram-generator.conf.d/99-try-omarchy.conf"
    )
    check(
        "[zram0]" in zram_override
        and "compression-algorithm = lzo-rle" in zram_override,
        "factory zram uses the ARM kernel's supported lzo-rle backend",
    )
    check(
        '"$root/usr/bin/omarchy-audio-input-set-default"' in configure
        and "audio_helper_source_digest=$(sha256sum" in configure
        and "native audio input helper did not replace" in configure,
        "native input selection replaces the upstream command",
    )
    check("cmp -s" not in configure, "rootfs configuration uses only declared build tools")

    build = read(GUEST / "build.sh")
    pack_image = read(GUEST / "scripts/pack-image.sh")
    check(
        "build-update-image.sh" in build
        and '--update-dir "$update_output"' in build
        and "update.ext4.zst" in pack_image,
        "guest build emits the signed offline update disk",
    )
    check(
        "TRY_OMARCHY_DEFER_INITRAMFS=1" in build
        and build.index("TRY_OMARCHY_DEFER_INITRAMFS=1")
        < build.index("build-update-image.sh")
        < build.rindex("mkinitcpio -P"),
        "owned payload follows finalization and final initramfs embeds its release",
    )
    prepare_update = read(GUEST / "scripts/prepare-update-root.py")
    owned_payload_source = read(
        GUEST / "native-overlay/usr/local/lib/try-omarchy/owned-payload"
    )
    check(
        all(
            representative in prepare_update
            for representative in (
                "/etc/skel",
                "/usr/share/omarchy",
                "/usr/share/try-omarchy/repo",
                "factory-overlay",
                "native-overlay",
                "SOURCE_TREE_MAPPINGS",
            )
        )
        and "/var/lib/try-omarchy/preserved" in owned_payload_source,
        "owned manifest converges Omarchy, overlays, integrations, and release metadata",
    )
    check(
        "migrations/0000-0001-bootstrap-update-v1.sh" not in configure
        and "native-overlay/." in configure,
        "factory image retains the universal owned-payload reconciler",
    )
    update_hook = read(
        GUEST / "native-overlay/usr/lib/initcpio/hooks/try-omarchy-update"
    )
    check(
        "remount,bind,ro" in update_hook
        and "for protected in home root" in update_hook,
        "offline update makes home and root read-only",
    )
    update_runner = read(
        GUEST / "native-overlay/usr/local/lib/try-omarchy/update-runner"
    )
    check(
        "--needed" not in update_runner
        and "TRY_OMARCHY_OWNED_PAYLOAD_SHA256" in update_runner,
        "offline transaction reinstalls exact packages and binds the owned manifest",
    )
    initramfs_config = read(
        GUEST / "factory-overlay/etc/mkinitcpio.conf.d/90-try-omarchy.conf"
    )
    check(
        "fsck try-omarchy-update" in initramfs_config,
        "initramfs runs offline updates after mounting the candidate root",
    )
    health_unit = read(
        GUEST
        / "native-overlay/usr/lib/systemd/system/try-omarchy-health.service"
    )
    check(
        "WantedBy=multi-user.target" in health_unit
        and "ConditionPathExists=/dev/virtio-ports/dev.tryomarchy.control"
        in health_unit
        and "--report" in health_unit,
        "trial health runs headlessly at multi-user target",
    )
    graphical_health_unit = read(
        GUEST
        / "native-overlay/usr/lib/systemd/user/try-omarchy-graphical-health.service"
    )
    check(
        "PartOf=graphical-session.target" in graphical_health_unit
        and "--mark-graphical-ready" in graphical_health_unit,
        "normal health requires a responsive graphical-session probe",
    )
    owned_payload = (
        GUEST
        / "native-overlay/usr/local/lib/try-omarchy/owned-payload"
    )
    check(
        owned_payload.is_file() and owned_payload.stat().st_mode & stat.S_IXUSR != 0,
        "signed owned-payload helper exists and is executable",
    )

    finalizer = read(GUEST / "scripts/finalize-rootfs.sh")
    check("factory" in finalizer and "aarch64" in finalizer, "finalizer enforces the native factory contract")
    check("systemd-growfs-root.service" in finalizer, "factory disk grows on first boot")

    manifest_writer = read(GUEST / "scripts/write-guest-manifest.py")
    check('"kind": "try-omarchy-guest-artifacts"' in manifest_writer, "new artifacts use the native manifest identity")
    check(
        '"update.ext4": ("guest-update-disk"' in manifest_writer
        and '"update.ext4.zst": ("guest-update-disk-compressed"'
        in manifest_writer,
        "guest manifest identifies raw and compressed update artifacts",
    )

    python_files = [
        GUEST / "scripts/prepare-update-root.py",
        GUEST / "scripts/update_contract.py",
        GUEST / "scripts/write-update-contract.py",
        GUEST / "native-overlay/usr/local/lib/try-omarchy/health-report",
    ]
    with tempfile.TemporaryDirectory() as temporary:
        for index, path in enumerate(python_files):
            py_compile.compile(
                str(path),
                cfile=str(Path(temporary) / f"update-{index}.pyc"),
                doraise=True,
            )
    check(True, "guest update Python tools compile")

    audio_bridge = GUEST / "native-overlay/usr/local/bin/omarchy-native-audio-bridge"
    check(audio_bridge.stat().st_mode & stat.S_IXUSR != 0, "native audio bridge is executable")
    with tempfile.TemporaryDirectory() as temporary:
        py_compile.compile(str(audio_bridge), cfile=str(Path(temporary) / "audio.pyc"), doraise=True)
    check(True, "native audio bridge compiles")

    clipboard_bridge = GUEST / "native-overlay/usr/local/bin/omarchy-native-clipboard-bridge"
    check(clipboard_bridge.stat().st_mode & stat.S_IXUSR != 0, "native clipboard bridge is executable")
    with tempfile.TemporaryDirectory() as temporary:
        py_compile.compile(str(clipboard_bridge), cfile=str(Path(temporary) / "clipboard.pyc"), doraise=True)
    check(True, "native clipboard bridge compiles")
    clipboard_unit = read(GUEST / "native-overlay/usr/lib/systemd/user/omarchy-native-clipboard-bridge.service")
    check(
        "PartOf=graphical-session.target" in clipboard_unit
        and "ConditionPathExists=/dev/virtio-ports/dev.tryomarchy.clipboard" in clipboard_unit,
        "clipboard bridge follows the graphical session and its virtio port",
    )
    clipboard_rule = read(GUEST / "native-overlay/etc/udev/rules.d/92-omarchy-native-clipboard.rules")
    check(
        'ATTR{name}=="dev.tryomarchy.clipboard"' in clipboard_rule and 'GROUP="users"' in clipboard_rule,
        "clipboard port is readable by the provisioned users group",
    )

    audio_input_helper = GUEST / "native-overlay/usr/bin/omarchy-audio-input-set-default"
    check(audio_input_helper.stat().st_mode & stat.S_IXUSR != 0, "native audio input helper is executable")

    display_sync = GUEST / "native-overlay/usr/local/bin/omarchy-native-display-sync"
    check(display_sync.stat().st_mode & stat.S_IXUSR != 0, "native display sync is executable")
    monitor_fragment = read(GUEST / "fragments/hypr-monitors-arm-qemu.append.lua")
    check(
        'o.exec_on_start("/usr/local/bin/omarchy-native-display-sync")'
        in monitor_fragment,
        "ARM VirGL profile starts native display sync",
    )
    with tempfile.TemporaryDirectory() as temporary:
        temporary_path = Path(temporary)
        fake_bin = temporary_path / "bin"
        fake_bin.mkdir()
        reload_log = temporary_path / "reloads"
        drm_root = temporary_path / "drm"
        connector = drm_root / "card0-Virtual-1"
        connector.mkdir(parents=True)
        (connector / "status").write_text("connected\n", encoding="utf-8")
        qemu_edid = bytearray(384)
        qemu_edid[:8] = b"\x00\xff\xff\xff\xff\xff\xff\x00"
        # A 2560x1440-point Cocoa window encoded at 110 logical DPI. With 2x
        # backing this 5120x2880 mode maps to Hyprland scale 2.
        qemu_edid[21:23] = bytes([59, 33])
        qemu_edid[126] = 2
        # QEMU encodes its dynamic 5120x2880@60 mode in a DisplayID 1.3
        # Type I detailed timing block, not in the base EDID descriptors.
        displayid = bytearray(128)
        displayid[:8] = bytes([0x70, 0x13, 0x17, 0x03, 0x00, 0x03, 0x00, 0x14])
        displayid[8:28] = bytes.fromhex(
            "c2 e2 01 88 ff 13 ff 06 ff 04 98 00 3f 0b 63 00 0d 00 0d 00"
        )
        displayid[28] = (-sum(displayid[1:28])) & 0xFF
        displayid[127] = (-sum(displayid[:127])) & 0xFF
        qemu_edid[256:384] = displayid
        qemu_edid[127] = (-sum(qemu_edid[:127])) & 0xFF
        (connector / "edid").write_bytes(qemu_edid)

        legacy_connector = drm_root / "card0-Virtual-2"
        legacy_connector.mkdir()
        (legacy_connector / "status").write_text("connected\n", encoding="utf-8")
        legacy_edid = bytearray(128)
        legacy_edid[:8] = b"\x00\xff\xff\xff\xff\xff\xff\x00"
        # Legacy 1920x1080@60 DTD on a low-PPI 509x286 mm display, with
        # 280 H blanking, 45 V blanking, and negative H/V sync.
        legacy_edid[54:72] = bytes.fromhex(
            "02 3a 80 18 71 38 2d 40 58 2c 45 00 fd 1e 11 00 00 18"
        )
        legacy_edid[127] = (-sum(legacy_edid[:127])) & 0xFF
        (legacy_connector / "edid").write_bytes(legacy_edid)
        fake_hyprctl = fake_bin / "hyprctl"
        fake_hyprctl.write_text(
            '#!/bin/bash\nprintf "%s\\n" "$*" >>"$HYPRCTL_LOG"\nprintf "ok\\n"\n',
            encoding="utf-8",
        )
        fake_hyprctl.chmod(0o755)
        events = """\
ACTION=change
SUBSYSTEM=drm
HOTPLUG=1

ACTION=add
SUBSYSTEM=drm
HOTPLUG=1

ACTION=change
SUBSYSTEM=drm
HOTPLUG=0

ACTION=change
SUBSYSTEM=drm
HOTPLUG=1
"""
        environment = os.environ.copy()
        environment["PATH"] = f"{fake_bin}:{environment['PATH']}"
        environment["HYPRCTL_LOG"] = str(reload_log)
        environment["OMARCHY_DISPLAY_SYNC_DRM_ROOT"] = str(drm_root)
        subprocess.run(
            [str(display_sync), "--from-stdin"],
            input=events,
            text=True,
            env=environment,
            check=True,
        )
        check(
            reload_log.read_text(encoding="utf-8").splitlines()
            == [
                'eval hl.monitor({ output = "", mode = "modeline 1236 5120 6400 6553 6912 2880 2894 2908 2980 -hsync -vsync", scale = "2" })',
                'eval hl.monitor({ output = "", mode = "modeline 149 1920 2008 2052 2200 1080 1084 1089 1125 -hsync -vsync", scale = "1" })',
                'eval hl.monitor({ output = "", mode = "modeline 1236 5120 6400 6553 6912 2880 2894 2908 2980 -hsync -vsync", scale = "2" })',
                'eval hl.monitor({ output = "", mode = "modeline 149 1920 2008 2052 2200 1080 1084 1089 1125 -hsync -vsync", scale = "1" })',
            ],
            "native display sync handles QEMU DisplayID and legacy EDID hotplug modes",
        )

    shell_files = [
        GUEST / "test",
        display_sync,
        *GUEST.glob("*.sh"),
        *GUEST.glob("scripts/*.sh"),
        *GUEST.glob("migrations/*.sh"),
        owned_payload,
        GUEST / "native-overlay/usr/local/lib/try-omarchy/update-runner",
        GUEST / "native-overlay/usr/lib/initcpio/hooks/try-omarchy-update",
        GUEST / "native-overlay/usr/lib/initcpio/install/try-omarchy-update",
    ]
    for path in sorted(shell_files):
        subprocess.run(["bash", "-n", str(path)], check=True)
    check(True, f"{len(shell_files)} guest shell scripts pass bash syntax checks")

    forbidden_names = {"package.json", "package-lock.json", "next.config.ts", "vite.config.ts"}
    check(not any((REPO / name).exists() for name in forbidden_names), "repository has no web or Node build entrypoint")

    if args.source:
        source = args.source.resolve()
        expected_commit = spec["upstream"]["commit"]
        actual_commit = subprocess.run(
            ["git", "-C", str(source), "rev-parse", "HEAD"],
            check=True,
            text=True,
            capture_output=True,
        ).stdout.strip()
        check(actual_commit == expected_commit, "optional Omarchy source checkout matches the pinned commit")
        for relative in spec["authenticity"]["requiredPaths"]:
            check((source / relative).exists(), f"pinned source contains {relative}")

    print("native guest contract verified")


if __name__ == "__main__":
    main()
