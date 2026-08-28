#!/bin/bash

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd -P)
native_dir=$(cd "$test_dir/.." && pwd -P)
bundler="$native_dir/bundle-macho-dependencies.sh"
compatibility_verifier="$native_dir/verify-macos-compatibility.sh"

fail() {
  echo "runtime-relocation.test: $*" >&2
  exit 1
}

assert_fails_with() {
  local expected=$1
  shift
  local output
  if output=$("$@" 2>&1); then
    fail "command unexpectedly succeeded: $*"
  fi
  [[ $output == *"$expected"* ]] || \
    fail "failure did not contain [$expected]: $output"
}

test_root=$(mktemp -d /private/tmp/omarchy-runtime-relocation-test.XXXXXX)
case "$test_root" in
  /private/tmp/omarchy-runtime-relocation-test.??????) ;;
  *) fail "unexpected test root: $test_root" ;;
esac
cleanup() {
  local exit_status=$?
  trap - EXIT HUP INT TERM
  rm -rf -- "$test_root"
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

runtime="$test_root/runtime with spaces"
missing_runtime="$test_root/missing-runtime"
mkdir -p "$runtime/bin" "$runtime/lib" "$missing_runtime/bin" "$missing_runtime/lib"

clang -arch arm64 -mmacosx-version-min=15.0 -dynamiclib \
  -Wl,-headerpad_max_install_names \
  -Wl,-install_name,/private/omarchy-build/libfixture.dylib \
  -x c - -o "$runtime/lib/libfixture.dylib" <<'EOF'
int omarchy_fixture_value(void) { return 42; }
EOF

for output in "$runtime/bin/fixture" "$missing_runtime/bin/fixture"; do
  clang -arch arm64 -mmacosx-version-min=15.0 \
    -Wl,-headerpad_max_install_names \
    -Wl,-rpath,/private/omarchy-build \
    "$runtime/lib/libfixture.dylib" -x c - -o "$output" <<'EOF'
extern int omarchy_fixture_value(void);
int main(void) { return omarchy_fixture_value() == 42 ? 0 : 1; }
EOF
done

assert_fails_with 'external dependency remains' \
  "$bundler" --verify-only "$runtime"
assert_fails_with 'needs an unstaged library' "$bundler" "$missing_runtime"

"$bundler" "$runtime" >/dev/null
codesign --force --sign - "$runtime/lib/libfixture.dylib" >/dev/null
codesign --force --sign - "$runtime/bin/fixture" >/dev/null
"$bundler" --verify-only "$runtime" >/dev/null
"$compatibility_verifier" "$runtime" >/dev/null
"$runtime/bin/fixture"

dependencies=$(otool -L "$runtime/bin/fixture")
[[ $dependencies == *'@executable_path/../lib/libfixture.dylib'* ]] || \
  fail "executable dependency was not relocated"
[[ $dependencies != *'/private/omarchy-build/'* ]] || \
  fail "executable retained its build-machine dependency"

echo 'runtime relocation tests passed'
