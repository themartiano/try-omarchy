#!/bin/bash
# Called by omarchy-refresh-pacman after it copies the x86_64 channel template
# to /etc and before pacman -Syyuu. Restore the ARM factory files so the
# upgrade uses Arch Linux ARM plus the local try-omarchy repo.
set -euo pipefail

sudo install -m 0644 /usr/share/try-omarchy/pacman.conf /etc/pacman.conf
sudo install -m 0644 /usr/share/try-omarchy/mirrorlist /etc/pacman.d/mirrorlist
