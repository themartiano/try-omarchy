#!/usr/bin/env python3
"""Fast, host-independent checks for the native ARM64 guest build contract."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import py_compile
import re
import stat
import subprocess
import tempfile
import time
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


def encoded_share_name(name: str) -> str:
    return base64.urlsafe_b64encode(name.encode()).decode().rstrip("=")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, help="optional pinned Omarchy checkout")
    args = parser.parse_args()

    spec = json_file(GUEST / "spec.json")
    check(spec.get("schemaVersion") == 1, "guest spec schema is supported")
    check(spec["image"]["architecture"] == "aarch64", "guest is ARM64-only")
    check(spec["guest"].get("profile") == "factory", "guest is an unprovisioned factory image")
    check(spec["guest"].get("username") is None, "factory image has no baked-in user")
    check(
        re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-.][A-Za-z0-9.]+)?", spec["upstream"].get("release", ""))
        is not None,
        "upstream release is explicit",
    )
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
        and update["guestStateSchema"] == 3
        and isinstance(update["protocolVersion"], int)
        and update["protocolVersion"] > 0,
        "offline update protocol is explicit and versioned",
    )
    check(set(spec["inputs"]) == {"packages", "packageLock", "pacmanConfig"}, "spec has a minimal input set")
    for path in spec["inputs"].values():
        check((GUEST / path).is_file(), f"spec input exists: {path}")

    pacman_conf = read(GUEST / spec["inputs"]["pacmanConfig"])
    check(
        "[core]" in pacman_conf and "[alarm]" in pacman_conf,
        "factory pacman uses Arch Linux ARM repositories",
    )
    check(
        "[multilib]" not in pacman_conf,
        "factory pacman omits the x86_64 multilib repository",
    )
    check(
        "stable-mirror.omarchy.org" not in pacman_conf
        and "pkgs.omarchy.org/stable" not in pacman_conf,
        "factory pacman omits Omarchy's x86_64 channel repositories",
    )
    check(
        "[omarchy]" in pacman_conf
        and "Server = https://pkgs.omarchy.org/$arch" in pacman_conf,
        "factory pacman retains the ARM Omarchy keyring repository",
    )
    check(
        "IgnorePkg = linux-aarch64" in pacman_conf,
        "factory pacman holds the QEMU-booted kernel",
    )
    arm_mirrorlist = read(GUEST / "mirrorlist.aarch64")
    check(
        "mirror.archlinuxarm.org/$arch/$repo" in arm_mirrorlist
        and "stable-mirror.omarchy.org" not in arm_mirrorlist,
        "factory mirrorlist uses Arch Linux ARM",
    )

    package_text = (GUEST / spec["inputs"]["packages"]).read_bytes()
    package_lock = json_file(GUEST / spec["inputs"]["packageLock"])
    check(package_lock.get("architecture") == "aarch64", "package lock is ARM64")
    check(
        package_lock.get("requestedFileSha256") == hashlib.sha256(package_text).hexdigest(),
        "package lock matches packages.txt",
    )
    packages = package_lock.get("packages")
    check(isinstance(packages, dict) and len(packages) > 100, "package transaction is fully locked")
    requested_packages = {
        line.strip()
        for line in package_text.decode().splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }
    check(
        "fakeroot" in requested_packages and "fakeroot" in packages,
        "factory transaction includes fakeroot for AUR package builds",
    )
    yay = spec.get("supplyChain", {}).get("yay", {})
    check(
        set(yay)
        == {
            "binarySha256",
            "license",
            "licenseSha256",
            "licenseUrl",
            "reportedVersion",
            "sha256",
            "url",
            "version",
        }
        and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", yay.get("version", "")) is not None
        and yay.get("url")
        == f"https://github.com/Jguer/yay/releases/download/v{yay.get('version')}/yay_{yay.get('version')}_aarch64.tar.gz"
        and yay.get("licenseUrl")
        == f"https://raw.githubusercontent.com/Jguer/yay/v{yay.get('version')}/LICENSE"
        and yay.get("license") == "GPL-3.0-or-later"
        and all(
            re.fullmatch(r"[0-9a-f]{64}", yay.get(key, "")) is not None
            for key in ("sha256", "binarySha256", "licenseSha256")
        ),
        "official ARM64 yay release and license are fully pinned",
    )

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
    user_migration_manifest = read(
        GUEST
        / "native-overlay/usr/share/try-omarchy/user-migrations/0003-hypr-toggle-defaults.tsv"
    )
    check(
        user_migration_manifest.splitlines()
        == [
            "22d43e72bf5b38e64b82409961c292329997c314f6c8a418b10b19c2193b1dc8\twindow-no-gaps.lua",
            "c89793cc84bcf450116fa817db4a18b6e5e026cd2e138fd7ae595d0aec34d3bd\tsingle-window-aspect-ratio.lua",
        ],
        "per-user migration freezes the two affected Omarchy 4.0.1 toggles",
    )
    user_migration_unit = read(
        GUEST
        / "native-overlay/usr/lib/systemd/user/try-omarchy-user-migrate.service"
    )
    check(
        "Before=graphical-session-pre.target graphical-session.target"
        in user_migration_unit
        and "ExecStart=/usr/local/lib/try-omarchy/user-migrate"
        in user_migration_unit
        and "WantedBy=default.target" in user_migration_unit,
        "user-state repairs run before the graphical session consumes Hyprland state",
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
    check(
        '"$root/usr/local/bin/omarchy-native-mac-share"' in configure
        and "default.target.wants/omarchy-native-mac-share-link.service" in configure,
        "guest links the shared Mac folder into each home at login",
    )
    check(
        '"$root/usr/local/lib/try-omarchy/user-migrate"' in configure
        and "default.target.wants/try-omarchy-user-migrate.service" in configure,
        "guest runs versioned user-state repairs at login",
    )
    check(
        "pre-refresh-pacman-restore-arm.sh" in configure
        and "pre-refresh-pacman.d/restore-arm-pacman" in configure
        and 'install -m 0644 "$arm_mirrorlist"' in configure
        and "install -m 0644 /etc/pacman.d/mirrorlist" not in configure,
        "ARM pacman restore uses Omarchy's pre-refresh hook and a pinned mirrorlist",
    )
    restore_hook = read(GUEST / "fragments/pre-refresh-pacman-restore-arm.sh")
    check(
        "install -m 0644 /usr/share/try-omarchy/pacman.conf /etc/pacman.conf"
        in restore_hook
        and "install -m 0644 /usr/share/try-omarchy/mirrorlist /etc/pacman.d/mirrorlist"
        in restore_hook,
        "pre-refresh hook restores the complete Try Omarchy pacman files",
    )
    local_repository = read(GUEST / "scripts/register-local-repository.sh")
    check(
        'install -m 0644 "$root/etc/pacman.conf" "$root/usr/share/try-omarchy/pacman.conf"'
        in local_repository
        and 'install -m 0644 "$root/etc/pacman.d/mirrorlist" "$root/usr/share/try-omarchy/mirrorlist"'
        in local_repository,
        "pacman recovery files snapshot the final local-repository configuration",
    )
    check(
        "expected_archive_count=3" in local_repository
        and "factory repository is missing pinned yay" in local_repository,
        "immutable local repository requires the pinned yay package",
    )
    shared_folder = spec["runtime"]["sharedFolder"]
    check(
        shared_folder["device"] == "virtio-9p-pci"
        and shared_folder["securityModel"] == "none"
        and shared_folder["guestOwnerUid"] == 1000
        and shared_folder["guestOwnerGid"] == 1000
        and shared_folder["mountTag"] == "mac"
        and shared_folder["guestMountPoint"] == "/mnt/mac"
        and shared_folder["guestLinkNameParameter"] == "omarchy.shared_folder_name"
        and "virtio-9p-pci" in spec["runtime"]["devices"],
        "shared folder contract maps Mac files to the first Omarchy user over virtio-9p",
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
    register_yay = read(GUEST / "scripts/register-pinned-yay.sh")
    check(
        "register-pinned-yay.sh" in build
        and build.index("register-pinned-yay.sh")
        < build.index("register-local-repository.sh")
        and "download digest mismatch" in register_yay
        and "yay archive has an unexpected member set" in register_yay
        and "installed yay binary digest mismatch" in register_yay
        and "depend = fakeroot" in register_yay
        and "provides = yay=$version" in register_yay
        and "runuser -u alpm -- /usr/bin/yay --version" in register_yay,
        "guest installs verified yay before sealing its local repository",
    )
    third_party_notices = read(REPO / "THIRD_PARTY_NOTICES.md")
    check(
        "**yay**" in third_party_notices and "GPL-3.0-or-later" in third_party_notices,
        "third-party notices cover the pinned yay redistribution",
    )
    pack_image = read(GUEST / "scripts/pack-image.sh")
    check(
        "build-update-image.sh" in build
        and '--update-dir "$update_output"' in build
        and "update.ext4.zst" in pack_image,
        "guest build emits the signed offline update disk",
    )
    build_cache = read(REPO / "scripts/build-cache.py")
    check(
        '"update.ext4"' in build_cache and '"update.ext4.zst"' in build_cache,
        "build cache accepts both offline update artifacts",
    )
    build_update_image = read(GUEST / "scripts/build-update-image.sh")
    prepare_update = read(GUEST / "scripts/prepare-update-root.py")
    check(
        "*.pkg.tar.zst" in build_update_image
        and "*.pkg.tar.xz" in build_update_image
        and "*.pkg.tar.zst" in prepare_update
        and "*.pkg.tar.xz" in prepare_update,
        "offline update accepts both Try Omarchy zstd and Arch Linux ARM xz packages",
    )
    check(
        "TRY_OMARCHY_DEFER_INITRAMFS=1" in build
        and build.index("TRY_OMARCHY_DEFER_INITRAMFS=1")
        < build.index("build-update-image.sh")
        < build.rindex("mkinitcpio -P"),
        "owned payload follows finalization and final initramfs embeds its release",
    )
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
                "omarchy-native-mac-share.service",
                "omarchy-native-mac-share-link.service",
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
    bootstrap_migration = read(
        GUEST / "migrations/0000-0001-bootstrap-update-v1.sh"
    )
    check(
        "original-etc/sddm.conf.d/autologin.conf" in bootstrap_migration
        and "Session=omarchy.desktop" in bootstrap_migration
        and "restore_autologin" in bootstrap_migration,
        "schema bootstrap preserves the provisioned graphical autologin",
    )
    native_autologin = read(
        GUEST
        / "native-overlay/etc/systemd/system/omarchy-provision-owner.service.d/10-try-omarchy-native.conf"
    )
    check(
        "ExecStartPost=" in native_autologin
        and "omarchy-provision-autologin-once.service" in native_autologin
        and "10-try-omarchy-native.conf" in prepare_update,
        "native provisioning keeps direct graphical login across VM boots",
    )
    yay_migration = read(GUEST / "migrations/0001-0002-add-yay.sh")
    check(
        all(
            marker in yay_migration
            for marker in (
                "/usr/bin/yay",
                "/usr/bin/fakeroot",
                "/usr/share/licenses/try-omarchy-yay/LICENSE",
                "The package transaction runs before schema migrations",
            )
        ),
        "schema 1-to-2 migration verifies the pinned yay package state",
    )
    hypr_toggle_migration = read(
        GUEST / "migrations/0002-0003-repair-hypr-toggle-defaults.sh"
    )
    check(
        all(
            marker in hypr_toggle_migration
            for marker in (
                "owned-payload",
                "/usr/local/lib/try-omarchy/user-migrate",
                "0003-hypr-toggle-defaults.tsv",
                "try-omarchy-user-migrate.service",
            )
        ),
        "schema 2-to-3 migration arms the deferred Hyprland repair",
    )
    migration_edges = [
        tuple(int(part) for part in path.name.split("-", 2)[:2])
        for path in sorted(GUEST.glob("migrations/*.sh"))
    ]
    check(
        migration_edges == [(0, 1), (1, 2), (2, 3)]
        and migration_edges[-1][1] == update["guestStateSchema"],
        "migration catalog has one complete path from legacy state to schema 3",
    )
    update_hook = read(
        GUEST / "native-overlay/usr/lib/initcpio/hooks/try-omarchy-update"
    )
    check(
        "remount,bind,ro" in update_hook
        and "for protected in home root" in update_hook,
        "offline update makes home and root read-only",
    )
    check(
        "candidate_root=/new_root" in update_hook
        and "candidate_root=/sysroot" not in update_hook,
        "offline update targets mkinitcpio's mounted real root",
    )
    check(
        'control_link="/dev/virtio-ports/$TRY_OMARCHY_CONTROL_PORT"' in update_hook
        and 'readlink -f "$control_link"' in update_hook
        and '[ -c "$resolved_control_device" ]' in update_hook,
        "offline update resolves the udev control symlink to a character device",
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
    check("systemctl enable omarchy-native-mac-share.service" in finalizer, "shared Mac folder mounts at boot")

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
    mac_share = GUEST / "native-overlay/usr/local/bin/omarchy-native-mac-share"
    check(mac_share.stat().st_mode & stat.S_IXUSR != 0, "native Mac share mounter is executable")
    with tempfile.TemporaryDirectory() as temporary:
        temporary_path = Path(temporary)
        virtio_root = temporary_path / "9pnet_virtio"
        other = virtio_root / "virtio2"
        other.mkdir(parents=True)
        (other / "mount_tag").write_bytes(b"other\0")
        share = virtio_root / "virtio3"
        share.mkdir()
        (share / "mount_tag").write_bytes(b"mac\0")
        environment = os.environ.copy()
        environment["OMARCHY_MAC_SHARE_VIRTIO_ROOT"] = str(virtio_root)
        found = subprocess.run(
            [str(mac_share), "--find-device"],
            text=True,
            env=environment,
            capture_output=True,
            check=True,
        )
        check(found.stdout.strip() == "virtio3", "Mac share mounter finds the virtio-9p device by mount tag")
        environment["OMARCHY_MAC_SHARE_TAG"] = "absent"
        missing = subprocess.run(
            [str(mac_share), "--find-device"],
            text=True,
            env=environment,
            capture_output=True,
            check=False,
        )
        check(missing.returncode == 1 and missing.stdout == "", "Mac share mounter reports an absent share")

        cmdline = temporary_path / "cmdline"
        # "Wörk Files" as URL-safe base64 without padding, as the launcher emits it.
        cmdline.write_text("root=/dev/vda rw omarchy.qemu_virgl=1 omarchy.shared_folder_name=V8O2cmsgRmlsZXM\n")
        home = temporary_path / "home"
        (home / "Documents").mkdir(parents=True)
        (home / "OldName").symlink_to("/mnt/mac")
        environment["OMARCHY_MAC_SHARE_CMDLINE"] = str(cmdline)
        environment["OMARCHY_MAC_SHARE_ASSUME_MOUNTED"] = "1"
        environment["HOME"] = str(home)
        name = subprocess.run([str(mac_share), "--name"], text=True, env=environment, capture_output=True, check=True)
        check(name.stdout == "Wörk Files\n", "Mac share link name decodes from the kernel command line")
        for option_like_name in ("-n", "-e", "-E"):
            cmdline.write_text(
                f"root=/dev/vda rw omarchy.shared_folder_name={encoded_share_name(option_like_name)}\n"
            )
            decoded = subprocess.run(
                [str(mac_share), "--name"], text=True, env=environment, capture_output=True, check=True
            )
            check(
                decoded.stdout == f"{option_like_name}\n",
                f"Mac share link preserves option-like name {option_like_name}",
            )
        cmdline.write_text("root=/dev/vda rw omarchy.qemu_virgl=1 omarchy.shared_folder_name=V8O2cmsgRmlsZXM\n")
        subprocess.run([str(mac_share), "--link"], env=environment, check=True, capture_output=True)
        check(
            os.readlink(home / "Wörk Files") == "/mnt/mac" and not (home / "OldName").exists(),
            "Mac share link uses the Mac folder name and drops stale links",
        )
        cmdline.write_text("root=/dev/vda rw omarchy.shared_folder_name=RG9jdW1lbnRz\n")
        subprocess.run([str(mac_share), "--link"], env=environment, check=True, capture_output=True)
        check(
            os.readlink(home / "Documents") == "/mnt/mac" and not (home / "Wörk Files").exists(),
            "Mac share link replaces an empty xdg folder of the same name",
        )
        (home / "Documents").unlink()
        (home / "Documents").mkdir()
        (home / "Documents" / "keep.txt").write_text("keep")
        subprocess.run([str(mac_share), "--link"], env=environment, check=True, capture_output=True)
        check(
            (home / "Documents" / "keep.txt").exists() and os.readlink(home / "Mac") == "/mnt/mac",
            "Mac share link keeps a populated folder and falls back to ~/Mac",
        )
        cmdline.write_text("root=/dev/vda rw\n")
        check(
            subprocess.run([str(mac_share), "--name"], text=True, env=environment, capture_output=True, check=True).stdout == "Mac\n",
            "Mac share link name falls back to Mac without a launcher parameter",
        )

        # Sharing turned off: the link service still runs, drops every link to
        # the mount point, and gives back an xdg folder that a link displaced.
        (home / "Documents" / "keep.txt").unlink()
        (home / "Documents").rmdir()
        (home / "Documents").symlink_to("/mnt/mac")
        (home / ".config").mkdir()
        (home / ".config" / "user-dirs.dirs").write_text(
            'XDG_DESKTOP_DIR="$HOME/Desktop"\nXDG_DOCUMENTS_DIR="$HOME/Documents"\n'
        )
        environment["OMARCHY_MAC_SHARE_ASSUME_MOUNTED"] = "0"
        subprocess.run([str(mac_share), "--link"], env=environment, check=True, capture_output=True)
        check(
            not (home / "Mac").is_symlink()
            and not (home / "Mac").exists()
            and (home / "Documents").is_dir()
            and not (home / "Documents").is_symlink(),
            "Mac share link cleanup runs without a mount and restores a displaced xdg folder",
        )

        # Existing non-XDG directories belong to the guest, even when empty.
        # Use ~/Mac as the fallback instead of deleting the existing folder.
        work = home / "Work"
        work.mkdir()
        cmdline.write_text(
            f"root=/dev/vda rw omarchy.shared_folder_name={encoded_share_name('Work')}\n"
        )
        environment["OMARCHY_MAC_SHARE_ASSUME_MOUNTED"] = "1"
        subprocess.run([str(mac_share), "--link"], env=environment, check=True, capture_output=True)
        check(
            work.is_dir() and not work.is_symlink() and os.readlink(home / "Mac") == "/mnt/mac",
            "Mac share link preserves an empty non-xdg folder and falls back to ~/Mac",
        )
        environment["OMARCHY_MAC_SHARE_ASSUME_MOUNTED"] = "0"
        subprocess.run([str(mac_share), "--link"], env=environment, check=True, capture_output=True)
        check(work.is_dir(), "Mac share cleanup leaves the preserved non-xdg folder intact")

        # Names beginning with two dots are valid Mac basenames and must be
        # included when stale links are removed.
        cmdline.write_text(
            f"root=/dev/vda rw omarchy.shared_folder_name={encoded_share_name('..Work')}\n"
        )
        environment["OMARCHY_MAC_SHARE_ASSUME_MOUNTED"] = "1"
        subprocess.run([str(mac_share), "--link"], env=environment, check=True, capture_output=True)
        hidden_share = home / "..Work"
        check(
            hidden_share.is_symlink() and os.readlink(hidden_share) == "/mnt/mac",
            "Mac share link supports a name beginning with two dots",
        )
        environment["OMARCHY_MAC_SHARE_ASSUME_MOUNTED"] = "0"
        subprocess.run([str(mac_share), "--link"], env=environment, check=True, capture_output=True)
        check(not hidden_share.exists() and not hidden_share.is_symlink(), "Mac share cleanup removes a ..-prefixed link")
        cmdline.write_text("root=/dev/vda rw\n")
        environment["OMARCHY_MAC_SHARE_ASSUME_MOUNTED"] = "1"

        # Sharing turned off: --mount returns at once instead of polling for
        # a device that will never appear.
        environment["OMARCHY_MAC_SHARE_TAG"] = "mac"
        started = time.monotonic()
        skipped = subprocess.run(
            [str(mac_share), "--mount"], text=True, env=environment, capture_output=True, check=False
        )
        check(
            skipped.returncode == 0
            and "sharing is off" in skipped.stderr
            and time.monotonic() - started < 2,
            "Mac share mount returns immediately when the launcher shares nothing",
        )
        check(
            subprocess.run([str(mac_share), "--enabled"], env=environment, check=False).returncode == 1,
            "Mac share reports sharing off without a launcher parameter",
        )
        cmdline.write_text("root=/dev/vda rw omarchy.shared_folder_name=RG9jdW1lbnRz\n")
        check(
            subprocess.run([str(mac_share), "--enabled"], env=environment, check=False).returncode == 0,
            "Mac share reports sharing on with a launcher parameter",
        )
    share_unit = read(GUEST / "native-overlay/usr/lib/systemd/system/omarchy-native-mac-share.service")
    check(
        "ExecStart=/usr/local/bin/omarchy-native-mac-share --mount" in share_unit
        and "Before=sddm.service" in share_unit,
        "Mac share mounts before the display manager",
    )
    link_unit = read(GUEST / "native-overlay/usr/lib/systemd/user/omarchy-native-mac-share-link.service")
    check(
        "ExecStart=/usr/local/bin/omarchy-native-mac-share --link" in link_unit
        and "ConditionPathIsMountPoint" not in link_unit,
        "Mac share link service runs at login even when nothing is mounted",
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
        mac_share,
        *GUEST.glob("*.sh"),
        *GUEST.glob("scripts/*.sh"),
        *GUEST.glob("fragments/*.sh"),
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
        release_tag = f"v{spec['upstream']['release']}^{{commit}}"
        tagged_commit = subprocess.run(
            ["git", "-C", str(source), "rev-parse", release_tag],
            check=True,
            text=True,
            capture_output=True,
        ).stdout.strip()
        check(tagged_commit == expected_commit, "optional Omarchy source checkout matches the release tag")
        for record in user_migration_manifest.splitlines():
            expected_digest, filename = record.split("\t")
            affected_toggle = source / "default/hypr/toggles" / filename
            check(
                affected_toggle.is_file()
                and hashlib.sha256(affected_toggle.read_bytes()).hexdigest()
                == expected_digest,
                f"user migration digest matches pinned toggle {filename}",
            )
        for relative in spec["authenticity"]["requiredPaths"]:
            check((source / relative).exists(), f"pinned source contains {relative}")

    print("native guest contract verified")


if __name__ == "__main__":
    main()
