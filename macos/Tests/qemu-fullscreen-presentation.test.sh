#!/bin/bash

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd -P)
macos_dir=$(cd "$test_dir/.." && pwd -P)

fail() {
  printf 'qemu-fullscreen-presentation.test: %s\n' "$*" >&2
  exit 1
}

patch_path="$macos_dir/patches/qemu-cocoa-fullscreen-autohide.patch"
build_script="$macos_dir/build-qemu-gpu-runtime.sh"

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

[[ -f $patch_path && ! -L $patch_path ]] || \
  fail "missing regular Cocoa fullscreen patch: $patch_path"
[[ -f $build_script && ! -L $build_script ]] || \
  fail "missing regular QEMU build script: $build_script"

actual_sha=$(hash_file "$patch_path")
script_sha=$(awk -F= '$1 == "fullscreen_autohide_patch_sha256" { print $2 }' "$build_script")
[[ $script_sha == "$actual_sha" ]] || \
  fail "build script checksum for the Cocoa fullscreen patch is stale"

grep -Fq 'fullscreen_autohide_patch="$native_dir/patches/qemu-cocoa-fullscreen-autohide.patch"' \
  "$build_script" || fail "build script does not reference the Cocoa fullscreen patch"
grep -Fq 'verify_file_sha "Try Omarchy Cocoa fullscreen autohide patch"' \
  "$build_script" || fail "build script does not verify the Cocoa fullscreen patch"
grep -Fq '"$fullscreen_autohide_patch" "$fullscreen_autohide_patch_sha256"' \
  "$build_script" || fail "build script does not verify the pinned fullscreen patch checksum"
grep -Fq 'patch -d "$source_dir" -p1 -f -i "$fullscreen_autohide_patch"' \
  "$build_script" || fail "build script does not apply the Cocoa fullscreen patch"

grep -Fq 'willUseFullScreenPresentationOptions' "$patch_path" || \
  fail "patch does not target the fullscreen presentation delegate"
grep -Fq '+           NSApplicationPresentationHideDock |' "$patch_path" || \
  fail "fullscreen patch no longer keeps the dock hidden"
grep -Fq '+           NSApplicationPresentationAutoHideMenuBar;' "$patch_path" || \
  fail "fullscreen patch does not enable the auto-hidden macOS menu bar"
if grep -Eq '^\+.*NSApplicationPresentationHideMenuBar' "$patch_path"; then
  fail "the presentation delegate still requests a permanently hidden menu bar"
fi
