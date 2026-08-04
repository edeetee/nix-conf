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
    # Prevent ZeroTier interfaces from causing hostname conflicts.
    # Otherwise Avahi sees the same hostname on both wlp5s0 and zt* interfaces
    # and renames itself to homeserver-edt-2, breaking mDNS resolution.
    denyInterfaces = [ "zt*" ];
    publish.enable = true;
    publish.userServices = true;
    publish.addresses = true;
    publish.domain = true;
    publish.workstation = true;
    nssmdns4 = true;
    nssmdns6 = true;
    openFirewall = true;
  };

  services.zerotierone = {
    enable = true;
    joinNetworks = [ "56374ac9a48a755c" ];
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  programs.nix-ld.enable = true;
}
