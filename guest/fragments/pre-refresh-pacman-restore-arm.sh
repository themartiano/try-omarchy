#!/bin/bash

# Omarchy copies its x86_64 channel template to /etc immediately before this
# hook runs. Restore the final ARM configuration assembled by Try Omarchy so
# pacman refreshes Arch Linux ARM, the keyring-only Omarchy repository, and the
# immutable local repository instead.
set -euo pipefail

sudo install -m 0644 /usr/share/try-omarchy/pacman.conf /etc/pacman.conf
sudo install -m 0644 /usr/share/try-omarchy/mirrorlist /etc/pacman.d/mirrorlist
