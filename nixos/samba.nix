{
  config,
  pkgs,
  lib,
  ...
}:
{
  users.users.render = {
    isNormalUser = true;
    group = "render";
    extraGroups = [
      "video"
      "networkmanager"
      "gdm"
      "wheel"
    ];
    packages = with pkgs; [ ];
  };

  users.groups.render = { };

  services.samba-wsdd = {
    # make shares visible for Windows clients
    enable = true;
    # openFirewall = true;
  };

  services.samba = {
    enable = true;

    nmbd.enable = false;

    settings = {
      global = {
        "workgroup" = "WORKGROUP";
        "server string" = "smbnix";
        "security" = "user";
        "guest account" = "render";
        "map to guest" = "bad user";

        # Performance
        "socket options" = "TCP_NODELAY SO_SNDBUF=131072 SO_RCVBUF=131072";
        "use sendfile" = "yes";
        "min receivefile size" = 16384;
        "aio read size" = 16384;
        "aio write size" = 16384;
      };

      public = {
        path = "/mnt/render";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "yes";
        "create mask" = "0666";
        "directory mask" = "0777";
        "force user" = "render";
        "force group" = "render";
      };
      optiphonic = {
        path = "/mnt/OPTIPHONIC/";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "create mask" = "0644";
        "directory mask" = "0755";
        "force user" = "edeetee";
        "force group" = "edeetee";
      };
      edeetee = {
        path = "/home/edeetee";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "create mask" = "0644";
        "directory mask" = "0755";
        "force user" = "edeetee";
        "force group" = "wheel";
      };
      windows = {
        path = "/mnt/windows";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "create mask" = "0644";
        "directory mask" = "0755";
      };
    };
  };
}
