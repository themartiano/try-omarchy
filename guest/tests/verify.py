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
import shutil
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
    check(set(spec["inputs"]) == {"packages", "packageLock", "pacmanConfig"}, "spec has a minimal input set")
    for path in spec["inputs"].values():
        check((GUEST / path).is_file(), f"spec input exists: {path}")

    authenticity = spec["authenticity"]
    verbatim_trees = authenticity["verbatimRuntimeTrees"]
    backported_trees = authenticity["backportedRuntimeTrees"]
    check(
        "shell" not in verbatim_trees
        and backported_trees == ["shell"]
        and not set(verbatim_trees) & set(backported_trees),
        "patched shell tree is separated from verbatim upstream runtime trees",
    )
    backports = authenticity["backports"]
    check(
        [backport.get("id") for backport in backports]
        == ["notification-hover-close", "notification-screen-privacy"],
        "notification backports are explicitly ordered and identified",
    )
    for backport in backports:
        patch_path = GUEST / backport["patch"]
        check(patch_path.is_file(), f"backport patch exists: {backport['id']}")
        check(
            hashlib.sha256(patch_path.read_bytes()).hexdigest() == backport["patchSha256"],
            f"backport patch digest matches: {backport['id']}",
        )
        check(
            backport.get("reference", "").startswith("https://github.com/basecamp/omarchy/"),
            f"backport has an upstream review reference: {backport['id']}",
        )
        for target in backport["targets"]:
            check(
                re.fullmatch(r"[0-9a-f]{64}", target.get("beforeSha256", "")) is not None
                and re.fullmatch(r"[0-9a-f]{64}", target.get("afterSha256", "")) is not None,
                f"backport target digests are pinned: {backport['id']} {target['path']}",
            )

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
        "IgnorePkg = linux-aarch64 hyprland" in pacman_conf,
        "factory pacman holds the QEMU-booted kernel and patched compositor",
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
    ttfx = spec.get("supplyChain", {}).get("ttfx", {})
    check(
        ttfx
        == {
            "version": "0.3.2",
            "pkgrel": 1,
            "repository": "https://github.com/omacom-io/ttfx",
            "commit": "7203e354498462064b7c0a89375051f65cf2ce99",
            "tree": "2162aa57e857d28d6e81fcbe1c65ad390d4f24f3",
            "packageRecipeCommit": "6284fcf437681c5e9b5cb6354fb111c48125ed3f",
            "url": "https://github.com/omacom-io/ttfx/archive/refs/tags/v0.3.2.tar.gz",
            "sha256": "d0c0df4867e7f03142fb7f77c66670d0e8da15534239c1a7abfd89f19dfc00f6",
            "cargoLockSha256": "49e2091962fc4d425b4cf3bde1a105719b5b50eed0583ec90e85922adb45e2ce",
            "binarySha256": "9171a07c752b202a21f80a4ad336a9d093be06a6c96b062e8b5e0c158d2a86d2",
            "target": "aarch64-unknown-linux-gnu",
            "rustPackageVersion": "rust 1:1.98.0-1",
            "rustcVersion": "rustc 1.98.0 (88d9e12ae 2026-08-18) (Arch Linux rust 1:1.98.0-1)",
            "cargoVersion": "cargo 1.98.0 (797e8a9bc 2026-08-05) (Arch Linux rust 1:1.98.0-1)",
            "reportedVersion": "ttfx 0.3.2",
            "license": "MIT",
            "licenseSha256": "175441de2eb9a0d3f0627c404ad71929336fd98d75926cc27b9e364d35cc7977",
            "noticeSha256": "e2db8c2ff527fdd6d012440d629916e9d75328f38d0e0975f4e942ea91c4e98c",
        },
        "official ttfx ARM64 source build and package recipe are fully pinned",
    )
    hyprland = spec.get("supplyChain", {}).get("hyprland", {})
    check(
        hyprland
        == {
            "version": "0.56.1",
            "pkgrel": "3.1",
            "upstreamPackageVersion": "0.56.1-3",
            "repository": "https://github.com/hyprwm/Hyprland",
            "commit": "5c9377c15f85c50648f35ca5a213754f95b93ca0",
            "url": "https://github.com/hyprwm/Hyprland/releases/download/v0.56.1/source-v0.56.1.tar.gz",
            "sha256": "c5b26eb377360358d01839a1de43fdc004a33e56d6a5d442fdad69b9f3a10549",
            "upstreamPackageSha256": "4fcb1b5efe019e184a85b234f75151e68fd8f60ace9b06ff59e7ffbd8a280f7a",
            "patch": "patches/hyprland/rounded-border-coverage.patch",
            "patchSha256": "0edaf034b16849e4364d2a6524319416c65e811d96b7bf5ea17d3d0e2ae9c472",
            "glazeVersion": "7.2.0",
            "glazeCommit": "b518eec7a22e56ffa238b072c07f47efa7cea97f",
            "glazeUrl": "https://github.com/stephenberry/glaze/archive/refs/tags/v7.2.0.tar.gz",
            "glazeSha256": "17dba19ae63ae48f94994f00d49d5cb3c8f1306db1046c534c4828662490b7d4",
            "glazeLicenseSha256": "5d49e66411a0807a7c8d6b911b9a26b59e940c71aebe561a3ad8b0b80ac4b7b6",
            "binarySha256": "dace45cd963209dcd6560c333b9fdd23624c635e88811caa147a3b0d384dc6a8",
            "license": "BSD-3-Clause",
            "issue": "https://github.com/themartiano/try-omarchy/issues/5",
            "buildPackages": {
                "base-devel": "1-2",
                "binutils": "2.46+r70+g155188ea10a7-1",
                "cmake": "4.4.3-1",
                "gcc": "16.1.1+r12+g301eb08fa2c5-1",
                "gcc-libs": "16.1.1+r12+g301eb08fa2c5-1",
                "glibc": "2.43+r22+g8362e8ce10b2-2",
                "hyprland": "0.56.1-3",
                "hyprland-protocols": "0.7.0-1",
                "make": "4.4.1-3",
                "meson": "1.12.0-1",
                "ninja": "1.13.2-3",
                "pkgconf": "3.0.6-1",
                "xorgproto": "2025.1-1",
            },
        }
        and packages.get("hyprland") == hyprland["upstreamPackageVersion"],
        "rounded-border Hyprland source, toolchain, and upstream package are fully pinned",
    )
    hyprland_patch = GUEST / hyprland["patch"]
    check(
        hyprland_patch.is_file()
        and hashlib.sha256(hyprland_patch.read_bytes()).hexdigest() == hyprland["patchSha256"],
        "rounded-border Hyprland patch digest matches the build spec",
    )
    launcher = read(REPO / "macos/run-qemu-gpu.sh")
    hyprland_identity = hashlib.sha256(
        json.dumps(
            hyprland,
            ensure_ascii=True,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    check(
        'supply_chain.get("hyprland")' in launcher
        and '"build spec hyprland component"' in launcher
        and '"build spec hyprland build packages"' in launcher
        and hyprland_identity in launcher,
        "native launcher accepts and pins the patched Hyprland component",
    )
    hyprland_patch_text = read(hyprland_patch)
    check(
        "roundingWithEdgeBias" in hyprland_patch_text
        and "SMOOTHING_CONSTANT * 2.0" in hyprland_patch_text
        and "RENDERED_BORDER_SIZE >= 3 && WINDOWOPAQUE &&" in hyprland_patch_text
        and "m_data.mainSurface" in hyprland_patch_text
        and "including for translucent borders" in hyprland_patch_text
        and "BORDEROPAQUE" not in hyprland_patch_text
        and "+    if (!ROUNDING_OVERLAPS_BORDER)" in hyprland_patch_text
        and "-    rounding -= 1; // to fix a border issue" in hyprland_patch_text,
        "Hyprland backport guards the two-pass rounded-border coverage overlap",
    )

    container = read(GUEST / "build-container.sh")
    check("linux/arm64" in container and '"$guest_dir/Containerfile"' in container, "container builder targets ARM64")
    check('output="$repo_dir/dist/guest"' in container, "guest output defaults to dist/guest")
    check("try-omarchy-guest-work" in container, "guest cache has a project-scoped Docker volume")
    containerfile = read(GUEST / "Containerfile")
    check(
        "arch-install-scripts e2fsprogs git python rust=1:1.98.0-1 zstd" in containerfile,
        "guest builder pins Rust for source-built components",
    )

    materialize = read(GUEST / "scripts/materialize-omarchy.sh")
    check(
        'mkdir -p "$root/etc/skel/.local/state/omarchy/toggles/hypr"' in materialize
        and 'copy_contents "$source_dir/default/hypr/toggles"' not in materialize
        and 'toggles/flags.lua' in materialize,
        "skel hypr toggles seed only flags.lua, not the catalog",
    )

    configure = read(GUEST / "scripts/configure-rootfs.sh")
    check("factory-overlay" in configure and "native-overlay" in configure, "rootfs receives only native factory overlays")
    check(
        "compat/ttfx-arm64" not in configure and not (GUEST / "compat/ttfx-arm64").exists(),
        "obsolete no-op ttfx compatibility command is absent",
    )
    check("omarchy-provision-owner.service" in configure, "first boot uses upstream owner provisioning")
    native_autologin = read(
        GUEST
        / "native-overlay/etc/systemd/system/omarchy-provision-owner.service.d/10-try-omarchy-native.conf"
    )
    check(
        "ExecStartPost=" in native_autologin
        and "omarchy-provision-autologin-once.service" in native_autologin,
        "native provisioning keeps direct graphical login across VM boots",
    )
    check("omarchy-native-audio-bridge" in configure, "guest installs native host-audio integration")
    check(
        "graphical-session.target.wants/omarchy-native-clipboard-bridge.service" in configure,
        "guest starts clipboard sharing with the graphical session",
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
        'install -m 0644 "$pacman_conf" "$root/usr/share/try-omarchy/pacman.conf"'
        in local_repository
        and 'install -m 0644 "$root/etc/pacman.d/mirrorlist" "$root/usr/share/try-omarchy/mirrorlist"'
        in local_repository,
        "pacman recovery files snapshot the final local-repository configuration",
    )
    check(
        "expected_archive_count=5" in local_repository
        and "factory repository is missing pinned ttfx" in local_repository
        and "factory repository is missing pinned yay" in local_repository
        and "factory repository is missing patched Hyprland" in local_repository
        and "immutable local repository does not have priority" in local_repository
        and "resolves the patched Hyprland package locally" in local_repository
        and "refusing canonical unsafe root" in local_repository,
        "immutable local repository requires and prioritizes the patched Hyprland",
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
        and '"$root/usr/bin/omarchy-screensaver"' in configure
        and "for native_command in omarchy-audio-input-set-default omarchy-screensaver" in configure
        and "did not replace the upstream command" in configure,
        "native input selection and screensaver cleanup replace upstream commands",
    )
    check("cmp -s" not in configure, "rootfs configuration uses only declared build tools")

    build = read(GUEST / "build.sh")
    check(
        "verify-screensaver-override.py" in build
        and build.index("verify-screensaver-override.py") < build.index("materialize-omarchy.sh"),
        "every guest build checks the screensaver override against its pinned source",
    )
    check(
        "apply-omarchy-backports.py" in build
        and build.index("materialize-omarchy.sh") < build.index("apply-omarchy-backports.py")
        < build.index("configure-rootfs.sh"),
        "reviewed Omarchy backports apply only to the verified staged source",
    )
    provenance_writer = read(GUEST / "scripts/write-provenance.py")
    check(
        "backportedRuntimeTrees" in provenance_writer
        and '"backports": backports' in provenance_writer
        and "enumerated reviewed backports" in provenance_writer,
        "guest provenance distinguishes verbatim trees from reviewed backports",
    )
    register_runtime = read(GUEST / "scripts/register-omarchy-runtime.sh")
    check(
        'cursor_restore="$root/usr/local/bin/omarchy-native-cursor-restore"' in register_runtime
        and 'cp -a "$cursor_restore" "$stage/usr/local/bin/omarchy-native-cursor-restore"'
        in register_runtime,
        "packaged Omarchy runtime owns the screensaver cursor helper",
    )
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
    register_ttfx = read(GUEST / "scripts/register-pinned-ttfx.sh")
    check(
        "register-pinned-ttfx.sh" in build
        and build.index("register-pinned-ttfx.sh")
        < build.index("register-local-repository.sh")
        and "download digest mismatch" in register_ttfx
        and "ttfx source archive has an unsafe member set" in register_ttfx
        and "ttfx Cargo.lock digest mismatch" in register_ttfx
        and "ttfx license digest mismatch" in register_ttfx
        and "ttfx notice digest mismatch" in register_ttfx
        and 'cargo fetch --locked --target "$target"' in register_ttfx
        and 'cargo build --frozen --release --target "$target"' in register_ttfx
        and "CARGO_ENCODED_RUSTFLAGS" in register_ttfx
        and "ttfx Rust package identity mismatch" in register_ttfx
        and "ttfx reproducible binary digest mismatch" in register_ttfx
        and "ttfx build is missing required screensaver option" in register_ttfx
        and "ttfx build failed its bounded ASCII render smoke test" in register_ttfx
        and "ttfx build is not an ARM64 ELF binary" in register_ttfx
        and "provides = ttfx=$version" in register_ttfx
        and "conflict = ttfx" in register_ttfx
        and "installed ttfx binary differs from the built artifact" in register_ttfx
        and 'arch-chroot "$root" /usr/bin/ttfx --version' in register_ttfx,
        "guest builds and packages verified ttfx before sealing its local repository",
    )
    register_hyprland = read(GUEST / "scripts/register-patched-hyprland.sh")
    check(
        "register-patched-hyprland.sh" in build
        and build.index("register-patched-hyprland.sh")
        < build.index("register-local-repository.sh")
        and "Hyprland source archive has an unsafe member set" in register_hyprland
        and "Hyprland patch digest mismatch" in register_hyprland
        and "git apply --check" in register_hyprland
        and "FETCHCONTENT_SOURCE_DIR_GLAZE" in register_hyprland
        and "reproducible binary digest mismatch" in register_hyprland
        and "upstream package digest mismatch" in register_hyprland
        and "installed Hyprland binary digest mismatch" in register_hyprland
        and "could not generate patched Hyprland mtree" in register_hyprland
        and "pacman -Qkk" in register_hyprland
        and "Glaze license digest mismatch" in register_hyprland
        and "LICENSE.glaze" in register_hyprland
        and "build_package_records[@]} == 13" in register_hyprland
        and "builder_pacman_config" in register_hyprland
        and "could not derive the Hyprland builder pacman configuration" in register_hyprland
        and 'pacman -Syy --noconfirm --config "$builder_pacman_config"' in register_hyprland
        and register_hyprland.index(
            'pacman -Syy --noconfirm --config "$builder_pacman_config"'
        )
        < register_hyprland.index(
            'pacman --noconfirm --config "$builder_pacman_config" -S --needed'
        )
        and "refusing canonical unsafe root" in register_hyprland,
        "guest builds and packages the verified Hyprland rounded-border backport",
    )
    third_party_notices = read(REPO / "THIRD_PARTY_NOTICES.md")
    check(
        "**yay**" in third_party_notices and "GPL-3.0-or-later" in third_party_notices,
        "third-party notices cover the pinned yay redistribution",
    )
    check(
        "**ttfx**" in third_party_notices
        and "TerminalTextEffects" in third_party_notices
        and "MIT" in third_party_notices,
        "third-party notices cover ttfx and its TerminalTextEffects attribution",
    )
    check(
        "**Hyprland**" in third_party_notices and "BSD-3-Clause" in third_party_notices,
        "third-party notices cover the patched Hyprland redistribution",
    )
    check(
        "**Glaze**" in third_party_notices and "MIT" in third_party_notices,
        "third-party notices cover the Hyprland build's bundled Glaze headers",
    )

    finalizer = read(GUEST / "scripts/finalize-rootfs.sh")
    check("factory" in finalizer and "aarch64" in finalizer, "finalizer enforces the native factory contract")
    check("systemd-growfs-root.service" in finalizer, "factory disk grows on first boot")
    check("systemctl enable omarchy-native-mac-share.service" in finalizer, "shared Mac folder mounts at boot")
    check(
        'expected_ttfx=$(read_spec' in finalizer
        and "/usr/bin/ttfx --version" in finalizer
        and "pacman -Qoq /usr/local/bin/omarchy-native-cursor-restore" in finalizer
        and "Obsolete ttfx compatibility command shadows" in finalizer,
        "finalizer requires packaged ttfx without a shadowing compatibility command",
    )
    check(
        "pacman -Q hyprland" in finalizer
        and "Rounded-border Hyprland backport is missing" in finalizer
        and "Rounded-border Hyprland binary digest mismatch" in finalizer,
        "finalizer requires the exact rounded-border Hyprland package",
    )

    manifest_writer = read(GUEST / "scripts/write-guest-manifest.py")
    check('"kind": "try-omarchy-guest-artifacts"' in manifest_writer, "new artifacts use the native manifest identity")

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

    screensaver_override = GUEST / "native-overlay/usr/bin/omarchy-screensaver"
    cursor_restore = GUEST / "native-overlay/usr/local/bin/omarchy-native-cursor-restore"
    check(screensaver_override.stat().st_mode & stat.S_IXUSR != 0, "native screensaver override is executable")
    check(cursor_restore.stat().st_mode & stat.S_IXUSR != 0, "native cursor restore helper is executable")
    check(
        "/usr/local/bin/omarchy-native-cursor-restore 2>/dev/null || true"
        in read(screensaver_override),
        "screensaver cleanup delegates to the native cursor policy",
    )

    display_sync = GUEST / "native-overlay/usr/local/bin/omarchy-native-display-sync"
    check(display_sync.stat().st_mode & stat.S_IXUSR != 0, "native display sync is executable")
    monitor_fragment = read(GUEST / "fragments/hypr-monitors-arm-qemu.append.lua")
    check(
        'o.exec_on_start("/usr/local/bin/omarchy-native-display-sync")'
        in monitor_fragment
        and 'omarchy_kernel_option_enabled("omarchy.qemu_virgl=1")' in monitor_fragment
        and "cursor = { invisible = true }" in monitor_fragment,
        "ARM VirGL profile starts display sync and uses the host-composited cursor",
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
        screensaver_override,
        cursor_restore,
        display_sync,
        mac_share,
        *GUEST.glob("*.sh"),
        *GUEST.glob("scripts/*.sh"),
        *GUEST.glob("fragments/*.sh"),
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
        for relative in spec["authenticity"]["requiredPaths"]:
            check((source / relative).exists(), f"pinned source contains {relative}")

        for backport in backports:
            for target in backport["targets"]:
                check(
                    hashlib.sha256((source / target["path"]).read_bytes()).hexdigest()
                    == target["beforeSha256"],
                    f"pinned source matches backport preimage: {backport['id']} {target['path']}",
                )

        with tempfile.TemporaryDirectory() as temporary:
            staged_root = Path(temporary) / "root"
            staged_omarchy = staged_root / "usr/share/omarchy"
            for backport in backports:
                for target in backport["targets"]:
                    destination = staged_omarchy / target["path"]
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source / target["path"], destination)

            subprocess.run(
                [
                    "python3",
                    str(GUEST / "scripts/apply-omarchy-backports.py"),
                    "--root",
                    str(staged_root),
                    "--spec",
                    str(GUEST / "spec.json"),
                ],
                check=True,
                text=True,
                capture_output=True,
            )
            for backport in backports:
                for target in backport["targets"]:
                    check(
                        hashlib.sha256((staged_omarchy / target["path"]).read_bytes()).hexdigest()
                        == target["afterSha256"],
                        f"backport produces reviewed postimage: {backport['id']} {target['path']}",
                    )

            notification_card = read(
                staged_omarchy / "shell/plugins/notifications/components/NotificationCard.qml"
            )
            check(
                'Layout.rightMargin: Style.space(10)' in notification_card
                and 'opacity: root.hovered ? 1 : 0' in notification_card
                and 'text: "✕"' in notification_card
                and 'onClicked: root.closeRequested()' in notification_card
                and notification_card.index("// Hover-revealed close")
                > notification_card.index("id: mainColumn"),
                "notification hover exposes a topmost clickable dismiss control",
            )

            notification_service = read(
                staged_omarchy / "shell/plugins/notifications/Service.qml"
            )
            check(
                'firstPartyServiceFor("omarchy.idle")' in notification_service
                and 'firstPartyServiceFor("omarchy.lock")' in notification_service
                and "!idleService.screensaverStateKnown" in notification_service
                and 'visible: popupModel.count > 0 && !service.screenObscured'
                in notification_service
                and "!card.hovered && !service.screenObscured" in notification_service,
                "notification popups hide and pause behind screensaver and lock surfaces",
            )
            idle_service = read(staged_omarchy / "shell/plugins/services/idle/Service.qml")
            check(
                "property bool screensaverStateKnown: false" in idle_service
                and 'command: ["hyprctl", "-j", "clients"]' in idle_service
                and "function reconcileScreensaverWindows(payload)" in idle_service
                and "screensaverWindowsClosedDuringProbe" in idle_service
                and "id: screensaverStateProbeRetry" in idle_service
                and idle_service.count("screensaverStateProbeRetry.restart()") >= 3
                and "!root.screensaverStateKnown && !screensaverStateProbe.running"
                in idle_service,
                "screensaver state reconciles preexisting windows and retries failed probes",
            )
            popup_visible = lambda count, state_known, screensavers, lock_ready, locked: (
                count > 0
                and state_known
                and screensavers == 0
                and lock_ready
                and not locked
            )
            check(
                popup_visible(1, True, 0, True, False)
                and not popup_visible(1, False, 0, True, False)
                and not popup_visible(1, True, 1, True, False)
                and not popup_visible(1, True, 0, False, False)
                and not popup_visible(1, True, 0, True, True)
                and not popup_visible(0, True, 0, True, False),
                "notification visibility covers startup, screensaver, lock, and empty states",
            )

        source_status = subprocess.run(
            ["git", "-C", str(source), "status", "--porcelain", "--untracked-files=all"],
            check=True,
            text=True,
            capture_output=True,
        ).stdout
        check(source_status == "", "backport verification leaves the pinned checkout untouched")

        upstream_screensaver = read(source / "bin/omarchy-screensaver")
        upstream_cursor_restore = (
            "  hyprctl eval 'hl.config({ cursor = { invisible = false } })' &>/dev/null "
            "|| hyprctl keyword cursor:invisible false &>/dev/null || true"
        )
        native_cursor_restore = "  /usr/local/bin/omarchy-native-cursor-restore 2>/dev/null || true"
        check(
            upstream_screensaver.count(upstream_cursor_restore) == 1
            and read(screensaver_override)
            == upstream_screensaver.replace(upstream_cursor_restore, native_cursor_restore),
            "native screensaver override differs from pinned upstream only at cursor restoration",
        )

    print("native guest contract verified")


if __name__ == "__main__":
    main()
