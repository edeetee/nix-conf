# Networking configuration for homeserver-edt
{ config, pkgs, ... }:
{
  networking = {
    hostName = "homeserver-edt";
    networkmanager.enable = true;
    nameservers = [
      "1.1.1.1"
      "8.8.8.8"
    ];
    firewall = {
      enable = false;
      allowedUDPPorts = [ 9 ];
    };
  };

  services.avahi = {
    enable = true;
    # IPv6 privacy-extension (SLAAC temp) address rotation on wlp5s0 causes
    # Avahi to re-probe the hostname and falsely detect a "host name conflict",
    # renaming homeserver-edt.local -> homeserver-edt-2.local and breaking mDNS.
    # (Same class of bug as the ZeroTier reflection issue in fa8a598.)
    # The server is reached via IPv4 everywhere, so disable IPv6 mDNS entirely.
    ipv6 = false;
    publish.enable = true;
    publish.userServices = true;
    publish.addresses = true;
    publish.domain = true;
    publish.workstation = true;
    nssmdns4 = true;
    nssmdns6 = true;
    openFirewall = true;
  };

  # services.zerotierone = {
  #   enable = true;
  #   joinNetworks = [ "56374ac9a48a755c" ];
  # };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  programs.nix-ld.enable = true;
}
