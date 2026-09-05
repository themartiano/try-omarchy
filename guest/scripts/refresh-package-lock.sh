#!/bin/bash

# Resolve, but do not download, the complete package transaction. Write to a
# review path first; replacing the checked-in lock is an intentional update.
set -euo pipefail

usage() {
  echo "Usage: refresh-package-lock.sh [--source OMARCHY_SOURCE] [--spec FILE] --output FILE"
}

fail() {
  echo "refresh-package-lock: $*" >&2
  exit 1
}

script_dir=$(cd "$(dirname "$0")" && pwd)
guest_dir=$(cd "$script_dir/.." && pwd)
source_dir=""
spec="$guest_dir/spec.json"
output=""

while (($#)); do
  case "$1" in
    --source)
      source_dir=${2:-}
      shift 2
      ;;
    --output)
      output=${2:-}
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

[[ -f $spec ]] || fail "--spec must be a build spec"
spec=$(cd "$(dirname "$spec")" && pwd)/$(basename "$spec")
architecture=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["image"]["architecture"])' "$spec")
packages_input=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["inputs"]["packages"])' "$spec")
packages_file="$guest_dir/$packages_input"
[[ $architecture == "aarch64" ]] || fail "native guest architecture must be aarch64"
[[ -f $packages_file ]] || fail "package list not found: $packages_file"
[[ -n $output ]] || fail "--output is required"
[[ $(uname -s) == "Linux" && $(uname -m) == "$architecture" ]] \
  || fail "run on $architecture Linux (the matching builder container is fine)"
(( EUID == 0 )) || fail "run as root so pacman can refresh its isolated databases"

pacman_input=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["inputs"].get("pacmanConfig", ""))' "$spec")
if [[ -n $pacman_input ]]; then
  upstream_pacman_config="$guest_dir/$pacman_input"
else
  [[ -n $source_dir && -d $source_dir/.git ]] || fail "--source must be the pinned Omarchy checkout"
  upstream_pacman_config="$source_dir/default/pacman/pacman-stable.conf"
fi
[[ -f $upstream_pacman_config ]] || fail "pacman configuration not found: $upstream_pacman_config"

temporary=$(mktemp -d)
cleanup() {
  rm -rf "$temporary"
}
trap cleanup EXIT
chmod 0755 "$temporary"
mkdir -p "$temporary/db"
chmod 0755 "$temporary/db"
config="$temporary/pacman.conf"
package_lock_input=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["inputs"]["packageLock"])' "$spec")
package_lock_file="$guest_dir/$package_lock_input"
[[ -f $package_lock_file ]] || fail "package lock not found: $package_lock_file"

builder_conf_args=(
  python3 "$script_dir/write-builder-pacman-conf.py"
  --spec "$spec"
  --guest-dir "$guest_dir"
  --guest-config "$upstream_pacman_config"
  --package-lock "$package_lock_file"
  --output "$config"
)
if [[ ${OMARCHY_PACMAN_DISABLE_SANDBOX:-0} == "1" ]]; then
  builder_conf_args+=(--disable-sandbox)
fi
abi_pin_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("inputs", {}).get("abiPackagePins", [])))' "$spec")
if (( abi_pin_count > 0 )); then
  builder_conf_args+=(--abi-repo "$temporary/abi-pin-repo")
fi
"${builder_conf_args[@]}" || fail "could not derive the factory builder pacman configuration"

pacman -Syy --noconfirm --config "$config" \
  --dbpath "$temporary/db" --logfile "$temporary/pacman.log"
python3 "$script_dir/resolve-package-lock.py" \
  --config "$config" \
  --dbpath "$temporary/db" \
  --packages "$packages_file" \
  --output "$temporary/resolved.json"

mkdir -p "$(dirname "$output")"
install -m 0644 "$temporary/resolved.json" "$output"
echo "Wrote reviewable package lock to $output"
