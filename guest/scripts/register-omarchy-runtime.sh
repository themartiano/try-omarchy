#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: register-omarchy-runtime.sh --root ROOT --work WORK --spec SPEC --pacman-config CONFIG

Builds a local Arch package from the already-verified staged Omarchy runtime
and registers it in the guest package database without rewriting its files.
USAGE
}

fail() {
  echo "register-omarchy-runtime: $*" >&2
  exit 1
}

root=""
work=""
spec=""
pacman_config=""

while (($#)); do
  case "$1" in
    --root)
      root=${2:-}
      shift 2
      ;;
    --work)
      work=${2:-}
      shift 2
      ;;
    --spec)
      spec=${2:-}
      shift 2
      ;;
    --pacman-config)
      pacman_config=${2:-}
      shift 2
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

[[ $root == /* && -d $root ]] || fail "--root must be an absolute staged root"
case "$root" in
  /|/bin|/boot|/etc|/home|/opt|/root|/usr|/var)
    fail "refusing unsafe root: $root"
    ;;
esac
[[ $work == /* && -d $work ]] || fail "--work must be an absolute directory"
[[ -f $spec ]] || fail "spec not found: $spec"
[[ -f $pacman_config ]] || fail "pacman config not found: $pacman_config"
[[ -d $root/usr/share/omarchy ]] || fail "materialize Omarchy before registering it"
[[ -x $root/usr/bin/omarchy-version ]] || fail "official omarchy-version command is missing"
[[ -f $root/usr/share/licenses/omarchy/LICENSE ]] || fail "Omarchy license is missing"
for command in pacman python3 tar zstd; do
  command -v "$command" >/dev/null || fail "$command is required"
done

mapfile -t metadata < <(python3 - "$spec" <<'PY'
import json
import pathlib
import sys

spec = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(spec["upstream"]["version"])
print(spec["upstream"]["release"])
print(spec["upstream"]["repository"])
print(spec["upstream"]["commit"])
print(spec["image"]["sourceDateEpoch"])
PY
)
(( ${#metadata[@]} == 5 )) || fail "could not read package identity from spec"
source_version=${metadata[0]}
release=${metadata[1]}
repository=${metadata[2]}
commit=${metadata[3]}
source_date_epoch=${metadata[4]}
[[ $source_version =~ ^[A-Za-z0-9._+]+$ ]] || fail "unsafe source version: $source_version"
[[ $release =~ ^[A-Za-z0-9._+]+$ ]] || fail "unsafe release version: $release"
[[ $commit =~ ^[0-9a-f]{40}$ ]] || fail "invalid upstream commit"
[[ $source_date_epoch =~ ^[0-9]+$ ]] || fail "invalid source date epoch"
[[ $(<"$root/usr/share/omarchy/version") == "$source_version" ]] || fail "staged version differs from spec"

package_name=try-omarchy-runtime
package_version="$release-1"
stage=$(mktemp -d "$work/omarchy-runtime-package.XXXXXX")
cleanup() {
  rm -rf "$stage"
}
trap cleanup EXIT

mkdir -p \
  "$stage/usr/bin" \
  "$stage/usr/local/bin" \
  "$stage/usr/local/lib/try-omarchy" \
  "$stage/usr/local/share/try-omarchy/vivaldi" \
  "$stage/usr/share" \
  "$stage/usr/share/licenses"
cp -a "$root/usr/share/omarchy" "$stage/usr/share/omarchy"
cp -a "$root/usr/share/licenses/omarchy" "$stage/usr/share/licenses/omarchy"

# The VM-specific screensaver override is one of the packaged Omarchy commands
# below. Keep its cursor-policy helper in the same package so reinstalling or
# verifying the runtime cannot leave that command with an unowned dependency.
cursor_restore="$root/usr/local/bin/omarchy-native-cursor-restore"
[[ -f $cursor_restore && -x $cursor_restore && ! -L $cursor_restore ]] ||
  fail "native screensaver cursor helper is missing or unsafe"
cp -a "$cursor_restore" "$stage/usr/local/bin/omarchy-native-cursor-restore"

vivaldi_installer="$root/usr/local/lib/try-omarchy/install-vivaldi-arm64"
vivaldi_key="$root/usr/local/share/try-omarchy/vivaldi/linux_signing_key.pub"
[[ -f $vivaldi_installer && -x $vivaldi_installer && ! -L $vivaldi_installer ]] ||
  fail "Vivaldi ARM64 installer is missing or unsafe"
[[ -f $vivaldi_key && ! -L $vivaldi_key ]] || fail "Vivaldi package key is missing or unsafe"
cp -a "$vivaldi_installer" "$stage/usr/local/lib/try-omarchy/install-vivaldi-arm64"
cp -a "$vivaldi_key" "$stage/usr/local/share/try-omarchy/vivaldi/linux_signing_key.pub"

shopt -s nullglob
runtime_commands=("$root/usr/bin/omarchy" "$root/usr/bin"/omarchy-*)
(( ${#runtime_commands[@]} > 1 )) || fail "staged Omarchy commands are missing"
for command in "${runtime_commands[@]}"; do
  [[ -f $command ]] || fail "unexpected Omarchy command: $command"
  cp -a "$command" "$stage/usr/bin/$(basename "$command")"
done

installed_size=$(python3 - "$stage/usr" <<'PY'
import os
import pathlib
import sys

total = 0
for path in pathlib.Path(sys.argv[1]).rglob("*"):
    if not path.is_dir():
        total += path.lstat().st_size
print(total)
PY
)

cat >"$stage/.PKGINFO" <<EOF
pkgname = $package_name
pkgbase = $package_name
pkgver = $package_version
pkgdesc = Pinned Basecamp Omarchy runtime $commit for the Try Omarchy guest
url = $repository
builddate = $source_date_epoch
packager = Try Omarchy reproducible guest builder
size = $installed_size
arch = any
license = MIT
provides = omarchy=$release
EOF

archive="$stage/$package_name-$package_version-any.pkg.tar.zst"
tar \
  --sort=name \
  --mtime="@$source_date_epoch" \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  --format=gnu \
  -C "$stage" \
  -cf - .PKGINFO usr |
  zstd --force --quiet -12 --threads=1 -o "$archive"

# The payload is already present and was verified against the pinned source.
# --dbonly registers ownership/version metadata without replacing a single
# upstream byte. The local package resolves `pacman -Q omarchy` via provides.
pacman \
  --noconfirm \
  --config "$pacman_config" \
  --root "$root" \
  --dbpath "$root/var/lib/pacman" \
  --logfile "$root/var/log/pacman.log" \
  -U --dbonly "$archive"

query=$(pacman --config "$pacman_config" --root "$root" --dbpath "$root/var/lib/pacman" -Q omarchy)
[[ $query == "$package_name $package_version" ]] || fail "provider query returned: $query"
pacman --config "$pacman_config" --root "$root" --dbpath "$root/var/lib/pacman" -Qkk "$package_name" >/dev/null ||
  fail "registered package does not own the complete staged runtime"

# Keep an immutable package copy in the guest's local sync repository. Without
# a matching sync record, pacman classifies this source-pinned runtime as an AUR
# package and the upstream updater attempts to hand it to yay.
repo_dir="$root/usr/share/try-omarchy/repo"
install -d -m 0755 "$repo_dir"
install -m 0644 "$archive" "$repo_dir/$(basename "$archive")"

echo "Registered $query for pinned source $commit"
