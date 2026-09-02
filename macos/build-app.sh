#!/bin/bash

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: macos/build-app.sh [--open] [--dmg] [--guest-dir DIR]
                                  [--sign-identity IDENTITY]
                                  [--notarize-profile PROFILE]

Build a self-contained Apple Silicon app. Developer ID signing is used when
--sign-identity is supplied; otherwise the local build is ad-hoc signed.
--notarize-profile implies --dmg and names a notarytool keychain profile.
EOF
  exit 64
}

open_app=0
build_dmg=0
guest_dir=
sign_identity=${OMARCHY_CODESIGN_IDENTITY:--}
notarize_profile=
while (($#)); do
  case "$1" in
    --open) open_app=1; shift ;;
    --dmg) build_dmg=1; shift ;;
    --guest-dir)
      (($# >= 2)) || usage
      guest_dir=$2
      shift 2
      ;;
    --sign-identity)
      (($# >= 2)) || usage
      sign_identity=$2
      shift 2
      ;;
    --notarize-profile)
      (($# >= 2)) || usage
      notarize_profile=$2
      build_dmg=1
      shift 2
      ;;
    *) usage ;;
  esac
done

macos_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$macos_dir/.." && pwd -P)
helper="$macos_dir/.build/release/omarchy-vm-helper"
app="$repo_dir/dist/Try Omarchy.app"
contents="$app/Contents"
bundled_qemu="$contents/Resources/runtime/bin/Try Omarchy"
module_cache="$macos_dir/.build/module-cache"
runtime_source="$macos_dir/.build/qemu-gpu-runtime"
guest_dir=${guest_dir:-"$repo_dir/dist/guest"}
dependency_bundler="$macos_dir/bundle-macho-dependencies.sh"
compatibility_verifier="$macos_dir/verify-macos-compatibility.sh"
package_dmg="$macos_dir/package-dmg.sh"
app_icon_source="$macos_dir/OmarchyIcon.svg"
app_icon_renderer_source="$macos_dir/render-app-icon.swift"
app_icon_packer="$macos_dir/pack-app-icon.py"
icon_renderer="$macos_dir/.build/app-icon-renderer"
iconset="$macos_dir/.build/TryOmarchy.iconset"
generated_icon="$macos_dir/.build/TryOmarchy.icns"

[[ -d $runtime_source && ! -L $runtime_source ]] || {
  echo "build-app: missing staged QEMU runtime; run build-qemu-gpu-runtime.sh first" >&2
  exit 1
}
[[ -d $guest_dir && ! -L $guest_dir ]] || {
  echo "build-app: missing factory guest directory: $guest_dir" >&2
  exit 1
}
guest_dir=$(cd "$guest_dir" && pwd -P)
[[ -x $dependency_bundler && ! -L $dependency_bundler ]] || {
  echo "build-app: dependency bundler is missing or unsafe" >&2
  exit 1
}
[[ -x $compatibility_verifier && ! -L $compatibility_verifier ]] || {
  echo "build-app: compatibility verifier is missing or unsafe" >&2
  exit 1
}
[[ -f $app_icon_source && ! -L $app_icon_source ]] || {
  echo "build-app: app icon source is missing or unsafe" >&2
  exit 1
}
[[ -f $app_icon_renderer_source && ! -L $app_icon_renderer_source ]] || {
  echo "build-app: app icon renderer is missing or unsafe" >&2
  exit 1
}
[[ -f $app_icon_packer && ! -L $app_icon_packer ]] || {
  echo "build-app: app icon packer is missing or unsafe" >&2
  exit 1
}
for tool in python3 sips xcrun; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "build-app: $tool is required to render the app icon" >&2
    exit 1
  }
done
if [[ -n $notarize_profile && $sign_identity == - ]]; then
  echo "build-app: notarization requires --sign-identity with a Developer ID Application identity" >&2
  exit 1
fi
[[ -x $runtime_source/bin/zstd && ! -L $runtime_source/bin/zstd ]] || {
  echo "build-app: staged runtime is missing pinned zstd" >&2
  exit 1
}

mkdir -p "$repo_dir/dist"
# Keep generated development bundles out of Spotlight. The installed copy in
# /Applications is the canonical user-facing app; indexing both makes
# Command-Space offer an indistinguishable duplicate after a local build.
touch "$repo_dir/dist/.metadata_never_index"
cd "$macos_dir"
mkdir -p "$module_cache/swift" "$module_cache/clang" "$module_cache/icon"
export SWIFT_MODULECACHE_PATH="$module_cache/swift"
export CLANG_MODULE_CACHE_PATH="$module_cache/clang"
export MACOSX_DEPLOYMENT_TARGET=15.0
swift build --disable-sandbox -c release -debug-info-format none

rm -rf "$iconset"
rm -f "$generated_icon"
mkdir "$iconset"
xcrun swiftc \
  -module-cache-path "$module_cache/icon" \
  -framework AppKit \
  "$app_icon_renderer_source" \
  -o "$icon_renderer"
"$icon_renderer" "$app_icon_source" "$iconset/icon_512x512@2x.png"
while IFS=$'\t' read -r icon_name icon_pixels; do
  sips \
    -z "$icon_pixels" "$icon_pixels" \
    "$iconset/icon_512x512@2x.png" \
    --out "$iconset/$icon_name" >/dev/null
done <<'ICON_SIZES'
icon_16x16.png	16
icon_16x16@2x.png	32
icon_32x32.png	32
icon_32x32@2x.png	64
icon_128x128.png	128
icon_128x128@2x.png	256
icon_256x256.png	256
icon_256x256@2x.png	512
icon_512x512.png	512
ICON_SIZES
python3 "$app_icon_packer" "$iconset" "$generated_icon"
[[ -f $generated_icon && ! -L $generated_icon ]] || {
  echo "build-app: generated app icon is missing or unsafe" >&2
  exit 1
}

rm -rf "$app"
mkdir -p \
  "$contents/MacOS" \
  "$contents/Resources/guest" \
  "$contents/Resources/runtime/bin" \
  "$contents/Resources/scripts"
install -m 0755 "$helper" "$contents/MacOS/omarchy-vm-helper"
install -m 0644 "$macos_dir/Info.plist" "$contents/Info.plist"
install -m 0644 "$generated_icon" "$contents/Resources/TryOmarchy.icns"
ditto "$runtime_source" "$contents/Resources/runtime"
install -m 0755 "$macos_dir/run-qemu-gpu.sh" "$contents/Resources/scripts/run-qemu-gpu.sh"
install -m 0644 "$macos_dir/qemu-persistent-storage.sh" \
  "$contents/Resources/scripts/qemu-persistent-storage.sh"
install -m 0644 "$macos_dir/qemu-port-forwarding.sh" \
  "$contents/Resources/scripts/qemu-port-forwarding.sh"
for guest_resource in \
  LICENSE.omarchy \
  SHA256SUMS \
  build-spec.json \
  guest-manifest.json \
  initramfs-linux.img \
  packages.lock.txt \
  provenance.json \
  rootfs.ext4.zst \
  vmlinuz-linux; do
  [[ -f $guest_dir/$guest_resource && ! -L $guest_dir/$guest_resource ]] || {
    echo "build-app: factory guest resource is missing or unsafe: $guest_resource" >&2
    exit 1
  }
  if [[ $guest_resource == rootfs.ext4.zst ]]; then
    cp -c "$guest_dir/$guest_resource" "$contents/Resources/guest/$guest_resource"
  else
    cp "$guest_dir/$guest_resource" "$contents/Resources/guest/$guest_resource"
  fi
  chmod 0644 "$contents/Resources/guest/$guest_resource"
done

mv "$contents/Resources/runtime/bin/qemu-system-aarch64" "$bundled_qemu"
"$dependency_bundler" --verify-only "$contents/Resources/runtime"

sign_options=(--force --sign "$sign_identity")
if [[ $sign_identity != - ]]; then
  sign_options+=(--options runtime --timestamp)
fi
app_sign_options=("${sign_options[@]}" --identifier dev.tryomarchy.native)
qemu_sign_options=("${sign_options[@]}" --identifier dev.tryomarchy.native)
for library in "$contents/Resources/runtime/lib"/*.dylib; do
  codesign "${sign_options[@]}" "$library"
done
codesign "${sign_options[@]}" "$contents/Resources/runtime/bin/zstd"
codesign "${qemu_sign_options[@]}" \
  --entitlements "$macos_dir/qemu-hvf.entitlements" \
  "$bundled_qemu"
codesign "${app_sign_options[@]}" \
  --entitlements "$macos_dir/omarchy-vm-helper.entitlements" \
  "$contents/MacOS/omarchy-vm-helper"

launch_record=$(OMARCHY_QEMU_GPU_INSPECT_ONLY=1 \
  "$contents/Resources/scripts/run-qemu-gpu.sh")
IFS=$'\t' read -r bundle_identity source_disk_sha source_disk_bytes \
  compressed_disk_bytes working_disk_bytes kernel_command_line <<<"$launch_record"
launch_configuration="$contents/Resources/guest/launch.plist"
/usr/bin/plutil -create xml1 "$launch_configuration"
/usr/bin/plutil -insert bundleIdentity -string "$bundle_identity" "$launch_configuration"
/usr/bin/plutil -insert sourceDiskSHA256 -string "$source_disk_sha" "$launch_configuration"
/usr/bin/plutil -insert sourceDiskBytes -integer "$source_disk_bytes" "$launch_configuration"
/usr/bin/plutil -insert compressedDiskBytes -integer "$compressed_disk_bytes" "$launch_configuration"
/usr/bin/plutil -insert workingDiskBytes -integer "$working_disk_bytes" "$launch_configuration"
/usr/bin/plutil -insert kernelCommandLine -string "$kernel_command_line" "$launch_configuration"

codesign "${app_sign_options[@]}" \
  --entitlements "$macos_dir/omarchy-vm-helper.entitlements" \
  "$app"
codesign --verify --deep --strict --verbose=2 "$app"
"$compatibility_verifier" "$app"

echo "[native] Built $app"
if (( build_dmg )); then
  dmg="$repo_dir/dist/TryOmarchy.dmg"
  rm -f "$dmg"
  package_options=()
  if [[ $sign_identity != - ]]; then
    package_options+=(--sign-identity "$sign_identity")
  fi
  if [[ -n $notarize_profile ]]; then
    package_options+=(--notarize-profile "$notarize_profile")
  fi
  if ((${#package_options[@]})); then
    "$package_dmg" "${package_options[@]}" "$app" "$dmg"
  else
    "$package_dmg" "$app" "$dmg"
  fi
fi
if (( open_app )); then
  open "$app"
fi
