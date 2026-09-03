#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: materialize-omarchy.sh --root ROOT --source OMARCHY_SOURCE [--spec SPEC]

Installs the pinned, authentic Omarchy source tree into a staged rootfs. This
step only copies files, so it can also be exercised on macOS during validation.
USAGE
}

fail() {
  echo "materialize-omarchy: $*" >&2
  exit 1
}

script_dir=$(cd "$(dirname "$0")" && pwd)
guest_dir=$(cd "$script_dir/.." && pwd)
root=""
source_dir=""
spec="$guest_dir/spec.json"
skip_git_check=0

while (($#)); do
  case "$1" in
    --root)
      root=${2:-}
      shift 2
      ;;
    --source)
      source_dir=${2:-}
      shift 2
      ;;
    --spec)
      spec=${2:-}
      shift 2
      ;;
    --skip-git-check)
      skip_git_check=1
      shift
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

[[ -n $root ]] || fail "--root is required"
[[ -n $source_dir ]] || fail "--source is required"
[[ -f $spec ]] || fail "spec not found: $spec"
[[ -d $source_dir ]] || fail "source not found: $source_dir"
[[ $root == /* ]] || fail "--root must be an absolute path"
case "$root" in
  /|/bin|/boot|/etc|/home|/opt|/root|/usr|/var)
    fail "refusing unsafe root: $root"
    ;;
esac
mkdir -p "$root"

python3 - "$spec" "$source_dir" <<'PY'
import json
import pathlib
import sys

spec = json.loads(pathlib.Path(sys.argv[1]).read_text())
source = pathlib.Path(sys.argv[2])
missing = [path for path in spec["authenticity"]["requiredPaths"] if not (source / path).exists()]
if missing:
    raise SystemExit("missing required upstream paths: " + ", ".join(missing))
version = (source / "version").read_text().strip()
if version != spec["upstream"]["version"]:
    raise SystemExit(f"upstream version mismatch: expected {spec['upstream']['version']}, got {version}")
PY

if (( skip_git_check == 0 )); then
  command -v git >/dev/null || fail "git is required to verify the upstream checkout"
  [[ -d $source_dir/.git ]] || fail "upstream source must be a git checkout"
  expected_commit=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["upstream"]["commit"])' "$spec")
  expected_tree=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["upstream"]["tree"])' "$spec")
  actual_commit=$(git -C "$source_dir" rev-parse HEAD)
  actual_tree=$(git -C "$source_dir" rev-parse 'HEAD^{tree}')
  [[ $actual_commit == "$expected_commit" ]] || fail "commit mismatch: expected $expected_commit, got $actual_commit"
  [[ $actual_tree == "$expected_tree" ]] || fail "tree mismatch: expected $expected_tree, got $actual_tree"
  [[ -z $(git -C "$source_dir" status --porcelain --untracked-files=all) ]] || fail "upstream checkout has local or untracked changes"
fi

copy_tree() {
  local from=$1
  local to=$2
  rm -rf "$to"
  mkdir -p "$(dirname "$to")"
  cp -a "$from" "$to"
}

copy_contents() {
  local from=$1
  local to=$2
  mkdir -p "$to"
  cp -a "$from/." "$to/"
}

install_file() {
  local mode=$1
  local from=$2
  local to=$3
  mkdir -p "$(dirname "$to")"
  install -m "$mode" "$from" "$to"
}

omarchy_root="$root/usr/share/omarchy"
rm -rf "$omarchy_root"
mkdir -p "$omarchy_root/bin" "$omarchy_root/themes"

# Match the upstream package's runtime layout. Every copied byte comes from the
# pinned Basecamp repository; the web-only profile is applied later in /etc/skel.
for tree in config default install migrations shell applications; do
  copy_tree "$source_dir/$tree" "$omarchy_root/$tree"
done

while IFS= read -r theme; do
  [[ -n $theme ]] || continue
  copy_tree "$source_dir/themes/$theme" "$omarchy_root/themes/$theme"
done < <(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["themes"]))' "$spec")

for file in icon.png icon.txt logo.svg logo.txt version; do
  install_file 0644 "$source_dir/$file" "$omarchy_root/$file"
done
install_file 0644 "$source_dir/LICENSE" "$root/usr/share/licenses/omarchy/LICENSE"

# Production Omarchy exposes commands in /usr/bin and keeps package-path
# symlinks for code that resolves $OMARCHY_PATH/bin explicitly.
while IFS= read -r command; do
  name=$(basename "$command")
  install_file 0755 "$command" "$root/usr/bin/$name"
  ln -s "/usr/bin/$name" "$omarchy_root/bin/$name"
done < <(find "$source_dir/bin" -maxdepth 1 -type f | sort)

# Seed new users exactly like omarchy-settings does.
rm -rf "$root/etc/skel/.config"
copy_tree "$source_dir/config" "$root/etc/skel/.config"
install_file 0644 "$source_dir/default/bashrc" "$root/etc/skel/.bashrc"
mkdir -p "$root/etc/skel/.local/share/applications"
copy_contents "$source_dir/applications" "$root/etc/skel/.local/share/applications"
# Presence of a file here enables that Hyprland flag. default/hypr/toggles is
# the catalog (window-no-gaps, 1:1 single window), not the factory default.
# flags.lua is a no-op sentinel so the directory is not empty; copy only that.
mkdir -p "$root/etc/skel/.local/state/omarchy/toggles/hypr"
install_file 0644 "$source_dir/default/hypr/toggles/flags.lua" \
  "$root/etc/skel/.local/state/omarchy/toggles/hypr/flags.lua"

if [[ -d $source_dir/default/nautilus-python/extensions ]]; then
  copy_tree "$source_dir/default/nautilus-python/extensions" "$root/etc/skel/.local/share/nautilus-python/extensions"
fi
if [[ -f $source_dir/default/tensaku/state.toml ]]; then
  install_file 0644 "$source_dir/default/tensaku/state.toml" "$root/etc/skel/.local/state/tensaku/state.toml"
fi
mkdir -p "$root/etc/skel/.config/omarchy/branding"
install_file 0644 "$source_dir/logo.txt" "$root/etc/skel/.config/omarchy/branding/about.txt"
install_file 0644 "$source_dir/icon.txt" "$root/etc/skel/.config/omarchy/branding/screensaver.txt"
ln -sfn /usr/share/omarchy "$root/etc/skel/.local/share/omarchy"

# Package-owned integration points needed by the real session.
install_file 0644 "$source_dir/default/uwsm/env.d/10-omarchy" "$root/usr/share/uwsm/env.d/10-omarchy"
copy_contents "$source_dir/default/environment.d" "$root/usr/lib/environment.d"
install_file 0644 "$source_dir/default/fontconfig/conf.avail/50-omarchy.conf" "$root/usr/share/fontconfig/conf.avail/50-omarchy.conf"
mkdir -p "$root/etc/fonts/conf.d"
ln -sfn /usr/share/fontconfig/conf.avail/50-omarchy.conf "$root/etc/fonts/conf.d/50-omarchy.conf"
copy_contents "$source_dir/default/xdg-terminal-exec" "$root/usr/share/xdg-terminal-exec"
install_file 0644 "$source_dir/default/applications/mimeapps.list" "$root/usr/share/applications/mimeapps.list"
copy_contents "$source_dir/default/systemd/user" "$root/usr/lib/systemd/user"
copy_contents "$source_dir/default/systemd/user@.service.d" "$root/usr/lib/systemd/system/user@.service.d"
copy_contents "$source_dir/default/systemd/zram-generator.conf.d" "$root/usr/lib/systemd/zram-generator.conf.d"
install_file 0644 "$source_dir/default/systemd/faster-shutdown.conf" "$root/etc/systemd/system.conf.d/10-faster-shutdown.conf"
install_file 0644 "$source_dir/default/wayland-sessions/omarchy.desktop" "$root/usr/local/share/wayland-sessions/omarchy.desktop"
install_file 0644 "$source_dir/default/fonts/omarchy/omarchy.ttf" "$root/usr/share/fonts/omarchy/omarchy.ttf"
install_file 0644 "$source_dir/etc/profile.d/omarchy.sh" "$root/etc/profile.d/omarchy.sh"
install_file 0644 "$source_dir/etc/fastfetch/config.jsonc" "$root/etc/fastfetch/config.jsonc"

# Preserve the application metadata and artwork used by Quickshell's real app
# provider. Normalize display-style artwork names to the lowercase, hyphenated
# icon identifiers used by the desktop files and accepted by GTK's icon cache.
mkdir -p "$root/usr/share/icons/hicolor/256x256/apps"
while IFS= read -r icon; do
  icon_name=$(basename "$icon" | LC_ALL=C tr '[:upper:] ' '[:lower:]-')
  icon_target="$root/usr/share/icons/hicolor/256x256/apps/$icon_name"
  [[ ! -e $icon_target ]] || fail "normalized icon name collides: $icon_name"
  install_file 0644 "$icon" "$icon_target"
done < <(find "$source_dir/applications/icons" -maxdepth 1 -type f | sort)
install_file 0644 "$source_dir/icon.png" "$root/usr/share/pixmaps/omarchy.png"
install_file 0644 "$source_dir/icon.png" "$root/usr/share/icons/hicolor/256x256/apps/omarchy.png"

# These are package scriptlet sources used by Omarchy's own reset/refresh
# commands. They stay authentic without overwriting the factory image's /etc files.
mkdir -p "$omarchy_root/etc-overrides"
install_file 0644 "$source_dir/default/bashrc" "$omarchy_root/etc-overrides/dot.bashrc"
install_file 0644 "$source_dir/etc/nsswitch.conf" "$omarchy_root/etc-overrides/nsswitch.conf"
install_file 0644 "$source_dir/etc/security/faillock.conf" "$omarchy_root/etc-overrides/security-faillock.conf"
install_file 0644 "$source_dir/etc/plymouth/plymouthd.conf" "$omarchy_root/etc-overrides/plymouth-plymouthd.conf"

mkdir -p "$root/usr/share/try-omarchy"
install_file 0644 "$spec" "$root/usr/share/try-omarchy/build-spec.json"
if [[ -d $source_dir/.git && $skip_git_check == 0 ]]; then
  python3 "$guest_dir/scripts/source-digest.py" \
    --source "$source_dir" \
    --output "$root/usr/share/try-omarchy/upstream-tree.json"
  expected_digest=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["upstream"]["treeSha256"])' "$spec")
  actual_digest=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' "$root/usr/share/try-omarchy/upstream-tree.json")
  [[ $actual_digest == "$expected_digest" ]] || fail "normalized source digest mismatch: expected $expected_digest, got $actual_digest"
fi

echo "Materialized Omarchy $(cat "$source_dir/version") at $omarchy_root"
