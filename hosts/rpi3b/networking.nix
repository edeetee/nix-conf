# Networking for rpi3b — ZeroTier-first, same as the homeserver
#
# The Pi is reachable via its ZeroTier IP on the `smart-access-rds` network
# (1c33c1ced0f6e11c — the same network this Mac joins). Join the node in the
# ZeroTier web UI after first boot, then it's reachable from anywhere.
#
# No avahi/mDNS here (unlike the homeserver): the Pi is a headless thin
# client reached by ZT IP, and skipping mDNS keeps it lean.

{ config, pkgs, ... }:
{
  networking = {
    hostName = "rpi3b";
    # For WiFi (2.4GHz). If wired via the 10/100 ethernet, still fine.
    networkmanager.enable = true;
    # Home-lab box on a private ZeroTier net, mirroring the homeserver.
    firewall.enable = false;
  };

  services.zerotierone = {
    enable = true;
    joinNetworks = [ "1c33c1ced0f6e11c" ]; # smart-access-rds
  };

  services.openssh = {
    enable = true;
    settings = {
      # Password auth ON for bootstrap (the stock ARM image starts with an
      # empty root password; after first login, copy your key and set this
      # to false like the homeserver does).
      PasswordAuthentication = true;
    };
  };
}
