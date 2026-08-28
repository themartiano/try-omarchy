#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: macos/bundle-macho-dependencies.sh [--verify-only] RUNTIME_DIR" >&2
  exit 64
}

fail() {
  echo "bundle-macho-dependencies: $*" >&2
  exit 1
}

verify_only=0
if [[ ${1:-} == --verify-only ]]; then
  verify_only=1
  shift
fi
[[ $# == 1 ]] || usage
runtime_dir=$1
[[ $runtime_dir == /* && -d $runtime_dir && ! -L $runtime_dir ]] || \
  fail "runtime directory must be an absolute direct directory"
runtime_dir=$(cd "$runtime_dir" && pwd -P)
bin_dir="$runtime_dir/bin"
lib_dir="$runtime_dir/lib"
[[ -d $bin_dir && ! -L $bin_dir ]] || fail "runtime bin directory is missing or unsafe"
[[ -d $lib_dir && ! -L $lib_dir ]] || fail "runtime lib directory is missing or unsafe"

for tool in awk file find grep install_name_tool otool sed; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
done

macho_dependencies() {
  otool -L "$1" | sed -n '2,$p' | \
    sed -E 's/^[[:space:]]+//; s/ \(compatibility version.*$//'
}

macho_install_name() {
  otool -D "$1" 2>/dev/null | sed -n '2p' || true
}

macho_rpaths() {
  otool -l "$1" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" { print $2; in_rpath = 0 }
  '
}

images=()
while IFS= read -r -d '' candidate; do
  [[ -f $candidate && ! -L $candidate ]] || \
    fail "runtime contains an unsafe file entry: $candidate"
  description=$(file -b "$candidate") || fail "could not inspect file type: $candidate"
  [[ $description == *Mach-O* ]] || continue
  images+=("$candidate")
done < <(find "$bin_dir" "$lib_dir" -maxdepth 1 -type f -print0)
((${#images[@]} > 0)) || fail "runtime has no Mach-O images"

canonical_dependency() {
  local image=$1
  local dependency_name=$2
  if [[ $image == "$bin_dir"/* ]]; then
    printf '@executable_path/../lib/%s\n' "$dependency_name"
  else
    printf '@loader_path/%s\n' "$dependency_name"
  fi
}

canonical_rpath() {
  if [[ $1 == "$bin_dir"/* ]]; then
    printf '%s\n' '@executable_path/../lib'
  else
    printf '%s\n' '@loader_path'
  fi
}

if (( ! verify_only )); then
  for image in "${images[@]}"; do
    if [[ $image == "$lib_dir"/* ]]; then
      expected_id="@rpath/${image##*/}"
      current_id=$(macho_install_name "$image")
      [[ -n $current_id ]] || fail "dylib has no install name: $image"
      [[ $current_id == "$expected_id" ]] || \
        install_name_tool -id "$expected_id" "$image"
    fi

    install_name=$(macho_install_name "$image")
    dependencies=$(macho_dependencies "$image") || \
      fail "could not inspect Mach-O dependencies: $image"
    while IFS= read -r dependency; do
      [[ -n $dependency ]] || continue
      [[ -n $install_name && $dependency == "$install_name" ]] && continue
      case "$dependency" in
        /System/Library/*|/usr/lib/*) continue ;;
      esac

      dependency_name=${dependency##*/}
      [[ -n $dependency_name ]] || \
        fail "invalid dependency in $(basename "$image"): $dependency"
      local_library="$lib_dir/$dependency_name"
      [[ -f $local_library && ! -L $local_library ]] || \
        fail "$(basename "$image") needs an unstaged library: $dependency"
      replacement=$(canonical_dependency "$image" "$dependency_name")
      [[ $dependency == "$replacement" ]] || \
        install_name_tool -change "$dependency" "$replacement" "$image"
    done <<<"$dependencies"

    expected_rpath=$(canonical_rpath "$image")
    found_expected=0
    rpaths=$(macho_rpaths "$image") || fail "could not inspect Mach-O rpaths: $image"
    while IFS= read -r rpath; do
      [[ -n $rpath ]] || continue
      if [[ $rpath == "$expected_rpath" ]]; then
        ((found_expected += 1))
      else
        install_name_tool -delete_rpath "$rpath" "$image"
      fi
    done <<<"$rpaths"
    ((found_expected <= 1)) || fail "duplicate isolated rpath in $(basename "$image")"
    ((found_expected == 1)) || install_name_tool -add_rpath "$expected_rpath" "$image"
  done
fi

for image in "${images[@]}"; do
  if [[ $image == "$lib_dir"/* ]]; then
    expected_id="@rpath/${image##*/}"
    [[ $(macho_install_name "$image") == "$expected_id" ]] || \
      fail "unexpected dylib install name in $(basename "$image")"
  fi

  install_name=$(macho_install_name "$image")
  dependencies=$(macho_dependencies "$image") || \
    fail "could not inspect Mach-O dependencies: $image"
  while IFS= read -r dependency; do
    [[ -n $dependency ]] || continue
    [[ -n $install_name && $dependency == "$install_name" ]] && continue
    case "$dependency" in
      /System/Library/*|/usr/lib/*) continue ;;
    esac

    dependency_name=${dependency##*/}
    expected_dependency=$(canonical_dependency "$image" "$dependency_name")
    [[ $dependency == "$expected_dependency" ]] || \
      fail "external dependency remains in $(basename "$image"): $dependency"
    [[ -f $lib_dir/$dependency_name && ! -L $lib_dir/$dependency_name ]] || \
      fail "relocated dependency is missing for $(basename "$image"): $dependency"
  done <<<"$dependencies"

  expected_rpath=$(canonical_rpath "$image")
  rpaths=$(macho_rpaths "$image") || fail "could not inspect Mach-O rpaths: $image"
  [[ $rpaths == "$expected_rpath" ]] || \
    fail "$(basename "$image") has unexpected runtime search paths: ${rpaths:-<none>}"
done

# sdl2-compat resolves SDL3 with dlopen, so it is intentionally absent from
# otool output. Keep this explicit assertion alongside the generic closure.
sdl2="$lib_dir/libSDL2-2.0.0.dylib"
if [[ -f $sdl2 && ! -L $sdl2 ]] && \
  LC_ALL=C grep -aFq '@loader_path/libSDL3.dylib' "$sdl2"; then
  [[ -f $lib_dir/libSDL3.dylib && ! -L $lib_dir/libSDL3.dylib ]] || \
    fail "sdl2-compat needs the unstaged runtime library libSDL3.dylib"
fi

if (( verify_only )); then
  echo "[native] Verified ${#images[@]} self-contained runtime Mach-O images"
else
  echo "[native] Relocated ${#images[@]} self-contained runtime Mach-O images"
fi
