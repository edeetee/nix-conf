# Services for homeserver-edt
# Cockpit, Transmission, Homepage dashboard, nginx reverse proxy
#
# Jellyfin used to live here too; it was retired with the whole TV client stack
# in favour of Kodi reading /mnt/hdd directly (plans/kodi-tv.md).
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

  services.transmission = {
    enable = true;
    package = pkgs.transmission_4;
    settings = {
      download-dir = "/mnt/hdd/downloads";
      incomplete-dir-enabled = false;
      rename-partial-files = false;
      rpc-whitelist-enabled = false;
      rpc-host-whitelist-enabled = false;
      rpc-port = 9091;
      rpc-bind-address = "0.0.0.0";
    };
  };

  # Allow transmission daemon to write to downloads dir (owned by edeetee:users)
  users.users.transmission.extraGroups = [ "users" ];

  # Transmission runs sandboxed with PrivateMounts= + BindPaths= pointing at
  # `download-dir`. If /mnt/hdd isn't mounted yet when the service starts, the
  # bind mount captures the empty directory on the root filesystem, and all
  # downloads silently vanish (written to a hidden dir beneath the later mount).
  # Make the service wait until the filesystem backing download-dir is mounted.
  systemd.services.transmission.unitConfig.RequiresMountsFor = "/mnt/hdd/downloads";


  systemd.tmpfiles.rules = [
    "d /mnt/hdd/downloads 0777 edeetee users -"
    "d /mnt/hdd/downloads/.incomplete 0777 edeetee users -"

    # Kodi's library trees (plans/kodi-tv.md). Two roots, because Kodi cannot
    # scrape one directory as both Movies and TV shows, and /mnt/hdd/downloads
    # is a mix of film folders, loose episodes and season folders.
    #
    # Owned by edeetee for a measured reason: /mnt/hdd/media was root:169, a gid
    # that no longer exists in the group database, so no user could write there
    # and every hardlink import failed with EACCES. `d` also corrects the
    # ownership of the existing empty directories, which is the point here.
    #
    # Deliberately NOT /mnt/hdd/media itself: that is shared with transmission
    # (`torrents/`) and `.state/` — see the AGENTS.md warning about tmpfiles
    # rules taking ownership of shared mounts.
    "d /mnt/hdd/media/library 0775 edeetee users -"
    "d /mnt/hdd/media/library/movies 0775 edeetee users -"
    "d /mnt/hdd/media/library/shows 0775 edeetee users -"
  ];

  services.homepage-dashboard = {
    enable = true;
    listenPort = 8082;
    openFirewall = true;
    services = [
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

  # Store size is bounded by the generation cutoff, not by the GC schedule. This box is
  # rebuilt several times a day, so `--delete-older-than 30d` kept 38 system generations
  # and grew /nix/store to 67G.
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 1d";
  };
  nix.optimise.automatic = true;
  nix.settings = {
    # Hardlink identical files as they are added, rather than only in the weekly pass:
    # successive generations of the same package then share one copy on disk.
    auto-optimise-store = true;
    # Safety net for the small (182G) disk: let the daemon GC dead paths itself when free
    # space drops under min-free, and keep trimming until max-free is reached. Only
    # unreachable paths are removed, so nothing in the current or kept generations goes.
    min-free = "8G";
    max-free = "24G";
  };
}
