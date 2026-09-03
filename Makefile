SHELL := /bin/bash

override ROOT := $(realpath $(dir $(lastword $(MAKEFILE_LIST))))
override DIST := $(ROOT)/dist
override GUEST_DIST := $(DIST)/guest
override APP := $(DIST)/app.noindex/Try Omarchy.app
override DMG := $(DIST)/TryOmarchy.dmg
override BUILD_CACHE := $(ROOT)/scripts/build-cache.py
override BUILD_STATE := $(ROOT)/.build/state
RELEASE_SIGN_IDENTITY ?= Developer ID Application: Eduardo Martinez (RZC79MPD34)
RELEASE_NOTARY_PROFILE ?= try-omarchy
DEVELOPMENT_SIGN_IDENTITY ?= -
PACKAGE_SIGN_IDENTITY ?= $(RELEASE_SIGN_IDENTITY)
PACKAGE_NOTARY_PROFILE ?= $(RELEASE_NOTARY_PROFILE)
FORCE ?= 0

.DEFAULT_GOAL := help
.PHONY: help doctor test guest runtime app build run run-ephemeral reset update-omarchy package package-preflight release release-preflight clean clean-all clean-guest

help:
	@printf '%s\n' \
	  'Try Omarchy — native macOS build commands' \
	  '' \
	  '  make doctor         Check the local toolchain' \
	  '  make test           Run native and guest contract tests' \
	  '  make build          Build only changed guest, runtime, and app inputs' \
	  '  make build FORCE=1  Rebuild every component' \
	  '  make run            Build the app from existing artifacts and open it' \
	  '  make run DEVELOPMENT_SIGN_IDENTITY="Apple Development: ..."' \
	  '                      Keep macOS privacy grants across local rebuilds' \
	  '  make update-omarchy OMARCHY_RELEASE=x.y.z' \
	  '                      Pin an upstream release and refresh the ARM64 lock' \
	  '  make package        Create a signed and notarized distribution DMG' \
	  '  make release        Create a signed and notarized distribution DMG' \
	  '' \
	  'Component builds:' \
	  '  make guest          Ensure dist/guest is current (Docker)' \
	  '  make runtime        Ensure macos/.build/qemu-gpu-runtime is current' \
	  '  make app            Ensure both artifacts and the app are current' \
	  '' \
	  'Storage:' \
	  '  make run-ephemeral  Run without retaining VM changes' \
	  '  make reset          Open the confirmed factory-reset flow' \
	  '  make clean          Remove all project builds and build caches' \
	  '  make clean-all      Also remove VM data and stale temporary files'

doctor:
	@[[ "$$(uname -s)" == Darwin ]] || { echo 'error: macOS is required' >&2; exit 1; }
	@[[ "$$(uname -m)" == arm64 ]] || { echo 'error: an Apple Silicon Mac is required' >&2; exit 1; }
	@major=$$(sw_vers -productVersion | cut -d. -f1); (( major >= 15 )) || { echo 'error: macOS 15 or newer is required' >&2; exit 1; }
	@for tool in curl docker pkg-config python3 swift xcrun; do command -v "$$tool" >/dev/null || { echo "error: $$tool is required" >&2; exit 1; }; done
	@docker info >/dev/null 2>&1 || { echo 'error: Docker is installed but not running' >&2; exit 1; }
	@printf 'Toolchain ready: %s (%s)\n' "$$(sw_vers -productVersion)" "$$(uname -m)"

test:
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/tests/test-build-cache.py"
	@PYTHONDONTWRITEBYTECODE=1 python3 "$(ROOT)/tests/test-pack-app-icon.py"
	@$(ROOT)/guest/test
	@$(ROOT)/macos/Tests/macos-compatibility.test.sh
	@$(ROOT)/macos/Tests/runtime-relocation.test.sh
	@mkdir -p $(ROOT)/macos/.build/module-cache/swift $(ROOT)/macos/.build/module-cache/clang
	@cd $(ROOT)/macos && SWIFT_MODULECACHE_PATH=$(ROOT)/macos/.build/module-cache/swift CLANG_MODULE_CACHE_PATH=$(ROOT)/macos/.build/module-cache/clang swift test --disable-sandbox
	@$(ROOT)/macos/Tests/qemu-port-forwarding.test.sh
	@$(ROOT)/macos/Tests/run-qemu-ssh-contract.test.sh
	@$(ROOT)/macos/Tests/qemu-power-actions.test.sh
	@$(ROOT)/macos/Tests/qemu-persistent-storage.test.sh

guest:
	@OMARCHY_FORCE_BUILD="$(FORCE)" "$(BUILD_CACHE)" \
	  --root "$(ROOT)" --state-dir "$(BUILD_STATE)" guest -- \
	  "$(ROOT)/guest/build-container.sh" --output "$(GUEST_DIST)"

runtime:
	@OMARCHY_FORCE_BUILD="$(FORCE)" "$(BUILD_CACHE)" \
	  --root "$(ROOT)" --state-dir "$(BUILD_STATE)" runtime -- \
	  "$(ROOT)/macos/build-qemu-gpu-runtime.sh"

app: guest runtime
	@OMARCHY_FORCE_BUILD="$(FORCE)" \
	  OMARCHY_CODESIGN_IDENTITY="$(DEVELOPMENT_SIGN_IDENTITY)" \
	  "$(BUILD_CACHE)" \
	  --root "$(ROOT)" --state-dir "$(BUILD_STATE)" app -- \
	  "$(ROOT)/macos/build-app.sh" --guest-dir "$(GUEST_DIST)"

build: doctor app
	@printf 'Build output: %s\n' "$(APP)"

run: app
	@$(ROOT)/macos/open-qemu-gpu.sh

run-ephemeral: app
	@$(ROOT)/macos/open-qemu-gpu.sh --ephemeral

reset: app
	@$(ROOT)/macos/open-qemu-gpu.sh --reset-storage

update-omarchy:
	@[[ -n "$(strip $(OMARCHY_RELEASE))" ]] || { echo 'error: OMARCHY_RELEASE=x.y.z is required' >&2; exit 1; }
	@$(ROOT)/guest/scripts/update-upstream-pin.py \
	  --release "$(OMARCHY_RELEASE)" \
	  --spec "$(ROOT)/guest/spec.json" \
	  --cache-dir "$(ROOT)/.build/upstream"
	@$(ROOT)/guest/build-container.sh \
	  --refresh-package-lock "$(ROOT)/guest/packages.lock.json"
	@$(ROOT)/guest/test --source "$(ROOT)/.build/upstream/omarchy-v$(OMARCHY_RELEASE)"

package-preflight:
	@[[ "$(PACKAGE_SIGN_IDENTITY)" == "Developer ID Application:"* ]] || { echo 'error: PACKAGE_SIGN_IDENTITY must be a Developer ID Application identity' >&2; exit 1; }
	@[[ -n "$(strip $(PACKAGE_NOTARY_PROFILE))" ]] || { echo 'error: PACKAGE_NOTARY_PROFILE must name a notarytool keychain profile' >&2; exit 1; }

package: package-preflight
	@$(MAKE) --no-print-directory guest runtime
	@$(ROOT)/macos/build-app.sh \
	  --dmg \
	  --guest-dir "$(GUEST_DIST)" \
	  --sign-identity "$(PACKAGE_SIGN_IDENTITY)" \
	  --notarize-profile "$(PACKAGE_NOTARY_PROFILE)"

release-preflight:
	@[[ "$(RELEASE_SIGN_IDENTITY)" == "Developer ID Application:"* ]] || { echo 'error: RELEASE_SIGN_IDENTITY must be a Developer ID Application identity' >&2; exit 1; }
	@[[ -n "$(strip $(RELEASE_NOTARY_PROFILE))" ]] || { echo 'error: RELEASE_NOTARY_PROFILE must name a notarytool keychain profile' >&2; exit 1; }

release: release-preflight
	@$(MAKE) --no-print-directory guest runtime
	@$(ROOT)/macos/build-app.sh \
	  --dmg \
	  --guest-dir "$(GUEST_DIST)" \
	  --sign-identity "$(RELEASE_SIGN_IDENTITY)" \
	  --notarize-profile "$(RELEASE_NOTARY_PROFILE)"

clean:
	@echo 'Removing repository build output and caches...'
	@rm -rf -- \
	  "$(DIST)" \
	  "$(ROOT)/.build" \
	  "$(ROOT)/guest/.work" \
	  "$(ROOT)/macos/.build" \
	  "$(ROOT)/macos/.swiftpm"
	@find "$(ROOT)" -type d \( -name __pycache__ -o -name .pytest_cache \) \
	  -prune -exec rm -rf -- {} +
	@set -e; if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then \
	  while IFS= read -r container; do \
	    [[ -z "$$container" ]] || docker container rm "$$container" >/dev/null; \
	  done < <(docker container ls -aq --filter ancestor=try-omarchy-guest-builder); \
	  while IFS= read -r volume; do \
	    [[ -z "$$volume" ]] || docker volume rm "$$volume" >/dev/null; \
	  done < <(docker volume ls -q --filter label=dev.tryomarchy.role=guest-work); \
	  docker image rm -f try-omarchy-guest-builder >/dev/null 2>&1 || true; \
	  echo 'Removed Try Omarchy Docker builder image and guest-work volumes.'; \
	else \
	  echo 'Docker is unavailable; skipped project Docker cache cleanup.' >&2; \
	fi

clean-all:
	@[[ "$$(uname -s)" == Darwin ]] || { echo 'error: make clean-all requires macOS' >&2; exit 1; }
	@pgrep -f 'omarchy-[q]emu|omarchy-[d]mg|Try Omarchy[.]app/Contents/' >/dev/null 2>&1; status=$$?; \
	if (( status == 0 )); then \
	  echo 'error: Try Omarchy or one of its build tools is running; close it before make clean-all' >&2; \
	  exit 1; \
	elif (( status != 1 )); then \
	  echo 'error: could not safely inspect running processes' >&2; \
	  exit 1; \
	fi
	@confirmation=''; \
	if ! { \
	  printf '%s\n%s' \
	    'This permanently deletes all Try Omarchy builds, caches, VM disks, and app state.' \
	    'Type clean-all to continue: ' >/dev/tty && \
	  IFS= read -r confirmation </dev/tty; \
	}; then \
	  echo 'error: make clean-all requires an interactive terminal' >&2; \
	  exit 1; \
	fi; \
	[[ "$$confirmation" == clean-all ]] || { echo 'Cleanup cancelled.' >&2; exit 1; }
	@$(MAKE) --no-print-directory clean
	@user_home=$$(python3 -c 'import os,pwd; print(pwd.getpwuid(os.getuid()).pw_dir)'); \
	  [[ "$$user_home" == /* && "$$user_home" != / ]] || { echo 'error: could not resolve a safe user home' >&2; exit 1; }; \
	  app_support="$$user_home/Library/Application Support/Try Omarchy"; \
	  cache="$$user_home/Library/Caches/dev.tryomarchy.native"; \
	  preferences="$$user_home/Library/Preferences/dev.tryomarchy.native.plist"; \
	  saved_state="$$user_home/Library/Saved Application State/dev.tryomarchy.native.savedState"; \
	  echo "Removing persistent VM disks and app state from $$app_support..."; \
	  rm -rf -- "$$app_support" "$$cache" "$$preferences" "$$saved_state"
	@user_id=$$(id -u); \
	  find /private/tmp -maxdepth 1 -user "$$user_id" \
	    \( -name 'omarchy-qemu-source-build.*' \
	       -o -name 'omarchy-qemu-gpu-runtime.*' \
	       -o -name 'omarchy-qemu-gpu.??????' \
	       -o -name 'omarchy-qemu-storage-test.??????' \
	       -o -name 'omarchy-dmg.*' \) \
	    -exec rm -rf -- {} +; \
	  user_tmp=$$(getconf DARWIN_USER_TEMP_DIR); \
	  [[ "$$user_tmp" == /* && "$$user_tmp" != / && "$$user_tmp" != /private/tmp/ ]] || { echo 'error: could not resolve a safe user temporary directory' >&2; exit 1; }; \
	  find "$$user_tmp" -maxdepth 1 -user "$$user_id" \
	    \( -name 'omarchy-qemu-request-*' \
	       -o -name 'omarchy-qemu-path-*' \
	       -o -name 'omarchy-audio-route-tests.*' \
	       -o -name 'try-omarchy-space-estimate-*' \) \
	    -exec rm -rf -- {} +
	@echo 'Try Omarchy deep cleanup complete.'

clean-guest: clean
	@echo 'make clean-guest is now an alias for make clean.'
