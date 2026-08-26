#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: macos/bundle-macho-dependencies.sh RUNTIME_DIR" >&2
  exit 64
}

fail() {
  echo "bundle-macho-dependencies: $*" >&2
  exit 1
}

[[ $# == 1 ]] || usage
runtime_dir=$1
[[ $runtime_dir == /* && -d $runtime_dir && ! -L $runtime_dir ]] || \
  fail "runtime directory must be an absolute direct directory"
bin_dir="$runtime_dir/bin"
lib_dir="$runtime_dir/lib"
[[ -d $bin_dir && ! -L $bin_dir ]] || fail "runtime bin directory is missing or unsafe"
[[ -d $lib_dir && ! -L $lib_dir ]] || fail "runtime lib directory is missing or unsafe"

for tool in brew cmp file find install install_name_tool otool; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
done
brew_prefix=$(brew --prefix)
[[ $brew_prefix == /* && -d $brew_prefix/opt ]] || fail "cannot resolve the Homebrew build prefix"

find_brew_library() {
  local name=$1
  local match=
  local candidate=
  while IFS= read -r candidate; do
    [[ -n $candidate ]] || continue
    if [[ -n $match && ! $candidate -ef $match ]]; then
      fail "multiple Homebrew libraries match $name"
    fi
    match=$candidate
  done < <(find -L "$brew_prefix/opt" -path "*/lib/$name" -type f -print 2>/dev/null)
  [[ -n $match ]] || fail "cannot resolve Homebrew library: $name"
  printf '%s\n' "$match"
}

macho_dependencies() {
  otool -L "$1" | sed -n '2,$p' | \
    sed -E 's/^[[:space:]]+//; s/ \(compatibility version.*$//'
}

queue=()
for candidate in "$bin_dir"/* "$lib_dir"/*; do
  [[ -f $candidate && ! -L $candidate ]] || continue
  description=$(file -b "$candidate")
  [[ $description == *Mach-O* ]] || continue
  queue+=("$candidate")
done
((${#queue[@]} > 0)) || fail "runtime has no Mach-O images"

seen=$'\n'
index=0
while ((index < ${#queue[@]})); do
  image=${queue[$index]}
  ((index += 1))
  case "$seen" in
    *$'\n'"$image"$'\n'*) continue ;;
  esac
  seen+="$image"$'\n'

  while IFS= read -r dependency; do
    [[ -n $dependency ]] || continue
    case "$dependency" in
      /System/Library/*|/usr/lib/*) continue ;;
    esac

    source_path=
    dependency_name=${dependency##*/}
    case "$dependency" in
      @rpath/*|@loader_path/*|@executable_path/*)
        local_path="$lib_dir/$dependency_name"
        if [[ ! -f $local_path || -L $local_path ]]; then
          source_path=$(find_brew_library "$dependency_name")
          install -m 0755 "$source_path" "$local_path"
        fi
        ;;
      /*)
        source_path=$dependency
        [[ -f $source_path ]] || \
          fail "$(basename "$image") references missing library: $dependency"
        local_path="$lib_dir/$dependency_name"
        if [[ -e $local_path || -L $local_path ]]; then
          [[ -f $local_path && ! -L $local_path ]] || \
            fail "unsafe bundled library target: $local_path"
          cmp -s "$source_path" "$local_path" || \
            fail "library basename collision for $dependency_name"
        else
          install -m 0755 "$source_path" "$local_path"
        fi
        ;;
      *) fail "unsupported Mach-O dependency in $(basename "$image"): $dependency" ;;
    esac

    if [[ $image == "$bin_dir"/* ]]; then
      replacement="@executable_path/../lib/$dependency_name"
    else
      replacement="@loader_path/$dependency_name"
    fi
    [[ $dependency == "$replacement" ]] || \
      install_name_tool -change "$dependency" "$replacement" "$image"
    queue+=("$local_path")
  done < <(macho_dependencies "$image")

  # Homebrew's sdl2 formula is now sdl2-compat, which dlopens SDL3 at runtime
  # (@loader_path/libSDL3.dylib). otool -L does not surface that dependency.
  if [[ ${image##*/} == libSDL2-2.0.0.dylib ]] && \
    LC_ALL=C grep -aFq '@loader_path/libSDL3.dylib' "$image"; then
    local_sdl3="$lib_dir/libSDL3.dylib"
    if [[ ! -f $local_sdl3 || -L $local_sdl3 ]]; then
      if [[ -f $brew_prefix/opt/sdl3/lib/libSDL3.0.dylib ]]; then
        install -m 0755 "$brew_prefix/opt/sdl3/lib/libSDL3.0.dylib" "$local_sdl3"
      else
        install -m 0755 "$(find_brew_library libSDL3.0.dylib)" "$local_sdl3"
      fi
    fi
    queue+=("$local_sdl3")
  fi
done

for library in "$lib_dir"/*.dylib; do
  [[ -f $library && ! -L $library ]] || continue
  install_name_tool -id "@rpath/${library##*/}" "$library"
done

for image in "${queue[@]}"; do
  [[ -f $image ]] || continue
  while IFS= read -r dependency; do
    case "$dependency" in
      /System/Library/*|/usr/lib/*) ;;
      @loader_path/*)
        [[ -f ${image%/*}/${dependency#@loader_path/} ]] || \
          fail "relocated dependency is missing for $(basename "$image"): $dependency"
        ;;
      @executable_path/../lib/*|@rpath/*)
        [[ -f $lib_dir/${dependency##*/} ]] || \
          fail "relocated dependency is missing for $(basename "$image"): $dependency"
        ;;
      *) fail "external dependency remains in $(basename "$image"): $dependency" ;;
    esac
  done < <(macho_dependencies "$image")
done

echo "[native] Bundled ${#queue[@]} dependency references into $runtime_dir"
