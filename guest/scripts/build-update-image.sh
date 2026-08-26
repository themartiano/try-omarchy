#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: build-update-image.sh --root ROOT --package-cache DIR --package-lock FILE --output DIR [--spec SPEC]" >&2
  exit 64
}

fail() {
  echo "build-update-image: $*" >&2
  exit 1
}

script_dir=$(cd "$(dirname "$0")" && pwd)
guest_dir=$(cd "$script_dir/.." && pwd)
root=''
package_cache=''
package_lock=''
output=''
spec="$guest_dir/spec.json"

while (($#)); do
  case "$1" in
    --root) root=${2:-}; shift 2 ;;
    --package-cache) package_cache=${2:-}; shift 2 ;;
    --package-lock) package_lock=${2:-}; shift 2 ;;
    --output) output=${2:-}; shift 2 ;;
    --spec) spec=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done

[[ $root == /* && -d $root ]] || usage
[[ $package_cache == /* && -d $package_cache ]] || usage
[[ $package_lock == /* && -f $package_lock ]] || usage
[[ $output == /* ]] || usage
[[ -f $spec ]] || fail "spec not found: $spec"
for command in bsdtar e2fsck gzip mke2fs python3 repo-add sha256sum tar zstd; do
  command -v "$command" >/dev/null || fail "$command is required"
done

mkdir -p "$output"
output=$(cd "$output" && pwd)
staging=$(mktemp -d "${output%/*}/try-omarchy-update-root.XXXXXX")
repository_db=$(mktemp -d "${output%/*}/try-omarchy-update-db.XXXXXX")
cleanup() {
  rm -rf "$staging" "$repository_db"
}
trap cleanup EXIT

python3 "$script_dir/prepare-update-root.py" \
  --root "$root" \
  --package-cache "$package_cache" \
  --package-lock "$package_lock" \
  --migrations "$guest_dir/migrations" \
  --destination "$staging" \
  --spec "$spec"

shopt -s nullglob
archives=("$staging/repo/"*.pkg.tar.zst)
shopt -u nullglob
((${#archives[@]} > 0)) || fail "offline repository has no packages"
repo-add --quiet "$repository_db/try-omarchy-update.db.tar.gz" "${archives[@]}"
mkdir "$repository_db/extracted"
tar --warning=no-unknown-keyword -xf "$repository_db/try-omarchy-update.db.tar.gz" \
  -C "$repository_db/extracted"
source_date_epoch=$(python3 -c \
  'import json,sys; print(json.load(open(sys.argv[1]))["image"]["sourceDateEpoch"])' "$spec")
[[ $source_date_epoch =~ ^[0-9]+$ ]] || fail "invalid source date epoch"
find "$repository_db/extracted" -exec touch -h -d "@$source_date_epoch" {} +
mapfile -t database_entries < <(
  find "$repository_db/extracted" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort
)
((${#database_entries[@]} == ${#archives[@]})) \
  || fail "repository database has an unexpected package count"
tar \
  --sort=name \
  --mtime="@$source_date_epoch" \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  --format=gnu \
  -C "$repository_db/extracted" \
  -cf - "${database_entries[@]}" |
  gzip -n -9 >"$staging/repo/try-omarchy-update.db"

find "$staging" -exec touch -h -d "@$source_date_epoch" {} +
(
  cd "$staging"
  while IFS= read -r path; do
    sha256sum "${path#./}"
  done < <(find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort)
) >"$staging/SHA256SUMS"
update_sums_sha=$(sha256sum "$staging/SHA256SUMS")
update_sums_sha=${update_sums_sha%% *}
release_id=$(python3 -c \
  'import json,sys; print(json.load(open(sys.argv[1]))["releaseId"])' \
  "$staging/target-state.json")
[[ $release_id =~ ^[0-9a-f]{64}$ ]] || fail "invalid computed release identity"
owned_payload_sha=$(python3 -c \
  'import json,sys; print(json.load(open(sys.argv[1]))["ownedPayloadSha256"])' \
  "$staging/release.json")
[[ $owned_payload_sha =~ ^[0-9a-f]{64}$ ]] || fail "invalid owned-payload identity"
python3 "$script_dir/write-update-contract.py" \
  --root "$root" \
  --spec "$spec" \
  --release-id "$release_id" \
  --owned-payload-sha256 "$owned_payload_sha" \
  --update-sums-sha256 "$update_sums_sha"

used_kib=$(du -sk "$staging" | awk '{print $1}')
# Leave 25% plus 128 MiB for ext4 metadata, then round to a deterministic
# 256-MiB boundary. Package archives are immutable, so this does not hide a
# release-dependent capacity choice in the host launcher.
required_kib=$((used_kib + used_kib / 4 + 128 * 1024))
size_mib=$(((required_kib / 1024 + 255) / 256 * 256))
((size_mib > 0)) || fail "calculated update image size is invalid"
raw="$output/update.ext4"
compressed="$output/update.ext4.zst"
rm -f "$raw" "$compressed"
truncate -s "${size_mib}M" "$raw"
blocks=$((size_mib * 1024 * 1024 / 4096))
export SOURCE_DATE_EPOCH="$source_date_epoch"
export E2FSPROGS_FAKE_TIME="$source_date_epoch"
mke2fs -q -F -t ext4 -b 4096 -L omarchy-update \
  -U 5b27bda2-3c1e-5d21-91f4-599dde2bf4fb \
  -E lazy_itable_init=0,lazy_journal_init=0 \
  -d "$staging" "$raw" "$blocks"
e2fsck -fn "$raw"
zstd --force --quiet -12 --threads=0 "$raw" -o "$compressed"
printf '%s\n' "$update_sums_sha" >"$output/update.SHA256SUMS.sha256"

echo "Built offline update image with ${#archives[@]} packages: $compressed"
