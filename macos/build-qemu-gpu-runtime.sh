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
texture_patch="$native_dir/patches/qemu-texture-borrowing-11.1.patch"
identity_patch="$native_dir/patches/qemu-cocoa-product-identity.patch"
display_patch="$native_dir/patches/qemu-cocoa-dynamic-display.patch"
immersive_patch="$native_dir/patches/qemu-cocoa-immersive-mode.patch"
full_grab_patch="$native_dir/patches/qemu-cocoa-full-grab-focus.patch"
audio_device_patch="$native_dir/patches/qemu-sdl-audio-device-selection.patch"
shared_folder_patch="$native_dir/patches/qemu-9p-guest-owner.patch"
strchrnul_patch="$native_dir/patches/qemu-darwin-strchrnul-compat.patch"
prepare_runtime="$native_dir/prepare-qemu-gpu-runtime.sh"
pinned_bottles="$native_dir/pinned-runtime-bottles.sh"

qemu_commit=c3d48b7d1e89604920e5b81b91140c2ad39a1943
qemu_root="qemu-$qemu_commit"
qemu_archive_name="$qemu_root.tar.gz"
qemu_url="https://gitlab.com/qemu-project/qemu/-/archive/$qemu_commit/$qemu_archive_name"
qemu_sha256=7563781d7dec46f11509801e027f852597235d29ca7afa44a07ed9d8b108b8cd

startergo_commit=cbfb7641c933e8364dda0a035830603fd7455a4e
startergo_root="homebrew-qemu-virgl-kosmickrisp-$startergo_commit"
startergo_archive_name="$startergo_root.tar.gz"
startergo_url="https://github.com/startergo/homebrew-qemu-virgl-kosmickrisp/archive/$startergo_commit.tar.gz"
startergo_sha256=8b02c2bc4177047cb516f0cd5b510aa7a7aed2bdb3fb1d8507faf45fa5adc5a9
texture_patch_sha256=b20bdf9a7d7ccda5b86366ad9d09a3bf95308b98a06b1ece281344405bcc7ab9
gpu_fix_patch_sha256=2b0a589d5821fbbfaa65177c97395ec50382373373e5c6860821279f07d62bb2
identity_patch_sha256=5c9358c2858a74d6a678eacaae550a021f3e616c98c4e4e98c0e50bd869a0666
display_patch_sha256=d2b1ba0d8103640815b00a2bd02e59a7452bf79de524a33081011895101cf6ea
immersive_patch_sha256=fd1cd1a619778bda5c0c4cf58001fa7053af70ac717153ed9da819d8511a2574
full_grab_patch_sha256=a48fc375e53fd379bca958715b0d94802d3e17c6668f0b461800cf82839589fc
audio_device_patch_sha256=ccceaff1eabe5db54cbab03d5823c9ab73e922fc727702d3b790443d07f470a3
shared_folder_patch_sha256=41247692501655393ae3a40f56915472ab29b6e89c5173e33db1f62cca56632f
strchrnul_patch_sha256=ec1048dd0e8ebe53bf7e8a3bca9bf2f5f4336cd607d4cd077437470e9a32094a
macos_deployment_target=15.0

keycodemap_commit=f5772a62ec52591ff6870b7e8ef32482371f22c6
keycodemap_root="keycodemapdb-$keycodemap_commit"
keycodemap_archive_name="$keycodemap_root.tar.gz"
keycodemap_url="https://gitlab.com/qemu-project/keycodemapdb/-/archive/$keycodemap_commit/$keycodemap_archive_name"
keycodemap_sha256=d014b53382dbb17b8196ad12f50de7f20d0ef1b9f7d54b0be51a6cbb14209195

dtc_commit=b6910bec11614980a21e46fbccc35934b671bd81
dtc_root="dtc-$dtc_commit"
dtc_archive_name="$dtc_root.tar.gz"
# TEMPORARY: git.kernel.org cgit is returning 404 for every repository.
# Upstream mirror of the same commit; revert once kernel.org is back.
dtc_url="https://codeload.github.com/dgibson/dtc/tar.gz/$dtc_commit"
dtc_sha256=e115f987eec23a1ba25150a46ced1675de3716072d3b4905afb3a9cda0f007c7

ninja_version=1.13.0
ninja_archive_name=ninja-1.13.0-py3-none-macosx_10_9_universal2.whl
ninja_url="https://files.pythonhosted.org/packages/3c/74/d02409ed2aa865e051b7edda22ad416a39d81a84980f544f8de717cab133/$ninja_archive_name"
ninja_sha256=fa2a8bfc62e31b08f83127d1613d10821775a0eb334197154c4d6067b7068ff1

virgl_version=1.0.33
setuptools_archive_name=setuptools-84.0.0-py3-none-any.whl
setuptools_url="https://files.pythonhosted.org/packages/95/9c/c510029fc6ef33a6275cd2c5d3cecd6613dfd6aa401d57c54f1c18852ccf/$setuptools_archive_name"
setuptools_sha256=51a52592b3b99e102b609654876bd65f19f999935166d1352678931132b0c670

wheel_archive_name=wheel-0.48.0-py3-none-any.whl
wheel_url="https://files.pythonhosted.org/packages/2e/29/69cfbb602cd91690c55d38ba9fe53e6a7e76a6fa647bf38f19c138d25449/$wheel_archive_name"
wheel_sha256=3217dcc807155e45db462d7ef2431f5ddda0d7273b700d05a67b271ceb1287ab

pip_archive_name=pip-26.2.1-py3-none-any.whl
pip_url="https://files.pythonhosted.org/packages/f3/6e/1736e5b4ae2b778ef2f81c47d797de9f891d4d8acb047a24ca37a60294dd/$pip_archive_name"
pip_sha256=71138adf1f4ca900cdb7d289c21b7494329f2332b6d85f0e1c42108c0384ed3e

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
  echo "qemu-source-build: $*" >&2
  exit 1
}

log() {
  echo "[qemu-source-build] $*"
}

[[ -f $pinned_bottles && ! -L $pinned_bottles ]] || {
  echo "qemu-source-build: missing pinned bottle manifest: $pinned_bottles" >&2
  exit 1
}
# shellcheck source=macos/pinned-runtime-bottles.sh
source "$pinned_bottles"

for tool in awk bash chmod curl ditto file grep install mkdir mktemp patch \
  pkg-config python3 rm sed shasum sw_vers tar uname; do
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
[[ -f $full_grab_patch && ! -L $full_grab_patch ]] || \
  die "missing Cocoa full-grab patch: $full_grab_patch"
[[ -f $audio_device_patch && ! -L $audio_device_patch ]] || \
  die "missing SDL audio-device patch: $audio_device_patch"
[[ -f $texture_patch && ! -L $texture_patch ]] || \
  die "missing texture-borrowing patch: $texture_patch"
[[ -f $shared_folder_patch && ! -L $shared_folder_patch ]] || \
  die "missing 9p shared-folder patch: $shared_folder_patch"
[[ -f $strchrnul_patch && ! -L $strchrnul_patch ]] || \
  die "missing Darwin strchrnul compatibility patch: $strchrnul_patch"
[[ -x $prepare_runtime && ! -L $prepare_runtime ]] || \
  die "missing runtime preparation script: $prepare_runtime"
if [[ -n $archive_cache ]]; then
  [[ $archive_cache == /* ]] || die "--archive-dir must be an absolute path"
  [[ -d $archive_cache && ! -L $archive_cache ]] || \
    die "--archive-dir must name a regular directory: $archive_cache"
fi

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
setuptools_archive="$archive_dir/$setuptools_archive_name"
wheel_archive="$archive_dir/$wheel_archive_name"
pip_archive="$archive_dir/$pip_archive_name"

obtain_and_verify "QEMU $qemu_commit" "$qemu_url" "$qemu_sha256" "$qemu_archive"
obtain_and_verify "startergo patches $startergo_commit" "$startergo_url" "$startergo_sha256" "$startergo_archive"
obtain_and_verify "keycodemapdb $keycodemap_commit" "$keycodemap_url" "$keycodemap_sha256" "$keycodemap_archive"
obtain_and_verify "dtc $dtc_commit" "$dtc_url" "$dtc_sha256" "$dtc_archive"
obtain_and_verify "Ninja $ninja_version" "$ninja_url" "$ninja_sha256" "$ninja_archive"
obtain_and_verify "virglrenderer $virgl_version" "$virgl_url" "$virgl_sha256" "$virgl_archive"
obtain_and_verify "ANGLE $angle_version" "$angle_url" "$angle_sha256" "$angle_archive"
obtain_and_verify "libepoxy $epoxy_version" "$epoxy_url" "$epoxy_sha256" "$epoxy_archive"
while IFS=$'\t' read -r formula version archive_name archive_root archive_sha; do
  pinned_bottle_obtain \
    "$formula" "$formula $version" "$archive_sha" \
    "$archive_dir/$archive_name" "$archive_cache"
  pinned_bottle_validate_archive \
    "$formula $version" "$archive_dir/$archive_name" "$archive_root"
done < <(pinned_core_bottle_manifest)

obtain_and_verify "setuptools" "$setuptools_url" "$setuptools_sha256" "$setuptools_archive"
obtain_and_verify "wheel" "$wheel_url" "$wheel_sha256" "$wheel_archive"
obtain_and_verify "pip" "$pip_url" "$pip_sha256" "$pip_archive"

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
while IFS=$'\t' read -r formula version archive_name archive_root archive_sha; do
  tar -xzf "$archive_dir/$archive_name" -C "$dependency_root"
done < <(pinned_core_bottle_manifest)

source_dir="$source_parent/$qemu_root"
startergo_dir="$source_parent/$startergo_root"
[[ -f $source_dir/configure && -f $source_dir/ui/cocoa.m ]] || \
  die "QEMU source archive is incomplete"

install -m 0644 "$setuptools_archive" "$wheel_archive" "$pip_archive" \
  "$source_dir/python/wheels/"

mkdir -p "$source_dir/subprojects/keycodemapdb" "$source_dir/subprojects/dtc"
tar -xzf "$keycodemap_archive" -C "$source_dir/subprojects/keycodemapdb" --strip-components=1
tar -xzf "$dtc_archive" -C "$source_dir/subprojects/dtc" --strip-components=1

gpu_fix_patch="$startergo_dir/patches/gpu-spike-resolution-fix.patch"
verify_file_sha "Try Omarchy texture-borrowing patch" "$texture_patch" "$texture_patch_sha256"
verify_file_sha "startergo GPU-resolution patch" "$gpu_fix_patch" "$gpu_fix_patch_sha256"
verify_file_sha "Try Omarchy Cocoa product-identity patch" \
  "$identity_patch" "$identity_patch_sha256"
verify_file_sha "Try Omarchy dynamic-display patch" "$display_patch" "$display_patch_sha256"
verify_file_sha "Try Omarchy Cocoa immersive-mode patch" \
  "$immersive_patch" "$immersive_patch_sha256"
verify_file_sha "Try Omarchy Cocoa full-grab patch" \
  "$full_grab_patch" "$full_grab_patch_sha256"
verify_file_sha "Try Omarchy SDL audio-device patch" \
  "$audio_device_patch" "$audio_device_patch_sha256"
verify_file_sha "Try Omarchy 9p shared-folder patch" \
  "$shared_folder_patch" "$shared_folder_patch_sha256"
verify_file_sha "Try Omarchy Darwin strchrnul compatibility patch" \
  "$strchrnul_patch" "$strchrnul_patch_sha256"

log "Applying the exact render, identity, display, immersive, audio, folder, and Darwin compatibility patches"
patch -d "$source_dir" -p1 -f -i "$texture_patch"
patch -d "$source_dir" -p1 -f -i "$gpu_fix_patch"
patch -d "$source_dir" -p1 -f -i "$identity_patch"
patch -d "$source_dir" -p1 -f -i "$display_patch"
patch -d "$source_dir" -p1 -f -i "$immersive_patch"
patch -d "$source_dir" -p1 -f -i "$full_grab_patch"
patch -d "$source_dir" -p1 -f -i "$audio_device_patch"
patch -d "$source_dir" -p1 -f -i "$shared_folder_patch"
patch -d "$source_dir" -p1 -f -i "$strchrnul_patch"

virgl_root="$dependency_root/virglrenderer/$virgl_version"
angle_root="$dependency_root/angle/$angle_version"
epoxy_root="$dependency_root/libepoxy/$epoxy_version"
glib_root="$dependency_root/$PINNED_GLIB_ROOT"
pixman_root="$dependency_root/$PINNED_PIXMAN_ROOT"
slirp_root="$dependency_root/$PINNED_LIBSLIRP_ROOT"
sdl2_root="$dependency_root/$PINNED_SDL2_ROOT"
sdl3_root="$dependency_root/$PINNED_SDL3_ROOT"
gettext_root="$dependency_root/$PINNED_GETTEXT_ROOT"
pcre2_root="$dependency_root/$PINNED_PCRE2_ROOT"
zstd_root="$dependency_root/$PINNED_ZSTD_ROOT"
lz4_root="$dependency_root/$PINNED_LZ4_ROOT"
xz_root="$dependency_root/$PINNED_XZ_ROOT"
for directory in \
  "$virgl_root" "$angle_root" "$epoxy_root" \
  "$glib_root" "$pixman_root" "$slirp_root" "$sdl2_root" "$sdl3_root" \
  "$gettext_root" "$pcre2_root" "$zstd_root" "$lz4_root" "$xz_root"; do
  [[ -d $directory && ! -L $directory ]] || die "missing extracted dependency: $directory"
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

for pc_file in "$glib_root"/lib/pkgconfig/*.pc; do
  sed -i '' \
    -e "s|@@HOMEBREW_CELLAR@@/$PINNED_GLIB_ROOT|$glib_root|g" \
    -e "s|@@HOMEBREW_PREFIX@@/opt/gettext|$gettext_root|g" \
    "$pc_file"
done
for pc_file in "$pixman_root"/lib/pkgconfig/*.pc; do
  sed -i '' "s|@@HOMEBREW_CELLAR@@/$PINNED_PIXMAN_ROOT|$pixman_root|g" "$pc_file"
done
for pc_file in "$slirp_root"/lib/pkgconfig/*.pc; do
  sed -i '' "s|@@HOMEBREW_CELLAR@@/$PINNED_LIBSLIRP_ROOT|$slirp_root|g" "$pc_file"
done
for pc_file in "$pcre2_root"/lib/pkgconfig/*.pc; do
  sed -i '' "s|@@HOMEBREW_CELLAR@@/$PINNED_PCRE2_ROOT|$pcre2_root|g" "$pc_file"
done
sed -i '' \
  -e "s|^prefix=@@HOMEBREW_PREFIX@@$|prefix=$sdl2_root|" \
  -e "s|^libdir=@@HOMEBREW_PREFIX@@/lib$|libdir=$sdl2_root/lib|" \
  -e "s|^includedir=@@HOMEBREW_PREFIX@@/include$|includedir=$sdl2_root/include|" \
  "$sdl2_root/lib/pkgconfig/sdl2-compat.pc"

# sdl2-compat loads SDL3 by this exact @loader_path name. Keeping a private
# build-time copy beside SDL2 also makes any configure probes independent of
# globally installed libraries.
install -m 0755 "$sdl3_root/lib/libSDL3.0.dylib" "$sdl2_root/lib/libSDL3.dylib"

ditto -x -k "$ninja_archive" "$tool_root"
ninja="$tool_root/ninja-$ninja_version.data/scripts/ninja"
[[ -f $ninja && ! -L $ninja ]] || die "pinned Ninja wheel is missing its executable"
chmod 0755 "$ninja"

pkg_config_libdir="$virgl_root/lib/pkgconfig:$epoxy_root/lib/pkgconfig:$angle_root/lib/pkgconfig:$glib_root/lib/pkgconfig:$pixman_root/lib/pkgconfig:$slirp_root/lib/pkgconfig:$sdl2_root/lib/pkgconfig:$pcre2_root/lib/pkgconfig"
private_libraries="$virgl_root/lib:$epoxy_root/lib:$angle_root/lib:$glib_root/lib:$pixman_root/lib:$slirp_root/lib:$sdl2_root/lib:$gettext_root/lib:$pcre2_root/lib"

require_private_pkg_version() {
  local package=$1
  local expected=$2
  local actual

  actual=$(env PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$pkg_config_libdir" \
    pkg-config --modversion "$package" 2>/dev/null) || \
    die "pinned bottle set is missing pkg-config dependency: $package $expected"
  [[ $actual == "$expected" ]] || \
    die "$package version mismatch: expected $expected, got $actual"
}

require_private_pkg_version glib-2.0 2.88.3
require_private_pkg_version pixman-1 0.46.4
require_private_pkg_version slirp 4.9.4
require_private_pkg_version sdl2 2.32.70
require_private_pkg_version virglrenderer 1.2.0
require_private_pkg_version epoxy 1.5.11

build_dir="$source_dir/build"
mkdir "$build_dir"
log "Configuring QEMU 11.1.1 (HVF-only, Cocoa/VirGL, SLIRP, SDL audio, virtio-9p) for macOS $macos_deployment_target and newer"
(
  cd "$build_dir"
  env MACOSX_DEPLOYMENT_TARGET="$macos_deployment_target" \
    PKG_CONFIG_PATH= \
    PKG_CONFIG_LIBDIR="$pkg_config_libdir" \
    DYLD_LIBRARY_PATH="$private_libraries" \
    DYLD_FALLBACK_LIBRARY_PATH="$private_libraries" \
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
      --extra-cflags="-mmacosx-version-min=$macos_deployment_target -Werror=unguarded-availability-new" \
      --extra-ldflags="-mmacosx-version-min=$macos_deployment_target" \
      --ninja="$ninja"
)

config_host="$build_dir/config-host.h"
[[ -f $config_host && ! -L $config_host ]] || die "QEMU configure did not create config-host.h"
if grep -Eq '^[[:space:]]*#define[[:space:]]+HAVE_STRCHRNUL([[:space:]]+1)?[[:space:]]*$' \
  "$config_host"; then
  die "QEMU incorrectly enabled the macOS 15.4-only strchrnul API"
fi
python3 - \
  "$build_dir/compile_commands.json" \
  "-mmacosx-version-min=$macos_deployment_target" \
  '-Werror=unguarded-availability-new' <<'PY'
import json
import shlex
import sys

path, deployment_flag, availability_flag = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as source:
        commands = json.load(source)
except (OSError, UnicodeError, json.JSONDecodeError) as error:
    raise SystemExit(f"qemu-source-build: cannot audit compile commands: {error}")
if not isinstance(commands, list) or not commands:
    raise SystemExit("qemu-source-build: compile command database is empty")
missing = []
for record in commands:
    if not isinstance(record, dict):
        missing.append("<invalid record>")
        continue
    arguments = record.get("arguments")
    if not isinstance(arguments, list):
        command = record.get("command")
        arguments = shlex.split(command) if isinstance(command, str) else []
    if deployment_flag not in arguments or availability_flag not in arguments:
        missing.append(str(record.get("file", "<unknown source>")))
if missing:
    examples = ", ".join(missing[:5])
    raise SystemExit(
        f"qemu-source-build: compatibility flags are missing from "
        f"{len(missing)} compile commands ({examples})"
    )
print(f"[qemu-source-build] Audited compatibility flags in {len(commands)} compile commands")
PY

log "Building qemu-system-aarch64"
env MACOSX_DEPLOYMENT_TARGET="$macos_deployment_target" \
  PKG_CONFIG_PATH= \
  PKG_CONFIG_LIBDIR="$pkg_config_libdir" \
  DYLD_LIBRARY_PATH="$private_libraries" \
  DYLD_FALLBACK_LIBRARY_PATH="$private_libraries" \
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
