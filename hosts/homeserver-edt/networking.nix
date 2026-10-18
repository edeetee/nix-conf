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
      # KDE Connect (desktop.nix, kde.nix: the phone's run commands). Declared
      # although the firewall is off, so that KDE Connect does not silently
      # stop working the day it is turned on.
      allowedTCPPortRanges = [
        {
          from = 1714;
          to = 1764;
        }
      ];
      allowedUDPPortRanges = [
        {
          from = 1714;
          to = 1764;
        }
      ];
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

  # IPv6 off, 2026-10-18, "for now". The fault is upstream of this host — the
  # router — not this config, and it was measured rather than assumed:
  #
  #   router fe80::e246:eeff:fe2b:9e20 (global: 2404:440c:170a:ce00:e246:eeff:fe2b:9e20)
  #       ping from this host: 1.4 ms, 0% loss
  #   Mac, same /64 (2404:440c:170a:ce00::/64)
  #       ping from this host: 6 ms, 0% loss
  #   internet 2606:4700:4700::1111 / 2001:4860:4860::8888
  #       ping from this host: 100% packet loss; `curl -6` to api.themoviedb.org hangs
  #   traceroute6 run from the Mac: hop 1 is the router, then `* * *` for every hop
  #
  # So: the prefix is valid and on-link, the default route exists (`ip -6 route`
  # → `default via fe80::e246:eeff:fe2b:9e20 dev wlp5s0 proto ra`), the router
  # answers pings, and *two* machines on the LAN agree that nothing past the
  # router is reachable. That points at the router or the ISP: most likely the
  # WAN side has no IPv6 address / no working prefix delegation, so the router
  # advertises a prefix it cannot route anywhere. Things to check there before
  # suspecting this file: whether the router's WAN interface holds an IPv6
  # address, whether IPv6 is enabled on the ISP plan (on-link RA keeps working
  # even when upstream is dead, which is exactly what makes this confusing), and
  # whether its firewall drops outbound ICMPv6 (that alone would not stop TCP).
  #
  # Meanwhile it is expensive here: this host resolves AAAA first, so jellyfin
  # spent the full 100 s HttpClient timeout on *every* TMDb lookup (one `Error
  # while performing a library operation` per 100 s in its journal; a scan ran 46
  # minutes and was cancelled). With IPv6 off those connects fail immediately and
  # .NET falls back to IPv4, where the same request answers in 0.6 s.
  #
  # `networking.enableIPv6 = false` is what nixpkgs uses for this: it sets
  # `net.ipv6.conf.{all,default}.disable_ipv6`. `all` also covers loopback,
  # which is why `lo` is re-enabled below — that keeps anything binding `::1`
  # (node, .NET, dev servers) working. sysctl keys are applied in sorted order,
  # so all/default land first and the `lo` override after them.
  #
  # Applies on `nixos-rebuild switch` (no reboot). A *real* disable instead of a
  # sysctl would be `boot.kernelParams = [ "ipv6.disable=1" ]`, which does need
  # one. Delete both lines once the router's IPv6 actually works.
  #
  # Known consequence: the cifs mount of the Mac was established over a global
  # 2404:-address (see `findmnt /mnt/mac`), so that session dies with IPv6 and
  # has to be re-established over IPv4 — the automount does it by itself after
  # its 300 s idle timeout, or `systemctl restart mnt-mac.automount` forces it.
  networking.enableIPv6 = false;
  boot.kernel.sysctl."net.ipv6.conf.lo.disable_ipv6" = 0;
}
