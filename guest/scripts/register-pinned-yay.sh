#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: register-pinned-yay.sh --root ROOT --work WORK --spec SPEC --pacman-config CONFIG

Downloads the spec-pinned official yay ARM64 release and license, verifies
their digests and exact archive shape, then installs yay as a local Arch
package staged in the guest's immutable repository.
USAGE
}

fail() {
  echo "register-pinned-yay: $*" >&2
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
for command in arch-chroot curl install pacman python3 sha256sum tar zstd; do
  command -v "$command" >/dev/null || fail "$command is required"
done

mapfile -t metadata < <(python3 - "$spec" <<'PY'
import json
import pathlib
import sys

spec = json.loads(pathlib.Path(sys.argv[1]).read_text())
component = spec.get("supplyChain", {}).get("yay")
if component is None:
    print("disabled")
    raise SystemExit
print("enabled")
for key in (
    "version",
    "url",
    "sha256",
    "binarySha256",
    "reportedVersion",
    "license",
    "licenseUrl",
    "licenseSha256",
):
    print(component[key])
print(spec["image"]["architecture"])
print(spec["image"]["sourceDateEpoch"])
PY
) || fail "could not read pinned yay metadata"
[[ ${metadata[0]:-} == disabled ]] && exit 0
[[ ${metadata[0]:-} == enabled ]] || fail "invalid pinned yay state"
(( ${#metadata[@]} == 11 )) || fail "pinned yay metadata is incomplete"
version=${metadata[1]}
url=${metadata[2]}
sha256=${metadata[3]}
binary_sha256=${metadata[4]}
reported_version=${metadata[5]}
license=${metadata[6]}
license_url=${metadata[7]}
license_sha256=${metadata[8]}
architecture=${metadata[9]}
source_date_epoch=${metadata[10]}

[[ $architecture == aarch64 ]] || fail "pinned yay component supports only aarch64"
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid yay version: $version"
[[ $sha256 =~ ^[0-9a-f]{64}$ ]] || fail "invalid yay archive digest"
[[ $binary_sha256 =~ ^[0-9a-f]{64}$ ]] || fail "invalid yay binary digest"
[[ $reported_version == "yay v$version - libalpm v"* ]] || fail "invalid yay reported version"
[[ $license == GPL-3.0-or-later ]] || fail "unexpected yay license: $license"
[[ $license_sha256 =~ ^[0-9a-f]{64}$ ]] || fail "invalid yay license digest"
[[ $source_date_epoch =~ ^[0-9]+$ ]] || fail "invalid source date epoch"
expected_url="https://github.com/Jguer/yay/releases/download/v$version/yay_${version}_aarch64.tar.gz"
expected_license_url="https://raw.githubusercontent.com/Jguer/yay/v$version/LICENSE"
[[ $url == "$expected_url" ]] || fail "yay URL does not match the pinned official release"
[[ $license_url == "$expected_license_url" ]] || fail "yay license URL does not match the pinned tag"

cache_dir="$work/download-cache"
install -d -m 0755 "$cache_dir"
asset_cache="$cache_dir/yay_${version}_aarch64.tar.gz"
license_cache="$cache_dir/yay-$version.LICENSE"

verify_file() {
  local expected=$1
  local path=$2
  printf '%s  %s\n' "$expected" "$path" | sha256sum -c - >/dev/null
}

download_verified() {
  local source_url=$1
  local expected=$2
  local destination=$3
  local temporary=""

  [[ ! -L $destination ]] || fail "refusing symlinked download cache entry: $destination"
  if [[ -f $destination ]] && verify_file "$expected" "$destination"; then
    return 0
  fi
  rm -f "$destination"
  temporary=$(mktemp "$cache_dir/.download.XXXXXX")
  if ! curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error \
    "$source_url" --output "$temporary"; then
    rm -f "$temporary"
    fail "download failed: $source_url"
  fi
  if ! verify_file "$expected" "$temporary"; then
    rm -f "$temporary"
    fail "download digest mismatch: $source_url"
  fi
  chmod 0644 "$temporary"
  mv "$temporary" "$destination"
}

download_verified "$url" "$sha256" "$asset_cache"
download_verified "$license_url" "$license_sha256" "$license_cache"

package_name=try-omarchy-yay
package_version="$version-1"
stage=$(mktemp -d "$work/yay-package.XXXXXX")
cleanup() {
  rm -rf "$stage"
}
trap cleanup EXIT

expected_members=$(cat <<EOF
yay_${version}_aarch64/
yay_${version}_aarch64/bash
yay_${version}_aarch64/ca.mo
yay_${version}_aarch64/ca_ES.mo
yay_${version}_aarch64/cs.mo
yay_${version}_aarch64/da.mo
yay_${version}_aarch64/da_DK.mo
yay_${version}_aarch64/de.mo
yay_${version}_aarch64/en.mo
yay_${version}_aarch64/es.mo
yay_${version}_aarch64/eu.mo
yay_${version}_aarch64/fi.mo
yay_${version}_aarch64/fish
yay_${version}_aarch64/fr.mo
yay_${version}_aarch64/fr_FR.mo
yay_${version}_aarch64/he.mo
yay_${version}_aarch64/he_IL.mo
yay_${version}_aarch64/hu.mo
yay_${version}_aarch64/id.mo
yay_${version}_aarch64/it_IT.mo
yay_${version}_aarch64/ja.mo
yay_${version}_aarch64/ko.mo
yay_${version}_aarch64/nl.mo
yay_${version}_aarch64/pl.mo
yay_${version}_aarch64/pl_PL.mo
yay_${version}_aarch64/pt.mo
yay_${version}_aarch64/pt_BR.mo
yay_${version}_aarch64/ru.mo
yay_${version}_aarch64/ru_RU.mo
yay_${version}_aarch64/sk.mo
yay_${version}_aarch64/sv.mo
yay_${version}_aarch64/tr.mo
yay_${version}_aarch64/uk.mo
yay_${version}_aarch64/vi.mo
yay_${version}_aarch64/vi_VN.mo
yay_${version}_aarch64/yay
yay_${version}_aarch64/yay.8
yay_${version}_aarch64/zh_CN.mo
yay_${version}_aarch64/zh_TW.mo
yay_${version}_aarch64/zsh
EOF
)
actual_members=$(tar -tzf "$asset_cache" | LC_ALL=C sort)
[[ $actual_members == "$expected_members" ]] || fail "yay archive has an unexpected member set"

install -d -m 0755 "$stage/extracted"
tar -xzf "$asset_cache" --no-same-owner -C "$stage/extracted"
asset_root="$stage/extracted/yay_${version}_aarch64"
verify_file "$binary_sha256" "$asset_root/yay" || fail "extracted yay binary digest mismatch"

install -Dm0755 "$asset_root/yay" "$stage/usr/bin/yay"
install -Dm0644 "$asset_root/yay.8" "$stage/usr/share/man/man8/yay.8"
install -Dm0644 "$asset_root/bash" "$stage/usr/share/bash-completion/completions/yay"
install -Dm0644 "$asset_root/zsh" "$stage/usr/share/zsh/site-functions/_yay"
install -Dm0644 "$asset_root/fish" "$stage/usr/share/fish/vendor_completions.d/yay.fish"
install -Dm0644 "$license_cache" "$stage/usr/share/licenses/$package_name/LICENSE"
for message_catalog in "$asset_root"/*.mo; do
  locale=$(basename "$message_catalog" .mo)
  [[ $locale =~ ^[A-Za-z_]+$ ]] || fail "unsafe yay locale: $locale"
  install -Dm0644 "$message_catalog" "$stage/usr/share/locale/$locale/LC_MESSAGES/yay.mo"
done

installed_size=$(du -sb "$stage/usr" | awk '{print $1}')
cat >"$stage/.PKGINFO" <<EOF
pkgname = $package_name
pkgbase = $package_name
pkgver = $package_version
pkgdesc = Pinned official yay $version binary for the Omarchy ARM64 guest
url = https://github.com/Jguer/yay
builddate = $source_date_epoch
packager = Try Omarchy reproducible guest builder
size = $installed_size
arch = aarch64
license = GPL-3.0-or-later
provides = yay=$version
conflict = yay
depend = pacman>=7.1
depend = git
depend = sudo
depend = fakeroot
EOF

package_archive="$stage/$package_name-$package_version-aarch64.pkg.tar.zst"
tar \
  --sort=name \
  --mtime="@$source_date_epoch" \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  --format=gnu \
  -C "$stage" \
  -cf - .PKGINFO usr |
  zstd --force --quiet -12 --threads=1 -o "$package_archive"

pacman \
  --noconfirm \
  --config "$pacman_config" \
  --root "$root" \
  --dbpath "$root/var/lib/pacman" \
  --logfile "$root/var/log/pacman.log" \
  -U "$package_archive"

query=$(pacman --config "$pacman_config" --root "$root" --dbpath "$root/var/lib/pacman" -Q "$package_name")
[[ $query == "$package_name $package_version" ]] || fail "provider query returned: $query"
pacman --config "$pacman_config" --root "$root" --dbpath "$root/var/lib/pacman" -Qkk "$package_name" >/dev/null ||
  fail "installed yay package failed its ownership check"
pacman --config "$pacman_config" --root "$root" --dbpath "$root/var/lib/pacman" -T yay >/dev/null ||
  fail "installed yay package does not satisfy the yay dependency"
verify_file "$binary_sha256" "$root/usr/bin/yay" || fail "installed yay binary digest mismatch"
reported=$(arch-chroot "$root" /usr/bin/runuser -u alpm -- /usr/bin/yay --version)
[[ $reported == "$reported_version" ]] || fail "yay reported an unexpected identity: $reported"

repo_dir="$root/usr/share/try-omarchy/repo"
install -d -m 0755 "$repo_dir"
install -m 0644 "$package_archive" "$repo_dir/$(basename "$package_archive")"
echo "Registered $query from verified official asset $sha256"
