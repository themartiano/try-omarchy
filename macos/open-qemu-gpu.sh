#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: macos/open-qemu-gpu.sh [--ephemeral | --reset-storage] [GUEST_DIR]" >&2
  exit 64
}

fail() {
  echo "open-qemu-gpu: $*" >&2
  exit 1
}

wrapper_source=${BASH_SOURCE[0]}
[[ $wrapper_source == /* ]] || wrapper_source="$PWD/$wrapper_source"
[[ -f $wrapper_source && ! -L $wrapper_source ]] || {
  fail "wrapper must be invoked from its repo-local regular file"
}
macos_dir=$(cd "$(dirname "$wrapper_source")" && pwd -P) || {
  fail "cannot resolve the native macOS directory"
}
expected_wrapper="$macos_dir/open-qemu-gpu.sh"
[[ $wrapper_source -ef $expected_wrapper ]] || {
  fail "wrapper path does not match the repo-local launcher"
}

launcher_arguments=(--run-qemu)
case ${1:-} in
  --ephemeral|--reset-storage)
    launcher_arguments+=("$1")
    shift
    ;;
  --*) usage ;;
esac
(( $# <= 1 )) || usage
if (($#)); then
  [[ $1 != --* && $1 != *$'\n'* && $1 != *$'\r'* ]] || usage
  [[ -d $1 && ! -L $1 ]] || fail "ARM guest directory is missing or unsafe: $1"
  guest_dir=$(cd "$1" && pwd -P) || fail "cannot resolve ARM guest directory: $1"
  launcher_arguments+=("$guest_dir")
fi

repo_dir=$(cd "$macos_dir/.." && pwd -P)
app="$repo_dir/dist/app.noindex/Try Omarchy.app"
helper="$app/Contents/MacOS/omarchy-vm-helper"
info_plist="$app/Contents/Info.plist"
[[ -d $app && ! -L $app ]] || {
  fail "missing exact built app at $app; run make app first"
}
[[ -f $helper && ! -L $helper && -x $helper ]] || {
  fail "built app has no safe native helper executable"
}
[[ -f $info_plist && ! -L $info_plist ]] || {
  fail "built app has no safe Info.plist"
}
/usr/bin/codesign --verify --strict "$app" >/dev/null 2>&1 || {
  fail "built app does not have a valid code signature"
}
bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null) || {
  fail "built app has no bundle identifier"
}
[[ $bundle_identifier == dev.tryomarchy.native ]] || {
  fail "built app has an unexpected bundle identifier: $bundle_identifier"
}
bundle_executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist" 2>/dev/null) || {
  fail "built app has no bundle executable"
}
[[ $bundle_executable == omarchy-vm-helper ]] || {
  fail "built app has an unexpected executable: $bundle_executable"
}
microphone_usage=$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$info_plist" 2>/dev/null) || {
  fail "built app has no microphone usage description"
}
[[ -n $microphone_usage ]] || fail "built app has an empty microphone usage description"
camera_usage=$(/usr/libexec/PlistBuddy -c 'Print :NSCameraUsageDescription' "$info_plist" 2>/dev/null) || {
  fail "built app has no camera usage description"
}
[[ -n $camera_usage ]] || fail "built app has an empty camera usage description"

exec /usr/bin/open \
  -n \
  -W \
  --env OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK=1 \
  --stdin /dev/null \
  --stdout /dev/null \
  --stderr /dev/null \
  "$app" \
  --args \
  "${launcher_arguments[@]}"
