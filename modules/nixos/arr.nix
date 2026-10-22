# nixarr (WIP) — NOT imported by any host.
#
# Stale as of plans/kodi-tv.md: this module's shape is "nixarr brings its own
# Jellyfin", and Jellyfin is retired on this repo's only NixOS media host (Kodi
# reads /mnt/hdd directly). Kept only as an aspiration for the *media directory*
# layout it implies (/mnt/hdd/media, /mnt/hdd/media/.state); if it is ever
# adopted, the Jellyfin half has to be dropped first. Decision D4 in the plan.
{
  config,
  pkgs,
  lib,
  ...
}:
{
  nixarr = {
    enable = true;
    mediaDir = "/mnt/hdd/media";
    stateDir = "/mnt/hdd/media/.state/nixarr";

    jellyfin = {
      enable = true;
      openFirewall = true;
    };

    transmission = {
      enable = true;
    };

    # bazarr = {
    #   enable = true;
    #   openFirewall = true;
    # };
    lidarr = {
      enable = true;
      openFirewall = true;
    };
    prowlarr = {
      enable = true;
      openFirewall = true;
    };
    radarr = {
      enable = true;
      openFirewall = true;
    };
    sonarr = {
      enable = true;
      openFirewall = true;
    };
    jellyseerr = {
      enable = true;
      openFirewall = true;
    };
  };
}
