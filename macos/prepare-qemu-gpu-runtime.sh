#!/bin/bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: macos/prepare-qemu-gpu-runtime.sh --source-qemu PATH [--archive-dir DIR]

Stage, relocate, validate, and ad-hoc sign the source-built QEMU runtime at:
  macos/.build/qemu-gpu-runtime

The complete runtime closure comes from checksum-pinned arm64_sequoia bottles;
it never reads or bundles libraries from the build machine's Homebrew prefix.
With --archive-dir, reuse pinned archives from DIR after verifying every hash.
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
pinned_bottles="$native_dir/pinned-runtime-bottles.sh"
dependency_bundler="$native_dir/bundle-macho-dependencies.sh"
compatibility_verifier="$native_dir/verify-macos-compatibility.sh"
runtime_manifest="$native_dir/runtime-files.txt"

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

[[ -f $pinned_bottles && ! -L $pinned_bottles ]] || \
  die "missing pinned bottle manifest: $pinned_bottles"
# shellcheck source=macos/pinned-runtime-bottles.sh
source "$pinned_bottles"

for tool in awk codesign curl ditto file find grep install mkdir mktemp otool \
  python3 rm sed shasum sw_vers tar uname xattr; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool is unavailable: $tool"
done

[[ $(uname -s) == Darwin ]] || die "the pinned bottles require macOS"
[[ $(uname -m) == arm64 ]] || die "the pinned bottles require Apple Silicon (arm64)"
macos_major=$(sw_vers -productVersion | awk -F. '{ print $1 }')
[[ $macos_major =~ ^[0-9]+$ ]] || die "could not determine the macOS version"
((macos_major >= 15)) || die "the pinned arm64_sequoia bottles require macOS 15 or newer"
[[ -n $source_qemu ]] || die "--source-qemu is required"
[[ $source_qemu == /* ]] || die "--source-qemu must be an absolute path"
[[ -f $source_qemu && ! -L $source_qemu && -x $source_qemu ]] || \
  die "--source-qemu must name a regular executable: $source_qemu"
[[ -f $entitlements && ! -L $entitlements ]] || \
  die "missing QEMU signing entitlements: $entitlements"
[[ -x $dependency_bundler && ! -L $dependency_bundler ]] || \
  die "missing dependency relocation tool: $dependency_bundler"
[[ -x $compatibility_verifier && ! -L $compatibility_verifier ]] || \
  die "missing macOS compatibility verifier: $compatibility_verifier"
[[ -f $runtime_manifest && ! -L $runtime_manifest ]] || \
  die "missing runtime file manifest: $runtime_manifest"
if [[ -n $archive_cache ]]; then
  [[ $archive_cache == /* ]] || die "--archive-dir must be an absolute path"
  [[ -d $archive_cache && ! -L $archive_cache ]] || \
    die "--archive-dir must name a regular directory: $archive_cache"
fi

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
extract_dir="$work_dir/extracted"
staged_runtime="$work_dir/runtime"
mkdir -p "$archive_dir" "$extract_dir" "$staged_runtime/bin" "$staged_runtime/lib"

download_and_verify() {
  local label=$1
  local url=$2
  local expected_sha=$3
  local output=$4
  local actual_sha

  log "Downloading $label"
  curl --fail --location --silent --show-error \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --retry 3 --connect-timeout 20 \
    --output "$output" "$url"
  actual_sha=$(pinned_bottle_sha256 "$output") || die "could not hash $label"
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
  actual_sha=$(pinned_bottle_sha256 "$cached") || die "could not hash cached $label"
  [[ $actual_sha == "$expected_sha" ]] || \
    die "$label cache checksum mismatch: expected $expected_sha, got $actual_sha"
  log "Using cached $label"
  install -m 0644 "$cached" "$output"
}

virgl_archive="$archive_dir/$virgl_archive_name"
angle_archive="$archive_dir/$angle_archive_name"
epoxy_archive="$archive_dir/$epoxy_archive_name"
obtain_and_verify "virglrenderer $virgl_version" "$virgl_url" "$virgl_sha256" "$virgl_archive"
obtain_and_verify "ANGLE $angle_version" "$angle_url" "$angle_sha256" "$angle_archive"
obtain_and_verify "libepoxy $epoxy_version" "$epoxy_url" "$epoxy_sha256" "$epoxy_archive"

pinned_bottle_validate_archive \
  "virglrenderer $virgl_version" "$virgl_archive" "virglrenderer/$virgl_version"
pinned_bottle_validate_archive \
  "ANGLE $angle_version" "$angle_archive" "angle/$angle_version"
pinned_bottle_validate_archive \
  "libepoxy $epoxy_version" "$epoxy_archive" "libepoxy/$epoxy_version"

while IFS=$'\t' read -r formula version archive_name archive_root archive_sha; do
  archive="$archive_dir/$archive_name"
  pinned_bottle_obtain \
    "$formula" "$formula $version" "$archive_sha" "$archive" "$archive_cache"
  pinned_bottle_validate_archive "$formula $version" "$archive" "$archive_root"
done < <(pinned_core_bottle_manifest)

virgl_member="virglrenderer/$virgl_version/lib/libvirglrenderer.1.dylib"
epoxy_member="libepoxy/$epoxy_version/lib/libepoxy.0.dylib"
egl_member="angle/$angle_version/lib/libEGL.dylib"
gles_member="angle/$angle_version/lib/libGLESv2.dylib"
pinned_bottle_require_regular_member \
  "virglrenderer $virgl_version" "$virgl_archive" "$virgl_member"
pinned_bottle_require_regular_member \
  "libepoxy $epoxy_version" "$epoxy_archive" "$epoxy_member"
pinned_bottle_require_regular_member "ANGLE $angle_version" "$angle_archive" "$egl_member"
pinned_bottle_require_regular_member "ANGLE $angle_version" "$angle_archive" "$gles_member"

tar -xzf "$virgl_archive" -C "$extract_dir" "$virgl_member"
tar -xzf "$epoxy_archive" -C "$extract_dir" "$epoxy_member"
tar -xzf "$angle_archive" -C "$extract_dir" "$egl_member" "$gles_member"

install -m 0755 "$source_qemu" "$staged_runtime/bin/qemu-system-aarch64"
install -m 0755 "$extract_dir/$virgl_member" \
  "$staged_runtime/lib/libvirglrenderer.1.dylib"
install -m 0755 "$extract_dir/$epoxy_member" "$staged_runtime/lib/libepoxy.0.dylib"
install -m 0755 "$extract_dir/$egl_member" "$staged_runtime/lib/libEGL.dylib"
install -m 0755 "$extract_dir/$gles_member" "$staged_runtime/lib/libGLESv2.dylib"

while IFS=$'\t' read -r archive_name member destination; do
  archive="$archive_dir/$archive_name"
  pinned_bottle_require_regular_member "$archive_name" "$archive" "$member"
  tar -xzf "$archive" -C "$extract_dir" "$member"
  install -m 0755 "$extract_dir/$member" "$staged_runtime/$destination"
done < <(pinned_runtime_member_manifest)

runtime_files=()
runtime_file_count=0
while IFS= read -r relative || [[ -n $relative ]]; do
  [[ $relative =~ ^(bin|lib)/[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || \
    die "runtime file manifest contains an unsafe path: ${relative:-<empty>}"
  for ((runtime_file_index = 0; runtime_file_index < runtime_file_count; runtime_file_index++)); do
    [[ ${runtime_files[$runtime_file_index]} != "$relative" ]] || \
      die "runtime file manifest contains a duplicate path: $relative"
  done
  runtime_files[$runtime_file_count]=$relative
  ((runtime_file_count += 1))
done < "$runtime_manifest"
((runtime_file_count > 0)) || die "runtime file manifest is empty"

runtime_images=()
for relative in "${runtime_files[@]}"; do
  image="$staged_runtime/$relative"
  [[ -f $image && ! -L $image ]] || die "staged runtime is missing $relative"
  description=$(file -b "$image") || die "could not inspect staged runtime file: $relative"
  [[ $description == *Mach-O* && $description == *arm64* ]] || \
    die "expected an arm64 Mach-O image, got '$description' for $relative"
  xattr -c "$image"
  codesign --remove-signature "$image" >/dev/null 2>&1 || true
  runtime_images+=("$image")
done

log "Relocating the complete pinned runtime closure"
"$dependency_bundler" "$staged_runtime"

log "Ad-hoc signing the relocated runtime"
for library in "$staged_runtime/lib"/*.dylib; do
  codesign --force --sign - "$library"
done
codesign --force --sign - "$staged_runtime/bin/zstd"
codesign --force --sign - --entitlements "$entitlements" \
  "$staged_runtime/bin/qemu-system-aarch64"

is_expected_runtime_file() {
  local candidate=$1
  local expected
  for expected in "${runtime_files[@]}"; do
    [[ $candidate == "$expected" ]] && return 0
  done
  return 1
}

qemu_minimum_versions() {
  otool -l "$1" | awk '
    $1 == "cmd" {
      expected = ""
      if ($2 == "LC_BUILD_VERSION") {
        expected = "minos"
      } else if ($2 == "LC_VERSION_MIN_MACOSX") {
        expected = "version"
      }
      next
    }
    expected != "" && $1 == expected {
      print $2
      expected = ""
    }
  '
}

verify_runtime_tree() {
  local root=$1
  local qemu="$root/bin/qemu-system-aarch64"
  local zstd="$root/bin/zstd"
  local path
  local relative
  local actual_count=0
  local description
  local entitlements_output
  local minimum_versions
  local minimum_version
  local version_output
  local zstd_version
  local accel_help
  local machine_help
  local cpu_help
  local display_help
  local device_help
  local netdev_help
  local audio_help
  local marker

  while IFS= read -r -d '' path; do
    relative=${path#"$root"/}
    if [[ -L $path ]]; then
      die "runtime contains an unsafe symlink: $relative"
    elif [[ -d $path ]]; then
      [[ $relative == bin || $relative == lib ]] || \
        die "runtime contains an unexpected directory: $relative"
    elif [[ -f $path ]]; then
      is_expected_runtime_file "$relative" || \
        die "runtime contains an unexpected file: $relative"
      ((actual_count += 1))
    else
      die "runtime contains an unsafe entry: $relative"
    fi
  done < <(find "$root" -mindepth 1 -print0)
  ((actual_count == ${#runtime_files[@]})) || \
    die "runtime file set is incomplete"

  for relative in "${runtime_files[@]}"; do
    path="$root/$relative"
    [[ -f $path && ! -L $path ]] || die "published runtime is missing $relative"
    description=$(file -b "$path") || die "could not inspect $relative"
    [[ $description == *Mach-O* && $description == *arm64* ]] || \
      die "published runtime contains a non-arm64 image: $relative"
    codesign --verify --strict --verbose=2 "$path" >/dev/null 2>&1 || \
      die "invalid code signature: $relative"
  done
  [[ -x $qemu && -x $zstd ]] || die "runtime executables are not executable"

  "$dependency_bundler" --verify-only "$root"
  "$compatibility_verifier" "$root"

  minimum_versions=$(qemu_minimum_versions "$qemu") || \
    die "could not inspect QEMU's minimum macOS version"
  [[ -n $minimum_versions ]] || die "QEMU has no minimum macOS version"
  while IFS= read -r minimum_version; do
    [[ $minimum_version == 15.0 ]] || \
      die "QEMU has unexpected minimum macOS version: $minimum_version"
  done <<<"$minimum_versions"

  entitlements_output=$(codesign -d --entitlements - "$qemu" 2>&1) || \
    die "could not inspect QEMU's code-signing entitlements"
  [[ $entitlements_output == *com.apple.security.hypervisor* ]] || \
    die "QEMU is missing the com.apple.security.hypervisor entitlement"

  version_output=$(
    unset DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_FRAMEWORK_PATH
    "$qemu" --version 2>&1
  ) || die "relocated QEMU cannot load its pinned dependencies: $version_output"
  [[ $version_output == QEMU\ emulator\ version\ 10.2.50* ]] || \
    die "relocated QEMU returned an unexpected version string: $version_output"

  zstd_version=$(
    unset DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_FRAMEWORK_PATH
    "$zstd" --version 2>&1
  ) || die "relocated zstd cannot load its pinned dependencies: $zstd_version"
  [[ $zstd_version == *'v1.5.7'* ]] || \
    die "relocated zstd returned an unexpected version string: $zstd_version"

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
  printf '%s\n' "$display_help" | awk '$1 == "cocoa" { found = 1 } END { exit !found }' || \
    die "relocated QEMU is missing its Cocoa display backend"

  device_help=$("$qemu" -device help 2>&1) || \
    die "relocated QEMU could not enumerate devices: $device_help"
  for device in \
    'name "virtio-gpu-gl-pci"' \
    'name "intel-hda"' \
    'name "hda-micro"' \
    'name "virtio-net-pci"' \
    'name "virtio-9p-pci"'; do
    [[ $device_help == *"$device"* ]] || die "relocated QEMU is missing device $device"
  done

  netdev_help=$("$qemu" -machine virt -netdev help 2>&1) || \
    die "relocated QEMU could not enumerate network backends: $netdev_help"
  printf '%s\n' "$netdev_help" | awk '$1 == "user" { found = 1 } END { exit !found }' || \
    die "relocated QEMU is missing the SLIRP user network backend"

  audio_help=$("$qemu" -machine virt -audiodev help 2>&1) || \
    die "relocated QEMU could not enumerate audio backends: $audio_help"
  printf '%s\n' "$audio_help" | awk '$1 == "sdl" { found = 1 } END { exit !found }' || \
    die "relocated QEMU is missing the SDL audio backend"

  for marker in \
    OMARCHY_SDL_AUDIO_CONTROL_DIRECTORY \
    OMARCHY_SDL_INPUT_DEVICE_NAME \
    OMARCHY_SDL_OUTPUT_DEVICE_NAME \
    guest_owner_uid \
    guest_owner_gid; do
    LC_ALL=C grep -aFq "$marker" "$qemu" || \
      die "relocated QEMU is missing the $marker integration hook"
  done
}

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

publish_dir=$(mktemp -d "$build_dir/.qemu-gpu-runtime.publish.XXXXXX")
ditto "$staged_runtime" "$publish_dir"
verify_runtime_tree "$publish_dir"

if [[ -e $runtime_dir || -L $runtime_dir ]]; then
  [[ -d $runtime_dir && ! -L $runtime_dir ]] || \
    die "refusing to replace an unsafe runtime target: $runtime_dir"
  atomic_rename swap "$publish_dir" "$runtime_dir" || \
    die "could not atomically replace $runtime_dir"
  remove_generated_dir "$publish_dir"
else
  atomic_rename exclusive "$publish_dir" "$runtime_dir" || \
    die "could not atomically publish $runtime_dir"
fi
publish_dir=

log "Prepared $runtime_dir"
log "Runtime is self-contained, targets macOS 15.0, and contains ${#runtime_files[@]} pinned Mach-O images"
