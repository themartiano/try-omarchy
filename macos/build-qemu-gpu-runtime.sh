#!/bin/bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: macos/build-qemu-gpu-runtime.sh [--archive-dir DIR]

Build the pinned startergo QEMU/VirGL source stack with Try Omarchy's Cocoa
identity, dynamic-display, and immersive-mode patches, then relocate, sign,
validate, and
atomically stage it at:
  macos/.build/qemu-gpu-runtime

The build is Apple-Silicon/HVF-only. It enables Cocoa+VirGL, SLIRP user
networking, SDL duplex audio, and virtio-9p folder sharing. All downloaded source archives and wheels are
immutable and checksum-pinned; scratch sources are removed on every exit.

With --archive-dir, reuse already-downloaded pinned archives from DIR. Every
archive is copied into private scratch space and checksum-verified before use.
EOF
}

archive_cache=
while (($#)); do
  case "$1" in
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
identity_patch="$native_dir/patches/qemu-cocoa-product-identity.patch"
display_patch="$native_dir/patches/qemu-cocoa-dynamic-display.patch"
immersive_patch="$native_dir/patches/qemu-cocoa-immersive-mode.patch"
audio_device_patch="$native_dir/patches/qemu-sdl-audio-device-selection.patch"
shared_folder_patch="$native_dir/patches/qemu-9p-guest-owner.patch"
prepare_runtime="$native_dir/prepare-qemu-gpu-runtime.sh"

qemu_commit=cf3e71d8fc8ba681266759bb6cb2e45a45983e3e
qemu_root="qemu-$qemu_commit"
qemu_archive_name="$qemu_root.tar.gz"
qemu_url="https://gitlab.com/qemu-project/qemu/-/archive/$qemu_commit/$qemu_archive_name"
qemu_sha256=72791c1fdbe20092990c6f36135ab5fe6890469b6b6b294fc97889395c6bfcea

startergo_commit=cbfb7641c933e8364dda0a035830603fd7455a4e
startergo_root="homebrew-qemu-virgl-kosmickrisp-$startergo_commit"
startergo_archive_name="$startergo_root.tar.gz"
startergo_url="https://github.com/startergo/homebrew-qemu-virgl-kosmickrisp/archive/$startergo_commit.tar.gz"
startergo_sha256=8b02c2bc4177047cb516f0cd5b510aa7a7aed2bdb3fb1d8507faf45fa5adc5a9
texture_patch_sha256=428528d3203fe487e7aac21f313bc83e53ad22168e8fd39aa9eb1791bc157903
gpu_fix_patch_sha256=2b0a589d5821fbbfaa65177c97395ec50382373373e5c6860821279f07d62bb2
identity_patch_sha256=5c9358c2858a74d6a678eacaae550a021f3e616c98c4e4e98c0e50bd869a0666
display_patch_sha256=19392fe5723829edea348b82a6b0a74f874724af243ed0fb9101007a22fa5bbb
immersive_patch_sha256=787b271b3c7260305f54f9d7ed5fbbf82d085347954977df6b12898c2efb5f0f
audio_device_patch_sha256=20469691f4cdabcd6b9513d6bf00fab9f66983e17b1e8477cc2e5ac47416feed
shared_folder_patch_sha256=585a5ed40cc7e4a155ca799d731e15354db9e75d4f517d0689be60200750f3e3

keycodemap_commit=f5772a62ec52591ff6870b7e8ef32482371f22c6
keycodemap_root="keycodemapdb-$keycodemap_commit"
keycodemap_archive_name="$keycodemap_root.tar.gz"
keycodemap_url="https://gitlab.com/qemu-project/keycodemapdb/-/archive/$keycodemap_commit/$keycodemap_archive_name"
keycodemap_sha256=d014b53382dbb17b8196ad12f50de7f20d0ef1b9f7d54b0be51a6cbb14209195

dtc_commit=b6910bec11614980a21e46fbccc35934b671bd81
dtc_root="dtc-$dtc_commit"
dtc_archive_name="$dtc_root.tar.gz"
dtc_url="https://git.kernel.org/pub/scm/utils/dtc/dtc.git/snapshot/$dtc_archive_name"
dtc_sha256=e115f987eec23a1ba25150a46ced1675de3716072d3b4905afb3a9cda0f007c7

ninja_version=1.13.0
ninja_archive_name=ninja-1.13.0-py3-none-macosx_10_9_universal2.whl
ninja_url="https://files.pythonhosted.org/packages/3c/74/d02409ed2aa865e051b7edda22ad416a39d81a84980f544f8de717cab133/$ninja_archive_name"
ninja_sha256=fa2a8bfc62e31b08f83127d1613d10821775a0eb334197154c4d6067b7068ff1

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

slirp_version=4.9.4
sdl_version=2.32.70

die() {
  echo "qemu-source-build: $*" >&2
  exit 1
}

log() {
  echo "[qemu-source-build] $*"
}

for tool in awk bash brew chmod curl ditto file install mkdir mktemp patch \
  pkg-config rm sed shasum sw_vers tar uname; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool is unavailable: $tool"
done

[[ $(uname -s) == Darwin ]] || die "this source build requires macOS"
[[ $(uname -m) == arm64 ]] || die "this source build requires Apple Silicon (arm64)"
macos_major=$(sw_vers -productVersion | awk -F. '{ print $1 }')
[[ $macos_major =~ ^[0-9]+$ ]] || die "could not determine the macOS version"
((macos_major >= 15)) || die "the pinned GPU bottles require macOS 15 or newer"
[[ -f $identity_patch && ! -L $identity_patch ]] || \
  die "missing Cocoa product-identity patch: $identity_patch"
[[ -f $display_patch && ! -L $display_patch ]] || \
  die "missing dynamic-display patch: $display_patch"
[[ -f $immersive_patch && ! -L $immersive_patch ]] || \
  die "missing immersive-mode patch: $immersive_patch"
[[ -f $audio_device_patch && ! -L $audio_device_patch ]] || \
  die "missing SDL audio-device patch: $audio_device_patch"
[[ -f $shared_folder_patch && ! -L $shared_folder_patch ]] || \
  die "missing 9p shared-folder patch: $shared_folder_patch"
[[ -x $prepare_runtime && ! -L $prepare_runtime ]] || \
  die "missing runtime preparation script: $prepare_runtime"
if [[ -n $archive_cache ]]; then
  [[ $archive_cache == /* ]] || die "--archive-dir must be an absolute path"
  [[ -d $archive_cache && ! -L $archive_cache ]] || \
    die "--archive-dir must name a regular directory: $archive_cache"
fi

export HOMEBREW_NO_AUTO_UPDATE=1
brew_prefix=$(brew --prefix) || die "Homebrew is required for build dependencies"
[[ $brew_prefix == /* && -d $brew_prefix ]] || die "invalid Homebrew prefix: $brew_prefix"

require_pkg_version() {
  local package=$1
  local expected=$2
  local actual

  actual=$(pkg-config --modversion "$package" 2>/dev/null) || \
    die "missing Homebrew pkg-config dependency: $package $expected"
  [[ $actual == "$expected" ]] || \
    die "$package version mismatch: expected $expected, got $actual"
}

require_pkg_version slirp "$slirp_version"
require_pkg_version sdl2 "$sdl_version"
pkg-config --exists glib-2.0 pixman-1 || \
  die "Homebrew glib and pixman development files are required"

work_dir=
remove_work_dir() {
  local path=$1
  [[ -n $path && ( -e $path || -L $path ) ]] || return 0
  [[ $path == /private/tmp/omarchy-qemu-source-build.* ]] || \
    die "refusing to remove unexpected scratch path: $path"
  rm -rf -- "$path"
}

cleanup() {
  local exit_status=$?
  trap - EXIT HUP INT TERM
  [[ -z $work_dir ]] || remove_work_dir "$work_dir" || true
  exit "$exit_status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

work_dir=$(mktemp -d /private/tmp/omarchy-qemu-source-build.XXXXXX)
archive_dir="$work_dir/archives"
listing_dir="$work_dir/listings"
source_parent="$work_dir/source"
dependency_root="$work_dir/dependencies"
tool_root="$work_dir/tools"
mkdir -p "$archive_dir" "$listing_dir" "$source_parent" "$dependency_root" "$tool_root"

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

verify_file_sha() {
  local label=$1
  local path=$2
  local expected=$3
  local actual

  actual=$(shasum -a 256 "$path" | awk '{ print $1 }') || \
    die "could not hash $label"
  [[ $actual == "$expected" ]] || \
    die "$label checksum mismatch: expected $expected, got $actual"
}

validate_tar_root() {
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
      ""|/*|..|../*|*/..|*/../*) die "$label contains an unsafe path: $member" ;;
    esac
    case "$member" in
      "$expected_root"|"$expected_root/"|"$expected_root/"*) ;;
      *) die "$label contains a path outside $expected_root: $member" ;;
    esac
  done <"$listing"
}

qemu_archive="$archive_dir/$qemu_archive_name"
startergo_archive="$archive_dir/$startergo_archive_name"
keycodemap_archive="$archive_dir/$keycodemap_archive_name"
dtc_archive="$archive_dir/$dtc_archive_name"
ninja_archive="$archive_dir/$ninja_archive_name"
virgl_archive="$archive_dir/$virgl_archive_name"
angle_archive="$archive_dir/$angle_archive_name"
epoxy_archive="$archive_dir/$epoxy_archive_name"

obtain_and_verify "QEMU $qemu_commit" "$qemu_url" "$qemu_sha256" "$qemu_archive"
obtain_and_verify "startergo patches $startergo_commit" "$startergo_url" "$startergo_sha256" "$startergo_archive"
obtain_and_verify "keycodemapdb $keycodemap_commit" "$keycodemap_url" "$keycodemap_sha256" "$keycodemap_archive"
obtain_and_verify "dtc $dtc_commit" "$dtc_url" "$dtc_sha256" "$dtc_archive"
obtain_and_verify "Ninja $ninja_version" "$ninja_url" "$ninja_sha256" "$ninja_archive"
obtain_and_verify "virglrenderer $virgl_version" "$virgl_url" "$virgl_sha256" "$virgl_archive"
obtain_and_verify "ANGLE $angle_version" "$angle_url" "$angle_sha256" "$angle_archive"
obtain_and_verify "libepoxy $epoxy_version" "$epoxy_url" "$epoxy_sha256" "$epoxy_archive"

validate_tar_root "QEMU $qemu_commit" "$qemu_archive" "$qemu_root" "$listing_dir/qemu.txt"
validate_tar_root "startergo patches" "$startergo_archive" "$startergo_root" "$listing_dir/startergo.txt"
validate_tar_root "keycodemapdb" "$keycodemap_archive" "$keycodemap_root" "$listing_dir/keycodemapdb.txt"
validate_tar_root "dtc" "$dtc_archive" "$dtc_root" "$listing_dir/dtc.txt"
validate_tar_root "virglrenderer" "$virgl_archive" "virglrenderer/$virgl_version" "$listing_dir/virglrenderer.txt"
validate_tar_root "ANGLE" "$angle_archive" "angle/$angle_version" "$listing_dir/angle.txt"
validate_tar_root "libepoxy" "$epoxy_archive" "libepoxy/$epoxy_version" "$listing_dir/libepoxy.txt"

tar -xzf "$qemu_archive" -C "$source_parent"
tar -xzf "$startergo_archive" -C "$source_parent"
tar -xzf "$virgl_archive" -C "$dependency_root"
tar -xzf "$angle_archive" -C "$dependency_root"
tar -xzf "$epoxy_archive" -C "$dependency_root"

source_dir="$source_parent/$qemu_root"
startergo_dir="$source_parent/$startergo_root"
[[ -f $source_dir/configure && -f $source_dir/ui/cocoa.m ]] || \
  die "QEMU source archive is incomplete"

mkdir -p "$source_dir/subprojects/keycodemapdb" "$source_dir/subprojects/dtc"
tar -xzf "$keycodemap_archive" -C "$source_dir/subprojects/keycodemapdb" --strip-components=1
tar -xzf "$dtc_archive" -C "$source_dir/subprojects/dtc" --strip-components=1

texture_patch="$startergo_dir/patches/qemu-texture-borrowing.patch"
gpu_fix_patch="$startergo_dir/patches/gpu-spike-resolution-fix.patch"
verify_file_sha "startergo texture-borrowing patch" "$texture_patch" "$texture_patch_sha256"
verify_file_sha "startergo GPU-resolution patch" "$gpu_fix_patch" "$gpu_fix_patch_sha256"
verify_file_sha "Try Omarchy Cocoa product-identity patch" \
  "$identity_patch" "$identity_patch_sha256"
verify_file_sha "Try Omarchy dynamic-display patch" "$display_patch" "$display_patch_sha256"
verify_file_sha "Try Omarchy Cocoa immersive-mode patch" \
  "$immersive_patch" "$immersive_patch_sha256"
verify_file_sha "Try Omarchy SDL audio-device patch" \
  "$audio_device_patch" "$audio_device_patch_sha256"
verify_file_sha "Try Omarchy 9p shared-folder patch" \
  "$shared_folder_patch" "$shared_folder_patch_sha256"

log "Applying the exact render, product-identity, dynamic-display, immersive-mode, audio-device, and shared-folder patches"
patch -d "$source_dir" -p1 -f -i "$texture_patch"
patch -d "$source_dir" -p1 -f -i "$gpu_fix_patch"
patch -d "$source_dir" -p1 -f -i "$identity_patch"
patch -d "$source_dir" -p1 -f -i "$display_patch"
patch -d "$source_dir" -p1 -f -i "$immersive_patch"
patch -d "$source_dir" -p1 -f -i "$audio_device_patch"
patch -d "$source_dir" -p1 -f -i "$shared_folder_patch"

virgl_root="$dependency_root/virglrenderer/$virgl_version"
angle_root="$dependency_root/angle/$angle_version"
epoxy_root="$dependency_root/libepoxy/$epoxy_version"
for directory in "$virgl_root" "$angle_root" "$epoxy_root"; do
  [[ -d $directory && ! -L $directory ]] || die "missing extracted GPU dependency: $directory"
done

# Bottle pkg-config files contain Homebrew relocation placeholders. Point only
# this private build at the verified extracted headers and libraries.
sed -i '' "s|@@HOMEBREW_CELLAR@@/virglrenderer/$virgl_version|$virgl_root|g" \
  "$virgl_root/lib/pkgconfig/virglrenderer.pc"
sed -i '' "s|@@HOMEBREW_CELLAR@@/libepoxy/$epoxy_version|$epoxy_root|g" \
  "$epoxy_root/lib/pkgconfig/epoxy.pc"
for pc_file in "$angle_root"/lib/pkgconfig/*.pc; do
  sed -i '' "s|^prefix=/opt/homebrew$|prefix=$angle_root|" "$pc_file"
done

ditto -x -k "$ninja_archive" "$tool_root"
ninja="$tool_root/ninja-$ninja_version.data/scripts/ninja"
[[ -f $ninja && ! -L $ninja ]] || die "pinned Ninja wheel is missing its executable"
chmod 0755 "$ninja"

slirp_pc_dir=$(pkg-config --variable=pcfiledir slirp)
sdl_pc_dir=$(pkg-config --variable=pcfiledir sdl2)
pkg_config_path="$virgl_root/lib/pkgconfig:$epoxy_root/lib/pkgconfig:$angle_root/lib/pkgconfig:$slirp_pc_dir:$sdl_pc_dir"
fallback_libraries="$virgl_root/lib:$epoxy_root/lib:$angle_root/lib"

build_dir="$source_dir/build"
mkdir "$build_dir"
log "Configuring QEMU 10.2.50 (HVF-only, Cocoa/VirGL, SLIRP, SDL audio, virtio-9p)"
(
  cd "$build_dir"
  env PKG_CONFIG_PATH="$pkg_config_path" \
    DYLD_FALLBACK_LIBRARY_PATH="$fallback_libraries" \
    ../configure \
      --prefix="$work_dir/install" \
      --target-list=aarch64-softmmu \
      --without-default-features \
      --enable-system \
      --enable-hvf \
      --disable-tcg \
      --enable-cocoa \
      --enable-opengl \
      --enable-virglrenderer \
      --enable-pixman \
      --enable-slirp \
      --enable-fdt=internal \
      --enable-sdl \
      --audio-drv-list=sdl \
      --enable-virtfs \
      --disable-debug-info \
      --disable-werror \
      --disable-download \
      --ninja="$ninja"
)

log "Building qemu-system-aarch64"
env DYLD_FALLBACK_LIBRARY_PATH="$fallback_libraries" \
  "$ninja" -C "$build_dir" qemu-system-aarch64

qemu_binary="$build_dir/qemu-system-aarch64"
description=$(file -b "$qemu_binary")
[[ $description == *Mach-O* && $description == *arm64* ]] || \
  die "source build did not produce an arm64 Mach-O QEMU binary"

log "Relocating, capability-gating, signing, and publishing the runtime"
"$prepare_runtime" \
  --source-qemu "$qemu_binary" \
  --archive-dir "$archive_dir"

log "Pinned patched runtime is ready; scratch source and archives will now be removed"
