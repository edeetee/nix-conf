# homeserver-edt: NixOS server entrypoint
#
# Imports all host-specific modules. Shared modules (common, nixvim, etc.)
# are imported by the flake so they apply to all machines.
#
# unified-remote.nix sits next to packages.nix rather than in modules/nixos/
# because it is one phone remote for one host's mpv, not a reusable feature.

{
  imports = [
    ./hardware-configuration.nix
    ./boot.nix
    ./networking.nix
    ./desktop.nix
    ./tv-session.nix
    ./services.nix
    ./packages.nix
    ./unified-remote.nix
    ./home.nix
    ./mac-share.nix
    ./deploy.nix
    ../../modules/nixos/steam.nix
    ../../modules/nixos/samba.nix
    ../../modules/nixos/reboot-to-windows.nix
    ../../modules/nixos/amd-gpu.nix
    ../../modules/nixos/airplay.nix
    ../../modules/nixos/check-mounts.nix
    ../../modules/nixos/sops.nix
    ../../modules/nixos/pi.nix
  ];

  system.stateVersion = "23.11";
}
