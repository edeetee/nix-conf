# homeserver-edt: NixOS server entrypoint
#
# Imports all host-specific modules. Shared modules (common, nixvim, etc.)
# are imported by the flake so they apply to all machines.

{
  imports = [
    ./hardware-configuration.nix
    ./boot.nix
    ./networking.nix
    ./desktop.nix
    ./services.nix
    ./packages.nix
    ../../modules/nixos/steam.nix
    ../../modules/nixos/samba.nix
    ../../modules/nixos/reboot-to-windows.nix
    ../../modules/nixos/amd-gpu.nix
    ../../modules/nixos/check-mounts.nix
    ../../modules/nixos/sops.nix
  ];

  system.stateVersion = "23.11";
}
