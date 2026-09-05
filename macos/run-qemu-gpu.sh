#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: macos/run-qemu-gpu.sh [--ephemeral | --reset-storage | --reset-storage-only] [GUEST_DIR]" >&2
  exit 64
}

fail() {
  echo "run-qemu-gpu: $*" >&2
  exit 1
}

storage_mode=persistent
reset_only=0
boot_recovery_consent_required_status=80
boot_recovery_failed_status=81
# QEMU 11's HVF backend requires Apple's in-hypervisor GICv3. Keep recovery
# and normal launches on one machine definition so they cannot drift apart.
qemu_machine='virt,accel=hvf,gic-version=3'

boot_recovery_fail() {
  echo "run-qemu-gpu: $*" >&2
  exit "$boot_recovery_failed_status"
}

case ${1:-} in
  --ephemeral)
    storage_mode=ephemeral
    shift
    ;;
  --reset-storage)
    storage_mode=reset
    shift
    ;;
  --reset-storage-only)
    storage_mode=reset
    reset_only=1
    shift
    ;;
  --*) usage ;;
esac
(( $# <= 1 )) || usage

script_dir=$(cd "$(dirname "$0")" && pwd -P)
resources_dir=$(cd "$script_dir/.." && pwd -P)
contents_dir=$(cd "$resources_dir/.." && pwd -P)
app_bundle=$(cd "$contents_dir/.." && pwd -P)
guest_input=${1:-"$resources_dir/guest"}
qemu_bin="$resources_dir/runtime/bin/Try Omarchy"
native_bridge="$contents_dir/MacOS/omarchy-vm-helper"
storage_library="$script_dir/qemu-persistent-storage.sh"
port_forwarding_library="$script_dir/qemu-port-forwarding.sh"

[[ $(uname -m) == arm64 ]] || fail "requires an ARM64 Mac"
[[ $(uname -s) == Darwin ]] || fail "requires macOS"
[[ -d $guest_input && ! -L $guest_input ]] || fail "ARM guest directory is missing or unsafe: $guest_input"
guest_dir=$(cd "$guest_input" && pwd -P)

for command in codesign file getconf id mktemp plutil ps sysctl; do
  command -v "$command" >/dev/null || fail "$command is required"
done

case ${OMARCHY_QEMU_GPU_INSPECT_ONLY:-0} in
  0)
    codesign --verify --deep --strict "$app_bundle" >/dev/null 2>&1 || {
      fail "the installed app is damaged or has an invalid code signature"
    }
    ;;
  1) ;;
  *) fail "OMARCHY_QEMU_GPU_INSPECT_ONLY must be 0 or 1" ;;
esac

[[ -f $qemu_bin && -x $qemu_bin ]] || {
  fail "missing bundled GPU QEMU runtime at $qemu_bin"
}
[[ -f $native_bridge && -x $native_bridge ]] || {
  fail "missing bundled native bridge at $native_bridge"
}
file "$qemu_bin" | grep -q 'arm64' || fail "staged QEMU is not an ARM64 executable"
LC_ALL=C grep -aFq 'TryOmarchy.icns' "$qemu_bin" || {
  fail "staged QEMU lacks the Try Omarchy macOS identity; run make runtime"
}
for marker in \
  OMARCHY_SDL_AUDIO_CONTROL_DIRECTORY \
  OMARCHY_SDL_INPUT_DEVICE_NAME \
  OMARCHY_SDL_OUTPUT_DEVICE_NAME; do
  LC_ALL=C grep -aFq "$marker" "$qemu_bin" || {
    fail "staged QEMU lacks persistent host audio routing; run make runtime"
  }
done
file "$native_bridge" | grep -q 'arm64' || fail "native bridge is not an ARM64 executable"
codesign --verify --strict "$native_bridge" >/dev/null 2>&1 || {
  fail "native bridge is not code-signed"
}

qemu_accels=$("$qemu_bin" -accel help 2>&1) || fail "cannot inspect staged QEMU accelerators"
printf '%s\n' "$qemu_accels" | grep -qx 'hvf' || fail "staged QEMU does not support HVF"
qemu_machines=$("$qemu_bin" -machine help 2>&1) || fail "cannot inspect staged QEMU machines"
printf '%s\n' "$qemu_machines" | grep -Eq '^virt[[:space:]]' || fail "staged QEMU does not provide the ARM virt machine"
qemu_cpus=$("$qemu_bin" -cpu help 2>&1) || fail "cannot inspect staged QEMU CPUs"
printf '%s\n' "$qemu_cpus" | grep -Eq '^[[:space:]]*host([[:space:]]|$)' || fail "staged QEMU does not expose the host CPU"
qemu_displays=$("$qemu_bin" -display help 2>&1) || fail "cannot inspect staged QEMU displays"
printf '%s\n' "$qemu_displays" | grep -qx 'cocoa' || fail "staged QEMU does not provide the Cocoa display"
qemu_devices=$("$qemu_bin" -device help 2>&1) || fail "cannot inspect staged QEMU devices"
qemu_help=$("$qemu_bin" -help 2>&1) || fail "cannot inspect staged QEMU options"
printf '%s\n' "$qemu_help" | grep -q -- '^-add-fd fd=fd,set=set' || {
  fail "staged QEMU cannot preserve the persistent-disk lock descriptor"
}
printf '%s\n' "$qemu_help" | grep -Fq -- '-action reboot=reset|shutdown' || {
  fail "staged QEMU cannot apply the required reboot policy"
}
printf '%s\n' "$qemu_help" | grep -Fq -- '-action shutdown=poweroff|pause' || {
  fail "staged QEMU cannot apply the required shutdown policy"
}
printf '%s\n' "$qemu_help" | grep -Fq 'full-grab=on|off' || {
  fail "staged QEMU cannot capture macOS system key combinations"
}
printf '%s\n' "$qemu_help" | grep -Fq 'immersive=on|off' || {
  fail "staged QEMU cannot select its fullscreen presentation"
}
qemu_netdevs=$("$qemu_bin" -machine virt -netdev help 2>&1) || {
  fail "cannot inspect staged QEMU network backends"
}
printf '%s\n' "$qemu_netdevs" | grep -qx 'user' || {
  fail "staged QEMU does not provide no-root SLIRP networking; run make runtime"
}
qemu_audiodevs=$("$qemu_bin" -machine virt -audiodev help 2>&1) || {
  fail "cannot inspect staged QEMU audio backends"
}
printf '%s\n' "$qemu_audiodevs" | grep -qx 'sdl' || {
  fail "staged QEMU does not provide duplex SDL audio; run make runtime"
}

require_qemu_device() {
  local device=$1
  [[ $qemu_devices == *"name \"$device\""* ]] || fail "staged QEMU does not provide $device"
}

for device in \
  hda-micro \
  intel-hda \
  virtconsole \
  virtserialport \
  virtio-balloon-pci \
  virtio-9p-pci \
  virtio-blk-pci \
  virtio-gpu-gl-pci \
  virtio-keyboard-pci \
  virtio-net-pci \
  virtio-rng-pci \
  virtio-serial-pci \
  virtio-tablet-pci; do
  require_qemu_device "$device"
done
for marker in guest_owner_uid guest_owner_gid; do
  LC_ALL=C grep -aFq "$marker" "$qemu_bin" || {
    fail "staged QEMU lacks the shared-folder owner mapping; run make runtime"
  }
done

qemu_entitlements=$(codesign -d --entitlements - "$qemu_bin" 2>&1) || {
  fail "staged QEMU is not code-signed for HVF"
}
[[ $qemu_entitlements == *com.apple.security.hypervisor* ]] || {
  fail "staged QEMU lacks the com.apple.security.hypervisor entitlement"
}

gpu_help=$("$qemu_bin" -device virtio-gpu-gl-pci,help 2>&1) || {
  fail "cannot inspect the staged VirGL device"
}
gpu_device='virtio-gpu-gl-pci,max_outputs=1,xres=1920,yres=1080'
if [[ $gpu_help == *'romfile=<str>'* ]]; then
  gpu_device+=',romfile='
fi

# Release apps carry the output of this strict validator in their signed
# resources, so a clean Mac does not need Python. Repo-local development
# bundles can still validate directly when no launch configuration is present.
launch_configuration="$guest_dir/launch.plist"
if [[ -f $launch_configuration && ! -L $launch_configuration ]]; then
  plist_read() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$launch_configuration" 2>/dev/null
  }
  bundle_validation=$(printf '%s\t%s\t%s\t%s\t%s\t%s' \
    "$(plist_read bundleIdentity)" \
    "$(plist_read sourceDiskSHA256)" \
    "$(plist_read sourceDiskBytes)" \
    "$(plist_read compressedDiskBytes)" \
    "$(plist_read workingDiskBytes)" \
    "$(plist_read kernelCommandLine)")
else
  command -v python3 >/dev/null 2>&1 || {
    fail "bundled launch configuration is missing and Python is unavailable for development validation"
  }
  # Emit one trusted tab-delimited record on stdout. All validation failures
  # go to stderr so command substitution cannot become launch data.
  bundle_validation=$(python3 - "$guest_dir" <<'PY'
import hashlib
import json
from pathlib import Path
import re
import stat
import sys


def fail(message: str) -> None:
    raise SystemExit(f"run-qemu-gpu: invalid ARM guest bundle: {message}")


def exact_keys(value: object, keys: set[str], label: str) -> dict[str, object]:
    if not isinstance(value, dict) or set(value) != keys:
        fail(f"{label} has an unexpected schema")
    return value


def load_json(path: Path, label: str) -> tuple[dict[str, object], bytes]:
    try:
        data = path.read_bytes()
        value = json.loads(data)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"cannot read {label}: {error}")
    if not isinstance(value, dict):
        fail(f"{label} is not a JSON object")
    return value, data


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            while chunk := handle.read(8 * 1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        fail(f"cannot hash {path.name}: {error}")
    return digest.hexdigest()


guest = Path(sys.argv[1])
expected_artifacts = {
    "LICENSE.omarchy": ("guest-license", "text/plain"),
    "build-spec.json": ("guest-metadata", "application/json"),
    "initramfs-linux.img": ("guest-initramfs", "application/vnd.linux.initramfs"),
    "packages.lock.txt": ("guest-metadata", "text/plain"),
    "provenance.json": ("guest-metadata", "application/json"),
    "rootfs.ext4": ("guest-rootfs", "application/vnd.omarchy.ext4"),
    "rootfs.ext4.zst": ("guest-rootfs-compressed", "application/zstd"),
    "vmlinuz-linux": ("guest-kernel", "application/vnd.linux.kernel"),
}
packaged_artifacts = set(expected_artifacts)
if not (guest / "rootfs.ext4").exists():
    packaged_artifacts.remove("rootfs.ext4")
expected_files = packaged_artifacts | {"guest-manifest.json", "SHA256SUMS"}

try:
    actual_files = {entry.name for entry in guest.iterdir()}
except OSError as error:
    fail(f"cannot enumerate bundle: {error}")
if actual_files != expected_files:
    missing = sorted(expected_files - actual_files)
    extra = sorted(actual_files - expected_files)
    fail(f"file set differs (missing={missing}, extra={extra})")
for name in expected_files:
    path = guest / name
    try:
        mode = path.lstat().st_mode
    except OSError as error:
        fail(f"cannot stat {name}: {error}")
    if not stat.S_ISREG(mode):
        fail(f"{name} is not a direct regular file")

manifest, manifest_data = load_json(guest / "guest-manifest.json", "guest-manifest.json")
exact_keys(
    manifest,
    {"artifacts", "build", "guest", "kind", "normalizedUpstreamTree", "schemaVersion", "upstream"},
    "guest-manifest.json",
)
if manifest.get("schemaVersion") != 1 or manifest.get("kind") != "try-omarchy-guest-artifacts":
    fail("guest manifest identity is invalid")
manifest_guest_raw = manifest.get("guest")
if not isinstance(manifest_guest_raw, dict):
    fail("guest manifest guest has an unexpected schema")
manifest_profile = manifest_guest_raw.get("profile")
manifest_guest_keys = {"architecture", "display", "distribution", "kernelCommandLine", "profile", "username"}
manifest_guest = exact_keys(manifest_guest_raw, manifest_guest_keys, "guest manifest guest")
if (
    manifest_guest.get("architecture") != "aarch64"
    or manifest_guest.get("distribution") != "Arch Linux"
    or manifest_profile != "factory"
    or manifest_guest.get("username") is not None
):
    fail("guest manifest is not a native ARM64 Omarchy factory guest")

spec, _ = load_json(guest / "build-spec.json", "build-spec.json")
exact_keys(
    spec,
    {
        "authenticity",
        "guest",
        "image",
        "inputs",
        "runtime",
        "schemaVersion",
        "supplyChain",
        "themes",
        "upstream",
    },
    "build-spec.json",
)
if spec.get("schemaVersion") != 1:
    fail("unsupported build spec schema")
image = exact_keys(
    spec.get("image"),
    {"architecture", "filesystem", "filesystemLabel", "filesystemUuid", "sizeMiB", "sourceDateEpoch"},
    "build spec image",
)
spec_guest_raw = spec.get("guest")
if not isinstance(spec_guest_raw, dict):
    fail("build spec guest has an unexpected schema")
spec_profile = spec_guest_raw.get("profile")
spec_guest_keys = {"defaultTheme", "hostname", "profile", "uid", "username", "virtualDisplay"}
spec_guest = exact_keys(spec_guest_raw, spec_guest_keys, "build spec guest")
if spec_profile != "factory" or manifest_profile != spec_profile:
    fail("manifest and build spec must describe the factory profile")

profile_contract = {
    "filesystemLabel": "omarchy-factory",
    "filesystemUuid": "89054943-1f4e-4f14-b934-d6db3fba4254",
    "sizeMiB": 6144,
    "hostname": "omarchy-factory",
    "username": None,
    "uid": None,
    "defaultTheme": None,
}
if (
    image.get("architecture") != "aarch64"
    or image.get("filesystem") != "ext4"
    or image.get("filesystemLabel") != profile_contract["filesystemLabel"]
    or image.get("filesystemUuid") != profile_contract["filesystemUuid"]
    or image.get("sizeMiB") != profile_contract["sizeMiB"]
):
    fail("build spec image contract is invalid")

display = exact_keys(
    spec_guest.get("virtualDisplay"),
    {"height", "refreshHz", "scale", "width"},
    "build spec display",
)
if (
    spec_guest.get("hostname") != profile_contract["hostname"]
    or spec_guest.get("username") != profile_contract["username"]
    or spec_guest.get("uid") != profile_contract["uid"]
    or spec_guest.get("defaultTheme") != profile_contract["defaultTheme"]
    or display != {"width": 1600, "height": 900, "refreshHz": 60, "scale": 1}
    or manifest_guest.get("display") != display
):
    fail("guest or display contract is invalid")

runtime = exact_keys(
    spec.get("runtime"),
    {
        "audio",
        "camera",
        "clipboard",
        "compressedDisk",
        "devices",
        "disk",
        "graphics",
        "hypervisor",
        "initramfs",
        "initramfsSource",
        "kernel",
        "kernelCommandLine",
        "kernelSource",
        "minimumCpuCount",
        "minimumMemoryMiB",
        "network",
        "recommendedMemoryMiB",
        "sharedFolder",
        "storage",
        "virtualMachineMonitor",
    },
    "build spec runtime",
)
expected_devices = [
    "virtio-blk-pci",
    "virtio-gpu-gl-pci",
    "virtio-keyboard-pci",
    "virtio-tablet-pci",
    "virtio-net-pci",
    "virtio-serial-pci",
    "virtconsole",
    "virtserialport",
    "virtio-rng-pci",
    "virtio-balloon-pci",
    "intel-hda",
    "hda-micro",
    "virtio-9p-pci",
]
clipboard = {
    "device": "virtserialport",
    "port": "dev.tryomarchy.clipboard",
    "formats": ["text/plain;charset=utf-8", "image/png"],
}
shared_folder = {
    "device": "virtio-9p-pci",
    "fsdriver": "local",
    "securityModel": "none",
    "mountTag": "mac",
    "guestOwnerUid": 1000,
    "guestOwnerGid": 1000,
    "guestMountPoint": "/mnt/mac",
    "guestLinkNameParameter": "omarchy.shared_folder_name",
}
graphics = {
    "device": "virtio-gpu-gl-pci",
    "display": "cocoa",
    "guestRenderer": "virgl",
    "hostRenderer": "angle-metal",
}
network = {
    "device": "virtio-net-pci",
    "backend": "slirp",
    "mode": "user",
    "sshAccess": {
        "activation": {
            "guestPort": 22,
            "kernelToken": "tryomarchy.ssh_access=1",
            "protocol": "tcp",
            "scope": "boot",
            "service": "sshd.service",
        },
        "preset": {
            "guestPort": 22,
            "hostAddress": "127.0.0.1",
            "hostPort": 2222,
            "protocol": "tcp",
        },
    },
}
audio = {
    "controller": "intel-hda",
    "codec": "hda-micro",
    "backend": "sdl",
    "duplex": True,
}
camera = {
    "activation": "on-demand",
    "device": "virtserialport",
    "framesPerSecond": 30,
    "guestDevice": "/dev/video42",
    "height": 720,
    "pixelFormat": "NV12",
    "port": "dev.tryomarchy.camera",
    "protocolVersion": 1,
    "width": 1280,
}
storage = {
    "device": "virtio-blk-pci",
    "format": "raw",
    "mode": "ephemeral",
    "initialization": "apfs-clone",
    "fallback": "full-copy",
    "expandedSizeMiB": 24576,
}
if (
    runtime.get("kernel") != "vmlinuz-linux"
    or runtime.get("kernelSource") != "/boot/Image"
    or runtime.get("initramfs") != "initramfs-linux.img"
    or runtime.get("initramfsSource") != "/boot/initramfs-linux.img"
    or runtime.get("disk") != "rootfs.ext4"
    or runtime.get("compressedDisk") != "rootfs.ext4.zst"
    or runtime.get("virtualMachineMonitor") != "qemu-system-aarch64"
    or runtime.get("hypervisor") != "hvf"
    or runtime.get("graphics") != graphics
    or runtime.get("network") != network
    or runtime.get("audio") != audio
    or runtime.get("camera") != camera
    or runtime.get("storage") != storage
    or runtime.get("clipboard") != clipboard
    or runtime.get("sharedFolder") != shared_folder
    or runtime.get("devices") != expected_devices
    or runtime.get("minimumMemoryMiB") != 2048
    or runtime.get("recommendedMemoryMiB") != 4096
    or runtime.get("minimumCpuCount") != 4
):
    fail("native runtime contract is invalid")

upstream = exact_keys(
    spec.get("upstream"),
    {"channel", "commit", "license", "release", "repository", "tree", "treeSha256", "version"},
    "build spec upstream",
)
if (
    upstream.get("repository") != "https://github.com/basecamp/omarchy"
    or upstream.get("channel") != "quattro"
    or upstream.get("license") != "MIT"
    or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-.][A-Za-z0-9.]+)?", str(upstream.get("release", "")))
    or not isinstance(upstream.get("version"), str)
    or not re.fullmatch(r"[0-9a-f]{40}", str(upstream.get("commit", "")))
    or not re.fullmatch(r"[0-9a-f]{40}", str(upstream.get("tree", "")))
    or not re.fullmatch(r"[0-9a-f]{64}", str(upstream.get("treeSha256", "")))
):
    fail("upstream identity is not pinned")

supply_chain_keys = {
    "archLinuxArmPackagesCommit",
    "archLinuxArmPackagesRepository",
    "hyprland",
    "mise",
    "omarchyPackagesCommit",
    "omarchyPackagesRepository",
    "ttfx",
    "vivaldi",
    "yay",
}
supply_chain = exact_keys(spec.get("supplyChain"), supply_chain_keys, "build spec supply chain")
if (
    supply_chain.get("omarchyPackagesRepository") != "https://github.com/omacom-io/omarchy-pkgs"
    or supply_chain.get("omarchyPackagesCommit") != "7e448b90313fea4fb78da9a78607287691d3b241"
    or supply_chain.get("archLinuxArmPackagesRepository") != "https://github.com/archlinuxarm/PKGBUILDs"
    or supply_chain.get("archLinuxArmPackagesCommit") != "0b5418fc3f62860b191cd872cb2f933f9fc77841"
):
    fail("ARM package supply chain is not pinned")
hyprland = exact_keys(
    supply_chain.get("hyprland"),
    {
        "binarySha256",
        "buildPackages",
        "commit",
        "glazeCommit",
        "glazeLicenseSha256",
        "glazeSha256",
        "glazeUrl",
        "glazeVersion",
        "issue",
        "license",
        "patch",
        "patchSha256",
        "pkgrel",
        "repository",
        "sha256",
        "upstreamPackageSha256",
        "upstreamPackageVersion",
        "url",
        "version",
    },
    "build spec hyprland component",
)
exact_keys(
    hyprland.get("buildPackages"),
    {
        "base-devel",
        "binutils",
        "cmake",
        "gcc",
        "gcc-libs",
        "glibc",
        "hyprland",
        "hyprland-protocols",
        "make",
        "meson",
        "ninja",
        "pkgconf",
        "xorgproto",
    },
    "build spec hyprland build packages",
)
hyprland_identity = hashlib.sha256(
    json.dumps(hyprland, ensure_ascii=True, sort_keys=True, separators=(",", ":")).encode("utf-8")
).hexdigest()
if hyprland_identity != "f3855f9bc084ee047657484400f413bb37d0797d71c64b9d9c2e459bdbc67bf5":
    fail("factory Hyprland component is not the reviewed rounded-border build")
mise = exact_keys(
    supply_chain.get("mise"),
    {"binarySha256", "license", "reportedVersion", "sha256", "url", "version"},
    "build spec mise component",
)
if mise != {
    "version": "2026.8.11",
    "url": "https://github.com/jdx/mise/releases/download/v2026.8.11/mise-v2026.8.11-linux-arm64.tar.xz",
    "sha256": "fefd580d2c6a8169762f40ce5019a61de5b2dcf0b38c5d428ef6b97d5ce76fba",
    "binarySha256": "6b7471271a990cbd6a795b24f9df83338aa220c227bf75fd083442e5a728f5f7",
    "reportedVersion": "2026.8.11 linux-arm64 (2026-08-23)",
    "license": "MIT",
}:
    fail("factory mise component is not the reviewed ARM64 release")
ttfx = exact_keys(
    supply_chain.get("ttfx"),
    {
        "cargoLockSha256",
        "binarySha256",
        "commit",
        "license",
        "licenseSha256",
        "noticeSha256",
        "packageRecipeCommit",
        "pkgrel",
        "reportedVersion",
        "repository",
        "rustPackageVersion",
        "rustcVersion",
        "cargoVersion",
        "sha256",
        "target",
        "tree",
        "url",
        "version",
    },
    "build spec ttfx component",
)
if ttfx != {
    "version": "0.3.2",
    "pkgrel": 1,
    "repository": "https://github.com/omacom-io/ttfx",
    "commit": "7203e354498462064b7c0a89375051f65cf2ce99",
    "tree": "2162aa57e857d28d6e81fcbe1c65ad390d4f24f3",
    "packageRecipeCommit": "6284fcf437681c5e9b5cb6354fb111c48125ed3f",
    "url": "https://github.com/omacom-io/ttfx/archive/refs/tags/v0.3.2.tar.gz",
    "sha256": "d0c0df4867e7f03142fb7f77c66670d0e8da15534239c1a7abfd89f19dfc00f6",
    "cargoLockSha256": "49e2091962fc4d425b4cf3bde1a105719b5b50eed0583ec90e85922adb45e2ce",
    "binarySha256": "d034cc5b9a8d410ce93113ef0a5d27b5ee2327948562bf2b0e756eebd326fa8f",
    "target": "aarch64-unknown-linux-gnu",
    "rustPackageVersion": "rust 1:1.98.1-1",
    "rustcVersion": "rustc 1.98.1 (48a229cea 2026-09-01) (Arch Linux rust 1:1.98.1-1)",
    "cargoVersion": "cargo 1.98.1 (797e8a9bc 2026-08-05) (Arch Linux rust 1:1.98.1-1)",
    "reportedVersion": "ttfx 0.3.2",
    "license": "MIT",
    "licenseSha256": "175441de2eb9a0d3f0627c404ad71929336fd98d75926cc27b9e364d35cc7977",
    "noticeSha256": "e2db8c2ff527fdd6d012440d629916e9d75328f38d0e0975f4e942ea91c4e98c",
}:
    fail("factory ttfx component is not the reviewed ARM64 source build")
yay = exact_keys(
    supply_chain.get("yay"),
    {
        "binarySha256",
        "license",
        "licenseSha256",
        "licenseUrl",
        "reportedVersion",
        "sha256",
        "url",
        "version",
    },
    "build spec yay component",
)
if yay != {
    "version": "13.0.1",
    "url": "https://github.com/Jguer/yay/releases/download/v13.0.1/yay_13.0.1_aarch64.tar.gz",
    "sha256": "75bc500c8677d6760f51117ae0a61689e9cf165bea3c4800825a5c879d030726",
    "binarySha256": "ec7453a87021f28331782d8077b8a2a7c69870710fcee991f2164dc197362ff2",
    "reportedVersion": "yay v13.0.1 - libalpm v16.0.1",
    "license": "GPL-3.0-or-later",
    "licenseUrl": "https://raw.githubusercontent.com/Jguer/yay/v13.0.1/LICENSE",
    "licenseSha256": "589ed823e9a84c56feb95ac58e7cf384626b9cbf4fda2a907bc36e103de1bad2",
}:
    fail("factory yay component is not the reviewed ARM64 release")
vivaldi = exact_keys(
    supply_chain.get("vivaldi"),
    {
        "license",
        "pkgrel",
        "reportedVersion",
        "repository",
        "rpmRelease",
        "rpmSha256",
        "rpmUrl",
        "signingFingerprint",
        "signingKey",
        "signingKeySha256",
        "version",
    },
    "build spec Vivaldi component",
)
if vivaldi != {
    "version": "8.2.4133.33",
    "rpmRelease": 1,
    "pkgrel": 2,
    "repository": "https://repo.vivaldi.com/stable",
    "rpmUrl": "https://downloads.vivaldi.com/stable/vivaldi-stable-8.2.4133.33-1.aarch64.rpm",
    "rpmSha256": "99fe7542199ba11d16d9af02783540c8c03554c37d80597a219595751414503d",
    "signingKey": "keys/vivaldi-package-composer-key11.asc",
    "signingKeySha256": "5c67d85c0aca9c0d166edb5bc5e6ebc21d67bce4e67c645e7bd76d299fd337ef",
    "signingFingerprint": "8D1FA52AEF58A09D889DD4221256C34716BD9233",
    "reportedVersion": "Vivaldi 8.2.4133.33",
    "license": "Multiple, see https://www.vivaldi.com/",
}:
    fail("Vivaldi installer is not pinned to the reviewed signed ARM64 release")

command_line = runtime.get("kernelCommandLine")
if not isinstance(command_line, str) or not command_line or any(character in command_line for character in "\x00\r\n\t"):
    fail("kernel command line is invalid")
if manifest_guest.get("kernelCommandLine") != command_line:
    fail("manifest and build spec command lines differ")
arguments = command_line.split(" ")
for required in ("root=/dev/vda", "rw", "rootwait", "console=tty0", "console=hvc0"):
    if arguments.count(required) != 1:
        fail(f"kernel command line must contain exactly one {required}")
if any(argument.startswith("omarchy.qemu_virgl=") for argument in arguments):
    fail("kernel command line already contains a QEMU VirGL role")
if any(argument.startswith("omarchy.shared_folder_name=") for argument in arguments):
    fail("kernel command line already contains a shared folder name")
if any(argument.startswith("tryomarchy.ssh_access=") for argument in arguments):
    fail("kernel command line contains a launcher-owned SSH activation argument")

records = manifest.get("artifacts")
if not isinstance(records, list) or len(records) != len(expected_artifacts):
    fail("artifact record count is invalid")
records_by_path: dict[str, dict[str, object]] = {}
for raw_record in records:
    record = exact_keys(raw_record, {"bytes", "mediaType", "path", "role", "sha256"}, "artifact record")
    path = record.get("path")
    if not isinstance(path, str) or path not in expected_artifacts or path in records_by_path:
        fail(f"artifact path is missing, duplicated, or unsafe: {path!r}")
    role, media_type = expected_artifacts[path]
    if record.get("role") != role or record.get("mediaType") != media_type:
        fail(f"artifact metadata is invalid for {path}")
    size = record.get("bytes")
    digest = record.get("sha256")
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
        fail(f"artifact size is invalid for {path}")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        fail(f"artifact digest is invalid for {path}")
    records_by_path[path] = record
if set(records_by_path) != set(expected_artifacts):
    fail("artifact records are incomplete")

calculated: dict[str, str] = {}
for name, record in records_by_path.items():
    path = guest / name
    if name not in packaged_artifacts:
        calculated[name] = str(record["sha256"])
        continue
    if path.stat().st_size != record["bytes"]:
        fail(f"artifact size mismatch for {name}")
    calculated[name] = sha256(path)
    if calculated[name] != record["sha256"]:
        fail(f"artifact digest mismatch for {name}")
calculated["guest-manifest.json"] = hashlib.sha256(manifest_data).hexdigest()

try:
    checksum_lines = (guest / "SHA256SUMS").read_text(encoding="ascii").splitlines()
except (OSError, UnicodeError) as error:
    fail(f"cannot read SHA256SUMS: {error}")
checksum_names = set(expected_artifacts) | {"guest-manifest.json"}
checksums: dict[str, str] = {}
for line in checksum_lines:
    match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._-]+)", line)
    if not match or match.group(2) not in checksum_names or match.group(2) in checksums:
        fail("SHA256SUMS has an invalid, unsafe, or duplicate entry")
    checksums[match.group(2)] = match.group(1)
if set(checksums) != checksum_names:
    fail("SHA256SUMS is incomplete")
for name, digest in checksums.items():
    if calculated[name] != digest:
        fail(f"SHA256SUMS mismatch for {name}")

kernel = guest / "vmlinuz-linux"
with kernel.open("rb") as handle:
    handle.seek(56)
    if handle.read(4) != b"ARM\x64":
        fail("vmlinuz-linux is not an uncompressed ARM64 Image")
with (guest / "initramfs-linux.img").open("rb") as handle:
    if handle.read(6) not in {b"070701", b"070702"}:
        fail("initramfs-linux.img is not a mkinitcpio newc archive")
rootfs = guest / "rootfs.ext4"
if rootfs.exists():
    if rootfs.stat().st_size != image["sizeMiB"] * 1024 * 1024:
        fail("rootfs.ext4 does not have the specified image size")
    with rootfs.open("rb") as handle:
        handle.seek(1024 + 56)
        if handle.read(2) != b"\x53\xef":
            fail("rootfs.ext4 does not have an ext4 superblock")
with (guest / "rootfs.ext4.zst").open("rb") as handle:
    if handle.read(4) != b"\x28\xb5\x2f\xfd":
        fail("rootfs.ext4.zst is not a Zstandard frame")

rootfs_record = records_by_path["rootfs.ext4"]
expanded_size_mib = storage.get("expandedSizeMiB", image["sizeMiB"])
if not isinstance(expanded_size_mib, int) or isinstance(expanded_size_mib, bool) or expanded_size_mib < image["sizeMiB"]:
    fail("working-disk expansion size is invalid")
sys.stdout.write(
    "\t".join(
        (
            calculated["guest-manifest.json"],
            str(rootfs_record["sha256"]),
            str(rootfs_record["bytes"]),
            str(records_by_path["rootfs.ext4.zst"]["bytes"]),
            str(expanded_size_mib * 1024 * 1024),
            command_line,
        )
    )
)
PY
  )
fi
IFS=$'\t' read -r bundle_identity source_disk_sha source_disk_bytes compressed_disk_bytes \
  expanded_disk_bytes kernel_command_line \
  <<<"$bundle_validation"
[[ $bundle_identity =~ ^[0-9a-f]{64}$ ]] || fail "validated bundle identity is invalid"
[[ $source_disk_sha =~ ^[0-9a-f]{64}$ ]] || fail "validated rootfs digest is invalid"
[[ $source_disk_bytes =~ ^[1-9][0-9]*$ ]] || fail "validated rootfs size is invalid"
[[ $compressed_disk_bytes =~ ^[1-9][0-9]*$ ]] || fail "validated compressed rootfs size is invalid"
[[ $expanded_disk_bytes =~ ^[1-9][0-9]*$ ]] || fail "validated working-disk size is invalid"
(( expanded_disk_bytes >= source_disk_bytes )) || fail "working disk cannot be smaller than its source"
[[ -n $kernel_command_line ]] || fail "validated kernel command line is empty"
case " $kernel_command_line " in
  *' tryomarchy.ssh_access='*)
    fail "validated kernel command line contains a launcher-owned SSH activation argument"
    ;;
esac
if [[ ${OMARCHY_QEMU_GPU_INSPECT_ONLY:-0} == 1 ]]; then
  printf '%s\n' "$bundle_validation"
  exit 0
fi

if [[ -n ${OMARCHY_QEMU_GPU_DISK_SIZE_GB:-} ]]; then
  requested_disk_size_gb=$OMARCHY_QEMU_GPU_DISK_SIZE_GB
  [[ $requested_disk_size_gb =~ ^[1-9][0-9]*$ ]] || {
    fail "OMARCHY_QEMU_GPU_DISK_SIZE_GB must be a whole number"
  }
  (( requested_disk_size_gb >= 10 )) || {
    fail "OMARCHY_QEMU_GPU_DISK_SIZE_GB must be at least 10 GB"
  }
  (( requested_disk_size_gb <= 8192 )) || {
    fail "OMARCHY_QEMU_GPU_DISK_SIZE_GB cannot exceed 8192 GB"
  }
  requested_disk_bytes=$((requested_disk_size_gb * 1024 * 1024 * 1024))
  (( requested_disk_bytes >= source_disk_bytes )) || {
    fail "the requested VM disk is smaller than the bundled factory image"
  }
  expanded_disk_bytes=$requested_disk_bytes
fi

[[ -f $storage_library && ! -L $storage_library ]] || {
  fail "persistent-storage library is missing or unsafe: $storage_library"
}
[[ -f $port_forwarding_library && ! -L $port_forwarding_library ]] || {
  fail "port-forwarding library is missing or unsafe: $port_forwarding_library"
}

# These libraries are sealed resources in normal app launches. The complete
# app bundle was verified above before either file can execute. Inspect-only is
# a build-time path and exits without sourcing any shell library.
# shellcheck source=qemu-persistent-storage.sh
source "$storage_library"
# shellcheck source=qemu-port-forwarding.sh
source "$port_forwarding_library"

if ! qemu_port_forwarding_configure "${OMARCHY_QEMU_GPU_PORT_FORWARDS:-}"; then
  fail "$QEMU_PORT_FORWARDING_ERROR"
fi
qemu_netdev=$QEMU_PORT_FORWARDING_NETDEV
port_forwarding_summary=$QEMU_PORT_FORWARDING_SUMMARY
ssh_kernel_argument=''
if ((QEMU_PORT_FORWARDING_ENABLES_SSH)); then
  ssh_kernel_argument=' tryomarchy.ssh_access=1'
fi

host_cpu_count=$(
  sysctl -n hw.logicalcpu 2>/dev/null ||
    sysctl -n hw.ncpu 2>/dev/null ||
    getconf _NPROCESSORS_ONLN 2>/dev/null
) || {
  fail "cannot determine the host CPU count"
}
[[ $host_cpu_count =~ ^[0-9]+$ ]] || fail "host CPU count is invalid: $host_cpu_count"
vcpu_count=8
if (( host_cpu_count < vcpu_count )); then
  vcpu_count=$host_cpu_count
fi
(( vcpu_count >= 4 )) || fail "the ARM guest requires at least four host CPUs"

# The launcher publishes one optional Mac folder for the guest. The Swift app
# canonicalizes and validates the selection first; re-check here so a stray
# environment value can never export an unsafe tree. Empty means disabled.
shared_folder=${OMARCHY_QEMU_GPU_SHARED_FOLDER:-}
shared_folder_mount_tag=mac
shared_folder_guest_owner_uid=1000
shared_folder_guest_owner_gid=1000
shared_folder_kernel_argument=""
if [[ -n $shared_folder ]]; then
  [[ $shared_folder == /* ]] || fail "shared folder must be an absolute path"
  [[ $shared_folder != *$'\n'* && $shared_folder != *$'\r'* && $shared_folder != *,* ]] || {
    fail "shared folder path contains an unsupported character"
  }
  [[ -d $shared_folder && ! -L $shared_folder ]] || {
    fail "shared folder is missing or is a symbolic link: $shared_folder"
  }
  shared_folder=$(cd "$shared_folder" && pwd -P) || fail "cannot resolve the shared folder"
  # A symlink in the middle of the path can resolve to a name that the first
  # check never saw, so validate the canonical path again before it goes into
  # QEMU's comma-delimited -fsdev option.
  [[ $shared_folder == /* && -d $shared_folder && ! -L $shared_folder ]] || {
    fail "shared folder resolves outside a plain directory: $shared_folder"
  }
  [[ $shared_folder != *$'\n'* && $shared_folder != *$'\r'* && $shared_folder != *,* ]] || {
    fail "shared folder resolves to a path with an unsupported character: $shared_folder"
  }
  [[ $(_qps_owner "$shared_folder") == $(id -u) ]] || {
    fail "shared folder must be owned by this user: $shared_folder"
  }
  home_dir=$(cd "$HOME" 2>/dev/null && pwd -P || true)
  case "$shared_folder" in
    /|/Users|/private|/private/tmp|/tmp|/System|/Library|/Applications|/Volumes)
      fail "refusing to share a system directory: $shared_folder"
      ;;
  esac
  if [[ -n $home_dir ]]; then
    [[ $shared_folder != "$home_dir" ]] || fail "refusing to share the whole home folder"
    [[ $shared_folder != "$home_dir/Library" && $shared_folder != "$home_dir/Library/"* ]] || {
      fail "refusing to share the Library folder"
    }
  fi
  # The guest links ~/<name> to the mount so a shared ~/Work appears as ~/Work.
  # The name travels on the kernel command line as URL-safe base64, which keeps
  # spaces and non-ASCII names intact inside one space-delimited parameter.
  shared_folder_name=${shared_folder##*/}
  [[ -n $shared_folder_name && $shared_folder_name != . && $shared_folder_name != .. ]] || {
    fail "shared folder has no usable name: $shared_folder"
  }
  shared_folder_name_encoded=$(printf '%s' "$shared_folder_name" | base64 | tr '+/' '-_' | tr -d '=\n')
  [[ $shared_folder_name_encoded =~ ^[A-Za-z0-9_-]+$ ]] || fail "cannot encode the shared folder name"
  shared_folder_kernel_argument=" omarchy.shared_folder_name=$shared_folder_name_encoded"
fi

work_dir=""
owner_marker=""
owner_token=""
qemu_pid=""
audio_bridge_pid=""
camera_bridge_pid=""
clipboard_bridge_pid=""

terminate_child() {
  local pid=$1
  local attempts=$2
  local attempt=0
  local state=""
  [[ $pid =~ ^[0-9]+$ ]] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  for ((attempt = 0; attempt < attempts; attempt++)); do
    state=$(ps -p "$pid" -o state= 2>/dev/null || true)
    [[ -n $state && $state != *Z* ]] || break
    sleep 0.05
  done
  state=$(ps -p "$pid" -o state= 2>/dev/null || true)
  if [[ -n $state && $state != *Z* ]]; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  set +e
  if [[ $qemu_pid =~ ^[0-9]+$ ]]; then
    terminate_child "$qemu_pid" 40
  fi
  if [[ $audio_bridge_pid =~ ^[0-9]+$ ]]; then
    terminate_child "$audio_bridge_pid" 20
  fi
  if [[ $camera_bridge_pid =~ ^[0-9]+$ ]]; then
    terminate_child "$camera_bridge_pid" 20
  fi
  if [[ $clipboard_bridge_pid =~ ^[0-9]+$ ]]; then
    terminate_child "$clipboard_bridge_pid" 20
  fi
  qemu_persistent_storage_release_lock
  if [[ -n $work_dir && -n $owner_marker && -n $owner_token ]]; then
    case "$work_dir" in
      /private/tmp/omarchy-qemu-gpu.??????)
        if [[ -d $work_dir && ! -L $work_dir && -f $owner_marker && ! -L $owner_marker ]] &&
           [[ $(_qps_owner "$work_dir") == $(id -u) ]] &&
           [[ $(<"$owner_marker") == "$owner_token" ]]; then
          /bin/rm -rf "$work_dir" || {
            echo "run-qemu-gpu: could not remove owned temporary directory $work_dir" >&2
          }
        else
          echo "run-qemu-gpu: refusing to remove unverified temporary directory $work_dir" >&2
        fi
        ;;
      *)
        echo "run-qemu-gpu: refusing to remove unexpected temporary path $work_dir" >&2
        ;;
    esac
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

reap_stale_work_dirs() {
  local candidate=""
  local marker=""
  local marker_value=""
  local launcher_pid=""
  local launcher_command=""
  local qemu_marker=""
  local stale_qemu_pid=""
  local qemu_command=""

  for candidate in /private/tmp/omarchy-qemu-gpu.??????; do
    [[ -d $candidate && ! -L $candidate ]] || continue
    [[ $(_qps_owner "$candidate") == $(id -u) ]] || continue
    [[ $(_qps_permissions "$candidate") == 700 ]] || continue

    marker="$candidate/.run-qemu-gpu.owner"
    [[ -f $marker && ! -L $marker ]] || continue
    marker_value=$(<"$marker")
    [[ $marker_value =~ ^run-qemu-gpu:v1:([0-9]+):([0-9]+)$ ]] || continue

    launcher_pid=${BASH_REMATCH[1]}
    launcher_command=$(ps -p "$launcher_pid" -o command= 2>/dev/null || true)
    [[ $launcher_command != *"run-qemu-gpu.sh"* ]] || continue

    qemu_marker="$candidate/.qemu.pid"
    if [[ -f $qemu_marker && ! -L $qemu_marker ]]; then
      stale_qemu_pid=$(<"$qemu_marker")
      if [[ $stale_qemu_pid =~ ^[0-9]+$ ]]; then
        qemu_command=$(ps -p "$stale_qemu_pid" -o command= 2>/dev/null || true)
        if [[ $qemu_command == *"$qemu_bin"* &&
              $qemu_command == *"unix:/tmp/${candidate##*/}/qmp.sock"* ]]; then
          continue
        fi
      fi
    fi

    echo "[qemu-gpu] Removing a verified stale disposable run: $candidate" >&2
    /bin/rm -rf "$candidate"
  done
}

reap_stale_work_dirs

boot_export_has_only_expected_contents() (
  local candidate=''
  local names=''

  shopt -s nullglob dotglob
  for candidate in "$1"/*; do
    names+="${candidate##*/}"$'\n'
  done
  shopt -u nullglob dotglob
  [[ $names == $'build-spec.json\ncomplete\ninitramfs\nkernel\n' ]]
)

assert_direct_owned_export_file() {
  local path=$1
  local label=$2

  [[ -f $path && ! -L $path ]] || boot_recovery_fail "$label is missing or unsafe"
  [[ $(_qps_lstat_kind "$path") == 'Regular File' ]] || {
    boot_recovery_fail "$label is not a direct regular file"
  }
  [[ $(_qps_owner "$path") == $(id -u) ]] || {
    boot_recovery_fail "$label is not owned by this user"
  }
}

recover_persistent_boot_kit() {
  local boot_export_dir="$work_dir/boot-export"
  local recovery_argument=''
  local recovery_command_line=''
  local recovery_state=''
  local recovery_status=0
  local recovery_stopped=0
  local attempt=0
  local recovered_command_line=''

  [[ $QEMU_SELECTED_STORAGE_MODE == persistent && \
     -n $QEMU_PERSISTENT_STORAGE_IDENTITY ]] || {
    boot_recovery_fail 'boot recovery requires a selected persistent VM'
  }
  [[ ${OMARCHY_QEMU_GPU_DRY_RUN:-0} == 0 ]] || {
    boot_recovery_fail 'this saved VM needs a one-time boot recovery; launch it normally before using dry-run mode'
  }
  mkdir -m 700 "$boot_export_dir" || boot_recovery_fail 'could not create the private boot-export directory'
  [[ -d $boot_export_dir && ! -L $boot_export_dir ]] || {
    boot_recovery_fail 'the private boot-export directory is unsafe'
  }
  [[ $(_qps_owner "$boot_export_dir") == $(id -u) && \
     $(_qps_permissions "$boot_export_dir") == 700 ]] || {
    boot_recovery_fail 'the private boot-export directory is not protected'
  }

  # The recovery initramfs mounts the old disk only far enough to read /boot.
  # QEMU also exposes the block device read-only, so neither fsck nor a malformed
  # guest can change user data while the matching boot pair is being recovered.
  for recovery_argument in $kernel_command_line; do
    if [[ $recovery_argument == rootflags=* ]]; then
      continue
    fi
    if [[ $recovery_argument == rw ]]; then
      recovery_argument=ro
    fi
    recovery_command_line+=" $recovery_argument"
  done
  recovery_command_line=${recovery_command_line# }
  recovery_command_line+=' rootflags=noload fsck.mode=skip tryomarchy.export_boot=1'

  echo '[qemu-gpu] Pairing the saved VM with its original boot files (one time).' >&2
  "$qemu_bin" \
    -name 'Try Omarchy Boot Recovery' \
    -machine "$qemu_machine" \
    -cpu 'host,pmu=off' \
    -smp '2,sockets=1,cores=2,threads=1' \
    -m 2G \
    -nodefaults \
    -no-reboot \
    -display none \
    -serial none \
    -monitor none \
    -qmp "unix:$qmp_socket,server=on,wait=off" \
    -kernel "$bundled_kernel" \
    -initrd "$bundled_initramfs" \
    -append "$recovery_command_line" \
    -drive "if=none,id=omarchy-recovery-root,file=$working_disk,format=raw,media=disk,cache=none,readonly=on" \
    -device 'virtio-blk-pci,drive=omarchy-recovery-root,serial=omarchy-root' \
    -device 'virtio-serial-pci,id=omarchy-recovery-serial' \
    -chardev 'stdio,id=omarchy-recovery-hvc0,signal=off' \
    -device 'virtconsole,bus=omarchy-recovery-serial.0,nr=0,chardev=omarchy-recovery-hvc0' \
    -fsdev "local,id=omarchy-boot-export,path=$boot_export_dir,security_model=none,multidevs=remap" \
    -device 'virtio-9p-pci,fsdev=omarchy-boot-export,mount_tag=try-omarchy-boot-export,romfile=' \
    -add-fd "$QEMU_PERSISTENT_STORAGE_QEMU_ADD_FD" &
  qemu_pid=$!
  printf '%s\n' "$qemu_pid" >"$work_dir/.qemu.pid" || \
    boot_recovery_fail 'could not record the recovery process'
  chmod 600 "$work_dir/.qemu.pid" || \
    boot_recovery_fail 'could not protect the recovery process record'

  for ((attempt = 0; attempt < 600; attempt++)); do
    recovery_state=$(ps -p "$qemu_pid" -o state= 2>/dev/null || true)
    if [[ -z $recovery_state || $recovery_state == *Z* ]]; then
      recovery_stopped=1
      break
    fi
    sleep 0.1
  done
  if (( recovery_stopped == 0 )); then
    terminate_child "$qemu_pid" 40
    qemu_pid=''
    boot_recovery_fail 'the one-time boot recovery did not finish within 60 seconds'
  fi
  if wait "$qemu_pid"; then
    recovery_status=0
  else
    recovery_status=$?
  fi
  qemu_pid=''
  /bin/rm -f "$work_dir/.qemu.pid" || \
    boot_recovery_fail 'could not clear the recovery process record'
  [[ ! -e $qmp_socket && ! -L $qmp_socket ]] || \
    /bin/rm -f "$qmp_socket" || boot_recovery_fail 'could not clear the recovery control socket'
  (( recovery_status == 0 )) || {
    boot_recovery_fail "the one-time boot recovery exited with status $recovery_status"
  }

  boot_export_has_only_expected_contents "$boot_export_dir" || {
    boot_recovery_fail 'the one-time boot recovery did not publish an exact, complete export'
  }
  assert_direct_owned_export_file "$boot_export_dir/complete" 'boot-export marker'
  assert_direct_owned_export_file "$boot_export_dir/kernel" 'recovered kernel'
  assert_direct_owned_export_file "$boot_export_dir/initramfs" 'recovered initramfs'
  assert_direct_owned_export_file "$boot_export_dir/build-spec.json" 'recovered build specification'
  [[ $(_qps_size "$boot_export_dir/complete") == 27 && \
     $(<"$boot_export_dir/complete") == try-omarchy-boot-export-v1 ]] || {
    boot_recovery_fail 'the one-time boot recovery completion marker is invalid'
  }
  [[ $(_qps_size "$boot_export_dir/build-spec.json") =~ ^[1-9][0-9]*$ && \
     $(_qps_size "$boot_export_dir/build-spec.json") -le 1048576 ]] || {
    boot_recovery_fail 'the recovered build specification has an invalid size'
  }
  recovered_command_line=$(
    /usr/bin/plutil -extract runtime.kernelCommandLine raw -expect string \
      "$boot_export_dir/build-spec.json" 2>/dev/null
  ) || boot_recovery_fail 'the recovered build specification has no kernel command line'
  chmod 600 \
    "$boot_export_dir/complete" \
    "$boot_export_dir/kernel" \
    "$boot_export_dir/initramfs" \
    "$boot_export_dir/build-spec.json" || {
      boot_recovery_fail 'could not protect the recovered boot files'
    }
  qemu_persistent_storage_stage_selected_boot_kit \
    "$boot_export_dir/kernel" \
    "$boot_export_dir/initramfs" \
    "$recovered_command_line" || {
      boot_recovery_fail 'could not pair the saved VM with its recovered boot files'
    }
  echo '[qemu-gpu] Saved VM boot files recovered; continuing normal launch.' >&2
}

umask 077
work_dir=$(mktemp -d '/private/tmp/omarchy-qemu-gpu.XXXXXX') || {
  fail "could not create a private temporary directory"
}
case "$work_dir" in
  /private/tmp/omarchy-qemu-gpu.??????) ;;
  *) fail "mktemp returned an unexpected path: $work_dir" ;;
esac
[[ -d $work_dir && ! -L $work_dir ]] || fail "temporary directory is unsafe: $work_dir"
[[ $(_qps_owner "$work_dir") == $(id -u) ]] || fail "temporary directory is not owned by this user"
owner_marker="$work_dir/.run-qemu-gpu.owner"
owner_token="run-qemu-gpu:v1:$$:${RANDOM}${RANDOM}"
printf '%s\n' "$owner_token" >"$owner_marker"
chmod 600 "$owner_marker"

# Foundation's standardizedFileURL deliberately spells macOS's private
# temporary-directory alias as /tmp. Keep the owned directory's physical path
# for cleanup, but expose the runtime sockets through that standardized alias.
qmp_socket="/tmp/${work_dir##*/}/qmp.sock"
audio_bridge_socket="/tmp/${work_dir##*/}/audio.sock"
camera_bridge_socket="/tmp/${work_dir##*/}/camera.sock"
clipboard_bridge_socket="/tmp/${work_dir##*/}/clipboard.sock"
audio_route_dir="/tmp/${work_dir##*/}/audio-routes"
mkdir -m 700 "$work_dir/audio-routes"

bundled_kernel="$guest_dir/vmlinuz-linux"
bundled_initramfs="$guest_dir/initramfs-linux.img"
selected_existing=0
if [[ $storage_mode == persistent ]]; then
  if qemu_persistent_storage_select_existing \
    "$bundle_identity" "$bundled_kernel" "$bundled_initramfs" \
    "$kernel_command_line"; then
    selected_existing=1
  else
    storage_status=$?
    if (( storage_status == QEMU_PERSISTENT_STORAGE_INCOMPATIBLE_STATUS )); then
      exit "$storage_status"
    fi
    if (( storage_status != QEMU_PERSISTENT_STORAGE_MISSING_STATUS )); then
      fail "could not inspect the saved VM disk"
    fi
  fi
fi

if (( selected_existing == 0 )); then
  source_disk="$guest_dir/rootfs.ext4"
  if [[ ! -e $source_disk && ! -L $source_disk ]]; then
    qemu_persistent_storage_materialize_source \
      "$bundle_identity" \
      "$guest_dir/rootfs.ext4.zst" \
      "$compressed_disk_bytes" \
      "$source_disk_sha" \
      "$source_disk_bytes" \
      "$resources_dir/runtime/bin/zstd" || fail "could not materialize the bundled root disk"
    source_disk=$QEMU_IMMUTABLE_SOURCE_DISK
  fi
  if qemu_persistent_storage_select \
    "$storage_mode" \
    "$bundle_identity" \
    "$source_disk" \
    "$source_disk_sha" \
    "$source_disk_bytes" \
    "$work_dir" \
    "$expanded_disk_bytes" \
    "$bundled_kernel" \
    "$bundled_initramfs" \
    "$kernel_command_line"; then
    :
  else
    storage_status=$?
    if (( storage_status == QEMU_PERSISTENT_STORAGE_INCOMPATIBLE_STATUS )); then
      exit "$storage_status"
    fi
    fail "could not prepare the selected root disk"
  fi
fi
working_disk=$QEMU_SELECTED_DISK

case ${OMARCHY_QEMU_GPU_DRY_RUN:-0} in
  0|1) ;;
  *) fail "OMARCHY_QEMU_GPU_DRY_RUN must be 0 or 1" ;;
esac
case ${OMARCHY_QEMU_GPU_ALLOW_BOOT_RECOVERY:-0} in
  0|1) ;;
  *) fail "OMARCHY_QEMU_GPU_ALLOW_BOOT_RECOVERY must be 0 or 1" ;;
esac
if (( QEMU_PERSISTENT_STORAGE_NEEDS_BOOT_RECOVERY )); then
  if [[ ${OMARCHY_QEMU_GPU_ALLOW_BOOT_RECOVERY:-0} != 1 ]]; then
    echo '[qemu-gpu] This older saved VM needs consent for one-time read-only boot pairing.' >&2
    exit "$boot_recovery_consent_required_status"
  fi
  recover_persistent_boot_kit
fi
launch_kernel=$QEMU_SELECTED_KERNEL
launch_initramfs=$QEMU_SELECTED_INITRAMFS
launch_kernel_command_line=$QEMU_SELECTED_KERNEL_COMMAND_LINE
[[ -n $launch_kernel && -n $launch_initramfs && -n $launch_kernel_command_line ]] || {
  fail 'the selected VM has no complete boot kit'
}

if ((reset_only)); then
  qemu_persistent_storage_release_lock
  echo "[qemu-gpu] Reset complete." >&2
  exit 0
fi

case ${OMARCHY_QEMU_GPU_IMMERSIVE:-1} in
  1)
    cocoa_full_screen=on
    cocoa_immersive=on
    ;;
  0)
    cocoa_full_screen=off
    cocoa_immersive=off
    ;;
  *) fail "OMARCHY_QEMU_GPU_IMMERSIVE must be 0 or 1" ;;
esac

qemu_args=(
  -name 'Try Omarchy'
  -machine "$qemu_machine"
  # HVF does not provide a usable guest PMU on Apple Silicon. Do not advertise
  # one: Linux otherwise probes the dead device and prints a misleading failure.
  -cpu 'host,pmu=off'
  -smp "$vcpu_count,sockets=1,cores=$vcpu_count,threads=1"
  -m 4G
  -nodefaults
  # Reboot the guest inside this QEMU process, but let shutdown close the app.
  -action 'reboot=reset,shutdown=poweroff'
  -netdev "$qemu_netdev"
  -device 'virtio-net-pci,netdev=omarchy-net,mac=52:54:00:12:34:56,romfile='
  -audiodev 'sdl,id=omarchy-audio'
  -device 'intel-hda,id=omarchy-hda,romfile='
  -device 'hda-micro,bus=omarchy-hda.0,audiodev=omarchy-audio'
  -serial none
  -monitor none
  -qmp "unix:$qmp_socket,server=on,wait=off"
  -kernel "$launch_kernel"
  -initrd "$launch_initramfs"
  -append "$launch_kernel_command_line omarchy.qemu_virgl=1$shared_folder_kernel_argument$ssh_kernel_argument"
  -drive "if=none,id=omarchy-root,file=$working_disk,format=raw,media=disk,cache=writeback"
  -device 'virtio-blk-pci,drive=omarchy-root,serial=omarchy-root'
  -device "$gpu_device"
  # Cocoa forwards its live backing-pixel dimensions and the current host
  # display refresh rate through Virtio GPU EDID. Its accessibility-backed
  # Full grab keeps every Command chord with the focused guest in either
  # presentation mode. Immersive launches Full Screen and hard-hides the Mac
  # menu bar and Dock; otherwise Cocoa opens a centered, resizable window.
  -display "cocoa,gl=es,show-cursor=on,zoom-to-fit=on,full-screen=$cocoa_full_screen,full-grab=on,immersive=$cocoa_immersive,swap-opt-cmd=off"
  -device 'virtio-keyboard-pci,romfile='
  -device 'virtio-tablet-pci,romfile='
  -object 'rng-random,id=omarchy-rng,filename=/dev/urandom'
  -device 'virtio-rng-pci,rng=omarchy-rng'
  -device virtio-balloon-pci
  -device 'virtio-serial-pci,id=omarchy-serial'
  -chardev 'stdio,id=omarchy-hvc0,signal=off'
  -device 'virtconsole,bus=omarchy-serial.0,nr=0,chardev=omarchy-hvc0'
  -chardev "socket,id=omarchy-audio-bridge,path=$audio_bridge_socket,server=on,wait=off"
  -device 'virtserialport,bus=omarchy-serial.0,nr=1,chardev=omarchy-audio-bridge,name=dev.tryomarchy.audio'
  -chardev "socket,id=omarchy-clipboard-bridge,path=$clipboard_bridge_socket,server=on,wait=off"
  -device 'virtserialport,bus=omarchy-serial.0,nr=2,chardev=omarchy-clipboard-bridge,name=dev.tryomarchy.clipboard'
  -chardev "socket,id=omarchy-camera-bridge,path=$camera_bridge_socket,server=on,wait=off"
  -device 'virtserialport,bus=omarchy-serial.0,nr=4,chardev=omarchy-camera-bridge,name=dev.tryomarchy.camera'
)

if [[ -n $shared_folder ]]; then
  # security_model=none performs every host operation as this Mac user and
  # ignores guest chown requests, so the Mac keeps real modes and ownership.
  # The patched local driver reports this user's files as the Omarchy owner
  # account so the guest kernel grants matching read/write access.
  qemu_args+=(
    -fsdev "local,id=omarchy-share,path=$shared_folder,security_model=none,multidevs=remap,guest_owner_uid=$shared_folder_guest_owner_uid,guest_owner_gid=$shared_folder_guest_owner_gid"
    -device "virtio-9p-pci,fsdev=omarchy-share,mount_tag=$shared_folder_mount_tag,romfile="
  )
fi

# SDL2 has one legacy process-wide override that would collapse input and
# output onto the same named device. The patched QEMU backend uses the two
# direction-specific Omarchy variables instead; unset means live System Default.
unset SDL_AUDIO_DEVICE_NAME
export OMARCHY_SDL_AUDIO_CONTROL_DIRECTORY="$audio_route_dir"

if [[ $QEMU_SELECTED_STORAGE_MODE == persistent ]]; then
  qemu_args+=(
    -add-fd "$QEMU_PERSISTENT_STORAGE_QEMU_ADD_FD"
  )
fi

if [[ ${OMARCHY_QEMU_GPU_DRY_RUN:-0} == 1 ]]; then
  printf '[qemu-gpu] dry-run command:' >&2
  printf ' %q' "$qemu_bin" "${qemu_args[@]}" >&2
  printf '\n[qemu-gpu] audio bridge command: %q --bridge-native-audio QEMU_PID %q %q' \
    "$native_bridge" "$audio_bridge_socket" "$audio_route_dir" >&2
  printf '\n[qemu-gpu] clipboard bridge command: %q --bridge-native-clipboard QEMU_PID %q' \
    "$native_bridge" "$clipboard_bridge_socket" >&2
  printf '\n[qemu-gpu] camera bridge command: %q --bridge-native-camera QEMU_PID %q' \
    "$native_bridge" "$camera_bridge_socket" >&2
  if [[ -n $shared_folder ]]; then
    printf '\n[qemu-gpu] shared folder: %q' "$shared_folder" >&2
  else
    printf '\n[qemu-gpu] shared folder: disabled' >&2
  fi
  printf '\n[qemu-gpu] port forwarding: %s' "$port_forwarding_summary" >&2
  printf '\n' >&2
  exit 0
fi
[[ ${OMARCHY_QEMU_GPU_DRY_RUN:-0} == 0 ]] || {
  fail "OMARCHY_QEMU_GPU_DRY_RUN must be 0 or 1"
}

if [[ $QEMU_SELECTED_STORAGE_MODE == persistent ]]; then
  echo "[qemu-gpu] Starting the persistent ARM64 VirGL guest with $vcpu_count vCPUs and 4 GiB RAM." >&2
  echo "[qemu-gpu] User data: $QEMU_PERSISTENT_STORAGE_DIRECTORY" >&2
else
  echo "[qemu-gpu] Starting a disposable ARM64 VirGL guest with $vcpu_count vCPUs and 4 GiB RAM." >&2
fi
if [[ -n $shared_folder ]]; then
  echo "[qemu-gpu] Shared folder: $shared_folder (guest ~/$shared_folder_name)" >&2
fi
echo "[qemu-gpu] Port forwarding: $port_forwarding_summary" >&2
"$qemu_bin" "${qemu_args[@]}" &
qemu_pid=$!
printf '%s\n' "$qemu_pid" >"$work_dir/.qemu.pid"
chmod 600 "$work_dir/.qemu.pid"

for ((attempt = 0; attempt < 100; attempt++)); do
  if [[ -S $qmp_socket && -S $audio_bridge_socket && -S $camera_bridge_socket && -S $clipboard_bridge_socket ]]; then
    break
  fi
  kill -0 "$qemu_pid" 2>/dev/null || fail "QEMU exited before creating its private QMP socket"
  sleep 0.05
done
[[ -S $qmp_socket ]] || fail "QEMU did not create its private QMP socket"
[[ -S $audio_bridge_socket ]] || fail "QEMU did not create its private audio bridge socket"
[[ -S $camera_bridge_socket ]] || fail "QEMU did not create its private camera bridge socket"
[[ -S $clipboard_bridge_socket ]] || fail "QEMU did not create its private clipboard bridge socket"
echo "[qemu-gpu] Ready. QMP: $qmp_socket" >&2

# FD 9 deliberately remains open only in QEMU. Letting the sibling audio
# bridge inherit it could keep a persistent workspace locked after QEMU exits.
"$native_bridge" --bridge-native-audio \
  "$qemu_pid" "$audio_bridge_socket" "$audio_route_dir" 9>&- &
audio_bridge_pid=$!

start_clipboard_bridge() {
  "$native_bridge" --bridge-native-clipboard \
    "$qemu_pid" "$clipboard_bridge_socket" 9>&- &
  clipboard_bridge_pid=$!
}
start_clipboard_bridge
clipboard_bridge_restarts=0

start_camera_bridge() {
  "$native_bridge" --bridge-native-camera \
    "$qemu_pid" "$camera_bridge_socket" 9>&- &
  camera_bridge_pid=$!
}
start_camera_bridge
camera_bridge_restarts=0

# Bash 3.2 has no `wait -n`. The native-audio bridge is required for the guest
# transport, so watch it alongside QEMU and fail if it exits unexpectedly.
while true; do
  qemu_state=$(ps -p "$qemu_pid" -o state= 2>/dev/null || true)
  [[ -n $qemu_state && $qemu_state != *Z* ]] || break

  audio_bridge_state=$(ps -p "$audio_bridge_pid" -o state= 2>/dev/null || true)
  if [[ -z $audio_bridge_state || $audio_bridge_state == *Z* ]]; then
    if wait "$audio_bridge_pid"; then
      audio_bridge_status=0
    else
      audio_bridge_status=$?
    fi
    audio_bridge_pid=""
    fail "native audio bridge exited while QEMU was running (status $audio_bridge_status)"
  fi

  # Clipboard sharing is a convenience, not a transport the guest depends on.
  # Restart it a few times rather than stopping the whole virtual machine.
  if [[ $clipboard_bridge_pid =~ ^[0-9]+$ ]]; then
    clipboard_bridge_state=$(ps -p "$clipboard_bridge_pid" -o state= 2>/dev/null || true)
    if [[ -z $clipboard_bridge_state || $clipboard_bridge_state == *Z* ]]; then
      if wait "$clipboard_bridge_pid"; then
        clipboard_bridge_status=0
      else
        clipboard_bridge_status=$?
      fi
      clipboard_bridge_pid=""
      if (( clipboard_bridge_restarts < 5 )); then
        clipboard_bridge_restarts=$((clipboard_bridge_restarts + 1))
        echo "[qemu-gpu] clipboard bridge exited (status $clipboard_bridge_status); restarting ($clipboard_bridge_restarts/5)" >&2
        sleep 1
        start_clipboard_bridge
      else
        echo "[qemu-gpu] clipboard sharing is unavailable for the rest of this session" >&2
      fi
    fi
  fi
  # Camera sharing is optional. A failed capture backend must not stop the VM;
  # reconnect it so a transient device change can recover in this session.
  if [[ $camera_bridge_pid =~ ^[0-9]+$ ]]; then
    camera_bridge_state=$(ps -p "$camera_bridge_pid" -o state= 2>/dev/null || true)
    if [[ -z $camera_bridge_state || $camera_bridge_state == *Z* ]]; then
      if wait "$camera_bridge_pid"; then
        camera_bridge_status=0
      else
        camera_bridge_status=$?
      fi
      camera_bridge_pid=""
      if (( camera_bridge_restarts < 5 )); then
        camera_bridge_restarts=$((camera_bridge_restarts + 1))
        echo "[qemu-gpu] camera bridge exited (status $camera_bridge_status); restarting ($camera_bridge_restarts/5)" >&2
        sleep 1
        start_camera_bridge
      else
        echo "[qemu-gpu] camera sharing is unavailable for the rest of this session" >&2
      fi
    fi
  fi
  sleep 0.1
done

if wait "$qemu_pid"; then
  qemu_status=0
else
  qemu_status=$?
fi
qemu_pid=""

for ((attempt = 0; attempt < 40; attempt++)); do
  audio_bridge_state=$(ps -p "$audio_bridge_pid" -o state= 2>/dev/null || true)
  [[ -n $audio_bridge_state && $audio_bridge_state != *Z* ]] || break
  sleep 0.05
done
audio_bridge_state=$(ps -p "$audio_bridge_pid" -o state= 2>/dev/null || true)
if [[ -n $audio_bridge_state && $audio_bridge_state != *Z* ]]; then
  terminate_child "$audio_bridge_pid" 20
else
  wait "$audio_bridge_pid" 2>/dev/null || true
fi
audio_bridge_pid=""
if [[ $clipboard_bridge_pid =~ ^[0-9]+$ ]]; then
  terminate_child "$clipboard_bridge_pid" 20
fi
clipboard_bridge_pid=""
if [[ $camera_bridge_pid =~ ^[0-9]+$ ]]; then
  terminate_child "$camera_bridge_pid" 20
fi
camera_bridge_pid=""
exit "$qemu_status"
