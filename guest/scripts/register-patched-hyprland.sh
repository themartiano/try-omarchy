#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: register-patched-hyprland.sh --root ROOT --work WORK --spec SPEC --pacman-config CONFIG

Builds the spec-pinned rounded-border Hyprland backport natively for ARM64,
repackages the verified upstream Arch package with the patched executable and
public headers, and registers it in the guest's immutable package repository.
USAGE
}

fail() {
  echo "register-patched-hyprland: $*" >&2
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
root=$(cd "$root" && pwd -P)
work=$(cd "$work" && pwd -P)
case "$root" in
  /|/bin|/boot|/etc|/home|/opt|/root|/usr|/var)
    fail "refusing canonical unsafe root: $root"
    ;;
esac
[[ $root != "$work" && $work != "$root/"* ]] || fail "work directory must be outside the staged root"
[[ $root != *$'\n'* && $work != *$'\n'* ]] || fail "root and work paths cannot contain newlines"

for command in arch-chroot bsdtar curl find git gzip install pacman python3 sha256sum sort tar touch xz zstd; do
  command -v "$command" >/dev/null || fail "$command is required"
done

guest_dir=$(cd "$(dirname "$0")/.." && pwd -P)
metadata_output=$(python3 - "$spec" <<'PY'
import json
import pathlib
import sys

document = json.loads(pathlib.Path(sys.argv[1]).read_text())
component = document.get("supplyChain", {}).get("hyprland")
if component is None:
    print("disabled")
    raise SystemExit

required = {
    "version",
    "pkgrel",
    "upstreamPackageVersion",
    "repository",
    "commit",
    "url",
    "sha256",
    "upstreamPackageSha256",
    "patch",
    "patchSha256",
    "glazeVersion",
    "glazeCommit",
    "glazeUrl",
    "glazeSha256",
    "glazeLicenseSha256",
    "binarySha256",
    "license",
    "issue",
    "buildPackages",
}
if set(component) != required:
    missing = sorted(required - set(component))
    extra = sorted(set(component) - required)
    raise SystemExit(f"invalid Hyprland metadata fields; missing={missing}, extra={extra}")

string_keys = required - {"buildPackages"}
for key in string_keys:
    value = component[key]
    if not isinstance(value, str) or not value or "\n" in value or "\r" in value:
        raise SystemExit(f"invalid Hyprland metadata value: {key}")

build_packages = component["buildPackages"]
if not isinstance(build_packages, dict) or not build_packages:
    raise SystemExit("Hyprland buildPackages must be a non-empty object")
if list(build_packages) != sorted(build_packages):
    raise SystemExit("Hyprland buildPackages must be sorted")
for name, version in build_packages.items():
    if not isinstance(name, str) or not name or not isinstance(version, str) or not version:
        raise SystemExit("invalid Hyprland buildPackages entry")
    if any(character in name + version for character in "\r\n\t|"):
        raise SystemExit("unsafe Hyprland buildPackages entry")

image = document.get("image", {})
architecture = image.get("architecture")
source_date_epoch = image.get("sourceDateEpoch")
if not isinstance(architecture, str):
    raise SystemExit("invalid image architecture")
if isinstance(source_date_epoch, bool) or not isinstance(source_date_epoch, int):
    raise SystemExit("invalid image sourceDateEpoch")

print("enabled")
for key in (
    "version",
    "pkgrel",
    "upstreamPackageVersion",
    "repository",
    "commit",
    "url",
    "sha256",
    "upstreamPackageSha256",
    "patch",
    "patchSha256",
    "glazeVersion",
    "glazeCommit",
    "glazeUrl",
    "glazeSha256",
    "glazeLicenseSha256",
    "binarySha256",
    "license",
    "issue",
):
    print(component[key])
print(architecture)
print(source_date_epoch)
print(json.dumps(build_packages, sort_keys=True, separators=(",", ":")))
PY
) || fail "could not read pinned Hyprland metadata"
mapfile -t metadata <<<"$metadata_output"
[[ ${metadata[0]:-} == disabled ]] && exit 0
[[ ${metadata[0]:-} == enabled ]] || fail "invalid pinned Hyprland state"
(( ${#metadata[@]} == 22 )) || fail "pinned Hyprland metadata is incomplete"

version=${metadata[1]}
pkgrel=${metadata[2]}
upstream_package_version=${metadata[3]}
repository=${metadata[4]}
commit=${metadata[5]}
url=${metadata[6]}
sha256=${metadata[7]}
upstream_package_sha256=${metadata[8]}
patch_relative=${metadata[9]}
patch_sha256=${metadata[10]}
glaze_version=${metadata[11]}
glaze_commit=${metadata[12]}
glaze_url=${metadata[13]}
glaze_sha256=${metadata[14]}
glaze_license_sha256=${metadata[15]}
binary_sha256=${metadata[16]}
license=${metadata[17]}
issue=${metadata[18]}
architecture=${metadata[19]}
source_date_epoch=${metadata[20]}
build_packages_json=${metadata[21]}

[[ $architecture == aarch64 ]] || fail "patched Hyprland supports only aarch64"
[[ $(uname -m) == aarch64 ]] || fail "patched Hyprland must be built natively on aarch64"
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid Hyprland version: $version"
[[ $pkgrel == 3.2 ]] || fail "unexpected Hyprland package release: $pkgrel"
[[ $upstream_package_version == "$version-3" ]] || fail "unexpected upstream Hyprland package version"
[[ $repository == https://github.com/hyprwm/Hyprland ]] || fail "unexpected Hyprland repository"
[[ $url == "$repository/releases/download/v$version/source-v$version.tar.gz" ]] ||
  fail "Hyprland URL does not match the pinned release"
[[ $commit =~ ^[0-9a-f]{40}$ ]] || fail "invalid Hyprland commit"
[[ $patch_relative == patches/hyprland/rounded-border-coverage.patch ]] ||
  fail "unexpected Hyprland patch path"
[[ $glaze_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid Glaze version"
[[ $glaze_commit == b518eec7a22e56ffa238b072c07f47efa7cea97f ]] || fail "unexpected Glaze commit"
[[ $glaze_url == "https://github.com/stephenberry/glaze/archive/refs/tags/v$glaze_version.tar.gz" ]] ||
  fail "Glaze URL does not match the pinned release"
[[ $license == BSD-3-Clause ]] || fail "unexpected Hyprland license: $license"
[[ $issue == https://github.com/themartiano/try-omarchy/issues/5 ]] || fail "unexpected Hyprland issue URL"
[[ $source_date_epoch =~ ^[0-9]+$ && $source_date_epoch -gt 0 ]] || fail "invalid source date epoch"
for digest in "$sha256" "$upstream_package_sha256" "$patch_sha256" "$glaze_sha256" "$glaze_license_sha256" "$binary_sha256"; do
  [[ $digest =~ ^[0-9a-f]{64}$ ]] || fail "invalid Hyprland content digest"
done

patch_path=$(python3 - "$guest_dir" "$patch_relative" <<'PY'
import pathlib
import sys

guest = pathlib.Path(sys.argv[1]).resolve(strict=True)
relative = pathlib.PurePosixPath(sys.argv[2])
if relative.is_absolute() or any(part in {"", ".", ".."} for part in relative.parts):
    raise SystemExit(1)
candidate = (guest / pathlib.Path(*relative.parts)).resolve(strict=True)
if candidate == guest or guest not in candidate.parents or not candidate.is_file():
    raise SystemExit(1)
print(candidate)
PY
) || fail "Hyprland patch path escapes the guest directory"
[[ ! -L $patch_path ]] || fail "refusing symlinked Hyprland patch"

verify_file() {
  local expected=$1
  local path=$2
  printf '%s  %s\n' "$expected" "$path" | sha256sum -c - >/dev/null
}

verify_file "$patch_sha256" "$patch_path" || fail "Hyprland patch digest mismatch"

cache_dir="$work/download-cache"
install -d -m 0755 "$cache_dir"
source_cache="$cache_dir/hyprland-$version-$commit.tar.gz"
glaze_cache="$cache_dir/glaze-$glaze_version-$glaze_commit.tar.gz"

download_verified() {
  local source_url=$1
  local expected=$2
  local destination=$3
  local temporary=""

  [[ ! -L $destination ]] || fail "refusing symlinked download cache entry: $destination"
  if [[ -f $destination ]] && verify_file "$expected" "$destination"; then
    return 0
  fi
  rm -f -- "$destination"
  temporary=$(mktemp "$cache_dir/.download.XXXXXX")
  if ! curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error \
    "$source_url" --output "$temporary"; then
    rm -f -- "$temporary"
    fail "download failed: $source_url"
  fi
  if ! verify_file "$expected" "$temporary"; then
    rm -f -- "$temporary"
    fail "download digest mismatch: $source_url"
  fi
  chmod 0644 "$temporary"
  mv "$temporary" "$destination"
}

download_verified "$url" "$sha256" "$source_cache"
download_verified "$glaze_url" "$glaze_sha256" "$glaze_cache"

stage=$(mktemp -d "$work/hyprland-package.XXXXXX")
cleanup() {
  if [[ -n ${stage:-} && -d $stage && $stage == "$work/"hyprland-package.* ]]; then
    rm -rf -- "$stage"
  fi
}
trap cleanup EXIT

validate_source_archive() {
  local archive=$1
  local expected_root=$2

  python3 - "$archive" "$expected_root" <<'PY'
import pathlib
import sys
import tarfile

archive = pathlib.Path(sys.argv[1])
expected_root = sys.argv[2]
seen = set()
with tarfile.open(archive, "r:gz") as source:
    members = source.getmembers()
    if not members:
        raise SystemExit(1)
    for member in members:
        name = member.name[:-1] if member.isdir() and member.name.endswith("/") else member.name
        if not name or name.startswith("/") or any(ord(character) < 32 or ord(character) == 127 for character in name):
            raise SystemExit(1)
        raw_parts = name.split("/")
        path = pathlib.PurePosixPath(name)
        if (
            any(part in {"", ".", ".."} for part in raw_parts)
            or path.as_posix() != name
            or path.parts[0] != expected_root
            or name in seen
            or not (member.isfile() or member.isdir())
        ):
            raise SystemExit(1)
        seen.add(name)
PY
}

validate_source_archive "$source_cache" hyprland-source || fail "Hyprland source archive has an unsafe member set"
validate_source_archive "$glaze_cache" "glaze-$glaze_version" || fail "Glaze source archive has an unsafe member set"
tar -xzf "$source_cache" --no-same-owner -C "$stage"
tar -xzf "$glaze_cache" --no-same-owner -C "$stage"

source_root="$stage/hyprland-source"
glaze_root="$stage/glaze-$glaze_version"
[[ -d $source_root && -d $glaze_root ]] || fail "verified source roots are missing"
[[ $(<"$source_root/VERSION") == "$version" ]] || fail "Hyprland source version mismatch"
python3 - "$source_root/src/version.h.in" "$commit" "$version" <<'PY' || fail "Hyprland source commit metadata mismatch"
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
commit = re.search(r'^#define GIT_COMMIT_HASH\s+"([0-9a-f]{40})"$', text, re.MULTILINE)
tag = re.search(r'^#define GIT_TAG\s+"([^"]+)"$', text, re.MULTILINE)
if commit is None or commit.group(1) != sys.argv[2] or tag is None or tag.group(1) != f"v{sys.argv[3]}":
    raise SystemExit(1)
PY
python3 - "$glaze_root/CMakeLists.txt" "$glaze_version" <<'PY' || fail "Glaze source version mismatch"
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r"project\s*\(\s*glaze\s+VERSION\s+([^\s)]+)", text, re.IGNORECASE)
if match is None or match.group(1) != sys.argv[2]:
    raise SystemExit(1)
PY
glaze_license="$glaze_root/LICENSE"
[[ -f $glaze_license && ! -L $glaze_license ]] || fail "Glaze license is missing"
verify_file "$glaze_license_sha256" "$glaze_license" || fail "Glaze license digest mismatch"

(
  cd "$source_root"
  git apply --check --no-index --whitespace=error-all "$patch_path"
  git apply --no-index --whitespace=error-all "$patch_path"
  git apply --check --reverse --no-index "$patch_path"
) || fail "could not apply the verified Hyprland patch"

mapfile -t build_package_records < <(python3 - "$build_packages_json" <<'PY'
import json
import sys

packages = json.loads(sys.argv[1])
expected = {
    "base-devel",
    "binutils",
    "cmake",
    "gcc",
    "gcc-libs",
    "glibc",
    "hyprland",
    "hyprland-protocols",
    "make",
    "meson",
    "ninja",
    "pkgconf",
    "xorgproto",
}
if set(packages) != expected:
    raise SystemExit(1)
for name in sorted(packages):
    print(f"{name}|{packages[name]}")
PY
)
(( ${#build_package_records[@]} == 13 )) || fail "unexpected Hyprland buildPackages set"
build_package_specs=()
for record in "${build_package_records[@]}"; do
  IFS='|' read -r package package_version extra <<<"$record"
  [[ -z ${extra:-} && $package =~ ^[a-z0-9@._+-]+$ && $package_version =~ ^[A-Za-z0-9_.+:~-]+$ ]] ||
    fail "invalid Hyprland build package: $record"
  build_package_specs+=("$package=$package_version")
done

# Derive the disposable build-host configuration from the reviewed guest
# configuration. The guest-only Omarchy repository and runtime package holds
# do not belong on the already-synchronized Arch Linux ARM builder.
builder_pacman_config="$stage/builder-pacman.conf"
python3 - "$pacman_config" "$builder_pacman_config" <<'PY' || fail "could not derive the Hyprland builder pacman configuration"
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text().splitlines()
sections = [line[1:-1] for line in source if re.fullmatch(r"\[[A-Za-z0-9@._+-]+\]", line)]
allowed = {"options", "core", "extra", "alarm", "aur", "omarchy", "try-omarchy-abi-pins", "try-omarchy-pinned-cache"}
if not sections or sections[0] != "options" or "omarchy" not in sections or any(s not in allowed for s in sections):
    raise SystemExit(1)

output = []
section = None
for line in source:
    if re.fullmatch(r"\[[A-Za-z0-9@._+-]+\]", line):
        section = line[1:-1]
    # Keep try-omarchy-abi-pins so Hyprland build deps can still resolve
    # libaquamarine.so=13 while ALA only publishes .so=14.
    if section in {"omarchy", "try-omarchy-pinned-cache"} or line.startswith("IgnorePkg"):
        continue
    output.append(line)

pathlib.Path(sys.argv[2]).write_text("\n".join(output).rstrip() + "\n")
PY
chmod 0600 "$builder_pacman_config"
# Docker can reuse a builder layer whose sync databases predate a repository
# move. Refresh them here so an unchanged pinned version is downloaded from its
# current repository path instead of producing mirror-wide 404 responses.
pacman -Syy --noconfirm --config "$builder_pacman_config"
pacman --noconfirm --config "$builder_pacman_config" -S --needed "${build_package_specs[@]}"
for command in cmake cmp readelf strip; do
  command -v "$command" >/dev/null || fail "$command is missing after installing Hyprland build packages"
done
for record in "${build_package_records[@]}"; do
  IFS='|' read -r package package_version <<<"$record"
  query=$(pacman -Q "$package")
  [[ $query == "$package $package_version" ]] || fail "Hyprland build package identity mismatch: $query"
done
if pacman -Q glaze >/dev/null 2>&1; then
  fail "unpinned system Glaze would bypass the verified source extraction"
fi

upstream_query=$(pacman --config "$pacman_config" --root "$root" --dbpath "$root/var/lib/pacman" -Q hyprland)
[[ $upstream_query == "hyprland $upstream_package_version" ]] ||
  fail "staged root does not contain the expected upstream Hyprland package: $upstream_query"

export SOURCE_DATE_EPOCH="$source_date_epoch"
export CFLAGS="-ffile-prefix-map=$stage=/usr/src/try-omarchy-hyprland -fdebug-prefix-map=$stage=/usr/src/try-omarchy-hyprland"
export CXXFLAGS="$CFLAGS"
jobs=$(nproc 2>/dev/null || getconf NPROCESSORS_CONF)
[[ $jobs =~ ^[1-9][0-9]*$ ]] || fail "could not determine Hyprland build parallelism"
(
  cd "$source_root"
  cmake --no-warn-unused-cli \
    -DCMAKE_BUILD_TYPE:STRING=Release \
    -DCMAKE_INSTALL_PREFIX:STRING=/usr \
    -DCMAKE_SKIP_RPATH=ON \
    -DFETCHCONTENT_SOURCE_DIR_GLAZE:PATH="$glaze_root" \
    -S . \
    -B build
  grep -Fq -- "$glaze_root/include" build/compile_commands.json ||
    fail "Hyprland configure did not use the verified Glaze extraction"
  cmake --build build --config Release --target all -j"$jobs"
)

built_binary="$source_root/build/Hyprland"
[[ -x $built_binary ]] || fail "Hyprland build did not produce an executable"
verify_arm64_elf() {
  local path=$1
  python3 - "$path" <<'PY'
import pathlib
import sys

header = pathlib.Path(sys.argv[1]).read_bytes()[:20]
if len(header) != 20 or header[:6] != b"\x7fELF\x02\x01" or int.from_bytes(header[18:20], "little") != 183:
    raise SystemExit(1)
PY
}
verify_arm64_elf "$built_binary" || fail "Hyprland build is not an ARM64 ELF binary"
strip --strip-unneeded "$built_binary"
verify_arm64_elf "$built_binary" || fail "stripped Hyprland build is not an ARM64 ELF binary"
dynamic_section=$(readelf -d "$built_binary")
[[ $dynamic_section != *"(RPATH)"* && $dynamic_section != *"(RUNPATH)"* ]] ||
  fail "Hyprland build contains a forbidden runtime search path"
version_runtime_dir="$stage/xdg-runtime"
install -d -m 0700 "$version_runtime_dir"
built_version=$(XDG_RUNTIME_DIR="$version_runtime_dir" "$built_binary" --version)
[[ $built_version == "Hyprland $version "* ]] || fail "Hyprland build reported an unexpected version"
built_binary_sha256=$(sha256sum "$built_binary")
built_binary_sha256=${built_binary_sha256%% *}
[[ $built_binary_sha256 == "$binary_sha256" ]] ||
  fail "Hyprland reproducible binary digest mismatch: $built_binary_sha256"

package_cache="$work/pacman-cache"
[[ -d $package_cache ]] || fail "signed pacman cache is missing: $package_cache"
upstream_candidates=()
for extension in xz zst; do
  candidate="$package_cache/hyprland-$upstream_package_version-aarch64.pkg.tar.$extension"
  [[ -e $candidate ]] || continue
  [[ -f $candidate && ! -L $candidate ]] || fail "unsafe upstream package cache entry: $candidate"
  upstream_candidates+=("$candidate")
done
(( ${#upstream_candidates[@]} == 1 )) ||
  fail "expected one cached upstream Hyprland package, found ${#upstream_candidates[@]}"
upstream_package=${upstream_candidates[0]}
verify_file "$upstream_package_sha256" "$upstream_package" || fail "upstream package digest mismatch"

upstream_tar="$stage/upstream-hyprland.tar"
case "$upstream_package" in
  *.pkg.tar.xz)
    xz --decompress --stdout "$upstream_package" >"$upstream_tar"
    ;;
  *.pkg.tar.zst)
    zstd --decompress --stdout "$upstream_package" >"$upstream_tar"
    ;;
  *)
    fail "unsupported upstream Hyprland package compression"
    ;;
esac
[[ -s $upstream_tar && ! -L $upstream_tar ]] || fail "could not decompress upstream Hyprland package"

python3 - "$upstream_tar" "$upstream_package_version" "$license" <<'PY' || fail "upstream Hyprland package has an unsafe member set"
import pathlib
import sys
import tarfile

archive = pathlib.Path(sys.argv[1])
expected_version = sys.argv[2]
expected_license = sys.argv[3]
allowed_metadata = {".BUILDINFO", ".MTREE", ".PKGINFO"}
required_files = {
    ".PKGINFO",
    "usr/bin/Hyprland",
    "usr/include/hyprland/src/render/OpenGL.hpp",
    "usr/include/hyprland/src/render/Shader.hpp",
    "usr/include/hyprland/src/render/pass/TexPassElement.hpp",
    "usr/include/hyprland/src/render/shaders/border.glsl.inc",
    "usr/include/hyprland/src/render/shaders/ext.frag.inc",
    "usr/include/hyprland/src/render/shaders/rounding.glsl.inc",
    "usr/include/hyprland/src/render/shaders/surface.frag.inc",
    "usr/share/licenses/hyprland/LICENSE",
}
seen = set()
regular_files = set()
symlinks = set()
with tarfile.open(archive, "r:") as package:
    members = package.getmembers()
    if not members:
        raise SystemExit(1)
    for member in members:
        name = member.name[:-1] if member.isdir() and member.name.endswith("/") else member.name
        if not name or name.startswith("/") or any(ord(character) < 32 or ord(character) == 127 for character in name):
            raise SystemExit(1)
        raw_parts = name.split("/")
        path = pathlib.PurePosixPath(name)
        if (
            any(part in {"", ".", ".."} for part in raw_parts)
            or path.as_posix() != name
            or name in seen
            or (path.parts[0] != "usr" and name not in allowed_metadata)
            or not (member.isfile() or member.isdir() or member.issym())
        ):
            raise SystemExit(1)
        seen.add(name)
        if member.isfile():
            regular_files.add(name)
        elif member.issym():
            symlinks.add(name)
            if name != "usr/bin/hyprland" or member.linkname not in {"Hyprland", "/usr/bin/Hyprland"}:
                raise SystemExit(1)

    for name in seen:
        parts = pathlib.PurePosixPath(name).parts
        for index in range(1, len(parts)):
            if pathlib.PurePosixPath(*parts[:index]).as_posix() in symlinks:
                raise SystemExit(1)
    if not required_files <= regular_files:
        raise SystemExit(1)

    pkginfo = package.extractfile(package.getmember(".PKGINFO"))
    if pkginfo is None:
        raise SystemExit(1)
    fields = {}
    for raw_line in pkginfo.read().decode("utf-8").splitlines():
        if not raw_line or raw_line.startswith("#"):
            continue
        key, separator, value = raw_line.partition(" = ")
        if not separator or not key or not value:
            raise SystemExit(1)
        fields.setdefault(key, []).append(value)

    def exactly(key, value):
        return fields.get(key) == [value]

    if not (
        exactly("pkgname", "hyprland")
        and exactly("pkgbase", "hyprland")
        and exactly("pkgver", expected_version)
        and exactly("arch", "aarch64")
        and fields.get("license") == [expected_license]
        and fields.get("depend")
        and "wayland-compositor" in fields.get("provides", [])
    ):
        raise SystemExit(1)
PY

package_root="$stage/package-root"
install -d -m 0755 "$package_root"
tar --extract --file "$upstream_tar" --no-same-owner --directory "$package_root"

header_paths=(
  src/render/OpenGL.hpp
  src/render/Shader.hpp
  src/render/pass/TexPassElement.hpp
  src/render/shaders/border.glsl.inc
  src/render/shaders/ext.frag.inc
  src/render/shaders/rounding.glsl.inc
  src/render/shaders/surface.frag.inc
)
[[ -f $package_root/usr/bin/Hyprland && ! -L $package_root/usr/bin/Hyprland ]] ||
  fail "upstream package executable is unsafe"
install -m 0755 "$built_binary" "$package_root/usr/bin/Hyprland"
for header in "${header_paths[@]}"; do
  source_header="$source_root/$header"
  packaged_header="$package_root/usr/include/hyprland/$header"
  [[ -f $source_header && ! -L $source_header ]] || fail "patched Hyprland header is missing: $header"
  [[ -f $packaged_header && ! -L $packaged_header ]] || fail "upstream Hyprland header is unsafe: $header"
  install -m 0644 "$source_header" "$packaged_header"
  cmp -s "$source_header" "$packaged_header" || fail "could not overlay patched Hyprland header: $header"
done
install -m 0644 "$glaze_license" "$package_root/usr/share/licenses/hyprland/LICENSE.glaze"
cmp -s "$glaze_license" "$package_root/usr/share/licenses/hyprland/LICENSE.glaze" || fail "could not retain the Glaze license"

rm -f -- "$package_root/.BUILDINFO" "$package_root/.MTREE"
installed_size=$(du -sb "$package_root/usr" | awk '{print $1}')
[[ $installed_size =~ ^[1-9][0-9]*$ ]] || fail "could not determine patched Hyprland installed size"
python3 - "$package_root/.PKGINFO" "$version-$pkgrel" "$repository" "$source_date_epoch" \
  "$installed_size" "$license" <<'PY' || fail "could not adapt upstream Hyprland package metadata"
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
package_version, repository, build_date, installed_size, expected_license = sys.argv[2:]
fields = {}
for raw_line in path.read_text().splitlines():
    if not raw_line or raw_line.startswith("#"):
        continue
    key, separator, value = raw_line.partition(" = ")
    if not separator or not key or not value or "\n" in value or "\r" in value:
        raise SystemExit(1)
    fields.setdefault(key, []).append(value)

def one(key):
    values = fields.get(key)
    if values is None or len(values) != 1:
        raise SystemExit(1)
    return values[0]

if (
    one("pkgname") != "hyprland"
    or one("pkgbase") != "hyprland"
    or one("arch") != "aarch64"
    or fields.get("license") != [expected_license]
    or not fields.get("depend")
):
    raise SystemExit(1)

lines = [
    "pkgname = hyprland",
    "pkgbase = hyprland",
    "xdata = pkgtype=pkg",
    f"pkgver = {package_version}",
    f"pkgdesc = {one('pkgdesc')}",
    f"url = {repository}",
    f"builddate = {build_date}",
    "packager = Try Omarchy reproducible guest builder",
    f"size = {installed_size}",
    "arch = aarch64",
    f"license = {expected_license}",
]
for key in ("group", "provides", "conflict", "replaces", "depend", "optdepend", "backup"):
    lines.extend(f"{key} = {value}" for value in fields.get(key, []))
path.write_text("\n".join(lines) + "\n")
PY

# Rebuild pacman's full-file integrity index after replacing the executable and
# public headers. Normalizing every input timestamp keeps the mtree reproducible
# while allowing `pacman -Qkk` to verify hashes, modes, sizes, and ownership.
find "$package_root" -exec touch -h -d "@$source_date_epoch" {} +
(
  cd "$package_root"
  LC_ALL=C find . -mindepth 1 ! -name .MTREE -print0 |
    LC_ALL=C sort -z |
    bsdtar -cnf - \
      --format=mtree \
      --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' \
      --no-recursion \
      --null \
      --files-from - |
    gzip -n -9 >.MTREE
)
chmod 0644 "$package_root/.MTREE"
[[ -s $package_root/.MTREE && ! -L $package_root/.MTREE ]] || fail "could not generate patched Hyprland mtree"

package_name=hyprland
package_version="$version-$pkgrel"
package_archive="$stage/$package_name-$package_version-aarch64.pkg.tar.zst"
tar \
  --sort=name \
  --mtime="@$source_date_epoch" \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  --format=gnu \
  -C "$package_root" \
  -cf - .PKGINFO .MTREE usr |
  zstd --force --quiet -12 --threads=1 -o "$package_archive"

archive_query=$(pacman --config "$pacman_config" -Qp "$package_archive")
[[ $archive_query == "$package_name $package_version" ]] || fail "local Hyprland package identity mismatch: $archive_query"
pacman \
  --noconfirm \
  --config "$pacman_config" \
  --root "$root" \
  --dbpath "$root/var/lib/pacman" \
  --logfile "$root/var/log/pacman.log" \
  -U "$package_archive"

query=$(pacman --config "$pacman_config" --root "$root" --dbpath "$root/var/lib/pacman" -Q "$package_name")
[[ $query == "$package_name $package_version" && $query != "$upstream_query" ]] ||
  fail "upstream Hyprland package was not replaced: $query"
pacman --config "$pacman_config" --root "$root" --dbpath "$root/var/lib/pacman" -Qkk "$package_name" >/dev/null ||
  fail "installed Hyprland package failed its ownership check"
verify_file "$built_binary_sha256" "$root/usr/bin/Hyprland" || fail "installed Hyprland binary digest mismatch"
for header in "${header_paths[@]}"; do
  cmp -s "$source_root/$header" "$root/usr/include/hyprland/$header" ||
    fail "installed Hyprland header differs from the patched source: $header"
done
cmp -s "$glaze_license" "$root/usr/share/licenses/hyprland/LICENSE.glaze" || fail "installed Glaze license differs from the verified source"
install -d -m 0700 "$root/run/try-omarchy-hyprland-check"
installed_version=$(arch-chroot "$root" env XDG_RUNTIME_DIR=/run/try-omarchy-hyprland-check /usr/bin/Hyprland --version)
rm -rf -- "$root/run/try-omarchy-hyprland-check"
[[ $installed_version == "Hyprland $version "* ]] || fail "installed Hyprland reported an unexpected identity"

repo_dir="$root/usr/share/try-omarchy/repo"
install -d -m 0755 "$repo_dir"
repo_archive="$repo_dir/$(basename "$package_archive")"
[[ ! -L $repo_archive ]] || fail "refusing symlinked immutable repository archive"
install -m 0644 "$package_archive" "$repo_archive"
verify_file "$(sha256sum "$package_archive" | awk '{print $1}')" "$repo_archive" ||
  fail "immutable repository Hyprland archive copy mismatch"

echo "Registered $query from verified Hyprland $commit with Glaze $glaze_commit for $issue (binary $built_binary_sha256)"
