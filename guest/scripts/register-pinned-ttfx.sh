#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: register-pinned-ttfx.sh --root ROOT --work WORK --spec SPEC --pacman-config CONFIG

Builds the spec-pinned official ttfx source natively for ARM64 using its locked
Rust dependencies, then installs it as a local Arch package staged in the
guest's immutable repository.
USAGE
}

fail() {
  echo "register-pinned-ttfx: $*" >&2
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
for command in arch-chroot cargo curl install pacman python3 rustc sha256sum tar timeout zstd; do
  command -v "$command" >/dev/null || fail "$command is required"
done

mapfile -t metadata < <(python3 - "$spec" <<'PY'
import json
import pathlib
import sys

spec = json.loads(pathlib.Path(sys.argv[1]).read_text())
component = spec.get("supplyChain", {}).get("ttfx")
if component is None:
    print("disabled")
    raise SystemExit
print("enabled")
for key in (
    "version",
    "pkgrel",
    "repository",
    "commit",
    "tree",
    "packageRecipeCommit",
    "url",
    "sha256",
    "cargoLockSha256",
    "binarySha256",
    "target",
    "rustPackageVersion",
    "rustcVersion",
    "cargoVersion",
    "reportedVersion",
    "license",
    "licenseSha256",
    "noticeSha256",
):
    print(component[key])
print(spec["image"]["architecture"])
print(spec["image"]["sourceDateEpoch"])
PY
) || fail "could not read pinned ttfx metadata"
[[ ${metadata[0]:-} == disabled ]] && exit 0
[[ ${metadata[0]:-} == enabled ]] || fail "invalid pinned ttfx state"
(( ${#metadata[@]} == 21 )) || fail "pinned ttfx metadata is incomplete"
version=${metadata[1]}
pkgrel=${metadata[2]}
repository=${metadata[3]}
commit=${metadata[4]}
tree=${metadata[5]}
package_recipe_commit=${metadata[6]}
url=${metadata[7]}
sha256=${metadata[8]}
cargo_lock_sha256=${metadata[9]}
binary_sha256=${metadata[10]}
target=${metadata[11]}
rust_package_version=${metadata[12]}
rustc_version=${metadata[13]}
cargo_version=${metadata[14]}
reported_version=${metadata[15]}
license=${metadata[16]}
license_sha256=${metadata[17]}
notice_sha256=${metadata[18]}
architecture=${metadata[19]}
source_date_epoch=${metadata[20]}

[[ $architecture == aarch64 ]] || fail "pinned ttfx component supports only aarch64"
[[ $target == aarch64-unknown-linux-gnu ]] || fail "unexpected ttfx build target: $target"
[[ $rust_package_version == "rust 1:1.98.1-1" ]] || fail "unexpected ttfx Rust package version"
[[ $(pacman -Q rust) == "$rust_package_version" ]] || fail "ttfx Rust package identity mismatch"
[[ $(rustc --version) == "$rustc_version" ]] || fail "ttfx rustc identity mismatch"
[[ $(cargo --version) == "$cargo_version" ]] || fail "ttfx Cargo identity mismatch"
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid ttfx version: $version"
[[ $pkgrel == 1 ]] || fail "unexpected ttfx package release: $pkgrel"
[[ $repository == https://github.com/omacom-io/ttfx ]] || fail "unexpected ttfx repository"
[[ $url == "$repository/archive/refs/tags/v$version.tar.gz" ]] || fail "ttfx URL does not match the pinned tag"
[[ $reported_version == "ttfx $version" ]] || fail "invalid ttfx reported version"
[[ $license == MIT ]] || fail "unexpected ttfx license: $license"
[[ $commit =~ ^[0-9a-f]{40}$ ]] || fail "invalid ttfx commit"
[[ $tree =~ ^[0-9a-f]{40}$ ]] || fail "invalid ttfx tree"
[[ $package_recipe_commit =~ ^[0-9a-f]{40}$ ]] || fail "invalid ttfx package recipe commit"
for digest in "$sha256" "$cargo_lock_sha256" "$binary_sha256" "$license_sha256" "$notice_sha256"; do
  [[ $digest =~ ^[0-9a-f]{64}$ ]] || fail "invalid ttfx content digest"
done
[[ $source_date_epoch =~ ^[0-9]+$ ]] || fail "invalid source date epoch"

cache_dir="$work/download-cache"
install -d -m 0755 "$cache_dir"
asset_cache="$cache_dir/ttfx-$version.tar.gz"

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

package_name=try-omarchy-ttfx
package_version="$version-$pkgrel"
stage=$(mktemp -d "$work/ttfx-package.XXXXXX")
cleanup() {
  rm -rf "$stage"
}
trap cleanup EXIT

python3 - "$asset_cache" "$version" <<'PY' || fail "ttfx source archive has an unsafe member set"
import pathlib
import sys
import tarfile

archive = pathlib.Path(sys.argv[1])
root = f"ttfx-{sys.argv[2]}"
with tarfile.open(archive, "r:gz") as source:
    members = source.getmembers()
    if not members:
        raise SystemExit(1)
    for member in members:
        path = pathlib.PurePosixPath(member.name)
        if (
            not path.parts
            or path.parts[0] != root
            or any(part in {"", ".", ".."} for part in path.parts)
            or not (member.isfile() or member.isdir())
        ):
            raise SystemExit(1)
PY

install -d -m 0755 "$stage/source"
tar -xzf "$asset_cache" --no-same-owner -C "$stage/source"
source_root="$stage/source/ttfx-$version"
[[ -d $source_root ]] || fail "ttfx source root is missing"
verify_file "$cargo_lock_sha256" "$source_root/Cargo.lock" || fail "ttfx Cargo.lock digest mismatch"
verify_file "$license_sha256" "$source_root/LICENSE" || fail "ttfx license digest mismatch"
verify_file "$notice_sha256" "$source_root/NOTICE" || fail "ttfx notice digest mismatch"

python3 - "$source_root/Cargo.toml" "$version" <<'PY' || fail "ttfx Cargo metadata mismatch"
import pathlib
import sys
import tomllib

package = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())["package"]
if package.get("name") != "ttfx" or package.get("version") != sys.argv[2] or package.get("license") != "MIT":
    raise SystemExit(1)
PY

export CARGO_HOME="$stage/cargo-home"
export CARGO_TARGET_DIR="$stage/target"
export CARGO_INCREMENTAL=0
export SOURCE_DATE_EPOCH="$source_date_epoch"
# Rust embeds source locations used by panic messages. Map the randomized,
# concurrency-safe build directory to a stable prefix so it cannot perturb the
# packaged binary or leak a particular builder path.
export CARGO_ENCODED_RUSTFLAGS="--remap-path-prefix=$stage=/usr/src/try-omarchy-ttfx"
install -d -m 0755 "$CARGO_HOME" "$CARGO_TARGET_DIR"
(
  cd "$source_root"
  cargo fetch --locked --target "$target"
  cargo build --frozen --release --target "$target"
)

built_binary="$CARGO_TARGET_DIR/$target/release/ttfx"
[[ -x $built_binary ]] || fail "ttfx build did not produce an executable"
python3 - "$built_binary" <<'PY' || fail "ttfx build is not an ARM64 ELF binary"
import pathlib
import sys

header = pathlib.Path(sys.argv[1]).read_bytes()[:20]
if len(header) != 20 or header[:6] != b"\x7fELF\x02\x01" or int.from_bytes(header[18:20], "little") != 183:
    raise SystemExit(1)
PY
built_version=$($built_binary --version)
[[ $built_version == "$reported_version" ]] || fail "ttfx reported an unexpected build identity: $built_version"
help=$($built_binary --help)
for option in --frame-rate --canvas-width --canvas-height --reuse-canvas --anchor-canvas \
  --anchor-text --random-effect --no-eol --no-restore-cursor; do
  [[ $help == *"$option"* ]] || fail "ttfx build is missing required screensaver option: $option"
done
printf 'OK\n' >"$stage/render-input.txt"
if ! timeout 10 "$built_binary" \
  -i "$stage/render-input.txt" \
  --frame-rate 1000 --canvas-width 8 --canvas-height 2 --reuse-canvas \
  --anchor-canvas c --anchor-text c --random-effect --include-effects print \
  --no-eol --no-restore-cursor >"$stage/render-output.txt"; then
  fail "ttfx build failed its bounded ASCII render smoke test"
fi
[[ -s $stage/render-output.txt ]] || fail "ttfx render smoke test produced no terminal output"
built_binary_sha256=$(sha256sum "$built_binary")
built_binary_sha256=${built_binary_sha256%% *}
[[ $built_binary_sha256 == "$binary_sha256" ]] ||
  fail "ttfx reproducible binary digest mismatch: $built_binary_sha256"

install -Dm0755 "$built_binary" "$stage/usr/bin/ttfx"
install -Dm0644 "$source_root/LICENSE" "$stage/usr/share/licenses/$package_name/LICENSE"
install -Dm0644 "$source_root/NOTICE" "$stage/usr/share/licenses/$package_name/NOTICE"
install -Dm0644 "$source_root/README.md" "$stage/usr/share/doc/$package_name/README.md"
"$built_binary" --print-completion bash |
  install -Dm0644 /dev/stdin "$stage/usr/share/bash-completion/completions/ttfx"
"$built_binary" --print-completion zsh |
  install -Dm0644 /dev/stdin "$stage/usr/share/zsh/site-functions/_ttfx"

installed_size=$(du -sb "$stage/usr" | awk '{print $1}')
cat >"$stage/.PKGINFO" <<EOF
pkgname = $package_name
pkgbase = $package_name
pkgver = $package_version
pkgdesc = Pinned official ttfx $version source build for the Omarchy ARM64 guest
url = $repository
builddate = $source_date_epoch
packager = Try Omarchy reproducible guest builder
size = $installed_size
arch = aarch64
license = MIT
provides = ttfx=$version
conflict = ttfx
depend = gcc-libs
depend = glibc
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
  fail "installed ttfx package failed its ownership check"
pacman --config "$pacman_config" --root "$root" --dbpath "$root/var/lib/pacman" -T ttfx >/dev/null ||
  fail "installed ttfx package does not satisfy the ttfx dependency"
verify_file "$built_binary_sha256" "$root/usr/bin/ttfx" || fail "installed ttfx binary differs from the built artifact"
installed_version=$(arch-chroot "$root" /usr/bin/ttfx --version)
[[ $installed_version == "$reported_version" ]] || fail "installed ttfx reported an unexpected identity: $installed_version"

repo_dir="$root/usr/share/try-omarchy/repo"
install -d -m 0755 "$repo_dir"
install -m 0644 "$package_archive" "$repo_dir/$(basename "$package_archive")"
echo "Registered $query from verified official source $sha256 (binary $built_binary_sha256)"
