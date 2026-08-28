#!/bin/bash

# Shared manifest and download helpers for the checksum-pinned Homebrew
# arm64_sequoia bottles used by the native runtime. This file is sourced by
# the runtime build scripts; it is not an executable entry point.

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "pinned-runtime-bottles.sh must be sourced" >&2
  exit 64
fi

readonly PINNED_GLIB_ROOT=glib/2.88.3
readonly PINNED_PIXMAN_ROOT=pixman/0.46.4
readonly PINNED_LIBSLIRP_ROOT=libslirp/4.9.4
readonly PINNED_SDL2_ROOT=sdl2-compat/2.32.70
readonly PINNED_SDL3_ROOT=sdl3/3.4.14
readonly PINNED_GETTEXT_ROOT=gettext/1.0
readonly PINNED_PCRE2_ROOT=pcre2/10.47_1
readonly PINNED_ZSTD_ROOT=zstd/1.5.7_1
readonly PINNED_LZ4_ROOT=lz4/1.10.0
readonly PINNED_XZ_ROOT=xz/5.8.3

readonly PINNED_GLIB_ARCHIVE=glib--2.88.3.arm64_sequoia.bottle.1.tar.gz
readonly PINNED_PIXMAN_ARCHIVE=pixman--0.46.4.arm64_sequoia.bottle.1.tar.gz
readonly PINNED_LIBSLIRP_ARCHIVE=libslirp--4.9.4.arm64_sequoia.bottle.tar.gz
readonly PINNED_SDL2_ARCHIVE=sdl2-compat--2.32.70.arm64_sequoia.bottle.tar.gz
readonly PINNED_SDL3_ARCHIVE=sdl3--3.4.14.arm64_sequoia.bottle.tar.gz
readonly PINNED_GETTEXT_ARCHIVE=gettext--1.0.arm64_sequoia.bottle.1.tar.gz
readonly PINNED_PCRE2_ARCHIVE=pcre2--10.47_1.arm64_sequoia.bottle.tar.gz
readonly PINNED_ZSTD_ARCHIVE=zstd--1.5.7_1.arm64_sequoia.bottle.tar.gz
readonly PINNED_LZ4_ARCHIVE=lz4--1.10.0.arm64_sequoia.bottle.1.tar.gz
readonly PINNED_XZ_ARCHIVE=xz--5.8.3.arm64_sequoia.bottle.tar.gz

pinned_core_bottle_manifest() {
  cat <<EOF
glib	2.88.3	$PINNED_GLIB_ARCHIVE	$PINNED_GLIB_ROOT	ca168ac34920f6ee13187d8e88af7d55c50b582fa78a5511e15fe9dd875e8b40
pixman	0.46.4	$PINNED_PIXMAN_ARCHIVE	$PINNED_PIXMAN_ROOT	86f5fc013d2b22bbe41c1c14661287bf8e8e4c3ac95cd05b08b886d24918fe34
libslirp	4.9.4	$PINNED_LIBSLIRP_ARCHIVE	$PINNED_LIBSLIRP_ROOT	78dc33e108213bceb8f4b8a9d0293c0ff578a806ace4dfc4199af8c9714a2ffe
sdl2-compat	2.32.70	$PINNED_SDL2_ARCHIVE	$PINNED_SDL2_ROOT	b5da3b02dfd9a68368f62a317b29f845dad4f29e067fc4aa81a351ca527a82c3
sdl3	3.4.14	$PINNED_SDL3_ARCHIVE	$PINNED_SDL3_ROOT	012d5bb068548cb42df1fd6ab231a8ef76e706a82822d84ed71a10be7f155263
gettext	1.0	$PINNED_GETTEXT_ARCHIVE	$PINNED_GETTEXT_ROOT	dde3cd0db0d7549fadf762b901f8c548dae99e3c592a6e6d41f60e1436253e5e
pcre2	10.47_1	$PINNED_PCRE2_ARCHIVE	$PINNED_PCRE2_ROOT	bef2e718b92e5e819a51723157e60eceb76acc4efb0894a10c315cd36abca13c
zstd	1.5.7_1	$PINNED_ZSTD_ARCHIVE	$PINNED_ZSTD_ROOT	d72adf48460a8384b256f88061cd7b9df4977df7fa2e0794051d427db754a565
lz4	1.10.0	$PINNED_LZ4_ARCHIVE	$PINNED_LZ4_ROOT	5bd143b7b784989e549637ea4e484af85ba481e640dde69bc35f3843ae25abc6
xz	5.8.3	$PINNED_XZ_ARCHIVE	$PINNED_XZ_ROOT	c4be907ac8459f8b3e764c06287cc88b79c1d5c16a2db1c0335e1facf4fd4dbe
EOF
}

# archive name, archive member, destination relative to the runtime root
pinned_runtime_member_manifest() {
  cat <<EOF
$PINNED_GLIB_ARCHIVE	$PINNED_GLIB_ROOT/lib/libglib-2.0.0.dylib	lib/libglib-2.0.0.dylib
$PINNED_PIXMAN_ARCHIVE	$PINNED_PIXMAN_ROOT/lib/libpixman-1.0.dylib	lib/libpixman-1.0.dylib
$PINNED_LIBSLIRP_ARCHIVE	$PINNED_LIBSLIRP_ROOT/lib/libslirp.0.dylib	lib/libslirp.0.dylib
$PINNED_SDL2_ARCHIVE	$PINNED_SDL2_ROOT/lib/libSDL2-2.0.0.dylib	lib/libSDL2-2.0.0.dylib
$PINNED_SDL3_ARCHIVE	$PINNED_SDL3_ROOT/lib/libSDL3.0.dylib	lib/libSDL3.dylib
$PINNED_GETTEXT_ARCHIVE	$PINNED_GETTEXT_ROOT/lib/libintl.8.dylib	lib/libintl.8.dylib
$PINNED_PCRE2_ARCHIVE	$PINNED_PCRE2_ROOT/lib/libpcre2-8.0.dylib	lib/libpcre2-8.0.dylib
$PINNED_ZSTD_ARCHIVE	$PINNED_ZSTD_ROOT/bin/zstd	bin/zstd
$PINNED_ZSTD_ARCHIVE	$PINNED_ZSTD_ROOT/lib/libzstd.1.5.7.dylib	lib/libzstd.1.dylib
$PINNED_LZ4_ARCHIVE	$PINNED_LZ4_ROOT/lib/liblz4.1.10.0.dylib	lib/liblz4.1.dylib
$PINNED_XZ_ARCHIVE	$PINNED_XZ_ROOT/lib/liblzma.5.dylib	lib/liblzma.5.dylib
EOF
}

pinned_bottle_sha256() {
  shasum -a 256 "$1" | awk '{ print $1 }'
}

pinned_bottle_download() {
  local formula=$1
  local label=$2
  local expected_sha=$3
  local output=$4
  local token_json
  local token
  local actual_sha

  [[ $formula =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid Homebrew formula name: $formula"
  log "Downloading pinned arm64_sequoia $label bottle"
  token_json=$(curl --fail --location --silent --show-error \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --retry 3 --connect-timeout 20 \
    --get \
    --data-urlencode 'service=ghcr.io' \
    --data-urlencode "scope=repository:homebrew/core/$formula:pull" \
    'https://ghcr.io/token') || die "could not request the $label bottle token"
  token=$(python3 -c '
import json
import sys

try:
    value = json.load(sys.stdin).get("token")
except (AttributeError, json.JSONDecodeError):
    raise SystemExit(1)
if not isinstance(value, str) or not value:
    raise SystemExit(1)
sys.stdout.write(value)
' <<<"$token_json") || die "GHCR returned an invalid token for $label"

  curl --fail --location --silent --show-error \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --retry 3 --connect-timeout 20 \
    --header "Authorization: Bearer $token" \
    --output "$output" \
    "https://ghcr.io/v2/homebrew/core/$formula/blobs/sha256:$expected_sha" || \
    die "could not download the pinned $label bottle"
  actual_sha=$(pinned_bottle_sha256 "$output") || die "could not hash $label"
  [[ $actual_sha == "$expected_sha" ]] || \
    die "$label checksum mismatch: expected $expected_sha, got $actual_sha"
}

pinned_bottle_obtain() {
  local formula=$1
  local label=$2
  local expected_sha=$3
  local output=$4
  local archive_cache=$5
  local cached
  local actual_sha

  if [[ -z $archive_cache ]]; then
    pinned_bottle_download "$formula" "$label" "$expected_sha" "$output"
    return
  fi

  cached="$archive_cache/${output##*/}"
  [[ -f $cached && ! -L $cached ]] || \
    die "archive cache is missing a regular ${output##*/}"
  actual_sha=$(pinned_bottle_sha256 "$cached") || die "could not hash cached $label"
  [[ $actual_sha == "$expected_sha" ]] || \
    die "$label cache checksum mismatch: expected $expected_sha, got $actual_sha"
  log "Using cached pinned arm64_sequoia $label bottle"
  install -m 0644 "$cached" "$output"
}

pinned_bottle_validate_archive() {
  local label=$1
  local archive=$2
  local expected_root=$3

  python3 - "$label" "$archive" "$expected_root" <<'PY'
import posixpath
import sys
import tarfile

label, archive, expected_root = sys.argv[1:]


def fail(message: str) -> None:
    print(f"{label}: {message}", file=sys.stderr)
    raise SystemExit(1)


def normalized(name: str) -> str:
    while name.startswith("./"):
        name = name[2:]
    if not name or name.startswith("/"):
        fail(f"unsafe archive path: {name!r}")
    result = posixpath.normpath(name)
    if result in {"", ".", ".."} or result.startswith("../"):
        fail(f"unsafe archive path: {name!r}")
    return result


try:
    source = tarfile.open(archive, "r:gz")
except (OSError, tarfile.TarError) as error:
    fail(f"not a readable gzip tar archive: {error}")

with source:
    members = source.getmembers()
    if not members:
        fail("archive is empty")
    seen: set[str] = set()
    for member in members:
        name = normalized(member.name)
        if name in seen:
            fail(f"duplicate archive path: {name}")
        seen.add(name)
        if name != expected_root and not name.startswith(expected_root + "/"):
            fail(f"path outside {expected_root}: {name}")
        if member.ischr() or member.isblk() or member.isfifo() or member.isdev():
            fail(f"unsupported special archive member: {name}")
        if member.issym():
            target = normalized(posixpath.join(posixpath.dirname(name), member.linkname))
            if target != expected_root and not target.startswith(expected_root + "/"):
                fail(f"symlink escapes {expected_root}: {name} -> {member.linkname}")
        elif member.islnk():
            target = normalized(member.linkname)
            if target != expected_root and not target.startswith(expected_root + "/"):
                fail(f"hard link escapes {expected_root}: {name} -> {member.linkname}")
PY
}

pinned_bottle_require_regular_member() {
  local label=$1
  local archive=$2
  local member=$3

  python3 - "$label" "$archive" "$member" <<'PY'
import sys
import tarfile

label, archive, expected = sys.argv[1:]
with tarfile.open(archive, "r:gz") as source:
    matches = [member for member in source.getmembers() if member.name.lstrip("./") == expected]
if len(matches) != 1 or not matches[0].isfile():
    print(f"{label} must contain exactly one regular {expected}", file=sys.stderr)
    raise SystemExit(1)
PY
}
