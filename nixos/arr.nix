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

    bazarr = {
      enable = true;
      openFirewall = true;
    };
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
