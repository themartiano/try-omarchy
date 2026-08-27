#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: register-local-repository.sh --root ROOT --spec SPEC"
}

fail() {
  echo "register-local-repository: $*" >&2
  exit 1
}

root=""
spec=""

while (($#)); do
  case "$1" in
    --root)
      root=${2:-}
      shift 2
      ;;
    --spec)
      spec=${2:-}
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
[[ -f $spec ]] || fail "spec not found: $spec"
for command in arch-chroot find gzip install python3 repo-add sort tar; do
  command -v "$command" >/dev/null || fail "$command is required"
done

mapfile -t metadata < <(python3 - "$spec" <<'PY'
import json
import pathlib
import sys

spec = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(spec["image"]["sourceDateEpoch"])
print(spec.get("guest", {}).get("profile"))
PY
)
(( ${#metadata[@]} == 2 )) || fail "could not read local repository contract"
source_date_epoch=${metadata[0]}
profile=${metadata[1]}
[[ $source_date_epoch =~ ^[0-9]+$ ]] || fail "invalid source date epoch"
[[ $profile == factory ]] || fail "native guest profile must be factory"

repo_name=try-omarchy
repo_dir="$root/usr/share/try-omarchy/repo"
[[ -d $repo_dir && ! -L $repo_dir ]] || fail "local package staging directory is missing"
shopt -s nullglob
archives=("$repo_dir"/*.pkg.tar.zst)
shopt -u nullglob
expected_archive_count=3
(( ${#archives[@]} == expected_archive_count )) ||
  fail "local repository expected $expected_archive_count package archive(s), found ${#archives[@]}"
[[ ${archives[*]} == *'/try-omarchy-runtime-'* ]] || fail "local repository is missing the Omarchy runtime"
[[ ${archives[*]} == *'/try-omarchy-mise-'* ]] || fail "factory repository is missing pinned mise"
[[ ${archives[*]} == *'/try-omarchy-yay-'* ]] || fail "factory repository is missing pinned yay"

temporary=$(mktemp -d "$root/usr/share/try-omarchy/.repo-db.XXXXXX")
cleanup() {
  rm -rf "$temporary"
}
trap cleanup EXIT

# repo-add generates correct pacman metadata, then we normalize and repack only
# its database payload so the otherwise-current archive timestamps cannot make
# the reproducible ext4 image vary between builds.
repo-add --quiet "$temporary/$repo_name.db.tar.gz" "${archives[@]}"
install -d -m 0755 "$temporary/extracted"
tar --warning=no-unknown-keyword -xf "$temporary/$repo_name.db.tar.gz" -C "$temporary/extracted"
find "$temporary/extracted" -exec touch -h -d "@$source_date_epoch" {} +
mapfile -t database_entries < <(
  find "$temporary/extracted" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort
)
(( ${#database_entries[@]} == expected_archive_count )) ||
  fail "local repository database has an unexpected entry count"
for entry in "${database_entries[@]}"; do
  [[ $entry =~ ^[A-Za-z0-9@._+-]+$ && $entry != .* ]] || fail "unsafe local repository entry: $entry"
done
tar \
  --sort=name \
  --mtime="@$source_date_epoch" \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  --format=gnu \
  -C "$temporary/extracted" \
  -cf - "${database_entries[@]}" |
  gzip -n -9 >"$repo_dir/$repo_name.db.tar.gz"
ln -sfn "$repo_name.db.tar.gz" "$repo_dir/$repo_name.db"

# Seed only the immutable local database into pacman's target-side sync cache.
# Refreshing every remote database here would make the image depend on mirror
# state newer than the reviewed transaction lock. Normal guest updates refresh
# this file:// repository and the signed remote repositories together.
install -d -m 0755 "$root/var/lib/pacman/sync"
install -m 0644 "$repo_dir/$repo_name.db.tar.gz" "$root/var/lib/pacman/sync/$repo_name.db"

if grep -q '^\[try-omarchy\]$' "$root/etc/pacman.conf"; then
  fail "local repository is already configured"
fi
cat >>"$root/etc/pacman.conf" <<'EOF'

# Immutable packages assembled from the checksummed Try Omarchy build spec.
[try-omarchy]
SigLevel = Optional TrustAll
Server = file:///usr/share/try-omarchy/repo
EOF

# This makes pacman -Qm correctly distinguish our pinned native packages from
# real AUR packages when Omarchy's updater reaches its AUR step.
foreign=$(arch-chroot "$root" pacman -Qem || true)
[[ -z $foreign ]] || fail "unrepresented foreign packages remain: $foreign"

# This is the complete runtime configuration: the reviewed ARM repositories
# plus the immutable local repository added above. The pre-refresh-pacman hook
# restores this exact file after Omarchy writes an x86_64 channel template.
install -m 0644 "$root/etc/pacman.conf" "$root/usr/share/try-omarchy/pacman.conf"
install -m 0644 "$root/etc/pacman.d/mirrorlist" "$root/usr/share/try-omarchy/mirrorlist"

echo "Registered ${#archives[@]} pinned package(s) in the immutable local repository"
