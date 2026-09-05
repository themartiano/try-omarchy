#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: register-pinned-voxtype.sh --root ROOT --work WORK --spec SPEC --pacman-config CONFIG

Downloads the signed Voxtype ARM64 release pinned by the guest spec, packages
the CPU, ONNX, and OSD binaries, and stages the opt-in voxtype-bin package in
the guest's immutable local repository without installing it in the factory.
USAGE
}

fail() {
  echo "register-pinned-voxtype: $*" >&2
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
for command in arch-chroot curl gpg install pacman python3 sha256sum tar zstd; do
  command -v "$command" >/dev/null || fail "$command is required"
done

mapfile -t metadata < <(python3 - "$spec" <<'PY'
import json
import pathlib
import sys

spec = json.loads(pathlib.Path(sys.argv[1]).read_text())
component = spec.get("supplyChain", {}).get("voxtype")
if component is None:
    print("disabled")
    raise SystemExit
print("enabled")
for key in (
    "version",
    "pkgrel",
    "repository",
    "sourceUrl",
    "sourceSha256",
    "sourceSignatureUrl",
    "sourceSignatureSha256",
    "signingKey",
    "signingKeySha256",
    "signingFingerprint",
    "reportedVersion",
    "license",
):
    print(component[key])
print(spec["image"]["architecture"])
print(spec["image"]["sourceDateEpoch"])
for name, asset in sorted(component["assets"].items()):
    print("|".join((name, asset["url"], asset["sha256"], asset["signatureUrl"], asset["signatureSha256"])))
PY
) || fail "could not read pinned Voxtype metadata"
[[ ${metadata[0]:-} == disabled ]] && exit 0
[[ ${metadata[0]:-} == enabled ]] || fail "invalid pinned Voxtype state"
(( ${#metadata[@]} == 21 )) || fail "pinned Voxtype metadata is incomplete"
version=${metadata[1]}
pkgrel=${metadata[2]}
repository=${metadata[3]}
source_url=${metadata[4]}
source_sha256=${metadata[5]}
source_signature_url=${metadata[6]}
source_signature_sha256=${metadata[7]}
signing_key_relative=${metadata[8]}
signing_key_sha256=${metadata[9]}
signing_fingerprint=${metadata[10]}
reported_version=${metadata[11]}
license=${metadata[12]}
architecture=${metadata[13]}
source_date_epoch=${metadata[14]}
asset_records=("${metadata[@]:15}")

[[ $architecture == aarch64 ]] || fail "pinned Voxtype package supports only aarch64"
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid Voxtype version: $version"
[[ $pkgrel =~ ^[1-9][0-9]*$ ]] || fail "invalid Voxtype pkgrel: $pkgrel"
[[ $repository == https://github.com/peteonrails/voxtype ]] || fail "unexpected Voxtype repository"
[[ $source_url == "https://github.com/peteonrails/voxtype/archive/refs/tags/v$version.tar.gz" ]] ||
  fail "Voxtype source URL does not match the pinned tag"
[[ $source_signature_url == "https://github.com/peteonrails/voxtype/releases/download/v$version/voxtype-$version.tar.gz.asc" ]] ||
  fail "Voxtype source signature URL does not match the pinned release"
[[ $source_sha256 =~ ^[0-9a-f]{64}$ ]] || fail "invalid Voxtype source digest"
[[ $source_signature_sha256 =~ ^[0-9a-f]{64}$ ]] || fail "invalid Voxtype source signature digest"
[[ $signing_key_relative == keys/voxtype-release.asc ]] || fail "unexpected Voxtype signing key path"
[[ $signing_key_sha256 =~ ^[0-9a-f]{64}$ ]] || fail "invalid Voxtype signing key digest"
[[ $signing_fingerprint =~ ^[0-9A-F]{40}$ ]] || fail "invalid Voxtype signing fingerprint"
[[ $reported_version == "voxtype $version" ]] || fail "invalid Voxtype reported version"
[[ $license == MIT ]] || fail "unexpected Voxtype license: $license"
[[ $source_date_epoch =~ ^[0-9]+$ ]] || fail "invalid source date epoch"

spec_dir=$(cd "$(dirname "$spec")" && pwd -P)
signing_key="$spec_dir/$signing_key_relative"
[[ -f $signing_key && ! -L $signing_key ]] || fail "Voxtype signing key is missing or symlinked"

expected_asset_names=(audioBridge cpu onnx osd osdGtk4 osdQuickshell)
(( ${#asset_records[@]} == ${#expected_asset_names[@]} )) || fail "unexpected Voxtype asset count"
for index in "${!asset_records[@]}"; do
  IFS='|' read -r name url digest signature_url signature_digest <<<"${asset_records[$index]}"
  [[ $name == "${expected_asset_names[$index]}" ]] || fail "unexpected Voxtype asset order: $name"
  [[ $digest =~ ^[0-9a-f]{64}$ ]] || fail "invalid Voxtype asset digest: $name"
  [[ $signature_digest =~ ^[0-9a-f]{64}$ ]] || fail "invalid Voxtype signature digest: $name"
  case "$name" in
    audioBridge) suffix=audio-bridge ;;
    cpu) suffix=cpu ;;
    onnx) suffix=onnx ;;
    osd) suffix=osd ;;
    osdGtk4) suffix=osd-gtk4 ;;
    osdQuickshell) suffix=osd-quickshell ;;
    *) fail "unsupported Voxtype asset: $name" ;;
  esac
  expected_url="https://github.com/peteonrails/voxtype/releases/download/v$version/voxtype-$version-linux-aarch64-$suffix"
  [[ $url == "$expected_url" ]] || fail "Voxtype asset URL does not match the pinned release: $name"
  [[ $signature_url == "$expected_url.asc" ]] || fail "Voxtype signature URL does not match the pinned release: $name"
done

verify_file() {
  local expected=$1
  local path=$2
  printf '%s  %s\n' "$expected" "$path" | sha256sum -c - >/dev/null
}

verify_file "$signing_key_sha256" "$signing_key" || fail "Voxtype signing key digest mismatch"

cache_dir="$work/download-cache"
install -d -m 0755 "$cache_dir"

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

source_cache="$cache_dir/voxtype-$version.tar.gz"
source_signature_cache="$source_cache.asc"
download_verified "$source_url" "$source_sha256" "$source_cache"
download_verified "$source_signature_url" "$source_signature_sha256" "$source_signature_cache"

declare -A asset_paths=()
declare -A asset_digests=()
declare -A signature_paths=()
for record in "${asset_records[@]}"; do
  IFS='|' read -r name url digest signature_url signature_digest <<<"$record"
  asset_paths[$name]="$cache_dir/voxtype-$version-$name"
  signature_paths[$name]="${asset_paths[$name]}.asc"
  asset_digests[$name]=$digest
  download_verified "$url" "$digest" "${asset_paths[$name]}"
  download_verified "$signature_url" "$signature_digest" "${signature_paths[$name]}"
done

stage=$(mktemp -d "$work/voxtype-package.XXXXXX")
cleanup() {
  rm -rf "$stage"
}
trap cleanup EXIT

gpg_home="$stage/gpg"
install -d -m 0700 "$gpg_home"
gpg --batch --homedir "$gpg_home" --import "$signing_key" >/dev/null 2>&1 ||
  fail "could not import the pinned Voxtype signing key"
mapfile -t imported_fingerprints < <(
  gpg --batch --homedir "$gpg_home" --with-colons --fingerprint "$signing_fingerprint" |
    awk -F: '$1 == "fpr" { print $10 }'
)
[[ ${imported_fingerprints[*]} == "$signing_fingerprint" ]] || fail "Voxtype signing key fingerprint mismatch"

verify_signature() {
  local signature=$1
  local payload=$2
  local status=""
  if ! status=$(gpg --batch --homedir "$gpg_home" --status-fd 1 --verify "$signature" "$payload" 2>/dev/null); then
    fail "Voxtype release signature verification failed: $(basename "$payload")"
  fi
  grep -q "^\[GNUPG:\] VALIDSIG $signing_fingerprint " <<<"$status" ||
    fail "Voxtype release signature used an unexpected key: $(basename "$payload")"
}

verify_signature "$source_signature_cache" "$source_cache"
for name in "${expected_asset_names[@]}"; do
  verify_signature "${signature_paths[$name]}" "${asset_paths[$name]}"
done

python3 - "$source_cache" "$version" <<'PY' || fail "Voxtype source archive has an unsafe member set"
import pathlib
import posixpath
import sys
import tarfile

archive = pathlib.Path(sys.argv[1])
prefix = f"voxtype-{sys.argv[2]}"
required = {
    f"{prefix}/LICENSE",
    f"{prefix}/README.md",
    f"{prefix}/config/default.toml",
    f"{prefix}/packaging/completions/voxtype.bash",
    f"{prefix}/packaging/completions/voxtype.fish",
    f"{prefix}/packaging/completions/voxtype.zsh",
    f"{prefix}/packaging/scripts/voxtype-configure-launcher",
    f"{prefix}/packaging/systemd/voxtype.service",
    f"{prefix}/packaging/voxtype-configure.desktop",
    f"{prefix}/quickshell/shell.qml",
    f"{prefix}/quickshell/voxtype-shared/qmldir",
}
seen = set()
with tarfile.open(archive, "r:gz") as source:
    for member in source.getmembers():
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != prefix:
            raise SystemExit(1)
        if not (member.isfile() or member.isdir() or member.issym()):
            raise SystemExit(1)
        if member.issym():
            target = member.linkname
            if target.startswith("/"):
                raise SystemExit(1)
            resolved = posixpath.normpath(posixpath.join(posixpath.dirname(member.name), target))
            if not (resolved == prefix or resolved.startswith(prefix + "/")):
                raise SystemExit(1)
        seen.add(member.name)
if not required <= seen:
    raise SystemExit(1)
PY

install -d -m 0755 "$stage/source"
tar -xzf "$source_cache" --no-same-owner --no-same-permissions -C "$stage/source"
source_root="$stage/source/voxtype-$version"

for name in "${expected_asset_names[@]}"; do
  python3 - "${asset_paths[$name]}" <<'PY' || fail "Voxtype $name asset is not an ARM64 ELF binary"
import pathlib
import struct
import sys

data = pathlib.Path(sys.argv[1]).read_bytes()[:20]
if len(data) != 20 or data[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<H", data, 18)[0] != 183:
    raise SystemExit(1)
PY
done

package_name=voxtype-bin
package_version="$version-$pkgrel"
install -Dm0755 "${asset_paths[cpu]}" "$stage/usr/lib/voxtype/voxtype-native"
install -Dm0755 "${asset_paths[onnx]}" "$stage/usr/lib/voxtype/voxtype-onnx"
install -Dm0755 "${asset_paths[osd]}" "$stage/usr/lib/voxtype/voxtype-osd"
install -Dm0755 "${asset_paths[osdGtk4]}" "$stage/usr/lib/voxtype/voxtype-osd-gtk4"
install -Dm0755 "${asset_paths[osdQuickshell]}" "$stage/usr/lib/voxtype/voxtype-osd-quickshell"
install -Dm0755 "${asset_paths[audioBridge]}" "$stage/usr/bin/voxtype-audio-bridge"
ln -s /usr/lib/voxtype/voxtype-native "$stage/usr/bin/voxtype"
ln -s /usr/lib/voxtype/voxtype-osd "$stage/usr/bin/voxtype-osd"

install -Dm0644 "$source_root/config/default.toml" "$stage/etc/voxtype/config.toml"
install -Dm0644 "$source_root/packaging/systemd/voxtype.service" "$stage/usr/lib/systemd/user/voxtype.service"
install -Dm0644 "$source_root/packaging/completions/voxtype.bash" "$stage/usr/share/bash-completion/completions/voxtype"
install -Dm0644 "$source_root/packaging/completions/voxtype.zsh" "$stage/usr/share/zsh/site-functions/_voxtype"
install -Dm0644 "$source_root/packaging/completions/voxtype.fish" "$stage/usr/share/fish/vendor_completions.d/voxtype.fish"
install -Dm0755 "$source_root/packaging/scripts/voxtype-configure-launcher" "$stage/usr/bin/voxtype-configure-launcher"
install -Dm0644 "$source_root/packaging/voxtype-configure.desktop" "$stage/usr/share/applications/voxtype-configure.desktop"
install -Dm0644 "$source_root/LICENSE" "$stage/usr/share/licenses/$package_name/LICENSE"
install -Dm0644 "$source_root/README.md" "$stage/usr/share/doc/$package_name/README.md"
install -d -m 0755 "$stage/usr/share/voxtype/quickshell"
cp -a "$source_root/quickshell/." "$stage/usr/share/voxtype/quickshell/"
find "$stage/usr/share/voxtype/quickshell" -type d -exec chmod 0755 {} +
find "$stage/usr/share/voxtype/quickshell" -type f -exec chmod 0644 {} +

for pair in "cpu:${asset_paths[cpu]}" "onnx:${asset_paths[onnx]}"; do
  name=${pair%%:*}
  binary=${pair#*:}
  smoke_path="$root/usr/share/try-omarchy/.voxtype-$name-smoke"
  install -Dm0755 "$binary" "$smoke_path"
  reported=$(arch-chroot "$root" "/usr/share/try-omarchy/.voxtype-$name-smoke" --version)
  rm -f "$smoke_path"
  [[ $reported == "$reported_version" ]] || fail "Voxtype $name binary reported an unexpected identity: $reported"
done

installed_size=$(du -sb "$stage/etc" "$stage/usr" | awk '{ total += $1 } END { print total }')
cat >"$stage/.PKGINFO" <<EOF
pkgname = $package_name
pkgbase = $package_name
pkgver = $package_version
pkgdesc = Signed official Voxtype $version ARM64 binaries for Omarchy dictation
url = $repository
builddate = $source_date_epoch
packager = Try Omarchy reproducible guest builder
size = $installed_size
arch = aarch64
license = MIT
provides = voxtype=$version
conflict = voxtype
depend = alsa-lib
depend = curl
depend = gcc-libs
depend = glibc
depend = gtk4-layer-shell
depend = which
optdepend = wtype: keyboard simulation for Wayland
optdepend = wl-clipboard: clipboard support
optdepend = libnotify: desktop notifications
optdepend = pipewire: recommended audio server
optdepend = pipewire-alsa: ALSA compatibility for PipeWire
optdepend = quickshell: Quickshell on-screen display
backup = etc/voxtype/config.toml
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
  -cf - .PKGINFO etc usr |
  zstd --force --quiet -12 --threads=1 -o "$package_archive"

package_metadata=$(tar -xOf "$package_archive" .PKGINFO)
for dependency in gtk4-layer-shell which; do
  grep -Fxq "depend = $dependency" <<<"$package_metadata" ||
    fail "Voxtype package is missing required runtime dependency: $dependency"
done

query=$(pacman --config "$pacman_config" -Qp "$package_archive")
[[ $query == "$package_name $package_version" ]] || fail "Voxtype package query returned: $query"
[[ $(readlink "$stage/usr/bin/voxtype") == /usr/lib/voxtype/voxtype-native ]] ||
  fail "Voxtype package does not activate the ARM64 CPU binary"
verify_file "${asset_digests[cpu]}" "$stage/usr/lib/voxtype/voxtype-native" ||
  fail "packaged Voxtype CPU binary digest mismatch"
verify_file "${asset_digests[onnx]}" "$stage/usr/lib/voxtype/voxtype-onnx" ||
  fail "packaged Voxtype ONNX binary digest mismatch"

repo_dir="$root/usr/share/try-omarchy/repo"
install -d -m 0755 "$repo_dir"
install -m 0644 "$package_archive" "$repo_dir/$(basename "$package_archive")"
echo "Registered opt-in $query from six signed official ARM64 assets"
