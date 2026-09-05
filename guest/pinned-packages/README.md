# Reviewed ABI package pins

Archives here are factory-build inputs for packages Arch Linux ARM no longer
publishes at the SONAME the locked Hyprland stack still requires.

They are digested in `guest/spec.json` (`inputs.abiPackagePins`), served only
through the disposable `[try-omarchy-abi-pins]` builder repository, and must not
appear in the finished guest's pacman configuration. The guest holds matching
runtime packages on `IgnorePkg` instead.
