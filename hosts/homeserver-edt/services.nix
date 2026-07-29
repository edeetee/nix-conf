# Services for homeserver-edt
# Cockpit, Jellyfin, Transmission, Homepage dashboard, nginx reverse proxy
{ config, pkgs, lib, ... }:
let
  host = "${config.networking.hostName}.local";
in
{
  services.flatpak.enable = true;

  nix.settings.experimental-features = "nix-command flakes";

  services.cockpit = {
    enable = true;
    port = 9090;
    settings = {
      WebService = {
        AllowUnencrypted = true;
        Origins = lib.mkForce "http://${host}:* https://${host}:* http://localhost:* https://localhost:*";
      };
    };
  };

  services.jellyfin.enable = true;

  services.transmission = {
    enable = true;
    package = pkgs.transmission_4;
    settings = {
      download-dir = "/mnt/hdd/downloads";
      incomplete-dir = "/mnt/hdd/downloads/.incomplete";
      rpc-whitelist = "127.0.0.1,192.168.*.*";
      rpc-port = 9091;
      rpc-bind-address = "0.0.0.0";
    };
  };

  systemd.tmpfiles.rules = [
    "d /mnt/hdd/downloads 0775 edeetee users -"
    "d /mnt/hdd/downloads/.incomplete 0775 edeetee users -"
  ];

  services.homepage-dashboard = {
    enable = true;
    listenPort = 8082;
    openFirewall = true;
    services = [
      {
        "Media" = [
          {
            "Jellyfin" = {
              icon = "jellyfin.svg";
              href = "http://${host}:8096";
              description = "Media server";
              widget = {
                type = "jellyfin";
                url = "http://127.0.0.1:8096";
              };
            };
          }
        ];
      }
      {
        "System" = [
          {
            "Cockpit" = {
              icon = "cockpit.svg";
              href = "http://${host}:9090";
              description = "Server management";
            };
          }
        ];
      }
      {
        "Downloads" = [
          {
            "Transmission" = {
              icon = "transmission.svg";
              href = "http://${host}:9091";
              description = "Torrent client";
              widget = {
                type = "transmission";
                url = "http://127.0.0.1:9091";
              };
            };
          }
        ];
      }
    ];
    widgets = [
      {
        resources = {
          cpu = true;
          memory = true;
          disk = "/";
        };
      }
      {
        datetime = {
          locale = "en-NZ";
        };
      }
    ];
    bookmarks = [
      {
        "System" = [
          {
            "Cockpit" = [{ abbr = "CP"; href = "http://${host}:9090"; }];
          }
        ];
      }
      {
        "Media" = [
          {
            "Jellyfin" = [{ abbr = "JF"; href = "http://${host}:8096"; }];
          }
        ];
      }
      {
        "Downloads" = [
          {
            "Transmission" = [{ abbr = "TR"; href = "http://${host}:9091"; }];
          }
        ];
      }
    ];
  };

  # Reverse proxy homepage on port 80
  services.nginx = {
    enable = true;
    virtualHosts."_" = {
      listen = [ { addr = "0.0.0.0"; port = 80; } ];
      locations."/" = {
        proxyPass = "http://127.0.0.1:8082";
        proxyWebsockets = true;
      };
    };
  };

  services.udisks2.enable = true;

  nix.optimise.automatic = true;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
}
