#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: guest/build.sh [options]

  --output DIR       Artifact directory (default: dist/guest)
  --work DIR         Persistent build/cache directory (default: guest/.work)
  --spec FILE        Architecture build spec (default: guest/spec.json)
  --source DIR       Use an existing clean pinned Omarchy checkout
  --keep-rootfs      Keep the staged package root after a successful build

Run as root on the architecture selected by the spec, or use the matching
container wrapper.
USAGE
}

fail() {
  echo "guest-build: $*" >&2
  exit 1
}

guest_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$guest_dir/.." && pwd)
output="$repo_dir/dist/guest"
work="$guest_dir/.work"
source_dir=""
spec="$guest_dir/spec.json"
keep_rootfs=0

while (($#)); do
  case "$1" in
    --output)
      output=${2:-}
      shift 2
      ;;
    --work)
      work=${2:-}
      shift 2
      ;;
    --source)
      source_dir=${2:-}
      shift 2
      ;;
    --spec)
      spec=${2:-}
      shift 2
      ;;
    --keep-rootfs)
      keep_rootfs=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

[[ $(uname -s) == "Linux" ]] || fail "full image builds require Linux"
[[ -f $spec ]] || fail "spec not found: $spec"
spec=$(cd "$(dirname "$spec")" && pwd)/$(basename "$spec")
architecture=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["image"]["architecture"])' "$spec")
packages_file=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["inputs"]["packages"])' "$spec")
package_lock_file=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["inputs"]["packageLock"])' "$spec")
packages_file="$guest_dir/$packages_file"
package_lock_file="$guest_dir/$package_lock_file"
[[ $architecture == "aarch64" ]] || fail "native guest architecture must be aarch64"
[[ $(uname -m) == "$architecture" ]] || fail "guest packages for $architecture must be assembled on $architecture"
[[ -f $packages_file ]] || fail "package list not found: $packages_file"
[[ -f $package_lock_file ]] || fail "package lock not found: $package_lock_file"
(( EUID == 0 )) || fail "run as root (pacstrap and arch-chroot require it)"
for command in pacstrap arch-chroot curl git gzip python3 mke2fs repo-add sha256sum zstd; do
  command -v "$command" >/dev/null || fail "$command is required; use the supplied Arch builder container"
done

output=$(mkdir -p "$output" && cd "$output" && pwd)
work=$(mkdir -p "$work" && cd "$work" && pwd)
if [[ -z $source_dir ]]; then
  source_dir="$work/omarchy-source"
  "$guest_dir/scripts/fetch-source.sh" --destination "$source_dir" --spec "$spec"
else
  source_dir=$(cd "$source_dir" && pwd)
fi

root=$(mktemp -d "$work/rootfs.XXXXXX")
resolution_db=$(mktemp -d "$work/pacman-db.XXXXXX")
pinned_repo=""
chmod 0755 "$resolution_db"
cleanup() {
  if (( keep_rootfs )); then
    echo "Staged rootfs retained at $root"
  else
    rm -rf "$root"
  fi
  rm -rf "$resolution_db"
  if [[ -n $pinned_repo ]]; then
    rm -rf "$pinned_repo"
  fi
}
trap cleanup EXIT

packages=()
while IFS= read -r package; do
  [[ -n $package && $package != \#* ]] || continue
  packages+=("$package")
done <"$packages_file"

echo "Installing ${#packages[@]} trimmed guest packages"
pacman_input=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["inputs"].get("pacmanConfig", ""))' "$spec")
if [[ -n $pacman_input ]]; then
  upstream_pacman_config="$guest_dir/$pacman_input"
else
  upstream_pacman_config="$source_dir/default/pacman/pacman-stable.conf"
fi
[[ -f $upstream_pacman_config ]] || fail "pacman configuration not found: $upstream_pacman_config"
package_cache="$work/pacman-cache"
pacman_config="$work/pacman-builder.conf"
[[ $package_cache != *$'\n'* ]] || fail "work path cannot contain a newline"
install -d -m 0755 "$package_cache"

# Omarchy's repository may contain binaries compiled against Qt's private ABI.
# Arch is rolling, so keep the small reviewed ABI set on the exact signed
# versions recorded in the transaction lock even after upstream mirrors move.
pinned_records_text=$(python3 -c '
import json, sys
spec = json.load(open(sys.argv[1]))
lock = json.load(open(sys.argv[2]))["packages"]
pins = spec["inputs"].get("packageCachePins", [])
if pins != sorted(set(pins)):
    raise SystemExit("packageCachePins must be sorted and unique")
for name in pins:
    if name not in lock:
        raise SystemExit(f"package cache pin is absent from the transaction lock: {name}")
    print(f"{name}|{lock[name]}")
' "$spec" "$package_lock_file") || fail "could not read reviewed cache pins"
pinned_records=()
if [[ -n $pinned_records_text ]]; then
  mapfile -t pinned_records <<<"$pinned_records_text"
fi
if ((${#pinned_records[@]})); then
  pinned_repo=$(mktemp -d "$work/pinned-repo.XXXXXX")
  for record in "${pinned_records[@]}"; do
    IFS='|' read -r package version <<<"$record"
    [[ -n $package && -n $version && $package != *'|'* && $version != *'|'* ]] \
      || fail "invalid package cache pin: $record"
    shopt -s nullglob
    matches=("$package_cache/$package-$version-"*.pkg.tar.zst)
    shopt -u nullglob
    ((${#matches[@]} == 1)) \
      || fail "expected exactly one cached archive for $package=$version, found ${#matches[@]}"
    archive=${matches[0]}
    [[ -f $archive.sig ]] || fail "cached package signature not found: $archive.sig"
    ln "$archive" "$archive.sig" "$pinned_repo/"
  done
  repo-add "$pinned_repo/try-omarchy-pinned-cache.db.tar.gz" \
    "$pinned_repo/"*.pkg.tar.zst >/dev/null
fi

# Preserve the pinned repository configuration exactly, adding only builder
# options. The generated file is temporary build input; configure-rootfs later
# installs Omarchy's unmodified pacman configuration into the guest.
options_sections=0
pinned_repo_inserted=0
while IFS= read -r line || [[ -n $line ]]; do
  if [[ -n $pinned_repo && $line =~ ^\[[^]]+\]$ && $line != "[options]" && $pinned_repo_inserted == 0 ]]; then
    printf '[try-omarchy-pinned-cache]\n'
    printf 'SigLevel = Required DatabaseOptional\n'
    printf 'Server = file://%s\n\n' "$pinned_repo"
    pinned_repo_inserted=1
  fi
  printf '%s\n' "$line"
  if [[ $line == "[options]" ]]; then
    printf 'CacheDir = %s\n' "$package_cache"
    if [[ ${OMARCHY_PACMAN_DISABLE_SANDBOX:-0} == "1" ]]; then
      printf 'DisableSandbox\n'
    fi
    options_sections=$((options_sections + 1))
  fi
done <"$upstream_pacman_config" >"$pacman_config"
(( options_sections == 1 )) || fail "pinned pacman configuration must contain one [options] section"
(( ${#pinned_records[@]} == 0 || pinned_repo_inserted == 1 )) \
  || fail "pinned pacman configuration does not contain a repository section"

# Resolve against an empty target database and require the reviewed transitive
# version lock before any multi-gigabyte package transaction begins.
pacman -Syy --noconfirm --config "$pacman_config" \
  --dbpath "$resolution_db" --logfile "$resolution_db/pacman.log"
python3 "$guest_dir/scripts/resolve-package-lock.py" \
  --config "$pacman_config" \
  --dbpath "$resolution_db" \
  --packages "$packages_file" \
  --output "$resolution_db/resolved.json" \
  --expect "$package_lock_file"

# pacstrap reads configured CacheDir paths for host-cache mode only with -P.
# The copied builder config is replaced by configure-rootfs below. Archives
# remain under $work across failed staging roots and are still signature-checked.
pacstrap -c -P -C "$pacman_config" -K -M "$root" "${packages[@]}"

# Fail before image packing if the repository's prebuilt Quickshell and the
# reviewed Qt private ABI set cannot actually load together.
arch-chroot "$root" /usr/bin/quickshell --version >/dev/null

# pacstrap creates a target-side mirror of every configured cache directory,
# even in host-cache mode. It must be empty; remove only that staged mirror and
# any empty parents it introduced, never the persistent cache itself.
staged_package_cache="$root$package_cache"
[[ $staged_package_cache == "$root/"* ]] || fail "unsafe staged package cache path"
rmdir "$staged_package_cache" || fail "target-side package cache mirror is unexpectedly non-empty"
staged_parent=$(dirname "$staged_package_cache")
while [[ $staged_parent != "$root" ]]; do
  rmdir "$staged_parent" 2>/dev/null || break
  staged_parent=$(dirname "$staged_parent")
done

python3 "$guest_dir/scripts/verify-screensaver-override.py" \
  --source "$source_dir/bin/omarchy-screensaver" \
  --override "$guest_dir/native-overlay/usr/bin/omarchy-screensaver"
"$guest_dir/scripts/materialize-omarchy.sh" --root "$root" --source "$source_dir" --spec "$spec"
python3 "$guest_dir/scripts/apply-omarchy-backports.py" --root "$root" --spec "$spec"
"$guest_dir/scripts/configure-rootfs.sh" --root "$root" --spec "$spec"
"$guest_dir/scripts/register-omarchy-runtime.sh" \
  --root "$root" \
  --work "$work" \
  --spec "$spec" \
  --pacman-config "$pacman_config"
"$guest_dir/scripts/register-pinned-mise.sh" \
  --root "$root" \
  --work "$work" \
  --spec "$spec" \
  --pacman-config "$pacman_config"
"$guest_dir/scripts/register-pinned-yay.sh" \
  --root "$root" \
  --work "$work" \
  --spec "$spec" \
  --pacman-config "$pacman_config"
"$guest_dir/scripts/register-pinned-ttfx.sh" \
  --root "$root" \
  --work "$work" \
  --spec "$spec" \
  --pacman-config "$pacman_config"
"$guest_dir/scripts/register-local-repository.sh" --root "$root" --spec "$spec"
arch-chroot "$root" /usr/local/lib/try-omarchy/finalize-rootfs
arch-chroot "$root" pacman -Q | LC_ALL=C sort >"$root/usr/share/try-omarchy/packages.lock.txt"

# arch-chroot bind-mounts the host resolver file at this path. Replace it only
# after every chroot invocation has returned and the temporary mount is gone.
ln -sfn ../run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"

"$guest_dir/scripts/pack-image.sh" --root "$root" --output "$output" --spec "$spec"
echo "Guest build complete: $output/guest-manifest.json"
