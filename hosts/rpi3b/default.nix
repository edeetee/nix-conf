# rpi3b: NixOS configuration for a Raspberry Pi 3B
#
# Role: always-on agent host, reachable over ZeroTier.
# A thin client — 1GB RAM, so deliberately NONE of the shared modules
# (common.nix, nixvim, desktop). The homeserver's commonModules pull in
# docker, go, postgres, a full nixvim config — way too heavy for this box.
#
# (The deepseek agent harness will slot in here as its own module once it
# exists — for now this is just the lean core system.)
#
# This config is BUILT on the homeserver (x86_64 → aarch64-linux via
# qemu-user emulation) and either flashed as an SD image or deployed with
# `nixos-rebuild --target-host`. The Pi never compiles anything itself —
# see install.md for the exact commands.
#
# nixos-hardware's raspberry-pi-3 module (imported from the flake) provides
# everything Pi-specific: bootloader, kernel, firmware, overlays. That's why
# there's no hardware-configuration.nix here.

{
  imports = [
    ./hardware-configuration.nix
    ./networking.nix
    ./services.nix
    ./packages.nix
  ];

  # WiFi/BT firmware for the BCM43438 (2.4GHz only on the 3B)
  hardware.enableRedistributableFirmware = true;

  # 1GB RAM: swap into compressed RAM rather than wearing the SD card
  zramSwap.enable = true;

  system.stateVersion = "23.11"; # match the homeserver
}
