#!/bin/bash

set -euo pipefail

minimum_macos_version=15.0

usage() {
  echo "Usage: macos/verify-macos-compatibility.sh ROOT" >&2
  exit 64
}

fail() {
  echo "macos-compatibility: $*" >&2
  exit 1
}

[[ $# == 1 ]] || usage
compatibility_root=$1
[[ $compatibility_root == /* ]] || fail "ROOT must be an absolute path"
[[ -d $compatibility_root && ! -L $compatibility_root ]] || \
  fail "ROOT must name a regular directory: $compatibility_root"
compatibility_root=$(cd "$compatibility_root" && pwd -P)

for tool in awk file find grep otool xcrun; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
done

version_is_newer() {
  local candidate=$1
  local supported=$2
  awk -v candidate="$candidate" -v supported="$supported" '
    BEGIN {
      candidate_count = split(candidate, candidate_parts, ".")
      supported_count = split(supported, supported_parts, ".")
      count = candidate_count > supported_count ? candidate_count : supported_count
      for (part_index = 1; part_index <= count; part_index++) {
        candidate_part = part_index <= candidate_count ? candidate_parts[part_index] + 0 : 0
        supported_part = part_index <= supported_count ? supported_parts[part_index] + 0 : 0
        if (candidate_part > supported_part) {
          exit 0
        }
        if (candidate_part < supported_part) {
          exit 1
        }
      }
      exit 1
    }
  '
}

minimum_versions() {
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

image_count=0
while IFS= read -r -d '' image; do
  description=$(file -b "$image") || fail "could not inspect file type: $image"
  [[ $description == *Mach-O* ]] || continue
  ((image_count += 1))

  versions=$(minimum_versions "$image") || \
    fail "could not inspect minimum macOS versions: $image"
  [[ -n $versions ]] || fail "Mach-O image has no minimum macOS version: $image"
  while IFS= read -r version; do
    [[ $version =~ ^[0-9]+([.][0-9]+)*$ ]] || \
      fail "invalid minimum macOS version '$version' in $image"
    if version_is_newer "$version" "$minimum_macos_version"; then
      fail "$image requires macOS $version; the release minimum is $minimum_macos_version"
    fi
  done <<<"$versions"

  strong_imports=$(xcrun nm -u -W -j --add-dyldinfo -arch all "$image" 2>/dev/null) || \
    fail "could not inspect strong imports: $image"
  if grep -Fxq '_strchrnul' <<<"$strong_imports"; then
    fail "$image strongly imports _strchrnul, which is unavailable before macOS 15.4"
  fi
done < <(find "$compatibility_root" -type f -print0)

((image_count > 0)) || fail "ROOT contains no Mach-O images: $compatibility_root"
echo "[compatibility] Verified $image_count Mach-O images for macOS $minimum_macos_version"
