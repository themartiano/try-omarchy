#!/bin/bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: macos/prepare-qemu-gpu-runtime.sh [--source-qemu PATH] [--archive-dir DIR]

Download, verify, relocate, and ad-hoc sign the pinned QEMU/VirGL runtime at:
  macos/.build/qemu-gpu-runtime

With --source-qemu, stage the locally built QEMU executable at PATH instead of
the unmodified startergo QEMU bottle. The pinned GPU dylibs are still downloaded
and isolated exactly as in the bottle path.

With --archive-dir, reuse already-downloaded pinned archives from DIR. Every
archive is copied into private scratch space and checksum-verified before use.

The script never taps, installs, links, or upgrades Homebrew formulae. Existing
Homebrew core dylibs are used in place and must already be installed.
EOF
}

source_qemu=
archive_cache=
while (($#)); do
  case "$1" in
    --source-qemu)
      (($# >= 2)) || { usage >&2; exit 64; }
      [[ -z $source_qemu ]] || { usage >&2; exit 64; }
      source_qemu=$2
      shift 2
      ;;
    --archive-dir)
      (($# >= 2)) || { usage >&2; exit 64; }
      [[ -z $archive_cache ]] || { usage >&2; exit 64; }
      archive_cache=$2
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

native_dir=$(cd "$(dirname "$0")" && pwd -P)
build_dir="$native_dir/.build"
runtime_dir="$build_dir/qemu-gpu-runtime"
entitlements="$native_dir/qemu-hvf.entitlements"

# These four releases are one receipt-proven runtime set. Do not independently
# update a GPU bottle to whatever its tap currently publishes.
qemu_version=1.0.27
qemu_archive_name=qemu-1.0.27.arm64_sequoia.bottle.tar.gz
qemu_url="https://github.com/startergo/homebrew-qemu-virgl-kosmickrisp/releases/download/v1.0.27/$qemu_archive_name"
qemu_sha256=a2eaeed6f7b52661436052b413f596785c5e14e2e1b65cd5509713fcfc164566

virgl_version=1.0.33
virgl_archive_name=virglrenderer-1.0.33.arm64_sequoia.bottle.tar.gz
virgl_url="https://github.com/startergo/homebrew-virglrenderer/releases/download/v1.0.33/$virgl_archive_name"
virgl_sha256=26ad3e927d300587024cd92276d38bf813f6228d130a1800c97f1c18688b34ba

angle_version=1.0.15
angle_archive_name=angle-1.0.15.arm64_sequoia.bottle.tar.gz
angle_url="https://github.com/startergo/homebrew-angle/releases/download/v1.0.15/$angle_archive_name"
angle_sha256=2b41a696f450a941016adf8b157e754c3223b6032ac9b9f0aac4216e899074c7

epoxy_version=1.0.4
epoxy_archive_name=libepoxy-1.0.4.arm64_sequoia.bottle.tar.gz
epoxy_url="https://github.com/startergo/homebrew-libepoxy/releases/download/v1.0.4/$epoxy_archive_name"
epoxy_sha256=8787cc8c34921834665262dff4941216dd6717edddf2c6d5cdfe04f03b24c517

die() {
  echo "qemu-gpu-runtime: $*" >&2
  exit 1
}

log() {
  echo "[qemu-gpu-runtime] $*"
}

for tool in awk brew codesign curl ditto file grep install install_name_tool mkdir \
  mktemp otool python3 rm sed shasum sw_vers tar uname xattr; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool is unavailable: $tool"
done

[[ $(uname -s) == Darwin ]] || die "the pinned bottles require macOS"
[[ $(uname -m) == arm64 ]] || die "the pinned bottles require Apple Silicon (arm64)"
macos_major=$(sw_vers -productVersion | awk -F. '{ print $1 }')
[[ $macos_major =~ ^[0-9]+$ ]] || die "could not determine the macOS version"
((macos_major >= 15)) || die "the pinned arm64_sequoia bottles require macOS 15 or newer"
[[ -f $entitlements ]] || die "missing QEMU signing entitlements: $entitlements"
if [[ -n $source_qemu ]]; then
  [[ $source_qemu == /* ]] || die "--source-qemu must be an absolute path"
  [[ -f $source_qemu && ! -L $source_qemu && -x $source_qemu ]] || \
    die "--source-qemu must name a regular executable: $source_qemu"
fi
if [[ -n $archive_cache ]]; then
  [[ $archive_cache == /* ]] || die "--archive-dir must be an absolute path"
  [[ -d $archive_cache && ! -L $archive_cache ]] || \
    die "--archive-dir must name a regular directory: $archive_cache"
fi

export HOMEBREW_NO_AUTO_UPDATE=1
brew_prefix=$(brew --prefix) || die "Homebrew is required for the QEMU core dylibs"
brew_cellar=$(brew --cellar) || die "could not determine the Homebrew Cellar"
[[ $brew_prefix == /* && -d $brew_prefix ]] || die "invalid Homebrew prefix: $brew_prefix"
[[ $brew_cellar == /* && -d $brew_cellar ]] || die "invalid Homebrew Cellar: $brew_cellar"

mkdir -p "$build_dir"
[[ -d $build_dir && ! -L $build_dir ]] || die "unsafe build directory: $build_dir"

work_dir=
publish_dir=

remove_generated_dir() {
  local path=$1
  [[ -n $path && ( -e $path || -L $path ) ]] || return 0
  if [[ $path == /private/tmp/omarchy-qemu-gpu-runtime.* || \
        $path == "$build_dir"/.qemu-gpu-runtime.* ]]; then
    rm -rf -- "$path"
    return
  fi
  echo "qemu-gpu-runtime: refusing to remove unexpected path: $path" >&2
  return 1
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM

  [[ -z $publish_dir ]] || remove_generated_dir "$publish_dir" || true
  [[ -z $work_dir ]] || remove_generated_dir "$work_dir" || true
  exit "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

work_dir=$(mktemp -d /private/tmp/omarchy-qemu-gpu-runtime.XXXXXX)
archive_dir="$work_dir/archives"
listing_dir="$work_dir/listings"
extract_dir="$work_dir/extracted"
staged_runtime="$work_dir/runtime"
mkdir -p "$archive_dir" "$listing_dir" "$extract_dir" \
  "$staged_runtime/bin" "$staged_runtime/lib"

download_and_verify() {
  local label=$1
  local url=$2
  local expected_sha=$3
  local output=$4
  local actual_sha

  log "Downloading $label"
  curl --fail --location --silent --show-error \
    --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 20 \
    --output "$output" "$url"
  actual_sha=$(shasum -a 256 "$output" | awk '{ print $1 }')
  [[ $actual_sha == "$expected_sha" ]] || \
    die "$label checksum mismatch: expected $expected_sha, got $actual_sha"
}

obtain_and_verify() {
  local label=$1
  local url=$2
  local expected_sha=$3
  local output=$4
  local cached
  local actual_sha

  if [[ -z $archive_cache ]]; then
    download_and_verify "$label" "$url" "$expected_sha" "$output"
    return
  fi

  cached="$archive_cache/${output##*/}"
  [[ -f $cached && ! -L $cached ]] || \
    die "archive cache is missing a regular ${output##*/}"
  actual_sha=$(shasum -a 256 "$cached" | awk '{ print $1 }')
  [[ $actual_sha == "$expected_sha" ]] || \
    die "$label cache checksum mismatch: expected $expected_sha, got $actual_sha"
  log "Using cached $label"
  install -m 0644 "$cached" "$output"
}

validate_archive() {
  local label=$1
  local archive=$2
  local expected_root=$3
  local listing=$4
  local member

  tar -tzf "$archive" >"$listing" || die "$label is not a readable gzip tar archive"
  [[ -s $listing ]] || die "$label archive is empty"

  while IFS= read -r member; do
    member=${member#./}
    case "$member" in
      ""|/*|..|../*|*/..|*/../*)
        die "$label contains an unsafe archive path: $member"
        ;;
    esac
    case "$member" in
      "$expected_root"|"$expected_root/"|"$expected_root/"*) ;;
      *) die "$label contains a path outside $expected_root: $member" ;;
    esac
  done <"$listing"
}

require_regular_member() {
  local label=$1
  local archive=$2
  local listing=$3
  local member=$4
  local count
  local type

  count=$(awk -v target="$member" '$0 == target { count++ } END { print count + 0 }' "$listing")
  [[ $count == 1 ]] || die "$label must contain exactly one regular $member"
  type=$(tar -tvzf "$archive" "$member" | awk 'NR == 1 { print substr($1, 1, 1) }')
  [[ $type == - ]] || die "$label member is not a regular file: $member"
}

qemu_archive="$archive_dir/$qemu_archive_name"
virgl_archive="$archive_dir/$virgl_archive_name"
angle_archive="$archive_dir/$angle_archive_name"
epoxy_archive="$archive_dir/$epoxy_archive_name"

if [[ -z $source_qemu ]]; then
  obtain_and_verify "QEMU $qemu_version" "$qemu_url" "$qemu_sha256" "$qemu_archive"
else
  log "Using source-built QEMU: $source_qemu"
fi
obtain_and_verify "virglrenderer $virgl_version" "$virgl_url" "$virgl_sha256" "$virgl_archive"
obtain_and_verify "ANGLE $angle_version" "$angle_url" "$angle_sha256" "$angle_archive"
obtain_and_verify "libepoxy $epoxy_version" "$epoxy_url" "$epoxy_sha256" "$epoxy_archive"

qemu_listing="$listing_dir/qemu.txt"
virgl_listing="$listing_dir/virglrenderer.txt"
angle_listing="$listing_dir/angle.txt"
epoxy_listing="$listing_dir/libepoxy.txt"
if [[ -z $source_qemu ]]; then
  validate_archive "QEMU $qemu_version" "$qemu_archive" "qemu/$qemu_version" "$qemu_listing"
fi
validate_archive "virglrenderer $virgl_version" "$virgl_archive" "virglrenderer/$virgl_version" "$virgl_listing"
validate_archive "ANGLE $angle_version" "$angle_archive" "angle/$angle_version" "$angle_listing"
validate_archive "libepoxy $epoxy_version" "$epoxy_archive" "libepoxy/$epoxy_version" "$epoxy_listing"

# The ARM launcher supplies an uncompressed kernel and initramfs directly, uses
# QEMU's generated virt DTB, and disables the GPU option ROM. No firmware/data
# from the bottle is needed in the isolated runtime.
qemu_member="qemu/$qemu_version/bin/qemu-system-aarch64"
virgl_member="virglrenderer/$virgl_version/lib/libvirglrenderer.1.dylib"
epoxy_member="libepoxy/$epoxy_version/lib/libepoxy.0.dylib"
egl_member="angle/$angle_version/lib/libEGL.dylib"
gles_member="angle/$angle_version/lib/libGLESv2.dylib"

if [[ -z $source_qemu ]]; then
  require_regular_member "QEMU $qemu_version" "$qemu_archive" "$qemu_listing" "$qemu_member"
fi
require_regular_member "virglrenderer $virgl_version" "$virgl_archive" "$virgl_listing" "$virgl_member"
require_regular_member "libepoxy $epoxy_version" "$epoxy_archive" "$epoxy_listing" "$epoxy_member"
require_regular_member "ANGLE $angle_version" "$angle_archive" "$angle_listing" "$egl_member"
require_regular_member "ANGLE $angle_version" "$angle_archive" "$angle_listing" "$gles_member"

if [[ -z $source_qemu ]]; then
  tar -xzf "$qemu_archive" -C "$extract_dir" "$qemu_member"
fi
tar -xzf "$virgl_archive" -C "$extract_dir" "$virgl_member"
tar -xzf "$epoxy_archive" -C "$extract_dir" "$epoxy_member"
tar -xzf "$angle_archive" -C "$extract_dir" "$egl_member" "$gles_member"

if [[ -n $source_qemu ]]; then
  install -m 0755 "$source_qemu" "$staged_runtime/bin/qemu-system-aarch64"
else
  install -m 0755 "$extract_dir/$qemu_member" \
    "$staged_runtime/bin/qemu-system-aarch64"
fi
install -m 0755 "$extract_dir/$virgl_member" "$staged_runtime/lib/libvirglrenderer.1.dylib"
install -m 0755 "$extract_dir/$epoxy_member" "$staged_runtime/lib/libepoxy.0.dylib"
install -m 0755 "$extract_dir/$egl_member" "$staged_runtime/lib/libEGL.dylib"
install -m 0755 "$extract_dir/$gles_member" "$staged_runtime/lib/libGLESv2.dylib"

macho_dependencies() {
  otool -L "$1" | sed -n '2,$p' | \
    sed -E 's/^[[:space:]]+//; s/ \(compatibility version.*$//'
}

has_dependency() {
  local image=$1
  local expected=$2
  local dependency
  local dependencies
  dependencies=$(macho_dependencies "$image") || \
    die "could not inspect Mach-O dependencies: $image"
  while IFS= read -r dependency; do
    [[ $dependency == "$expected" ]] && return 0
  done <<<"$dependencies"
  return 1
}

patch_dependency() {
  local image=$1
  local old=$2
  local new=$3
  has_dependency "$image" "$old" || \
    die "$(basename "$image") is missing expected dependency: $old"
  install_name_tool -change "$old" "$new" "$image"
}

macho_rpaths() {
  otool -l "$1" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" { print $2; in_rpath = 0 }
  '
}

has_rpath() {
  local image=$1
  local expected=$2
  local rpath
  local rpaths
  rpaths=$(macho_rpaths "$image") || die "could not inspect Mach-O rpaths: $image"
  while IFS= read -r rpath; do
    [[ $rpath == "$expected" ]] && return 0
  done <<<"$rpaths"
  return 1
}

replace_required_rpath() {
  local image=$1
  local old=$2
  local new=$3
  has_rpath "$image" "$old" || die "$(basename "$image") is missing expected rpath: $old"
  install_name_tool -rpath "$old" "$new" "$image"
}

patch_homebrew_core_dependencies() {
  local image=$1
  local dependency
  local dependencies
  local replacement
  local suffix

  dependencies=$(macho_dependencies "$image") || \
    die "could not inspect Mach-O dependencies: $image"
  while IFS= read -r dependency; do
    replacement=
    case "$dependency" in
      '@@HOMEBREW_PREFIX@@/opt/angle/'*|'/opt/homebrew/opt/angle/'*|\
      '@@HOMEBREW_PREFIX@@/opt/libepoxy/'*|'/opt/homebrew/opt/libepoxy/'*|\
      '@@HOMEBREW_PREFIX@@/opt/virglrenderer/'*|'/opt/homebrew/opt/virglrenderer/'*)
        die "$(basename "$image") still references a non-isolated GPU dependency: $dependency"
        ;;
      '@@HOMEBREW_PREFIX@@/'*)
        suffix=${dependency#@@HOMEBREW_PREFIX@@}
        replacement="$brew_prefix$suffix"
        ;;
      '@@HOMEBREW_CELLAR@@/'*)
        suffix=${dependency#@@HOMEBREW_CELLAR@@}
        replacement="$brew_cellar$suffix"
        ;;
      /opt/homebrew/*)
        suffix=${dependency#/opt/homebrew}
        replacement="$brew_prefix$suffix"
        ;;
      *'@@HOMEBREW_'*)
        die "$(basename "$image") has an unsupported Homebrew placeholder: $dependency"
        ;;
    esac

    [[ -n $replacement ]] || continue
    [[ -e $replacement ]] || \
      die "missing Homebrew core dependency for $(basename "$image"): $replacement"
    if [[ $dependency != "$replacement" ]]; then
      install_name_tool -change "$dependency" "$replacement" "$image"
    fi
  done <<<"$dependencies"
}

qemu_binary="$staged_runtime/bin/qemu-system-aarch64"
virgl_library="$staged_runtime/lib/libvirglrenderer.1.dylib"
epoxy_library="$staged_runtime/lib/libepoxy.0.dylib"
egl_library="$staged_runtime/lib/libEGL.dylib"
gles_library="$staged_runtime/lib/libGLESv2.dylib"
runtime_images=("$qemu_binary" "$virgl_library" "$epoxy_library" "$egl_library" "$gles_library")

for image in "${runtime_images[@]}"; do
  description=$(file -b "$image")
  [[ $description == *Mach-O* && $description == *arm64* ]] || \
    die "expected an arm64 Mach-O image, got '$description' for $image"
done

log "Relocating the staged Mach-O runtime"
for image in "${runtime_images[@]}"; do
  xattr -c "$image"
  codesign --remove-signature "$image"
done
install_name_tool -id '@rpath/libvirglrenderer.1.dylib' "$virgl_library"
install_name_tool -id '@rpath/libepoxy.0.dylib' "$epoxy_library"
install_name_tool -id '@rpath/libEGL.dylib' "$egl_library"
install_name_tool -id '@rpath/libGLESv2.dylib' "$gles_library"

patch_dependency "$qemu_binary" \
  '@@HOMEBREW_PREFIX@@/opt/virglrenderer/lib/libvirglrenderer.1.dylib' \
  '@rpath/libvirglrenderer.1.dylib'
patch_dependency "$qemu_binary" \
  '@@HOMEBREW_PREFIX@@/opt/libepoxy/lib/libepoxy.0.dylib' \
  '@rpath/libepoxy.0.dylib'
patch_dependency "$virgl_library" \
  '@@HOMEBREW_PREFIX@@/opt/libepoxy/lib/libepoxy.0.dylib' \
  '@rpath/libepoxy.0.dylib'

if [[ -n $source_qemu ]]; then
  if has_rpath "$qemu_binary" '@executable_path/../lib'; then
    :
  elif has_rpath "$qemu_binary" '@@HOMEBREW_PREFIX@@/lib'; then
    replace_required_rpath "$qemu_binary" \
      '@@HOMEBREW_PREFIX@@/lib' '@executable_path/../lib'
  elif has_rpath "$qemu_binary" "$brew_prefix/lib"; then
    replace_required_rpath "$qemu_binary" \
      "$brew_prefix/lib" '@executable_path/../lib'
  else
    install_name_tool -add_rpath '@executable_path/../lib' "$qemu_binary"
  fi
else
  replace_required_rpath "$qemu_binary" \
    '@@HOMEBREW_PREFIX@@/lib' '@executable_path/../lib'
fi
replace_required_rpath "$virgl_library" '@@HOMEBREW_PREFIX@@/lib' '@loader_path'
replace_required_rpath "$egl_library" '@executable_path/' '@loader_path'
replace_required_rpath "$gles_library" '@executable_path/' '@loader_path'

for image in "${runtime_images[@]}"; do
  patch_homebrew_core_dependencies "$image"
done

verify_image_dependencies() {
  local root=$1
  local image=$2
  local dependency
  local dependencies
  local local_library

  dependencies=$(macho_dependencies "$image") || \
    die "could not inspect Mach-O dependencies: $image"
  while IFS= read -r dependency; do
    case "$dependency" in
      *'@@HOMEBREW_'*)
        die "unrelocated Homebrew placeholder in $(basename "$image"): $dependency"
        ;;
      /opt/homebrew/opt/angle/*|/opt/homebrew/opt/libepoxy/*|/opt/homebrew/opt/virglrenderer/*)
        die "global GPU dependency remains in $(basename "$image"): $dependency"
        ;;
      @rpath/libvirglrenderer.1.dylib|@rpath/libepoxy.0.dylib|\
      @rpath/libEGL.dylib|@rpath/libGLESv2.dylib)
        local_library="$root/lib/${dependency##*/}"
        [[ -f $local_library ]] || die "missing isolated dylib: $local_library"
        ;;
      "$brew_prefix"/*)
        [[ -e $dependency ]] || die "missing Homebrew core dylib: $dependency"
        ;;
    esac
  done <<<"$dependencies"
}

verify_runtime_tree() {
  local root=$1
  local qemu="$root/bin/qemu-system-aarch64"
  local virgl="$root/lib/libvirglrenderer.1.dylib"
  local epoxy="$root/lib/libepoxy.0.dylib"
  local egl="$root/lib/libEGL.dylib"
  local gles="$root/lib/libGLESv2.dylib"
  local image
  local accel_help
  local cpu_help
  local device_help
  local display_help
  local entitlements_output
  local machine_help
  local netdev_help
  local audio_help
  local version_output

  [[ -x $qemu ]] || die "published runtime is missing qemu-system-aarch64"
  for image in "$virgl" "$epoxy" "$egl" "$gles"; do
    [[ -f $image ]] || die "published runtime is missing $(basename "$image")"
  done
  [[ ! -e $root/share && ! -L $root/share ]] || \
    die "the direct-kernel ARM runtime must not contain QEMU firmware data"

  [[ $(otool -D "$virgl" | sed -n '2p') == '@rpath/libvirglrenderer.1.dylib' ]] || \
    die "virglrenderer has an unexpected install name"
  [[ $(otool -D "$epoxy" | sed -n '2p') == '@rpath/libepoxy.0.dylib' ]] || \
    die "libepoxy has an unexpected install name"
  [[ $(otool -D "$egl" | sed -n '2p') == '@rpath/libEGL.dylib' ]] || \
    die "libEGL has an unexpected install name"
  [[ $(otool -D "$gles" | sed -n '2p') == '@rpath/libGLESv2.dylib' ]] || \
    die "libGLESv2 has an unexpected install name"
  has_rpath "$qemu" '@executable_path/../lib' || die "QEMU is missing its isolated library rpath"
  has_rpath "$virgl" '@loader_path' || die "virglrenderer is missing its isolated library rpath"

  for image in "$qemu" "$virgl" "$epoxy" "$egl" "$gles"; do
    verify_image_dependencies "$root" "$image"
    codesign --verify --strict --verbose=2 "$image" >/dev/null 2>&1 || \
      die "invalid code signature: $image"
  done
  entitlements_output=$(codesign -d --entitlements - "$qemu" 2>&1) || \
    die "could not inspect QEMU's code-signing entitlements"
  [[ $entitlements_output == *com.apple.security.hypervisor* ]] || \
    die "QEMU is missing the com.apple.security.hypervisor entitlement"

  version_output=$(
    unset DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_FRAMEWORK_PATH
    "$qemu" --version 2>&1
  ) || die "relocated QEMU cannot load its Homebrew core dependencies: $version_output"
  [[ $version_output == QEMU\ emulator\ version\ 10.2.50* ]] || \
    die "relocated QEMU returned an unexpected version string: $version_output"

  accel_help=$("$qemu" -accel help 2>&1) || \
    die "relocated QEMU could not enumerate accelerators: $accel_help"
  printf '%s\n' "$accel_help" | awk '$1 == "hvf" { found = 1 } END { exit !found }' || \
    die "relocated QEMU is missing the HVF accelerator"

  machine_help=$("$qemu" -machine help 2>&1) || \
    die "relocated QEMU could not enumerate machines: $machine_help"
  printf '%s\n' "$machine_help" | awk '$1 == "virt" { found = 1 } END { exit !found }' || \
    die "relocated QEMU is missing the ARM virt machine"

  cpu_help=$("$qemu" -cpu help 2>&1) || \
    die "relocated QEMU could not enumerate CPUs: $cpu_help"
  printf '%s\n' "$cpu_help" | awk '$1 == "host" { found = 1 } END { exit !found }' || \
    die "relocated QEMU is missing the host CPU"

  display_help=$("$qemu" -display help 2>&1) || \
    die "relocated QEMU could not enumerate display backends: $display_help"
  [[ $display_help == *$'\ncocoa\n'* ]] || \
    die "relocated QEMU is missing its Cocoa display backend"

  device_help=$("$qemu" -device help 2>&1) || \
    die "relocated QEMU could not enumerate devices: $device_help"
  [[ $device_help == *'name "virtio-gpu-gl-pci"'* ]] || \
    die "relocated QEMU is missing the virtio-gpu-gl-pci device"

  if [[ -n $source_qemu ]]; then
    netdev_help=$("$qemu" -machine virt -netdev help 2>&1) || \
      die "source-built QEMU could not enumerate network backends: $netdev_help"
    printf '%s\n' "$netdev_help" | awk '$1 == "user" { found = 1 } END { exit !found }' || \
      die "source-built QEMU is missing the SLIRP user network backend"

    audio_help=$("$qemu" -machine virt -audiodev help 2>&1) || \
      die "source-built QEMU could not enumerate audio backends: $audio_help"
    printf '%s\n' "$audio_help" | awk '$1 == "sdl" { found = 1 } END { exit !found }' || \
      die "source-built QEMU is missing the SDL audio backend"
    for marker in \
      OMARCHY_SDL_AUDIO_CONTROL_DIRECTORY \
      OMARCHY_SDL_INPUT_DEVICE_NAME \
      OMARCHY_SDL_OUTPUT_DEVICE_NAME; do
      LC_ALL=C grep -aFq "$marker" "$qemu" || \
        die "source-built QEMU is missing the $marker routing hook"
    done
    [[ $device_help == *'name "intel-hda"'* ]] || \
      die "source-built QEMU is missing the intel-hda controller"
    [[ $device_help == *'name "hda-micro"'* ]] || \
      die "source-built QEMU is missing the duplex hda-micro codec"
    [[ $device_help == *'name "virtio-net-pci"'* ]] || \
      die "source-built QEMU is missing the virtio-net-pci device"
    [[ $device_help == *'name "virtio-9p-pci"'* ]] || \
      die "source-built QEMU is missing the virtio-9p-pci shared-folder device"
    for marker in guest_owner_uid guest_owner_gid; do
      LC_ALL=C grep -aFq "$marker" "$qemu" || \
        die "source-built QEMU is missing the $marker shared-folder option"
    done
  fi
}

log "Ad-hoc signing the relocated runtime"
for library in "$virgl_library" "$epoxy_library" "$egl_library" "$gles_library"; do
  codesign --force --sign - "$library"
done
codesign --force --sign - --entitlements "$entitlements" "$qemu_binary"

verify_runtime_tree "$staged_runtime"

atomic_rename() {
  local mode=$1
  local source=$2
  local target=$3

  python3 - "$mode" "$source" "$target" <<'PY'
import ctypes
import os
import sys

flags = {"swap": 0x00000002, "exclusive": 0x00000004}
mode, source, target = sys.argv[1:]
try:
    flag = flags[mode]
except KeyError:
    raise SystemExit(f"unsupported atomic rename mode: {mode}")

libc = ctypes.CDLL(None, use_errno=True)
renamex_np = libc.renamex_np
renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
renamex_np.restype = ctypes.c_int
if renamex_np(os.fsencode(source), os.fsencode(target), flag) != 0:
    error = ctypes.get_errno()
    print(f"renamex_np({mode}) failed: {os.strerror(error)}", file=sys.stderr)
    raise SystemExit(1)
PY
}

# Copy the complete, verified runtime into a same-filesystem staging directory.
# Darwin's RENAME_SWAP keeps an existing runtime continuously addressable while
# replacing it. RENAME_EXCL makes first publication atomic without an existence
# check/mv race. Both operations leave the old or new tree untouched on error.
publish_dir=$(mktemp -d "$build_dir/.qemu-gpu-runtime.publish.XXXXXX")
ditto "$staged_runtime" "$publish_dir"
verify_runtime_tree "$publish_dir"

if [[ -e $runtime_dir || -L $runtime_dir ]]; then
  [[ -d $runtime_dir && ! -L $runtime_dir ]] || \
    die "refusing to replace an unsafe runtime target: $runtime_dir"
  atomic_rename swap "$publish_dir" "$runtime_dir" || \
    die "could not atomically replace $runtime_dir"
  # After a successful swap, publish_dir names the previous runtime. The EXIT
  # trap also removes it if a handled signal arrives at this command boundary.
  remove_generated_dir "$publish_dir"
else
  atomic_rename exclusive "$publish_dir" "$runtime_dir" || \
    die "could not atomically publish $runtime_dir"
fi
publish_dir=

log "Prepared $runtime_dir"
if [[ -n $source_qemu ]]; then
  log "Runtime contains patched qemu-system-aarch64 with SLIRP/SDL audio and four isolated GPU dylibs"
  log "Source-built QEMU uses Homebrew libslirp and SDL2 dylibs in place"
else
  log "Runtime contains qemu-system-aarch64 and four isolated GPU dylibs"
fi
